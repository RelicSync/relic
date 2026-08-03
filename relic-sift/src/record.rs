//! Output contract (spec §9): the pipeline's sole product is a
//! `ClassificationRecord`. The indexer consumes it; sift never touches storage.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub const SCHEMA_VERSION: &str = "sift/0.1";

/// What the caller says the item is (spec §4 `NormalizedItem.source_kind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceKind {
    String,
    Textblob,
    Image,
    File,
}

impl std::fmt::Display for SourceKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            SourceKind::String => "string",
            SourceKind::Textblob => "textblob",
            SourceKind::Image => "image",
            SourceKind::File => "file",
        };
        f.write_str(s)
    }
}

/// Where the item came from. Advisory only; never trusted for routing.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Origin {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

/// Normalized input (spec §4). `bytes` is the original, untouched payload.
#[derive(Debug, Clone)]
pub struct NormalizedItem {
    pub bytes: Vec<u8>,
    pub source_kind: SourceKind,
    pub declared_mime: Option<String>,
    pub origin: Origin,
}

/// Pipeline stage that produced a vote (for provenance).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Stage {
    #[serde(rename = "A-text")]
    AText,
    #[serde(rename = "A-file")]
    AFile,
    #[serde(rename = "A-image")]
    AImage,
    #[serde(rename = "B-text")]
    BText,
    #[serde(rename = "B-image")]
    BImage,
    #[serde(rename = "C-fusion")]
    CFusion,
}

/// One piece of evidence: `(category, score, provenance)` (spec §5/§7).
#[derive(Debug, Clone)]
pub struct Vote {
    pub category: String,
    pub score: f32,
    pub stage: Stage,
    /// e.g. `rule:aws_key`, `clip_zeroshot`, `head:centroid`
    pub signal: String,
}

impl Vote {
    pub fn new(category: &str, score: f32, stage: Stage, signal: &str) -> Self {
        Vote { category: category.into(), score, stage, signal: signal.into() }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Provenance {
    pub stage: Stage,
    pub signal: String,
    pub score: f32,
}

/// Typed PII/secret span. `value_masked` is safe to index; the raw value is
/// never emitted in searchable fields (spec §12).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entity {
    #[serde(rename = "type")]
    pub kind: String,
    pub span: [usize; 2],
    pub value_masked: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CategoryResult {
    pub primary: String,
    /// Full score vector so re-tagging after a taxonomy change is a pure
    /// recompute (spec §3).
    pub scores: BTreeMap<String, f32>,
    pub confidence: f32,
    pub needs_review: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmbeddingInfo {
    pub model: String,
    pub dim: usize,
    /// Content address of the vector (blake3 of the f32 bytes).
    #[serde(rename = "ref")]
    pub vec_ref: String,
    /// Inline vector — included only when the caller asks (standalone mode);
    /// in-app the indexer stores vectors itself.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vector: Option<Vec<f32>>,
    /// Per-chunk vectors for long documents (same space as `vector`, which
    /// remains the whole-doc embedding). Present only with inline vectors and
    /// only when the text spans more than one embed window.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chunks: Option<Vec<Vec<f32>>>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Embeddings {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<EmbeddingInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<EmbeddingInfo>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TimingMs {
    pub stage_a: u64,
    #[serde(skip_serializing_if = "is_zero")]
    pub extract: u64,
    #[serde(skip_serializing_if = "is_zero")]
    pub ocr: u64,
    #[serde(skip_serializing_if = "is_zero")]
    pub stage_b: u64,
    /// Open-vocabulary labeling pass (opt-in; zero when not run).
    #[serde(rename = "enrichment", skip_serializing_if = "is_zero")]
    pub labeling: u64,
    pub total: u64,
}

fn is_zero(v: &u64) -> bool {
    *v == 0
}

/// The full output contract (spec §9).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClassificationRecord {
    /// Content hash of the raw bytes (dedup key).
    pub item_id: String,
    pub schema_version: String,
    pub source_kind: SourceKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mime: Option<String>,
    pub category: CategoryResult,
    /// Multi-label flags (e.g. `pii_present`) — orthogonal to `category`.
    pub labels: Vec<String>,
    /// Deterministic tags in Relic SPEC §5 vocabulary plus sift extensions —
    /// what the ingest layer writes into `Relic.tags`. See
    /// docs/sift-integration.md for the mapping.
    pub relic_tags: Vec<String>,
    /// Open-vocabulary tags from the labeler, kept apart from `relic_tags`
    /// because they are **unbounded**: a consumer must snap near-duplicates and
    /// require recurrence before showing them as facets (`sift tags bound`),
    /// while the curated `relic_tags` pass through untouched. Empty when
    /// labeling is off — so a consumer that ignores this field keeps exactly
    /// the old, closed-vocabulary behavior.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub label_tags: Vec<String>,
    /// Searchable text (doc extraction / OCR). Secrets are masked here.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub extracted_text: Option<String>,
    /// The labeler's generated title (masked), exposed separately from
    /// `extracted_text` so the ingest layer can use it as a headline/title.
    /// None when none was produced (labeling off, PII-gated, or unparsed).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub caption: Option<String>,
    /// Short human title (first non-empty line, ≤80 chars) — mirrors
    /// relic-core's `make_preview` so the app shows consistent titles.
    pub preview: String,
    pub entities: Vec<Entity>,
    pub embeddings: Embeddings,
    pub provenance: Vec<Provenance>,
    pub model_versions: BTreeMap<String, String>,
    pub timing_ms: TimingMs,
    pub created_at: String,
}

/// Short list title: first non-empty line, capped at 80 chars (char-boundary
/// safe). Mirrors `relic_core::classify::make_preview`.
pub fn make_preview(text: &str) -> String {
    let line = text.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    let mut preview: String = line.chars().take(80).collect();
    if line.chars().count() > 80 {
        preview.push('…');
    }
    preview
}

pub fn item_id(bytes: &[u8]) -> String {
    format!("blake3:{}", blake3::hash(bytes).to_hex())
}
