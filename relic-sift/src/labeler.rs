//! Open-vocabulary labeling: a human-readable **title** plus free-form topical
//! **tags** for any captured item, text or image.
//!
//! This is the layer the closed taxonomy structurally cannot provide. Stage B's
//! centroid head answers "which of these 8 buckets", which it does near
//! perfectly and which is worth keeping — but no classifier can emit a string
//! that isn't already in `taxonomy.json`, and 74.3% of a real vault carries no
//! subject tag at all (docs/phase0-vault-eval-2026-07.md). Titles and open tags
//! are what close that gap, and the FTS `named` column weights them at bm25 14,
//! the strongest retrieval signal we have.
//!
//! The prompts and post-processing here are **exactly** the ones the Phase 0
//! vault eval measured (`relic-sift-next/harness/label_qwen35.py` v2 and
//! `caption_qwen35.py`). Changing a word invalidates those numbers, so don't
//! tune them casually — re-run the eval instead.

use std::path::Path;

use crate::stage_b::qwen35::{self, Primed, Qwen35, DEFAULT_MAX_PIXELS};

/// Text labeling prompt (harness v2). Tight and example-driven: tiny models
/// follow demonstrated patterns far better than described rules.
///
/// v1 also asked for an `entities` array. That turned out to be the weak layer
/// — it dumped code tokens as "entities" and on one wifi-password clip emitted
/// the password itself — so v2 drops the field entirely. The last two
/// demonstrations target v1's observed failures: a config file (v1 described
/// the *value* of a system prompt instead of the file) and a code snippet (v1
/// tagged a vector-embedding function "database, query").
pub const TEXT_SYSTEM: &str = r#"You label saved clipboard items for a personal search tool.

Reply with ONLY a JSON object, no other text:
{"title": "<max 8 words, what this item IS>", "tags": ["<exactly 3 lowercase topic words, all different>"]}

Rules:
- The title names the item. Never copy the item verbatim, never repeat a tag.
- Tags are subjects a person would search for, never formats. Use "aws", "billing", "recipe". Never use "text", "data", "json", "code", "note".
- For a config or settings file, say what it configures, not what its values say.

Example item:
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_REGION=us-west-2
Example reply:
{"title": "AWS access key for us-west-2", "tags": ["aws", "credentials", "infrastructure"]}

Example item:
Sarah: did you push the fix for the login bug?
Me: yeah it's on the android-lens branch, deploying now
Example reply:
{"title": "Chat about deploying the login bug fix", "tags": ["engineering", "deployment", "bugfix"]}

Example item:
{"model": "gpt-4", "max_tokens": 2048, "system": "You are a travel agent."}
Example reply:
{"title": "API settings for a travel agent bot", "tags": ["api", "configuration", "llm"]}

Example item:
def cosine(a, b): return dot(a, b) / (norm(a) * norm(b))
Example reply:
{"title": "Cosine similarity helper function", "tags": ["math", "vectors", "python"]}"#;

/// Image labeling prompt. The "never describe a person's identity or
/// appearance" rule is a product constraint, not a quality one.
pub const IMAGE_SYSTEM: &str = r#"You label saved screenshots and photos for a personal search tool.

Reply with ONLY a JSON object, no other text:
{"title": "<max 8 words, what this image shows>", "tags": ["<exactly 3 lowercase topic words, all different>"]}

Rules:
- The title says what the image is of. Be specific about the subject.
- Tags are subjects a person would search for, never formats. Use "coffee", "invoice", "mountains". Never use "image", "photo", "picture", "screenshot".
- Never describe a person's identity or appearance."#;

pub const IMAGE_USER: &str = "Label this image.";

/// Body cap before labeling. The model only needs enough to say what the thing
/// *is*; feeding a 50 KB clip would cost seconds of prefill for no extra signal.
pub const MAX_BODY_CHARS: usize = 2000;

/// Decode budgets, matching the Phase 0 eval. A title plus three tags is ~30
/// tokens; the headroom is for the model's occasional preamble.
const TEXT_MAX_NEW: usize = 60;
const IMAGE_MAX_NEW: usize = 48;

/// Format words the model was told to avoid but sometimes emits anyway. These
/// are worthless as tags — every item is "data" of some kind — and they are
/// exactly the noise that made the old taxonomy's output feel useless.
const BANNED: &[&str] = &[
    "text", "data", "json", "csv", "code", "note", "file", "string", "document", "info",
    "information", "misc", "other", "clip",
];

