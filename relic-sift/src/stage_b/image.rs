//! `B-image` (spec §6.2): zero-shot image classification. Two interchangeable
//! backends — **CLIP ViT-B/32** (combined graph) and **MobileCLIP2-S2**
//! (dual-tower: separate vision + text ONNX, validated upgrade: top-1
//! 0.783→0.913). Both reduce to the same thing: a per-prompt logit vector plus
//! an image embedding. The downstream category-softmax and content-tag-bank
//! aggregation is **shared and unchanged**, so the taxonomy's CLIP-calibrated
//! thresholds and every default image tag behave identically across backends —
//! the only per-backend knob is the cosine→logit scale.
//!
//! Candidate label strings come straight from the taxonomy; new categories are
//! new strings, no training. The image embedding is retained as the visual
//! search vector.

use std::ops::Range;
use std::path::Path;

use image::DynamicImage;
use ort::session::Session;
use ort::value::Tensor;
use tokenizers::Tokenizer;

use crate::models;
use crate::record::{Stage, Vote};
use crate::taxonomy::Taxonomy;

use super::{extract_f32, l2_normalize, softmax};

const MODEL_CAP: f32 = 0.92;

/// CLIP routinely reads a centered animal face (a dog or cat portrait) as a
/// person — the "a portrait photograph of a face" prompt matches a muzzle head-on.
/// When the `animal` prompt out-scores `people` by at least this many logits the
/// subject is unambiguously the animal, so we drop the spurious `people` tag.
/// A genuine person photo keeps `people` on top (animal scores *below* people
/// even with a pet in frame), so this never fires there. Calibrated from the
/// eval photos: dog portrait animal−people ≈ +8.2; real person photos ≈ −1 to −7.
const PEOPLE_ANIMAL_MARGIN: f32 = 4.0;

// --- CLIP preprocessing (resize shortest→224, center crop, CLIP mean/std) ----
const CLIP_SIZE: u32 = 224;
const CLIP_MEAN: [f32; 3] = [0.481_454_66, 0.457_827_5, 0.408_210_73];
const CLIP_STD: [f32; 3] = [0.268_629_54, 0.261_302_58, 0.275_777_11];
/// CLIP pads with `<|endoftext|>`; the text head pools at the first EOT.
const CLIP_PAD_ID: u32 = 49407;

// --- MobileCLIP2 preprocessing (resize shortest→256, center crop, no norm) ---
const MCLIP_SIZE: u32 = 256;
const MCLIP_MEAN: [f32; 3] = [0.0, 0.0, 0.0];
const MCLIP_STD: [f32; 3] = [1.0, 1.0, 1.0];
/// open_clip CLIP tokenizer pads with 0.
const MCLIP_PAD_ID: u32 = 0;
/// Trained open_clip logit scale: cosine → CLIP-equivalent logits so the
/// taxonomy's CLIP-calibrated category softmax and tag thresholds transfer
/// unchanged. (Standard open_clip clamp; verified against the eval tag golds.)
const MCLIP_LOGIT_SCALE: f32 = 100.0;

/// Backend producing a per-prompt logit vector + image embedding.
enum Backend {
    /// CLIP combined graph: input_ids + pixel_values + attention_mask →
    /// logits_per_image, image_embeds. Prompts are pre-tokenized into a fixed
    /// batch.
    Clip {
        session: Session,
        input_ids: Vec<i64>,
        attention_mask: Vec<i64>,
        batch: usize,
        seq_len: usize,
    },
    /// MobileCLIP2 dual-tower: vision tower per image; prompt text embeddings
    /// computed once at load (cached) and scored by cosine.
    Dual {
        vision: Session,
        /// L2-normalized prompt embeddings, row-major `[n_prompts, dim]`.
        text_embeds: Vec<f32>,
        dim: usize,
    },
}

pub struct ClipClassifier {
    backend: Backend,
    /// (category, prompt) pairs in taxonomy order; first `prompts.len()` rows.
    prompts: Vec<(String, String)>,
    /// (tag id, row range) per content tag.
    tag_ranges: Vec<(String, Range<usize>)>,
    /// Row range of the background/contrast prompts.
    bg_range: Range<usize>,
    tag_threshold: f32,
    tag_temperature: f32,
    /// Total prompt rows (categories + tags + background).
    n_rows: usize,
    pub model_version: String,
}

