//! Shared text-embedding encoder backing both the Stage-B text classifier
//! (`stage_b::text`) and the standalone search embedder (`embed`). It selects
//! EmbeddingGemma (preferred) or BGE from the model cache and hides their
//! differences behind one interface: tokenizer, pooling, retrieval prompt
//! prefixes, and MRL output dim.
//!
//! Retrieval convention (must match across classifier-stored doc vectors and
//! search query vectors so cosine = dot product):
//! - documents (stored / classified): embedded with the *document* prefix
//! - queries (search box): embedded with the *query* prefix
//! BGE keeps its single query instruction (docs raw); Gemma uses both task
//! prefixes. Either way `embed_docs`/`embed_query` land in the same space.

use std::path::Path;

use ort::session::Session;
use ort::value::Tensor;
use tokenizers::Tokenizer;

use crate::models;
use super::{extract_f32, l2_normalize, make_session};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum EmbedKind {
    Bge,
    Gemma,
}

/// Char cap before tokenization (token truncation to 512 does the real limiting).
const MAX_CHARS: usize = 8000;
/// MRL truncation dim for Gemma — 256 beat BGE-384 at a smaller footprint
/// (validated in relic-sift-next).
const GEMMA_DIM: usize = 256;
const BGE_DIM: usize = 384;

pub struct TextEmbedModel {
    session: Session,
    tokenizer: Tokenizer,
    kind: EmbedKind,
    wants_token_type: bool,
    pub dim: usize,
    pub model_version: String,
}

impl TextEmbedModel {
    /// Load the active text-embedding model (Gemma if present, else BGE) from
    /// the cache. Fails if neither the model nor the ONNX runtime is available;
    /// callers fall back (FTS-only search, or no Stage-B text head).
    /// Load the active *search* embedding model (Gemma if present, else BGE).
    pub fn load(model_dir: &Path) -> Result<Self, String> {
        Self::load_spec(model_dir, models::text_embedding_spec(model_dir))
    }

    /// Load a specific model spec (used to pin the classifier head to BGE while
    /// search uses Gemma).
    pub fn load_spec(model_dir: &Path, spec: &'static models::ModelSpec) -> Result<Self, String> {
        crate::ensure_runtime(model_dir)?;
        let kind = if spec.id == models::GEMMA.id { EmbedKind::Gemma } else { EmbedKind::Bge };
        let model_path = models::file_path(model_dir, &spec.files[0]);
        // Tokenizer is the last file in both specs ([onnx, tok] / [onnx, data, tok]).
        let tok_path = models::file_path(model_dir, spec.files.last().unwrap());
        let session = make_session(&model_path)?;
        let mut tokenizer =
            Tokenizer::from_file(&tok_path).map_err(|e| format!("load {}: {e}", tok_path.display()))?;
        tokenizer
            .with_truncation(Some(tokenizers::TruncationParams { max_length: 512, ..Default::default() }))
            .map_err(|e| e.to_string())?;
        let wants_token_type = session.inputs().iter().any(|i| i.name() == "token_type_ids");
        let dim = match kind {
            EmbedKind::Gemma => GEMMA_DIM,
            EmbedKind::Bge => BGE_DIM,
        };
        Ok(TextEmbedModel {
            session,
            tokenizer,
            kind,
            wants_token_type,
            dim,
            model_version: spec.version.to_string(),
        })
    }

    pub fn kind(&self) -> EmbedKind {
        self.kind
    }

    fn cap(t: &str) -> String {
        let t = t.trim();
        if t.len() <= MAX_CHARS {
            return t.to_string();
        }
        let mut end = MAX_CHARS;
        while !t.is_char_boundary(end) {
            end -= 1;
        }
        t[..end].to_string()
    }

    fn doc_input(&self, t: &str) -> String {
        let t = Self::cap(t);
        match self.kind {
            EmbedKind::Gemma => format!("title: none | text: {t}"),
            EmbedKind::Bge => t,
        }
    }

    fn query_input(&self, t: &str) -> String {
        let t = Self::cap(t);
        match self.kind {
            EmbedKind::Gemma => format!("task: search result | query: {t}"),
            EmbedKind::Bge => format!("Represent this sentence for searching relevant passages: {t}"),
        }
    }