/// Cap on emitted tags. The prompt asks for 3; this is the hard ceiling for
/// when it ignores that.
const MAX_TAGS: usize = 6;

/// One item's label.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Label {
    pub title: String,
    pub tags: Vec<String>,
}

/// Post-process raw model JSON the way anything writing to the DB must: dedupe
/// case-blind, drop the format words, cap the count, and enforce the tag-shape
/// contract from docs/sift-integration.md (lowercase, no spaces).
pub fn normalize(v: &serde_json::Value) -> Option<Label> {
    let mut seen: Vec<String> = Vec::new();
    let mut tags: Vec<String> = Vec::new();
    if let Some(arr) = v.get("tags").and_then(|t| t.as_array()) {
        for t in arr {
            let Some(t) = t.as_str() else { continue };
            let t = t.trim().to_lowercase().replace(' ', "-");
            let bare: String = t.chars().filter(|&c| c != '-').collect();
            if t.is_empty()
                || seen.contains(&t)
                || BANNED.contains(&t.as_str())
                || bare.is_empty()
                || !bare.chars().all(char::is_alphanumeric)
            {
                continue;
            }
            seen.push(t.clone());
            tags.push(t);
        }
    }
    tags.truncate(MAX_TAGS);
    let title = v.get("title").and_then(|t| t.as_str()).unwrap_or("").trim().to_string();
    Some(Label { title, tags })
}

/// Parse a raw completion into a [`Label`]: pull the first balanced JSON object
/// out of whatever prose the model wrapped it in, then normalize.
pub fn normalize_str(completion: &str) -> Option<Label> {
    qwen35::extract_json(completion).as_ref().and_then(normalize)
}

/// The labeler: one Qwen3.5 instance plus a primed state per prompt.
///
/// Priming is why this is a struct and not a function. The system block is ~390
/// tokens and a clipboard item is ~40, so prefilling the shared prefix once and
/// cloning the snapshot per item avoids re-doing an order of magnitude more
/// work than the item itself costs. The text and image prompts differ, so they
/// get separate snapshots, primed lazily — an install that never labels an
/// image never pays for the image prefix.
pub struct Labeler {
    model: Qwen35,
    text_primed: Option<Primed>,
    image_primed: Option<Primed>,
    /// Vision area cap; token count is `max_pixels / 1024` after the 2×2 merge.
    pub max_pixels: u32,
}

impl Labeler {
    /// Load the labeler. `vision` additionally builds the image tower.
    pub fn load(model_dir: &Path, vision: bool) -> Result<Self, String> {
        Ok(Labeler {
            model: Qwen35::load(model_dir, vision)?,
            text_primed: None,
            image_primed: None,
            max_pixels: DEFAULT_MAX_PIXELS,
        })
    }

    pub fn model_version(&self) -> &str {
        &self.model.model_version
    }

    pub fn has_vision(&self) -> bool {
        self.model.has_vision()
    }

    /// Prime a system prompt's prefix, but only if the split is safe.
    ///
    /// BPE can merge across the seam between prefix and body, in which case
    /// encoding the halves separately yields different tokens than encoding the
    /// whole — and the model would then be resumed from a state that doesn't
    /// match what it's being fed. That is a silent wrong-answer bug, so a dirty
    /// seam disables priming rather than risking it.
    fn primed_for(&mut self, system: &str, probe_body: &str) -> Result<Option<Primed>, String> {
        let prefix = Qwen35::prefix(system);
        if !self.model.seam_is_clean(&prefix, probe_body)? {
            return Ok(None);
        }
        Ok(Some(self.model.prime(&prefix)?))
    }

    /// Label a text item. `Ok(None)` means the model produced no parseable JSON.
    pub fn label_text(&mut self, body: &str) -> Result<Option<Label>, String> {
        let body = cap_chars(body, MAX_BODY_CHARS);
        if body.trim().is_empty() {
            return Ok(None);
        }
        if self.text_primed.is_none() {
            self.text_primed = self.primed_for(TEXT_SYSTEM, &body)?;
        }
        let prompt = Qwen35::build_prompt(TEXT_SYSTEM, &body, 0);
        let primed = self.text_primed.clone();
        let g = self.model.generate(&prompt, TEXT_MAX_NEW, primed.as_ref(), None, &[])?;
        Ok(qwen35::extract_json(&g.text).as_ref().and_then(normalize))
    }