/// The prompt bank derived from a taxonomy: category prompts, then per-tag
/// prompt ranges, then the background/contrast prompts.
///
/// Factored out so `ClipClassifier::load` and `sift prompts bake` build it from
/// one place. If baking used its own copy of this logic, a later taxonomy edit
/// could change row ORDER without changing the fingerprint's inputs in the same
/// way, and the baked matrix would quietly describe different prompts than the
/// rows it is indexed against.
pub(crate) struct PromptBank {
    pub prompts: Vec<(String, String)>,
    pub texts: Vec<String>,
    pub tag_ranges: Vec<(String, Range<usize>)>,
    pub bg_range: Range<usize>,
    pub tag_threshold: f32,
    pub tag_temperature: f32,
}

pub(crate) fn prompt_bank(taxonomy: &Taxonomy) -> Result<PromptBank, String> {
    let mut prompts = Vec::new();
    for c in taxonomy.clip_categories() {
        for p in &c.clip_prompts {
            prompts.push((c.id.clone(), p.clone()));
        }
    }
    if prompts.is_empty() {
        return Err("taxonomy has no clip_prompts".into());
    }
    let mut texts: Vec<String> = prompts.iter().map(|(_, p)| p.clone()).collect();

    let mut tag_ranges = Vec::new();
    let mut tag_threshold = 0.6;
    let mut tag_temperature = 10.0;
    if let Some(bank) = &taxonomy.image_tags {
        tag_threshold = bank.threshold;
        tag_temperature = bank.temperature.max(1e-3);
        for tag in &bank.tags {
            let start = texts.len();
            texts.extend(tag.prompts.iter().cloned());
            tag_ranges.push((tag.id.clone(), start..texts.len()));
        }
    }
    let bg_start = texts.len();
    if let Some(bank) = &taxonomy.image_tags {
        texts.extend(bank.background_prompts.iter().cloned());
    }
    let bg_range = bg_start..texts.len();
    Ok(PromptBank { prompts, texts, tag_ranges, bg_range, tag_threshold, tag_temperature })
}

/// Fingerprint of a prompt bank — the cache key for both the on-disk and the
/// baked-in prompt embeddings.
pub(crate) fn prompt_fingerprint(texts: &[String]) -> String {
    blake3::hash(texts.join("\n").as_bytes()).to_hex().to_string()
}

impl ClipClassifier {
    pub fn load(model_dir: &Path, taxonomy: &Taxonomy) -> Result<Self, String> {
        let spec = models::image_spec(model_dir);

        let PromptBank { prompts, texts, tag_ranges, bg_range, tag_threshold, tag_temperature } =
            prompt_bank(taxonomy)?;
        let n_rows = texts.len();

        let backend = if spec.id == models::MOBILECLIP2.id {
            Self::load_dual(model_dir, spec, &texts)?
        } else {
            Self::load_clip(model_dir, spec, &texts)?
        };

        Ok(ClipClassifier {
            backend,
            prompts,
            tag_ranges,
            bg_range,
            tag_threshold,
            tag_temperature,
            n_rows,
            model_version: spec.version.to_string(),
        })
    }

    fn load_clip(
        model_dir: &Path,
        spec: &models::ModelSpec,
        texts: &[String],
    ) -> Result<Backend, String> {
        let model_path = models::file_path(model_dir, &spec.files[0]);
        let tok_path = models::file_path(model_dir, &spec.files[1]);
        let session = super::make_session(&model_path)?;
        let mut tokenizer =
            Tokenizer::from_file(&tok_path).map_err(|e| format!("load {}: {e}", tok_path.display()))?;
        tokenizer
            .with_truncation(Some(tokenizers::TruncationParams { max_length: 77, ..Default::default() }))
            .map_err(|e| e.to_string())?;

        let encodings =
            tokenizer.encode_batch(texts.to_vec(), true).map_err(|e| format!("tokenize: {e}"))?;
        let seq_len = encodings.iter().map(|e| e.get_ids().len()).max().unwrap_or(1);
        let n = encodings.len();
        let mut input_ids = vec![CLIP_PAD_ID as i64; n * seq_len];
        let mut attention_mask = vec![0i64; n * seq_len];
        for (i, e) in encodings.iter().enumerate() {
            for (j, &id) in e.get_ids().iter().enumerate() {
                input_ids[i * seq_len + j] = id as i64;
                attention_mask[i * seq_len + j] = 1;
            }
        }
        Ok(Backend::Clip { session, input_ids, attention_mask, batch: n, seq_len })
    }

