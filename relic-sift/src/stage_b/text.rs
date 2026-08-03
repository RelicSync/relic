//! `B-text` (spec §6.1): bge-small-en-v1.5 int8 sentence embedding + a
//! nearest-centroid head over taxonomy prototypes. The embedding doubles as
//! the search vector (embed once). Centroids are computed on first run and
//! cached; retraining the head = editing prototypes in taxonomy.json and the
//! cache rebuilds (spec §13 user feedback loop, in its simplest form).

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::record::{Stage, Vote};
use crate::taxonomy::Taxonomy;

use super::encoder::{EmbedKind, TextEmbedModel};
use super::{l2_normalize, softmax};

/// Softmax temperature over cosine similarities, per embedding model. bge
/// cosines live in a narrow band (~0.55–0.9) so they want a high temperature;
/// Gemma's prefixed cosines spread wider, so a lower temperature keeps the vote
/// distribution comparable (calibrated against the eval corpus, spec §7.2).
const COSINE_TEMP_BGE: f32 = 22.0;
const COSINE_TEMP_GEMMA: f32 = 22.0;

/// Cap on model evidence — only Stage-A deterministic rules may hit ≥0.95.
const MODEL_CAP: f32 = 0.92;

/// Chunking window for long-document embeddings, in chars (≈ the encoder's
/// 512-token window with headroom). The overlap keeps sentences straddling a
/// boundary findable; the cap bounds enrichment cost per item.
const CHUNK_CHARS: usize = 1500;
const CHUNK_OVERLAP: usize = 200;
const MAX_CHUNKS: usize = 8;

// Stride must be positive or chunking would emit MAX_CHUNKS duplicate windows.
const _: () = assert!(CHUNK_OVERLAP < CHUNK_CHARS);

/// Split `text` into overlapping windows for per-chunk embedding. Empty when
/// the whole text fits one window — the whole-doc vector already covers it.
pub fn chunk_text(text: &str) -> Vec<String> {
    // Only the first ~MAX_CHUNKS windows are ever consumed — don't materialize
    // a multi-MB document as a Vec<char>.
    let take = (MAX_CHUNKS - 1) * (CHUNK_CHARS - CHUNK_OVERLAP) + CHUNK_CHARS;
    let chars: Vec<char> = text.chars().take(take).collect();
    if chars.len() <= CHUNK_CHARS + CHUNK_OVERLAP {
        return vec![];
    }
    let mut out = Vec::new();
    let mut start = 0usize;
    while start < chars.len() && out.len() < MAX_CHUNKS {
        let end = (start + CHUNK_CHARS).min(chars.len());
        out.push(chars[start..end].iter().collect());
        if end == chars.len() {
            break;
        }
        start = end - CHUNK_OVERLAP;
    }
    out
}

#[derive(Serialize, Deserialize)]
struct HeadCache {
    fingerprint: String,
    model: String,
    categories: Vec<String>,
    centroids: Vec<Vec<f32>>,
}

pub struct TextClassifier {
    /// Nearest-centroid head encoder — BGE when present (head was tuned on it),
    /// else Gemma. Produces category votes.
    head: TextEmbedModel,
    /// Search/stored vector encoder — Gemma when present and distinct from the
    /// head, else `None` (the head embedding is reused for storage). Keeping the
    /// head on BGE while the stored vector comes from Gemma is what lets search
    /// improve without changing any category outcome.
    search: Option<TextEmbedModel>,
    categories: Vec<String>,
    centroids: Vec<Vec<f32>>,
    /// Version of the head model (drives the centroid-cache fingerprint).
    pub model_version: String,
    /// Version of the stored search-vector model (Gemma when active).
    embed_version: String,
}

impl TextClassifier {
    pub fn load(model_dir: &Path, taxonomy: &Taxonomy) -> Result<Self, String> {
        let head = TextEmbedModel::load_spec(model_dir, crate::models::classifier_spec(model_dir))?;
        let model_version = head.model_version.clone();
        // Stand up a distinct Gemma search encoder only when it differs from the
        // head (i.e. both models are present); otherwise reuse the head vector.
        let search_spec = crate::models::text_embedding_spec(model_dir);
        let (search, embed_version) = if search_spec.id != crate::models::classifier_spec(model_dir).id {
            let s = TextEmbedModel::load_spec(model_dir, search_spec)?;
            let v = s.model_version.clone();
            (Some(s), v)
        } else {
            (None, model_version.clone())
        };
        let mut me = TextClassifier {
            head,
            search,
            categories: vec![],
            centroids: vec![],
            model_version,
            embed_version,
        };
        me.build_head(model_dir, taxonomy)?;
        Ok(me)
    }

    /// Model version of the stored search vector (Gemma when active, else head).
    pub fn embed_version(&self) -> &str {
        &self.embed_version
    }

