//! # relic-sift
//!
//! Relic's classification pipeline (spec: `relic-sift-classification-pipeline-spec.md`).
//! Three-stage cascade — **A** deterministic rules → **B** small local ONNX
//! models → **C** fusion/escalation — wrapped by normalization at the front
//! and embedding attachment at the back. Local-only: no network on the
//! classification hot path; model downloads happen only via [`models`].
//!
//! ```no_run
//! use relic_sift::{NormalizedItem, Origin, Sift, SiftConfig, SourceKind};
//!
//! let mut sift = Sift::new(SiftConfig::default());
//! let record = sift.classify(&NormalizedItem {
//!     bytes: b"AKIAIOSFODNN7EXAMPLE".to_vec(),
//!     source_kind: SourceKind::String,
//!     declared_mime: None,
//!     origin: Origin::default(),
//! });
//! assert_eq!(record.category.primary, "api_key");
//! ```

pub mod embed;
pub mod eval;
pub mod extract;
pub mod fusion;
pub mod labeler;
pub mod models;
pub mod perf;
pub mod ocr;
pub mod pii;
pub mod ppocr;
pub mod pipeline;
pub mod record;
pub mod stage_a;
pub mod stage_b;
pub mod tag_vocab;
pub mod tags;
pub mod taxonomy;
pub mod user_rules;

pub use embed::Embedder;
pub use labeler::{Label, Labeler};
pub use pipeline::{Sift, SiftConfig};

/// Initialize the ONNX runtime (idempotent, process-global). Needed before
/// building a standalone [`Embedder`] in a thread that hasn't built a [`Sift`].
pub fn ensure_runtime(model_dir: &std::path::Path) -> Result<(), String> {
    pipeline::init_ort(model_dir)
}
pub use record::{
    ClassificationRecord, Entity, NormalizedItem, Origin, SourceKind, SCHEMA_VERSION,
};
pub use taxonomy::Taxonomy;