    fn load_dual(
        model_dir: &Path,
        spec: &models::ModelSpec,
        texts: &[String],
    ) -> Result<Backend, String> {
        let vision = super::make_session(&models::file_path(model_dir, &spec.files[0]))?;
        // Prompt embeddings are taxonomy-derived and fixed, so the text tower is
        // only ever needed to produce this matrix. Resolution order:
        //   1. on-disk cache  — a previous run, or a custom taxonomy already baked
        //   2. baked-in default — covers every install that hasn't overridden
        //      taxonomy.json, which is why the 254 MB tower left the bundle
        //   3. the tower itself — custom taxonomy, cold
        let cache_path = model_dir.join("image-prompt-cache.json");
        let fingerprint = blake3::hash(texts.join("\n").as_bytes()).to_hex().to_string();
        if let Some((dim, text_embeds)) = read_prompt_cache(&cache_path, &fingerprint, spec.version) {
            return Ok(Backend::Dual { vision, text_embeds, dim });
        }
        if let Some((dim, text_embeds)) = baked_prompt_cache(&fingerprint, spec.version) {
            return Ok(Backend::Dual { vision, text_embeds, dim });
        }
        let (dim, text_embeds) = embed_prompts_dual(model_dir, texts)?;
        write_prompt_cache(&cache_path, &fingerprint, spec.version, dim, &text_embeds);
        Ok(Backend::Dual { vision, text_embeds, dim })
    }

    /// Zero-shot classify. Returns (category votes, image embedding,
    /// multi-label content tags). Backend-agnostic past the logit vector.
    pub fn classify(
        &mut self,
        img: &DynamicImage,
    ) -> Result<(Vec<Vote>, Vec<f32>, Vec<String>), String> {
        let (logits, image_embeds) = match &mut self.backend {
            Backend::Clip { session, input_ids, attention_mask, batch, seq_len } => {
                let pixel_values = preprocess(img, CLIP_SIZE, CLIP_MEAN, CLIP_STD);
                let n = *batch;
                let ids_t =
                    Tensor::from_array((vec![n as i64, *seq_len as i64], input_ids.clone()))
                        .map_err(|e| e.to_string())?;
                let mask_t =
                    Tensor::from_array((vec![n as i64, *seq_len as i64], attention_mask.clone()))
                        .map_err(|e| e.to_string())?;
                let px_t = Tensor::from_array((
                    vec![1i64, 3, CLIP_SIZE as i64, CLIP_SIZE as i64],
                    pixel_values,
                ))
                .map_err(|e| e.to_string())?;
                let outputs = session
                    .run(ort::inputs![
                        "input_ids" => ids_t,
                        "pixel_values" => px_t,
                        "attention_mask" => mask_t
                    ])
                    .map_err(|e| e.to_string())?;
                let (shape, logits) =
                    extract_f32(&outputs["logits_per_image"]).map_err(|e| e.to_string())?;
                debug_assert_eq!(shape, vec![1, self.n_rows]);
                let image_embeds = outputs
                    .get("image_embeds")
                    .and_then(|v| extract_f32(v).ok())
                    .map(|(_, data)| data)
                    .unwrap_or_default();
                (logits, image_embeds)
            }
            Backend::Dual { vision, text_embeds, dim } => {
                let pixel_values = preprocess(img, MCLIP_SIZE, MCLIP_MEAN, MCLIP_STD);
                let px_t = Tensor::from_array((
                    vec![1i64, 3, MCLIP_SIZE as i64, MCLIP_SIZE as i64],
                    pixel_values,
                ))
                .map_err(|e| e.to_string())?;
                let outputs =
                    vision.run(ort::inputs!["pixel_values" => px_t]).map_err(|e| e.to_string())?;
                let (_, raw) = extract_f32(&outputs[0]).map_err(|e| e.to_string())?;
                let mut img_emb = raw;
                l2_normalize(&mut img_emb);
                // logits = scale · cosine(image, prompt_i)
                let d = *dim;
                let logits: Vec<f32> = text_embeds
                    .chunks_exact(d)
                    .map(|row| {
                        MCLIP_LOGIT_SCALE
                            * row.iter().zip(&img_emb).map(|(a, b)| a * b).sum::<f32>()
                    })
                    .collect();
                (logits, img_emb)
            }
        };

        Ok(self.aggregate(&logits, image_embeds))
    }