    /// Build (or load from cache) per-category centroids from taxonomy
    /// prototypes.
    fn build_head(&mut self, model_dir: &Path, taxonomy: &Taxonomy) -> Result<(), String> {
        let fingerprint = taxonomy.head_fingerprint();
        let cache_path = model_dir.join("text-head-cache.json");
        if let Ok(s) = std::fs::read_to_string(&cache_path) {
            if let Ok(c) = serde_json::from_str::<HeadCache>(&s) {
                if c.fingerprint == fingerprint && c.model == self.model_version {
                    self.categories = c.categories;
                    self.centroids = c.centroids;
                    return Ok(());
                }
            }
        }
        let cats = taxonomy.text_head_categories();
        let mut categories = Vec::new();
        let mut centroids = Vec::new();
        for c in cats {
            let protos: Vec<&str> = c.prototypes.iter().map(String::as_str).collect();
            // Centroids use the task-specific *classification* prefix (Gemma);
            // BGE is unaffected (raw). This is the strongest head space — it beats
            // the doc prefix on code-vs-data and markdown-vs-todo boundaries.
            let embs = self.head.embed_classify(&protos)?;
            let dim = embs[0].len();
            let mut centroid = vec![0f32; dim];
            for e in &embs {
                for (a, b) in centroid.iter_mut().zip(e) {
                    *a += b;
                }
            }
            for a in centroid.iter_mut() {
                *a /= embs.len() as f32;
            }
            l2_normalize(&mut centroid);
            categories.push(c.id.clone());
            centroids.push(centroid);
        }
        let cache = HeadCache {
            fingerprint,
            model: self.model_version.clone(),
            categories: categories.clone(),
            centroids: centroids.clone(),
        };
        let _ = std::fs::write(&cache_path, serde_json::to_string(&cache).unwrap());
        self.categories = categories;
        self.centroids = centroids;
        Ok(())
    }

    /// Classify text into the head categories. Returns (votes, embedding).
    /// `demote` scales vote scores (OCR-fed text on image items). The embedding
    /// is the *document*-side vector, matching what the search query embedder
    /// compares against.
    pub fn classify(&mut self, text: &str, demote: f32) -> Result<(Vec<Vote>, Vec<f32>), String> {
        // Head votes come from the classification-prompt embedding (BGE: raw).
        let head_emb = self.head.embed_classify(&[text])?.remove(0);
        let temp = match self.head.kind() {
            EmbedKind::Gemma => COSINE_TEMP_GEMMA,
            EmbedKind::Bge => COSINE_TEMP_BGE,
        };
        let sims: Vec<f32> = self
            .centroids
            .iter()
            .map(|c| c.iter().zip(&head_emb).map(|(a, b)| a * b).sum::<f32>())
            .collect();
        let logits: Vec<f32> = sims.iter().map(|s| s * temp).collect();
        let probs = softmax(&logits);
        let mut votes = Vec::new();
        for (i, p) in probs.iter().enumerate() {
            if *p >= 0.02 {
                votes.push(Vote::new(
                    &self.categories[i],
                    (p * demote).min(MODEL_CAP),
                    Stage::BText,
                    &format!("head:{}", self.categories[i]),
                ));
            }
        }
        // The *stored* vector is always a *document*-prefix embedding (matching
        // the search-query space). A distinct search encoder is used when present;
        // otherwise the head model IS the search model (both Gemma) and we run a
        // second doc-prefix pass rather than store the classify-prefix head vector.
        let store_emb = self.embed_docs_store(&[text])?.remove(0);
        Ok((votes, store_emb))
    }

    /// Document-side embedding via the search encoder (or the head when they
    /// share one model) — the space every stored vector must live in.
    fn embed_docs_store(&mut self, texts: &[&str]) -> Result<Vec<Vec<f32>>, String> {
        match &mut self.search {
            Some(s) => s.embed_docs(texts),
            None => self.head.embed_docs(texts),
        }
    }

    /// Whole-doc document-prefix embedding WITHOUT classification votes — for
    /// items the classifier skips (rule-resolved / bare structural facts) that
    /// still need a vector so semantic search can reach them.
    pub fn embed_doc(&mut self, text: &str) -> Result<Vec<f32>, String> {
        Ok(self.embed_docs_store(&[text])?.remove(0))
    }

    /// Per-chunk embeddings for a long document; empty when it fits one window.
    pub fn embed_chunks(&mut self, text: &str) -> Result<Vec<Vec<f32>>, String> {
        let chunks = chunk_text(text);
        if chunks.is_empty() {
            return Ok(vec![]);
        }
        let refs: Vec<&str> = chunks.iter().map(String::as_str).collect();
        self.embed_docs_store(&refs)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_text_short_returns_empty() {
        assert!(chunk_text("").is_empty());
        assert!(chunk_text("a short clipboard note").is_empty());
        assert!(chunk_text(&"x".repeat(CHUNK_CHARS + CHUNK_OVERLAP)).is_empty());
    }

    #[test]
    fn chunk_text_long_overlaps_and_caps() {
        // 5 windows' worth of text → several chunks, each ≤ window size,
        // consecutive chunks sharing the overlap region.
        let text: String = (0..CHUNK_CHARS * 5).map(|i| ((b'a' + (i % 26) as u8) as char)).collect();
        let chunks = chunk_text(&text);
        assert!(chunks.len() >= 4 && chunks.len() <= MAX_CHUNKS);
        for c in &chunks {
            assert!(c.chars().count() <= CHUNK_CHARS);
        }
        for w in chunks.windows(2) {
            let tail: String = w[0].chars().skip(CHUNK_CHARS - CHUNK_OVERLAP).collect();
            let head: String = w[1].chars().take(CHUNK_OVERLAP).collect();
            assert_eq!(tail, head, "consecutive chunks must overlap");
        }
        // A pathological doc longer than the cap covers is truncated, not
        // unbounded.
        let huge: String = "y".repeat(CHUNK_CHARS * 40);
        assert_eq!(chunk_text(&huge).len(), MAX_CHUNKS);
    }
}
