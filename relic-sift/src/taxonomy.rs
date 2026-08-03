//! Versioned, extensible category schema (spec §3). The default taxonomy is
//! embedded in the binary; a user taxonomy at `<model_dir>/taxonomy.json`
//! overrides it (add a category = append an entry + prompts/prototypes).

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

pub const EMBEDDED_TAXONOMY: &str = include_str!("../taxonomy.json");

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Modality {
    Text,
    Image,
    File,
    Any,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Category {
    pub id: String,
    pub modality: Modality,
    /// Per-category confidence floor (spec §7.2). Below it → escalation.
    pub threshold: f32,
    /// Tags the ingest layer writes into `Relic.tags` for this category.
    #[serde(default)]
    pub relic_tags: Vec<String>,
    /// Zero-shot label strings for the CLIP image classifier (spec §6.2).
    #[serde(default)]
    pub clip_prompts: Vec<String>,
    /// Example texts embedded once to form this class's centroid (spec §6.1).
    #[serde(default)]
    pub prototypes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Label {
    pub id: String,
    #[serde(default)]
    pub relic_tags: Vec<String>,
}

/// One multi-label image content tag: applied when its best prompt beats the
/// background prompts by the bank's margin (orthogonal to the category).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageTag {
    pub id: String,
    pub prompts: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageTagBank {
    /// Binary-softmax probability a tag needs against the background.
    pub threshold: f32,
    /// Divisor applied to CLIP logits before the binary softmax (CLIP's
    /// logit_scale ≈ 100 is far too sharp for tag-vs-background margins).
    #[serde(default = "default_tag_temp")]
    pub temperature: f32,
    pub background_prompts: Vec<String>,
    pub tags: Vec<ImageTag>,
}

fn default_tag_temp() -> f32 {
    10.0
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Taxonomy {
    pub version: String,
    #[serde(default)]
    pub notes: String,
    pub categories: Vec<Category>,
    #[serde(default)]
    pub labels: Vec<Label>,
    #[serde(default)]
    pub image_tags: Option<ImageTagBank>,
}

impl Taxonomy {
    pub fn embedded() -> Taxonomy {
        serde_json::from_str(EMBEDDED_TAXONOMY).expect("embedded taxonomy.json is valid")
    }

    /// Load `<model_dir>/taxonomy.json` if present, else the embedded default.
    pub fn load(model_dir: &Path) -> Taxonomy {
        let user = model_dir.join("taxonomy.json");
        if let Ok(s) = std::fs::read_to_string(&user) {
            match serde_json::from_str(&s) {
                Ok(t) => return t,
                Err(e) => eprintln!("warning: ignoring invalid {}: {e}", user.display()),
            }
        }
        Taxonomy::embedded()
    }

    pub fn category(&self, id: &str) -> Option<&Category> {
        self.categories.iter().find(|c| c.id == id)
    }

    pub fn threshold(&self, id: &str) -> f32 {
        self.category(id).map(|c| c.threshold).unwrap_or(0.5)
    }

    pub fn relic_tags_for_category(&self, id: &str) -> &[String] {
        self.category(id).map(|c| c.relic_tags.as_slice()).unwrap_or(&[])
    }

    pub fn relic_tags_for_label(&self, id: &str) -> &[String] {
        self.labels
            .iter()
            .find(|l| l.id == id)
            .map(|l| l.relic_tags.as_slice())
            .unwrap_or(&[])
    }

    /// Text categories that have prototypes — i.e. what the Stage-B text head
    /// can vote for.
    pub fn text_head_categories(&self) -> Vec<&Category> {
        self.categories
            .iter()
            .filter(|c| c.modality == Modality::Text && !c.prototypes.is_empty())
            .collect()
    }

    /// Image categories with CLIP prompts — what zero-shot can vote for.
    pub fn clip_categories(&self) -> Vec<&Category> {
        self.categories
            .iter()
            .filter(|c| c.modality == Modality::Image && !c.clip_prompts.is_empty())
            .collect()
    }

    /// Stable fingerprint of the parts that feed the text head, used to
    /// invalidate the cached centroids when prototypes change.
    pub fn head_fingerprint(&self) -> String {
        let mut h = blake3::Hasher::new();
        for c in self.text_head_categories() {
            h.update(c.id.as_bytes());
            for p in &c.prototypes {
                h.update(p.as_bytes());
            }
        }
        h.finalize().to_hex().to_string()
    }
}

/// Map a fused result (primary category + labels + structural tags) to the
/// final `Relic.tags` value. Structural tags come first (they match
/// relic-core's deterministic `detect_tags` vocabulary), then category tags,
/// then label tags — deduplicated, order stable.
pub fn relic_tags(
    taxonomy: &Taxonomy,
    structural: &[String],
    primary: &str,
    labels: &[String],
) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut push = |t: &str| {
        if !out.iter().any(|x| x == t) {
            out.push(t.to_string());
        }
    };
    for t in structural {
        push(t);
    }
    for t in taxonomy.relic_tags_for_category(primary) {
        push(t);
    }
    for l in labels {
        for t in taxonomy.relic_tags_for_label(l) {
            push(t);
        }
    }
    out
}

/// Per-category thresholds as a map (handy for fusion).
pub fn thresholds(taxonomy: &Taxonomy) -> BTreeMap<String, f32> {
    taxonomy.categories.iter().map(|c| (c.id.clone(), c.threshold)).collect()
}

/// Normalize a tag so it is exactly one FTS5 token under relic-core's
/// tokenizer (`unicode61 … tokenchars '-_.'`) and can't collide with query
/// syntax: lowercase, whitespace/colons → `-`, anything outside
/// `[a-z0-9-_.]` dropped, repeats collapsed. Applied to every emitted tag
/// (taxonomy, structural, user rules) so `tags:<tag>` always works as typed.
pub fn normalize_tag(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut last_dash = false;
    for c in raw.trim().chars() {
        let c = match c {
            c if c.is_ascii_alphanumeric() => c.to_ascii_lowercase(),
            '-' | '_' | '.' => c,
            ' ' | '\t' | ':' | '/' => '-',
            _ => continue,
        };
        if c == '-' && (last_dash || out.is_empty()) {
            continue;
        }
        last_dash = c == '-';
        out.push(c);
    }
    while out.ends_with(['-', '.']) {
        out.pop();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_taxonomy_parses_and_has_seed_categories() {
        let t = Taxonomy::embedded();
        for id in [
            "api_key",
            "secret_other",
            "url",
            "email_body",
            "chat_message",
            "code",
            "log_line",
            "note_prose",
            "structured_data",
            "screenshot",
            "photo",
            "document_scan",
            "receipt",
            "diagram",
            "meme",
            "file_pdf",
            "file_binary",
            "unsorted",
        ] {
            assert!(t.category(id).is_some(), "missing category {id}");
        }
        assert!(t.labels.iter().any(|l| l.id == "pii_present"));
        // every image category must have CLIP prompts, every B-text category prototypes
        for c in t.clip_categories() {
            assert!(!c.clip_prompts.is_empty(), "{} has no clip prompts", c.id);
        }
        assert!(t.text_head_categories().len() >= 5);
    }

    #[test]
    fn v12_categories_and_image_tags_present() {
        let t = Taxonomy::embedded();
        for id in ["tracking_number", "otp_code", "address", "todo_list"] {
            assert!(t.category(id).is_some(), "missing {id}");
        }
        let bank = t.image_tags.as_ref().expect("image_tags bank");
        assert!(!bank.background_prompts.is_empty());
        assert!(bank.tags.iter().any(|x| x.id == "animal"));
        assert!(bank.tags.iter().any(|x| x.id == "qrcode"));
    }

    #[test]
    fn every_emitted_tag_is_already_normalized() {
        let t = Taxonomy::embedded();
        for c in &t.categories {
            for tag in &c.relic_tags {
                assert_eq!(&normalize_tag(tag), tag, "category {} tag {tag}", c.id);
            }
        }
        for l in &t.labels {
            for tag in &l.relic_tags {
                assert_eq!(&normalize_tag(tag), tag, "label {} tag {tag}", l.id);
            }
        }
        if let Some(bank) = &t.image_tags {
            for x in &bank.tags {
                assert_eq!(&normalize_tag(&x.id), &x.id, "image tag {}", x.id);
            }
        }
    }

    #[test]
    fn normalize_tag_table() {
        assert_eq!(normalize_tag("Email Body"), "email-body");
        assert_eq!(normalize_tag("lang:python"), "lang-python");
        assert_eq!(normalize_tag("  Work / ACME  "), "work-acme");
        assert_eq!(normalize_tag("v1.2.3"), "v1.2.3");
        assert_eq!(normalize_tag("héllo wörld"), "hllo-wrld");
        assert_eq!(normalize_tag("---"), "");
    }

    #[test]
    fn relic_tag_mapping_dedups_and_keeps_order() {
        let t = Taxonomy::embedded();
        let tags = relic_tags(
            &t,
            &["url".to_string(), "code".to_string()],
            "code",
            &["pii_present".to_string()],
        );
        // pii_present is a label/flag only — it no longer emits a `pii` tag.
        assert_eq!(tags, vec!["url", "code"]);
    }
}