    /// Shared category + content-tag aggregation over a per-prompt logit vector.
    /// Identical for both backends, so default tags are unchanged.
    fn aggregate(&self, logits: &[f32], image_embeds: Vec<f32>) -> (Vec<Vote>, Vec<f32>, Vec<String>) {
        // Category scores: softmax over the category prompts only.
        let n_cat = self.prompts.len();
        let probs = softmax(&logits[..n_cat]);

        // Prompt-ensemble: sum prompt probabilities per category.
        let mut by_cat: Vec<(String, f32)> = Vec::new();
        for ((cat, _), p) in self.prompts.iter().zip(&probs) {
            match by_cat.iter_mut().find(|(c, _)| c == cat) {
                Some((_, sum)) => *sum += p,
                None => by_cat.push((cat.clone(), *p)),
            }
        }
        let votes = by_cat
            .into_iter()
            .filter(|(_, p)| *p >= 0.02)
            .map(|(cat, p)| {
                let signal = format!("clip:{cat}");
                Vote::new(&cat, p.min(MODEL_CAP), Stage::BImage, &signal)
            })
            .collect();

        // Content tags: each tag's best prompt vs the best background prompt,
        // tempered binary softmax (multi-label, orthogonal to the category).
        let mut content_tags = Vec::new();
        if !self.bg_range.is_empty() {
            let best = |r: &Range<usize>| {
                logits[r.clone()].iter().cloned().fold(f32::NEG_INFINITY, f32::max)
            };
            let bg = best(&self.bg_range);
            let (mut people_logit, mut animal_logit) = (None, None);
            for (id, range) in &self.tag_ranges {
                let logit = best(range);
                let p = 1.0 / (1.0 + (-(logit - bg) / self.tag_temperature).exp());
                match id.as_str() {
                    "people" => people_logit = Some(logit),
                    "animal" => animal_logit = Some(logit),
                    _ => {}
                }
                if p >= self.tag_threshold {
                    content_tags.push(id.clone());
                }
            }
            // Living-subject disambiguation: a strongly animal-dominant scene is
            // not a person (see PEOPLE_ANIMAL_MARGIN).
            if let (Some(pl), Some(al)) = (people_logit, animal_logit) {
                if al - pl >= PEOPLE_ANIMAL_MARGIN {
                    content_tags.retain(|t| t != "people");
                }
            }
        }

        (votes, image_embeds, content_tags)
    }
}

/// Embed the prompt bank with the MobileCLIP2 text tower (loaded only here).
/// Run the MobileCLIP2 text tower over the prompt bank. Public within the crate
/// because `sift prompts bake` calls exactly this to generate the baked asset —
/// baking through the same code path is what guarantees the shipped bytes match
/// what a runtime computation would produce.
pub(crate) fn embed_prompts_dual(
    model_dir: &Path,
    texts: &[String],
) -> Result<(usize, Vec<f32>), String> {
    let text_file = &models::MOBILECLIP2_TEXT.files[0];
    let text_path = models::file_path(model_dir, text_file);
    if !text_path.exists() {
        return Err(format!(
            "{} is absent. It ships only for custom taxonomies; run `sift models download` \
             after overriding taxonomy.json",
            text_file.name
        ));
    }
    let mut text_session = super::make_session(&text_path)?;
    let tok_path = models::file_path(model_dir, &models::MOBILECLIP2.files[1]);
    let mut tokenizer =
        Tokenizer::from_file(&tok_path).map_err(|e| format!("load {}: {e}", tok_path.display()))?;
    tokenizer
        .with_truncation(Some(tokenizers::TruncationParams { max_length: 77, ..Default::default() }))
        .map_err(|e| e.to_string())?;
    tokenizer
        .with_padding(Some(tokenizers::PaddingParams {
            strategy: tokenizers::PaddingStrategy::Fixed(77),
            pad_id: MCLIP_PAD_ID,
            pad_token: "!".into(),
            ..Default::default()
        }));
    let encodings =
        tokenizer.encode_batch(texts.to_vec(), true).map_err(|e| format!("tokenize: {e}"))?;
    let n = encodings.len();
    let seq = 77;
    let mut ids = vec![MCLIP_PAD_ID as i64; n * seq];
    for (i, e) in encodings.iter().enumerate() {
        for (j, &id) in e.get_ids().iter().take(seq).enumerate() {
            ids[i * seq + j] = id as i64;
        }
    }
    let ids_t = Tensor::from_array((vec![n as i64, seq as i64], ids)).map_err(|e| e.to_string())?;
    let outputs =
        text_session.run(ort::inputs!["input_ids" => ids_t]).map_err(|e| e.to_string())?;
    let (shape, data) = extract_f32(&outputs[0]).map_err(|e| e.to_string())?;
    let dim = *shape.get(1).ok_or("unexpected text embed shape")?;
    let mut embeds = vec![0f32; n * dim];
    for i in 0..n {
        let mut row = data[i * dim..i * dim + dim].to_vec();
        l2_normalize(&mut row);
        embeds[i * dim..i * dim + dim].copy_from_slice(&row);
    }
    Ok((dim, embeds))
}