    /// Label an image. Requires the vision tower.
    pub fn label_image(&mut self, img: &image::DynamicImage) -> Result<Option<Label>, String> {
        if !self.model.has_vision() {
            return Err("vision tower not loaded".into());
        }
        if self.image_primed.is_none() {
            self.image_primed = self.primed_for(IMAGE_SYSTEM, IMAGE_USER)?;
        }
        let feats = self.model.vision_features(img, self.max_pixels)?;
        let prompt = Qwen35::build_prompt(IMAGE_SYSTEM, IMAGE_USER, feats.n_tokens);
        let primed = self.image_primed.clone();
        let g = self.model.generate(&prompt, IMAGE_MAX_NEW, primed.as_ref(), Some(&feats), &[])?;
        Ok(qwen35::extract_json(&g.text).as_ref().and_then(normalize))
    }

    /// Raw completion for one text item — used by `sift label --raw` to diff
    /// against the Python reference token-for-token.
    pub fn raw_text(&mut self, body: &str) -> Result<qwen35::Generated, String> {
        let body = cap_chars(body, MAX_BODY_CHARS);
        if self.text_primed.is_none() {
            self.text_primed = self.primed_for(TEXT_SYSTEM, &body)?;
        }
        let prompt = Qwen35::build_prompt(TEXT_SYSTEM, &body, 0);
        let primed = self.text_primed.clone();
        self.model.generate(&prompt, TEXT_MAX_NEW, primed.as_ref(), None, &[])
    }
}

/// Truncate on a char boundary (the reference slices a Python str, which is
/// codepoint-indexed; byte-slicing a UTF-8 body would panic mid-character).
fn cap_chars(s: &str, max: usize) -> String {
    match s.char_indices().nth(max) {
        Some((i, _)) => s[..i].to_string(),
        None => s.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn norm(v: serde_json::Value) -> Label {
        normalize(&v).unwrap()
    }

    #[test]
    fn drops_format_words() {
        let l = norm(json!({"title": "t", "tags": ["aws", "json", "data", "billing"]}));
        assert_eq!(l.tags, vec!["aws", "billing"]);
    }

    #[test]
    fn dedupes_case_blind_and_spaces_become_dashes() {
        let l = norm(json!({"title": "t", "tags": ["AWS", "aws", "machine learning"]}));
        assert_eq!(l.tags, vec!["aws", "machine-learning"]);
    }

    #[test]
    fn rejects_punctuation_only_and_symbol_tags() {
        let l = norm(json!({"title": "t", "tags": ["---", "c++", "ok1", ""]}));
        assert_eq!(l.tags, vec!["ok1"]);
    }

    #[test]
    fn caps_tag_count() {
        let l = norm(json!({"title": "t", "tags": ["a","b","c","d","e","f","g","h"]}));
        assert_eq!(l.tags.len(), MAX_TAGS);
    }

    #[test]
    fn tolerates_missing_and_wrongly_typed_fields() {
        let l = norm(json!({"tags": ["a", 3, null, "b"]}));
        assert_eq!(l.title, "");
        assert_eq!(l.tags, vec!["a", "b"]);
        let l = norm(json!({"title": "  spaced  "}));
        assert_eq!(l.title, "spaced");
        assert!(l.tags.is_empty());
    }

    #[test]
    fn body_cap_is_char_safe() {
        // Multi-byte throughout: a byte-slice at MAX_BODY_CHARS would land
        // mid-character and panic.
        let s: String = std::iter::repeat('é').take(MAX_BODY_CHARS + 50).collect();
        assert_eq!(cap_chars(&s, MAX_BODY_CHARS).chars().count(), MAX_BODY_CHARS);
    }

    /// The prompts are the eval's contract; a stray edit silently invalidates
    /// docs/phase0-vault-eval-2026-07.md.
    #[test]
    fn prompts_match_the_evaluated_shape() {
        assert!(TEXT_SYSTEM.contains(r#"{"title": "<max 8 words, what this item IS>""#));
        assert_eq!(TEXT_SYSTEM.matches("Example reply:").count(), 4);
        assert!(IMAGE_SYSTEM.contains("Never describe a person's identity or appearance."));
    }
}
