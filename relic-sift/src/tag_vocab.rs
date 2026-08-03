//! Bounding the open-vocabulary tag stream.
//!
//! The labeler emits whatever words fit the item, which is the point — but
//! measured on a real vault it is also the problem: **193 items produced 550
//! emissions over 327 distinct tags, 65% of them used exactly once**
//! (`relic-sift-next/results/vault_eval.json`). Coverage was perfect and the
//! vocabulary was useless as a facet, because a facet you see once is not a
//! facet.
//!
//! Two mechanisms, in this order, measured rather than argued
//! (`harness/tag_bound.py`):
//!
//! 1. **Snap** near-duplicates onto one representative using EmbeddingGemma
//!    cosine — the model already loaded in production. This is what makes
//!    "bound it to tags we already have" work without a hand-maintained list:
//!    `deployment`/`deploy`/`deployments` become one facet. A fixed list was
//!    the obvious alternative and it does not work — only 8% of what the model
//!    invents maps onto the existing machine vocabulary at cosine 0.85, so a
//!    whitelist would throw away 92% of the signal.
//! 2. **Recurrence**: a tag becomes a visible facet only once it has been seen
//!    `min_count` times. Below that it is *provisional* — still written to the
//!    item so full-text search finds it, just not rendered as a chip.
//!
//! Thresholds (0.85 / 2 → 119 tags at 94% item coverage, from 327):
//!
//! | cosine | ≥2 vocab | coverage | example merges                       |
//! |--------|----------|----------|--------------------------------------|
//! | 0.85   | 119      | 94%      | development←dev,developer,programming |
//! | 0.80   | 110      | 96%      | development←**project**,dev,developer |
//! | 0.75   | 101      | 98%      | python←**development,script,ai**      |
//!
//! 0.80 buys 2% coverage by folding `project` into `development`, and 0.75 is
//! plainly wrong. So 0.85 — the last threshold whose merges are all synonyms.
//!
//! Everything here is a pure function over explicit inputs: the corpus state
//! lives in the app's vault, not in this crate (spec §9.1 — the pipeline is
//! pure w.r.t. storage), and `sift tags bound` just passes it through.

use std::collections::HashMap;

/// Cosine at or above which two tags are the same facet.
pub const DEFAULT_THRESHOLD: f32 = 0.85;
/// Emissions a tag needs before it becomes a visible facet.
pub const DEFAULT_MIN_COUNT: u32 = 2;

/// A representative tag: the canonical string for its group, its embedding, and
/// how many emissions have folded into it.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Rep {
    pub tag: String,
    #[serde(default)]
    pub count: u32,
    pub vec: Vec<f32>,
}