#[derive(serde::Serialize, serde::Deserialize)]
struct PromptCache {
    fingerprint: String,
    model: String,
    dim: usize,
    embeds: Vec<f32>,
}

/// Generate the baked prompt-embedding asset for a taxonomy. Runs the real text
/// tower through [`embed_prompts_dual`] and emits the same `PromptCache` JSON
/// the runtime reads, so `sift prompts bake > assets/mobileclip2-prompts.json`
/// produces bytes the loader is guaranteed to accept.
pub fn bake_prompts(model_dir: &Path, taxonomy: &Taxonomy) -> Result<String, String> {
    let bank = prompt_bank(taxonomy)?;
    eprintln!("prompt bank: {} rows", bank.texts.len());
    let fingerprint = prompt_fingerprint(&bank.texts);
    eprintln!("fingerprint: {fingerprint}");
    eprintln!("embedding with the text tower (this loads 254 MB)...");
    let (dim, embeds) = embed_prompts_dual(model_dir, &bank.texts)?;
    eprintln!("embedded: {} rows x {dim}", embeds.len() / dim.max(1));
    let cache = PromptCache {
        fingerprint,
        model: models::MOBILECLIP2.version.to_string(),
        dim,
        embeds,
    };
    serde_json::to_string(&cache).map_err(|e| e.to_string())
}

/// Prompt embeddings for the BUILT-IN taxonomy, baked at build time by
/// `sift prompts bake`. This is what lets the 254 MB text tower leave the
/// default download: a stock install never needs to compute these.
///
/// Fingerprint-gated exactly like the disk cache, so if the embedded taxonomy
/// changes without re-baking, this simply misses instead of silently serving
/// embeddings for the wrong prompts.
const BAKED_PROMPTS: &str = include_str!("../../assets/mobileclip2-prompts.json");

fn baked_prompt_cache(fingerprint: &str, model: &str) -> Option<(usize, Vec<f32>)> {
    let c: PromptCache = serde_json::from_str(BAKED_PROMPTS).ok()?;
    (c.fingerprint == fingerprint && c.model == model).then_some((c.dim, c.embeds))
}

fn read_prompt_cache(path: &Path, fingerprint: &str, model: &str) -> Option<(usize, Vec<f32>)> {
    let c: PromptCache = serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()?;
    (c.fingerprint == fingerprint && c.model == model).then_some((c.dim, c.embeds))
}

fn write_prompt_cache(path: &Path, fingerprint: &str, model: &str, dim: usize, embeds: &[f32]) {
    let c = PromptCache {
        fingerprint: fingerprint.to_string(),
        model: model.to_string(),
        dim,
        embeds: embeds.to_vec(),
    };
    let _ = std::fs::write(path, serde_json::to_string(&c).unwrap());
}

/// Resize shortest side to `size`, center-crop `size`×`size`, scale to [0,1],
/// normalize with the given mean/std (identity for MobileCLIP), CHW.
fn preprocess(img: &DynamicImage, size: u32, mean: [f32; 3], std: [f32; 3]) -> Vec<f32> {
    let (w, h) = (img.width().max(1), img.height().max(1));
    let scale = size as f32 / w.min(h) as f32;
    let (nw, nh) = (
        ((w as f32 * scale).round() as u32).max(size),
        ((h as f32 * scale).round() as u32).max(size),
    );
    let resized = img.resize_exact(nw, nh, image::imageops::FilterType::CatmullRom);
    let x0 = (nw - size) / 2;
    let y0 = (nh - size) / 2;
    let cropped = resized.crop_imm(x0, y0, size, size).to_rgb8();

    let hw = (size * size) as usize;
    let mut out = vec![0f32; 3 * hw];
    for (i, px) in cropped.pixels().enumerate() {
        for c in 0..3 {
            out[c * hw + i] = (px.0[c] as f32 / 255.0 - mean[c]) / std[c];
        }
    }
    out
}
