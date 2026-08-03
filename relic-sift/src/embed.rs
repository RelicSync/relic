//! Lean query embedder for semantic / hybrid search. It loads only the bge
//! sentence model (no classification head), so the app's search path can turn a
//! query string into a vector without standing up the whole pipeline.
//!
//! The vectors it produces must live in the same space as the **document**
//! embeddings the enricher stores (`record.embeddings.text`): same model, CLS
//! pooling, L2 normalization. The one asymmetry is BGE's retrieval convention —
//! the *query* (and only the query) is prefixed with the instruction below; the
//! stored documents are embedded raw.

use std::path::Path;

use crate::stage_b::encoder::TextEmbedModel;

/// Thin wrapper over the shared [`TextEmbedModel`]: turns a search query into a
/// vector in the same space as the stored document embeddings (same model,
/// pooling, normalization; the query gets the retrieval *query* prefix, docs
/// the *document* prefix). Selects Gemma when present, else BGE.
pub struct Embedder {
    model: TextEmbedModel,
    pub model_version: String,
}

impl Embedder {
    /// Load the active text-embedding model from the cache. Fails if the model
    /// (or the ONNX runtime) isn't downloaded — callers fall back to FTS-only.
    pub fn load(model_dir: &Path) -> Result<Self, String> {
        let model = TextEmbedModel::load(model_dir)?;
        let model_version = model.model_version.clone();
        Ok(Embedder { model, model_version })
    }

    /// Embed a search query → L2-normalized vector matching the stored document
    /// embeddings (so cosine = dot product against them).
    pub fn embed_query(&mut self, query: &str) -> Result<Vec<f32>, String> {
        self.model.embed_query(query)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{NormalizedItem, Origin, Sift, SiftConfig, SourceKind};

    fn cosine(a: &[f32], b: &[f32]) -> f32 {
        a.iter().zip(b).map(|(x, y)| x * y).sum()
    }

    /// The query embedder must land in the same space as the document
    /// embeddings the enricher stores (same model, pooling, L2-norm; query gets
    /// the retrieval query prefix, docs the document prefix) — so a
    /// semantically-related query out-scores an unrelated one. Works with
    /// whichever text model is installed (Gemma or BGE). Ignored: needs the
    /// model. Run with `cargo test -p relic-sift -- --ignored query_and_doc`.
    #[test]
    #[ignore]
    fn query_and_doc_embeddings_share_space() {
        let dir = crate::models::model_dir();
        let spec = crate::models::text_embedding_spec(&dir);
        if !crate::models::is_present(&dir, spec) {
            eprintln!("skip: text embedding model not downloaded");
            return;
        }
        // Document vector exactly as the enricher persists it.
        let mut sift = Sift::new(SiftConfig { include_vectors: true, ..Default::default() });
        let doc = sift
            .classify(&NormalizedItem {
                bytes: b"the cat curled up and slept on the warm windowsill".to_vec(),
                source_kind: SourceKind::String,
                declared_mime: None,
                origin: Origin::default(),
            })
            .embeddings
            .text
            .expect("text embedding")
            .vector
            .expect("raw vector (include_vectors)");

        let mut emb = Embedder::load(&dir).unwrap();
        let related = emb.embed_query("a sleepy feline napping by the window").unwrap();
        let unrelated = emb.embed_query("quarterly revenue and stock market forecast").unwrap();

        let s_rel = cosine(&doc, &related);
        let s_unrel = cosine(&doc, &unrelated);
        assert!(s_rel > s_unrel, "related {s_rel:.3} should beat unrelated {s_unrel:.3}");
        assert!(s_rel > 0.3, "related similarity unexpectedly low: {s_rel:.3}");
    }
}