/// Nearest representative to `v` by cosine, if any. Vectors are L2-normalized
/// by the encoder, so cosine is a plain dot product.
fn nearest<'a>(v: &[f32], reps: &'a [Rep]) -> Option<(&'a str, f32)> {
    reps.iter()
        .map(|r| (r.tag.as_str(), dot(v, &r.vec)))
        .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

/// Fold `emitted` tags into `reps`, extending the vocabulary where nothing is
/// close enough.
///
/// `emitted` carries `(tag, vector, count)`. Ordering is **frequency-first,
/// then alphabetical**, and that is not cosmetic: it makes the corpus's own
/// dominant wording the canonical form instead of whichever string happened to
/// arrive or sort first. A newly created representative is immediately
/// available to later tags in the same batch, so `dev` and `developer` in one
/// batch collapse together even when neither existed before.
///
/// Returns the full `emitted tag → canonical` mapping. `reps` is updated in
/// place: counts accumulate and new representatives are appended.
pub fn absorb(reps: &mut Vec<Rep>, emitted: &[(String, Vec<f32>, u32)]) -> HashMap<String, String> {
    absorb_with(reps, emitted, DEFAULT_THRESHOLD)
}

pub fn absorb_with(
    reps: &mut Vec<Rep>,
    emitted: &[(String, Vec<f32>, u32)],
    threshold: f32,
) -> HashMap<String, String> {
    let mut order: Vec<&(String, Vec<f32>, u32)> = emitted.iter().collect();
    order.sort_by(|a, b| b.2.cmp(&a.2).then_with(|| a.0.cmp(&b.0)));

    let mut mapping = HashMap::new();
    for (tag, vec, count) in order {
        // An exact repeat of an existing representative is not a merge.
        if let Some(r) = reps.iter_mut().find(|r| &r.tag == tag) {
            r.count += count;
            mapping.insert(tag.clone(), tag.clone());
            continue;
        }
        match nearest(vec, reps) {
            Some((rep, score)) if score >= threshold => {
                let rep = rep.to_string();
                if let Some(r) = reps.iter_mut().find(|r| r.tag == rep) {
                    r.count += count;
                }
                mapping.insert(tag.clone(), rep);
            }
            _ => {
                reps.push(Rep { tag: tag.clone(), count: *count, vec: vec.clone() });
                mapping.insert(tag.clone(), tag.clone());
            }
        }
    }
    mapping
}

/// Re-derive the whole grouping from scratch, most-frequent first.
///
/// Needed because [`absorb`] is *online*: it sees tags in arrival order, so an
/// early rare spelling becomes the representative for a group that later
/// settles on different wording. Measured on the vault corpus, feeding the same
/// 550 emissions in 25-item chunks instead of all at once gives 122 visible
/// facets where the batch run gives 119 — same coverage, slightly different
/// grouping. Reconcile collapses that difference.
///
/// **`tags` must be every distinct emitted string with its own count, not just
/// the current representatives.** Given representatives only this is a no-op by
/// construction: a representative exists precisely because nothing was within
/// `threshold` of it, so re-agglomerating that set can never merge anything.
/// The alias rows are what carry the frequency information the reordering needs.
///
/// Returns `emitted string → new canonical` (identity entries included) plus the
/// rebuilt representative set. The caller rewrites stored tags through the
/// mapping.
pub fn reconcile(reps: &[Rep], threshold: f32) -> (HashMap<String, String>, Vec<Rep>) {
    let mut order: Vec<&Rep> = reps.iter().collect();
    order.sort_by(|a, b| b.count.cmp(&a.count).then_with(|| a.tag.cmp(&b.tag)));

    let mut out: Vec<Rep> = Vec::new();
    let mut mapping = HashMap::new();
    for r in order {
        match nearest(&r.vec, &out) {
            Some((rep, score)) if score >= threshold => {
                let rep = rep.to_string();
                if let Some(x) = out.iter_mut().find(|x| x.tag == rep) {
                    x.count += r.count;
                }
                mapping.insert(r.tag.clone(), rep);
            }
            _ => {
                out.push(r.clone());
                mapping.insert(r.tag.clone(), r.tag.clone());
            }
        }
    }
    (mapping, out)
}

/// Representatives that have earned a visible facet chip.
pub fn promoted(reps: &[Rep], min_count: u32) -> Vec<String> {
    let mut v: Vec<String> =
        reps.iter().filter(|r| r.count >= min_count).map(|r| r.tag.clone()).collect();
    v.sort();
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Hand-built unit vectors, so the agglomeration is tested without dragging
    /// a 330 MB encoder into a unit test. `sift tags bound` against the real
    /// vault output is what checks the embedding half.
    fn v(x: f32, y: f32) -> Vec<f32> {
        let n = (x * x + y * y).sqrt().max(1e-9);
        vec![x / n, y / n]
    }

    fn e(tag: &str, x: f32, y: f32, count: u32) -> (String, Vec<f32>, u32) {
        (tag.to_string(), v(x, y), count)
    }

    #[test]
    fn near_duplicates_collapse_onto_one_representative() {
        let mut reps = Vec::new();
        // Three near-identical directions plus one clearly different.
        let m = absorb(
            &mut reps,
            &[
                e("development", 1.0, 0.0, 3),
                e("dev", 1.0, 0.05, 1),
                e("developer", 1.0, 0.10, 1),
                e("coffee", 0.0, 1.0, 1),
            ],
        );
        assert_eq!(m["dev"], "development");
        assert_eq!(m["developer"], "development");
        assert_eq!(m["coffee"], "coffee");
        assert_eq!(reps.len(), 2);
        let dev = reps.iter().find(|r| r.tag == "development").unwrap();
        assert_eq!(dev.count, 5, "all three spellings fold into one count");
    }

    /// The whole reason ordering is by frequency: the dominant wording should
    /// win, not whichever string sorts first. Alphabetically "dev" precedes
    /// "development".
    #[test]
    fn the_most_frequent_spelling_becomes_canonical() {
        let mut reps = Vec::new();
        let m = absorb(&mut reps, &[e("dev", 1.0, 0.05, 1), e("development", 1.0, 0.0, 9)]);
        assert_eq!(m["dev"], "development");
        assert_eq!(reps.len(), 1);
        assert_eq!(reps[0].tag, "development");
    }

    #[test]
    fn distinct_concepts_stay_separate() {
        let mut reps = Vec::new();
        absorb(&mut reps, &[e("roofing", 1.0, 0.0, 1), e("recipe", 0.0, 1.0, 1)]);
        assert_eq!(reps.len(), 2);
    }

    #[test]
    fn a_new_representative_absorbs_later_tags_in_the_same_batch() {
        let mut reps = Vec::new();
        // Neither existed before; they must still end up as one facet.
        let m = absorb(&mut reps, &[e("deploy", 1.0, 0.0, 1), e("deployment", 1.0, 0.05, 1)]);
        assert_eq!(reps.len(), 1);
        assert_eq!(m["deploy"], m["deployment"]);
    }

    #[test]
    fn absorbing_into_an_existing_vocabulary_accumulates_counts() {
        let mut reps = vec![Rep { tag: "aws".into(), count: 4, vec: v(1.0, 0.0) }];
        let m = absorb(&mut reps, &[e("amazon-web-services", 1.0, 0.03, 1)]);
        assert_eq!(m["amazon-web-services"], "aws");
        assert_eq!(reps.len(), 1);
        assert_eq!(reps[0].count, 5);
    }

    /// An exact repeat is a count bump, never a merge candidate — otherwise a
    /// tag could be reassigned away from itself.
    #[test]
    fn exact_repeat_bumps_its_own_count() {
        let mut reps = vec![Rep { tag: "aws".into(), count: 1, vec: v(1.0, 0.0) }];
        let m = absorb(&mut reps, &[e("aws", 1.0, 0.0, 2)]);
        assert_eq!(m["aws"], "aws");
        assert_eq!(reps.len(), 1);
        assert_eq!(reps[0].count, 3);
    }

    #[test]
    fn promotion_needs_recurrence() {
        let reps = vec![
            Rep { tag: "roofing".into(), count: 2, vec: v(1.0, 0.0) },
            Rep { tag: "onceoff".into(), count: 1, vec: v(0.0, 1.0) },
        ];
        assert_eq!(promoted(&reps, DEFAULT_MIN_COUNT), vec!["roofing".to_string()]);
        // min_count 1 is "show everything" — the unbounded behavior.
        assert_eq!(promoted(&reps, 1).len(), 2);
    }

    /// Reconcile fixes what online absorption cannot: `dev` arrived first and
    /// became the representative, but the corpus settled on `development`.
    #[test]
    fn reconcile_renames_to_the_dominant_spelling() {
        let reps = vec![
            Rep { tag: "dev".into(), count: 2, vec: v(1.0, 0.05) },
            Rep { tag: "development".into(), count: 9, vec: v(1.0, 0.0) },
        ];
        let (m, out) = reconcile(&reps, DEFAULT_THRESHOLD);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].tag, "development");
        assert_eq!(out[0].count, 11);
        assert_eq!(m["dev"], "development");
        assert_eq!(m["development"], "development");
    }

    /// The trap that made this API take the full tag set: fed only
    /// representatives, reconcile cannot merge anything, because every
    /// representative exists precisely because nothing was near it. A caller
    /// that stores only representatives gets a silent no-op, not a fix.
    #[test]
    fn reconcile_over_representatives_only_is_a_no_op() {
        // What `absorb` leaves behind: mutually separated reps.
        let mut reps = Vec::new();
        absorb(&mut reps, &[e("dev", 1.0, 0.05, 1), e("coffee", 0.0, 1.0, 3)]);
        let before: Vec<String> = reps.iter().map(|r| r.tag.clone()).collect();
        let (m, out) = reconcile(&reps, DEFAULT_THRESHOLD);
        assert_eq!(out.len(), before.len(), "nothing can merge");
        assert!(m.iter().all(|(k, v)| k == v));

        // Fed the *aliases* too, the dominant spelling can win instead.
        let full = vec![
            Rep { tag: "dev".into(), count: 1, vec: v(1.0, 0.05) },
            Rep { tag: "development".into(), count: 6, vec: v(1.0, 0.0) },
            Rep { tag: "coffee".into(), count: 3, vec: v(0.0, 1.0) },
        ];
        let (m, out) = reconcile(&full, DEFAULT_THRESHOLD);
        assert_eq!(out.len(), 2);
        assert_eq!(m["dev"], "development");
    }

    #[test]
    fn reconcile_is_idempotent() {
        let reps = vec![
            Rep { tag: "development".into(), count: 9, vec: v(1.0, 0.0) },
            Rep { tag: "coffee".into(), count: 3, vec: v(0.0, 1.0) },
        ];
        let (_, once) = reconcile(&reps, DEFAULT_THRESHOLD);
        let (m, twice) = reconcile(&once, DEFAULT_THRESHOLD);
        assert_eq!(once.len(), twice.len());
        assert!(m.iter().all(|(k, v)| k == v), "a settled vocabulary must not move");
    }

    #[test]
    fn threshold_controls_how_aggressively_things_merge() {
        let mk = || vec![e("a", 1.0, 0.0, 2), e("b", 1.0, 0.6, 1)];
        let mut loose = Vec::new();
        absorb_with(&mut loose, &mk(), 0.5);
        assert_eq!(loose.len(), 1, "a loose threshold merges them");
        let mut tight = Vec::new();
        absorb_with(&mut tight, &mk(), 0.99);
        assert_eq!(tight.len(), 2, "a tight threshold keeps them apart");
    }
}