    fn classify_input(&self, t: &str) -> String {
        let t = Self::cap(t);
        match self.kind {
            EmbedKind::Gemma => format!("task: classification | query: {t}"),
            EmbedKind::Bge => t,
        }
    }

    /// Embed document-side texts (search/stored vectors) — retrieval prefix.
    pub fn embed_docs(&mut self, texts: &[&str]) -> Result<Vec<Vec<f32>>, String> {
        if texts.is_empty() {
            return Ok(vec![]);
        }
        let prepared: Vec<String> = texts.iter().map(|t| self.doc_input(t)).collect();
        self.forward(&prepared)
    }

    /// Embed texts for the nearest-centroid classification head — uses the
    /// task-specific *classification* prefix (Gemma); BGE is unaffected (raw).
    pub fn embed_classify(&mut self, texts: &[&str]) -> Result<Vec<Vec<f32>>, String> {
        if texts.is_empty() {
            return Ok(vec![]);
        }
        let prepared: Vec<String> = texts.iter().map(|t| self.classify_input(t)).collect();
        self.forward(&prepared)
    }

    /// Embed a single search query → L2-normalized vector in the document space.
    pub fn embed_query(&mut self, text: &str) -> Result<Vec<f32>, String> {
        let prepared = vec![self.query_input(text)];
        Ok(self.forward(&prepared)?.remove(0))
    }

    fn forward(&mut self, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        let encodings = self
            .tokenizer
            .encode_batch(texts.to_vec(), true)
            .map_err(|e| format!("tokenize: {e}"))?;
        let batch = encodings.len();
        let max_len = encodings.iter().map(|e| e.get_ids().len()).max().unwrap_or(1);
        let mut ids = vec![0i64; batch * max_len];
        let mut mask = vec![0i64; batch * max_len];
        for (i, e) in encodings.iter().enumerate() {
            for (j, (&id, &m)) in e.get_ids().iter().zip(e.get_attention_mask()).enumerate() {
                ids[i * max_len + j] = id as i64;
                mask[i * max_len + j] = m as i64;
            }
        }
        let shape = vec![batch as i64, max_len as i64];
        let ids_t = Tensor::from_array((shape.clone(), ids)).map_err(|e| e.to_string())?;
        let mask_t = Tensor::from_array((shape.clone(), mask)).map_err(|e| e.to_string())?;

        let outputs = if self.wants_token_type {
            let tt_t = Tensor::from_array((shape, vec![0i64; batch * max_len])).map_err(|e| e.to_string())?;
            self.session
                .run(ort::inputs![
                    "input_ids" => ids_t,
                    "attention_mask" => mask_t,
                    "token_type_ids" => tt_t
                ])
                .map_err(|e| e.to_string())?
        } else {
            self.session
                .run(ort::inputs!["input_ids" => ids_t, "attention_mask" => mask_t])
                .map_err(|e| e.to_string())?
        };

        let mut out = Vec::with_capacity(batch);
        match self.kind {
            // Gemma exports a pooled `sentence_embedding` [batch, 768]; MRL-truncate.
            EmbedKind::Gemma => {
                let (shape, data) =
                    extract_f32(&outputs["sentence_embedding"]).map_err(|e| e.to_string())?;
                let h = *shape.get(1).ok_or("unexpected gemma embedding shape")?;
                for i in 0..batch {
                    let row = &data[i * h..i * h + h];
                    let mut v = row[..self.dim.min(h)].to_vec();
                    l2_normalize(&mut v);
                    out.push(v);
                }
            }
            // BGE: last_hidden_state [batch, len, hidden] → CLS (first token).
            EmbedKind::Bge => {
                let (shape, data) = extract_f32(&outputs[0]).map_err(|e| e.to_string())?;
                let (b, l, h) = (shape[0], shape[1], shape[2]);
                for i in 0..b {
                    let start = i * l * h;
                    let mut v = data[start..start + h].to_vec();
                    l2_normalize(&mut v);
                    out.push(v);
                }
            }
        }
        Ok(out)
    }
}
