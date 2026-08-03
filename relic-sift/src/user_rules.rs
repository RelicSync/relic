//! User-defined global tagging rules — the bridge between sift's automatic
//! tags and the user's own vocabulary. A rule file at
//! `<model_dir>/user-rules.json` maps regexes to tags (and optionally a
//! category vote), and applies to *every* text the pipeline sees: string
//! items, extracted document text, and OCR output. This is how "anything
//! mentioning ACME is tagged `work`" happens automatically, while one-off
//! tags stay in the app's `user_tags` field, untouched by sift.
//!
//! Rule tags are normalized like every other tag (lowercase, one FTS token)
//! and land in `relic_tags` with provenance `user-rule:<name>`.

use std::path::{Path, PathBuf};

use regex::Regex;
use serde::Deserialize;

use crate::record::{Stage, Vote};
use crate::taxonomy::{normalize_tag, Taxonomy};

/// User category votes are capped just below the deterministic-win gate
/// (0.95): a rule can dominate ranking but never silently bypass fusion.
const USER_RULE_CAP: f32 = 0.94;

#[derive(Debug, Deserialize)]
struct RuleFile {
    #[serde(default)]
    rules: Vec<RawRule>,
}

#[derive(Debug, Deserialize)]
struct RawRule {
    name: String,
    /// Rust regex, matched anywhere in the item's text (case-sensitive
    /// unless the pattern opts into `(?i)`).
    #[serde(rename = "match")]
    pattern: String,
    #[serde(default)]
    tags: Vec<String>,
    /// Optional taxonomy category this rule votes for.
    #[serde(default)]
    category: Option<String>,
    #[serde(default = "default_confidence")]
    confidence: f32,
}

fn default_confidence() -> f32 {
    0.8
}

#[derive(Debug)]
pub struct CompiledRule {
    pub name: String,
    re: Regex,
    pub tags: Vec<String>,
    pub category: Option<String>,
    pub confidence: f32,
}

#[derive(Debug, Default)]
pub struct UserRules {
    pub rules: Vec<CompiledRule>,
}

impl UserRules {
    pub fn path(model_dir: &Path) -> PathBuf {
        model_dir.join("user-rules.json")
    }

    /// Load and compile rules; problems become warnings, never failures —
    /// a broken rule file must not take classification down.
    pub fn load(model_dir: &Path, taxonomy: &Taxonomy) -> (UserRules, Vec<String>) {
        let path = Self::path(model_dir);
        let mut warnings = Vec::new();
        let Ok(raw) = std::fs::read_to_string(&path) else {
            return (UserRules::default(), warnings);
        };
        let parsed: RuleFile = match serde_json::from_str(&raw) {
            Ok(p) => p,
            Err(e) => {
                warnings.push(format!("user-rules.json ignored: {e}"));
                return (UserRules::default(), warnings);
            }
        };
        let mut rules = Vec::new();
        for r in parsed.rules {
            if r.pattern.len() > 1024 {
                warnings.push(format!("user rule '{}' ignored: pattern too long", r.name));
                continue;
            }
            let re = match Regex::new(&r.pattern) {
                Ok(re) => re,
                Err(e) => {
                    warnings.push(format!("user rule '{}' ignored: {e}", r.name));
                    continue;
                }
            };
            let mut category = r.category;
            if let Some(c) = &category {
                if taxonomy.category(c).is_none() {
                    warnings.push(format!(
                        "user rule '{}': unknown category '{c}' dropped (tags kept)",
                        r.name
                    ));
                    category = None;
                }
            }
            let tags: Vec<String> =
                r.tags.iter().map(|t| normalize_tag(t)).filter(|t| !t.is_empty()).collect();
            if tags.is_empty() && category.is_none() {
                warnings.push(format!("user rule '{}' ignored: no tags or category", r.name));
                continue;
            }
            rules.push(CompiledRule {
                name: r.name,
                re,
                tags,
                category,
                confidence: r.confidence.clamp(0.0, USER_RULE_CAP),
            });
        }
        (UserRules { rules }, warnings)
    }

