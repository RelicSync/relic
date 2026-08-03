//! Stage C — fusion, confidence gating & escalation (spec §7).
//!
//! Votes are combined per category with a noisy-OR (rules and models treated
//! as independent evidence). A Stage-A rule at ≥ 0.95 wins outright; an A↔B
//! disagreement lets the model override the weak prior at a 0.9 penalty and
//! flags the item as a training-data candidate. Below the per-category
//! threshold the item escalates; with no VLM present (v0.1) escalation
//! terminates at `unsorted` + `needs_review`.

use std::collections::BTreeMap;

use crate::record::{CategoryResult, Provenance, Stage, Vote};
use crate::taxonomy::Taxonomy;

/// Score at or above which a Stage-A rule is deterministic and wins outright.
pub const RULE_WINS: f32 = 0.95;

pub struct FusionOutcome {
    pub category: CategoryResult,
    pub provenance: Vec<Provenance>,
    /// A↔B disagreement — a labeled-training-data candidate (spec §7.3).
    pub disagreement: bool,
}

pub fn fuse(votes: &[Vote], taxonomy: &Taxonomy) -> FusionOutcome {
    let mut provenance: Vec<Provenance> = votes
        .iter()
        .map(|v| Provenance { stage: v.stage, signal: v.signal.clone(), score: round3(v.score) })
        .collect();

    // 1. noisy-OR per category
    let mut combined: BTreeMap<String, f32> = BTreeMap::new();
    for v in votes {
        let p = combined.entry(v.category.clone()).or_insert(0.0);
        *p = 1.0 - (1.0 - *p) * (1.0 - v.score.clamp(0.0, 1.0));
    }

    if combined.is_empty() {
        provenance.push(Provenance {
            stage: Stage::CFusion,
            signal: "no_votes".into(),
            score: 0.0,
        });
        return FusionOutcome {
            category: CategoryResult {
                primary: "unsorted".into(),
                scores: BTreeMap::new(),
                confidence: 0.0,
                needs_review: true,
            },
            provenance,
            disagreement: false,
        };
    }

    let is_stage_a = |s: Stage| matches!(s, Stage::AText | Stage::AFile | Stage::AImage);
    let is_stage_b = |s: Stage| matches!(s, Stage::BText | Stage::BImage);

    // 2./3. argmax + confidence
    let (mut primary, mut conf) = combined
        .iter()
        .max_by(|a, b| a.1.total_cmp(b.1))
        .map(|(c, s)| (c.clone(), *s))
        .unwrap();

    // 4. deterministic rule wins outright
    let rule_win = votes
        .iter()
        .filter(|v| is_stage_a(v.stage) && v.score >= RULE_WINS)
        .max_by(|a, b| a.score.total_cmp(&b.score));

    let mut disagreement = false;
    if let Some(rule) = rule_win {
        primary = rule.category.clone();
        conf = rule.score;
        provenance.push(Provenance {
            stage: Stage::CFusion,
            signal: format!("deterministic_win:{}", rule.signal),
            score: round3(conf),
        });
    } else {
        // A "prior" is a real Stage-A opinion (≥ 0.4) — fallback floors like
        // `magic:pdf:fallback` (0.35) don't count.
        let a_top = votes
            .iter()
            .filter(|v| is_stage_a(v.stage) && v.score >= 0.4)
            .max_by(|a, b| a.score.total_cmp(&b.score));
        let b_top = votes
            .iter()
            .filter(|v| is_stage_b(v.stage))
            .max_by(|a, b| a.score.total_cmp(&b.score));
        if let (Some(a), Some(b)) = (a_top, b_top) {
            if a.category != b.category {
                disagreement = true;
                if b.score > a.score + 0.15 {
                    // model clearly beats the weak prior → override, penalized
                    primary = b.category.clone();
                    conf = combined[&primary] * 0.9;
                } else {
                    // ambiguous conflict → the deterministic prior holds
                    // (format shape beats semantic guess), small penalty
                    primary = a.category.clone();
                    conf = combined[&primary] * 0.95;
                }
                provenance.push(Provenance {
                    stage: Stage::CFusion,
                    signal: format!("disagreement:a={},b={}->{}", a.category, b.category, primary),
                    score: round3(conf),
                });
            }
        }
    }

    // 5. confidence gate → escalation. v0.1 has no VLM, so the ladder
    // terminates at unsorted + needs_review (spec §7.3 step 2).
    let mut needs_review = false;
    let threshold = taxonomy.threshold(&primary);
    if conf < threshold {
        needs_review = true;
        provenance.push(Provenance {
            stage: Stage::CFusion,
            signal: format!("below_threshold:{primary}<{threshold}"),
            score: round3(conf),
        });
        primary = "unsorted".into();
    }

    let scores: BTreeMap<String, f32> = combined.into_iter().map(|(c, s)| (c, round3(s))).collect();
    FusionOutcome {
        category: CategoryResult { primary, scores, confidence: round3(conf), needs_review },
        provenance,
        disagreement,
    }
}

fn round3(v: f32) -> f32 {
    (v * 1000.0).round() / 1000.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::Vote;

    fn tax() -> Taxonomy {
        Taxonomy::embedded()
    }

    #[test]
    fn deterministic_rule_wins_over_model() {
        let votes = vec![
            Vote::new("api_key", 0.97, Stage::AText, "rule:aws_access_key"),
            Vote::new("note_prose", 0.85, Stage::BText, "head:centroid"),
        ];
        let out = fuse(&votes, &tax());
        assert_eq!(out.category.primary, "api_key");
        assert!((out.category.confidence - 0.97).abs() < 1e-6);
        assert!(!out.category.needs_review);
    }

    #[test]
    fn model_overrides_weak_prior_with_penalty() {
        let votes = vec![
            Vote::new("code", 0.5, Stage::AText, "format:code_density"),
            Vote::new("log_line", 0.8, Stage::BText, "head:centroid"),
        ];
        let out = fuse(&votes, &tax());
        assert_eq!(out.category.primary, "log_line");
        assert!(out.disagreement);
        assert!((out.category.confidence - 0.8 * 0.9).abs() < 0.01);
    }

    #[test]
    fn agreement_combines_with_noisy_or() {
        let votes = vec![
            Vote::new("screenshot", 0.7, Stage::AImage, "no_exif+screen_dims"),
            Vote::new("screenshot", 0.8, Stage::BImage, "clip_zeroshot"),
        ];
        let out = fuse(&votes, &tax());
        assert_eq!(out.category.primary, "screenshot");
        let expect = 1.0 - (1.0 - 0.7) * (1.0 - 0.8);
        assert!((out.category.confidence - expect).abs() < 0.01);
    }

    #[test]
    fn low_confidence_escalates_to_unsorted() {
        let votes = vec![Vote::new("note_prose", 0.2, Stage::AText, "format:markdown")];
        let out = fuse(&votes, &tax());
        assert_eq!(out.category.primary, "unsorted");
        assert!(out.category.needs_review);
        // the score vector still carries the best guess for re-tagging
        assert!(out.category.scores.contains_key("note_prose"));
    }

    #[test]
    fn no_votes_is_unsorted() {
        let out = fuse(&[], &tax());
        assert_eq!(out.category.primary, "unsorted");
        assert!(out.category.needs_review);
    }
}