    /// Apply all rules to a text. Returns (tags to add, category votes).
    pub fn apply(&self, text: &str) -> (Vec<String>, Vec<Vote>) {
        let mut tags = Vec::new();
        let mut votes = Vec::new();
        for rule in &self.rules {
            if !rule.re.is_match(text) {
                continue;
            }
            for t in &rule.tags {
                if !tags.contains(t) {
                    tags.push(t.clone());
                }
            }
            if let Some(cat) = &rule.category {
                votes.push(Vote::new(
                    cat,
                    rule.confidence,
                    Stage::AText,
                    &format!("user-rule:{}", rule.name),
                ));
            }
        }
        (tags, votes)
    }

    pub const SAMPLE: &'static str = r#"{
  "_doc": "sift user tagging rules. Each rule: name, match (Rust regex, applied to any text the pipeline sees - strings, document text, OCR output), tags (added to relic_tags, normalized to lowercase single FTS tokens), optional category (taxonomy id to vote for) and confidence (0..0.94). Edit and re-run; rules reload per invocation.",
  "rules": [
    { "name": "work-acme", "match": "(?i)\\bacme\\b", "tags": ["work"] },
    { "name": "jira-ticket", "match": "\\b[A-Z]{2,10}-\\d{1,6}\\b", "tags": ["jira", "work"] },
    { "name": "home-renovation", "match": "(?i)contractor|drywall|permit\\s+#", "tags": ["renovation"] }
  ]
}
"#;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load_from(json: &str) -> (UserRules, Vec<String>) {
        use std::sync::atomic::{AtomicU32, Ordering};
        static N: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "sift-rules-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(UserRules::path(&dir), json).unwrap();
        UserRules::load(&dir, &Taxonomy::embedded())
    }

    #[test]
    fn sample_parses_and_applies() {
        let (rules, warnings) = load_from(UserRules::SAMPLE);
        assert!(warnings.is_empty(), "{warnings:?}");
        assert_eq!(rules.rules.len(), 3);
        let (tags, votes) = rules.apply("ping me about the ACME renewal, ref PROJ-1432");
        assert!(tags.contains(&"work".to_string()));
        assert!(tags.contains(&"jira".to_string()));
        assert!(votes.is_empty());
        let (tags, _) = rules.apply("nothing relevant here");
        assert!(tags.is_empty());
    }

    #[test]
    fn bad_rules_warn_and_are_skipped() {
        let (rules, warnings) = load_from(
            r#"{"rules": [
                {"name": "broken", "match": "([", "tags": ["x"]},
                {"name": "badcat", "match": "ok", "tags": ["kept"], "category": "no_such_category"},
                {"name": "empty", "match": "ok", "tags": []}
            ]}"#,
        );
        assert_eq!(rules.rules.len(), 1, "{warnings:?}");
        assert_eq!(warnings.len(), 3);
        let (tags, votes) = rules.apply("ok then");
        assert_eq!(tags, vec!["kept"]);
        assert!(votes.is_empty()); // bad category dropped
    }

    #[test]
    fn category_votes_are_capped_below_rule_wins() {
        let (rules, _) = load_from(
            r#"{"rules": [{"name": "force", "match": "INVOICE", "tags": [], "category": "structured_data", "confidence": 0.99}]}"#,
        );
        let (_, votes) = rules.apply("INVOICE #42");
        assert!((votes[0].score - 0.94).abs() < 1e-6);
    }

    #[test]
    fn tags_are_normalized() {
        let (rules, _) = load_from(
            r#"{"rules": [{"name": "n", "match": "x", "tags": ["Tax Docs 2026", "WORK:travel"]}]}"#,
        );
        let (tags, _) = rules.apply("x");
        assert_eq!(tags, vec!["tax-docs-2026", "work-travel"]);
    }
}
