//! Qwen3.5-0.8B (multimodal, Apache-2.0) — the open-vocabulary labeler that
//! replaces Florence-2's enrichment slot. Florence could only caption an image;
//! this produces a human-readable **title** plus free-form topical **tags** for
//! text *and* images, which is the output a closed `taxonomy.json` structurally
//! cannot emit (see docs/ai-labeling-audit-2026-07.md).
//!
//! Ported from `relic-sift-next/harness/qwen35.py`, which is the reference
//! implementation the Phase 0 vault eval was measured with. Greedy decode is
//! deterministic, so the two must agree token-for-token; `sift label --compare`
//! is what checks that.
//!
//! The architecture is NOT a plain decoder, and the state plumbing is the whole
//! trick (verified against the exported graph, not guessed):
//!
//! * 24 layers with `full_attention_interval: 4` → 18 `linear_attention` (Gated
//!   DeltaNet) + 6 `full_attention` at indices 3, 7, 11, 15, 19, 23. The graph
//!   names them by **layer index**, not a dense 0..17 counter, so `past_conv.{i}`
//!   exists for i in {0,1,2,4,5,6,8,…} and `past_key_values.{i}` only for
//!   {3,7,11,15,19,23}.
//! * Linear layers carry a **fixed-size** state: `past_conv.{i}` (B, 6144, 4) and
//!   `past_recurrent.{i}` (B, 16, 128, 128). Fixed-size means prefill passes real
//!   zeros at full size, NOT the zero-length tensor a KV cache starts from. Only
//!   the 6 attention layers get the growing (B, 2, past_seq, 256) KV pair.
//! * `position_ids` is **(3, B, S)** — mRoPE. Text advances all three rows in
//!   lockstep; images need real t/h/w indices, after which position and token
//!   count are no longer the same number.
//! * `inputs_embeds` comes from a separate `embed_tokens` graph and is **f32**,
//!   while every state tensor is **f16**. Mixing those up is a silent
//!   wrong-answer bug, not a load error.
//!
//! Non-thinking mode (the default for this model) requires the generation prompt
//! to end with a *pre-closed* think block — omit it and the model reasons out
//! loud instead of answering.

use std::borrow::Cow;
use std::path::Path;

use half::f16;
use ort::memory::Allocator;
use ort::session::{Session, SessionInputValue};
use ort::value::Tensor;
use tokenizers::Tokenizer;

use crate::models;

// --- architecture constants (config.json) -----------------------------------
const NUM_LAYERS: usize = 24;
const FULL_ATTENTION_INTERVAL: usize = 4;
const HIDDEN: usize = 1024;
const CONV_DIM: i64 = 6144;
const CONV_KERNEL: i64 = 4;
const REC_HEADS: i64 = 16;
const REC_K_DIM: i64 = 128;
const REC_V_DIM: i64 = 128;
const KV_HEADS: i64 = 2;
const KV_HEAD_DIM: i64 = 256;

/// Layer `i` is full-attention when `(i + 1) % 4 == 0`.
fn is_full_attention(layer: usize) -> bool {
    (layer + 1) % FULL_ATTENTION_INTERVAL == 0
}

// --- vision constants (vision_config / preprocessor_config) -----------------
const PATCH: u32 = 16;
const MERGE: u32 = 2;
const TEMPORAL_PATCH: usize = 2;
const IMAGE_MEAN: f32 = 0.5;
const IMAGE_STD: f32 = 0.5;
/// 3 channels × 2 temporal × 16 × 16.
const PATCH_FEATURE_DIM: usize = 3 * TEMPORAL_PATCH * (PATCH as usize) * (PATCH as usize);
/// Area cap for the vision tower. Token count is area/(32×32) after the 2×2
/// merge and decode cost is linear in it, so this is the main image-side knob.
pub const DEFAULT_MAX_PIXELS: u32 = 448 * 448;

// --- special tokens (tokenizer.json) ----------------------------------------
const IM_END: u32 = 248046;
const ENDOFTEXT: u32 = 248044;
const IMAGE_PAD: u32 = 248056;

/// Prefill chunk size. The export emits logits for *every* position and the
/// vocab is 248320, so priming a 390-token prefix in one call would allocate a
/// 390 × 248320 f16 tensor (~192 MB) purely to throw it away — only the state
/// matters here. At 64 that transient drops to ~32 MB for identical output.
const PRIME_CHUNK: usize = 64;

// Intra-op threads come from `crate::perf`, which scales them to the host:
// the old fixed 6 oversubscribed a 4-thread laptop. On any machine with 8+
// cores the Balanced profile still resolves to exactly 6, so the Python parity
// harness (which pins SIFT_THREADS anyway) is unaffected.

/// One entry of the hybrid cache, carrying the graph names on both sides so the
/// feed/roll loops never have to re-derive them.
#[derive(Clone)]
struct Slot {
    input: String,
    output: String,
    shape: Vec<i64>,
    data: Vec<f16>,
}

/// The full hybrid state: fixed-size conv + recurrent for the 18 DeltaNet
/// layers, growing KV for the 6 attention layers, in the graph's input order.
#[derive(Clone)]
pub struct State {
    slots: Vec<Slot>,
}

impl State {
    /// Initial cache for a batch of 1. Linear layers get real zeros at full
    /// size; attention layers get a zero-**length** KV pair.
    fn empty() -> Self {
        let mut slots = Vec::with_capacity(NUM_LAYERS * 2);
        let mut push = |input: String, output: String, shape: Vec<i64>| {
            let n: i64 = shape.iter().product();
            slots.push(Slot { input, output, shape, data: vec![f16::ZERO; n.max(0) as usize] });
        };
        for i in 0..NUM_LAYERS {
            if is_full_attention(i) {
                push(
                    format!("past_key_values.{i}.key"),
                    format!("present.{i}.key"),
                    vec![1, KV_HEADS, 0, KV_HEAD_DIM],
                );
                push(
                    format!("past_key_values.{i}.value"),
                    format!("present.{i}.value"),
                    vec![1, KV_HEADS, 0, KV_HEAD_DIM],
                );
            } else {
                push(
                    format!("past_conv.{i}"),
                    format!("present_conv.{i}"),
                    vec![1, CONV_DIM, CONV_KERNEL],
                );
                push(
                    format!("past_recurrent.{i}"),
                    format!("present_recurrent.{i}"),
                    vec![1, REC_HEADS, REC_K_DIM, REC_V_DIM],
                );
            }
        }
        State { slots }
    }

    /// Move every slot's buffer into a feed list. Taking (not cloning) matters:
    /// the KV half grows with the prefix, and at a ~390-token prompt this is
    /// ~15 MB that would otherwise be memcpy'd twice per decoded token.
    fn drain_into(
        &mut self,
        feeds: &mut Vec<(Cow<'static, str>, SessionInputValue<'static>)>,
    ) -> Result<(), String> {
        for slot in &mut self.slots {
            let data = std::mem::take(&mut slot.data);
            let t = f16_tensor(slot.shape.clone(), data)?;
            feeds.push((Cow::Owned(slot.input.clone()), t.into()));
        }
        Ok(())
    }

    /// Refill from the `present_*` outputs of the run this state was fed to.
    fn roll(&mut self, out: &ort::session::SessionOutputs) -> Result<(), String> {
        for slot in &mut self.slots {
            let (shape, data) = extract_f16(&out[slot.output.as_str()])?;
            slot.shape = shape;
            slot.data = data;
        }
        Ok(())
    }
}

/// A snapshot taken after a fixed prompt prefix, cloned per item so the shared
/// few-shot system block is prefilled once instead of once per item.
///
/// This pays off far more than it would for a normal decoder: the system prompt
/// is ~390 tokens and a clipboard item is ~40, so without it we re-prefill an
/// order of magnitude more than we need to, for every item in the backlog. It
/// stays cheap because DeltaNet's per-layer state is fixed-size — the snapshot
/// is a constant ~10 MB regardless of prefix length, unlike a KV cache that
/// grows with it. The 6 attention layers still hold a real
/// (1, 2, prefix_len, 256) pair, which is the only part that scales.
#[derive(Clone)]
pub struct Primed {
    state: State,
    /// Token count — drives `attention_mask`.
    past: usize,
    /// mRoPE position — diverges from `past` as soon as an image lands.
    pos: i64,
    text: String,
}

impl Primed {
    pub fn prefix(&self) -> &str {
        &self.text
    }
    pub fn tokens(&self) -> usize {
        self.past
    }
}

/// One image's encoded patches, ready for the vision tower.
pub struct ImagePatches {
    pixel_values: Vec<f32>,
    grid: (i64, i64, i64),
    /// Placeholder count after the 2×2 merge.
    pub n_tokens: usize,
}

/// Vision tower output: features to scatter over the `<|image_pad|>` run, plus
/// the **merged** grid `position_ids` wants.
pub struct ImageFeatures {
    features: Vec<f32>,
    merged_grid: (i64, i64, i64),
    pub n_tokens: usize,
}

pub struct Generated {
    pub text: String,
    pub n_prompt: usize,
    pub n_new: usize,
    pub prefill_ms: u64,
    pub total_ms: u64,
}

pub struct Qwen35 {
    embed: Session,
    decoder: Session,
    vision: Option<Session>,
    tokenizer: Tokenizer,
    pub model_version: String,
}

impl Qwen35 {
    /// Load the labeler. `vision` additionally builds the image tower (~62 MB);
    /// text-only labeling does not need it.
    pub fn load(model_dir: &Path, vision: bool) -> Result<Self, String> {
        crate::ensure_runtime(model_dir)?;
        let p = |i: usize| models::file_path(model_dir, &models::QWEN35.files[i]);
        let decoder = super::make_session_threads(&p(models::qwen35_files::DECODER), crate::perf::current_threads())?;
        let embed = super::make_session_threads(&p(models::qwen35_files::EMBED), crate::perf::current_threads())?;
        let vision = if vision {
            Some(super::make_session_threads(&p(models::qwen35_files::VISION), crate::perf::current_threads())?)
        } else {
            None
        };
        let tok_path = p(models::qwen35_files::TOKENIZER);
        let tokenizer = Tokenizer::from_file(&tok_path)
            .map_err(|e| format!("load {}: {e}", tok_path.display()))?;
        Ok(Qwen35 {
            embed,
            decoder,
            vision,
            tokenizer,
            model_version: models::QWEN35.version.to_string(),
        })
    }

    pub fn has_vision(&self) -> bool {
        self.vision.is_some()
    }

    // -- prompt --------------------------------------------------------------

    /// The shared prefix every item starts with — system block plus the opening
    /// of the user turn. Priming snapshots exactly this.
    pub fn prefix(system: &str) -> String {
        format!("<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n")
    }

    /// ChatML plus the pre-closed think block that selects non-thinking mode.
    /// `n_image_tokens` inserts the vision placeholder run the image features
    /// get scattered into.
    pub fn build_prompt(system: &str, user: &str, n_image_tokens: usize) -> String {
        let vision = if n_image_tokens > 0 {
            format!("<|vision_start|>{}<|vision_end|>", "<|image_pad|>".repeat(n_image_tokens))
        } else {
            String::new()
        };
        format!(
            "{}{vision}{user}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
            Self::prefix(system)
        )
    }

    fn encode(&self, text: &str) -> Result<Vec<u32>, String> {
        Ok(self.tokenizer.encode(text, false).map_err(|e| e.to_string())?.get_ids().to_vec())
    }

    /// Whether splitting a prompt at `prefix` retokenizes identically. Merging
    /// BPE across a seam can produce different tokens than encoding the halves,
    /// which would silently feed the model a different prefix than it was primed
    /// on — so priming is skipped rather than risked when this is false.
    pub fn seam_is_clean(&self, prefix: &str, body: &str) -> Result<bool, String> {
        let whole = self.encode(&format!("{prefix}{body}"))?;
        let mut split = self.encode(prefix)?;
        split.extend(self.encode(body)?);
        Ok(whole == split)
    }

    fn embed_ids(&mut self, ids: &[u32]) -> Result<Vec<f32>, String> {
        let n = ids.len();
        let row: Vec<i64> = ids.iter().map(|&x| x as i64).collect();
        let t = Tensor::from_array((vec![1i64, n as i64], row)).map_err(|e| e.to_string())?;
        let out = self.embed.run(ort::inputs!["input_ids" => t]).map_err(|e| e.to_string())?;
        Ok(super::extract_f32(&out["inputs_embeds"]).map_err(|e| e.to_string())?.1)
    }

    // -- mRoPE positions -----------------------------------------------------

    /// Build the (3, S) mRoPE block (row-major, batch 1) and return the next
    /// free position.
    ///
    /// Text tokens advance all three rows by one in lockstep. An image's tokens
    /// instead get their (t, h, w) coordinate within the merged grid, offset by
    /// the current position, and afterwards the sequence resumes at
    /// `start + max(t, h, w)` rather than `start + n_tokens`.
    ///
    /// That is the whole reason this is a separate function: with an image in
    /// the prompt, POSITION and TOKEN COUNT stop being the same number, so
    /// `attention_mask` (a count) and `position_ids` (a position) have to be
    /// tracked apart from here on. Getting it wrong fails quietly — the model
    /// just sees a slightly scrambled image.
    fn position_ids(ids: &[u32], grids: &[(i64, i64, i64)], start: i64) -> (Vec<i64>, i64) {
        let s = ids.len();
        let mut pos = vec![0i64; 3 * s];
        let (mut i, mut g, mut st) = (0usize, 0usize, start);
        while i < s {
            if ids[i] == IMAGE_PAD && g < grids.len() {
                let (t, h, w) = grids[g];
                g += 1;
                let n = (t * h * w) as usize;
                for k in 0..n.min(s - i) {
                    let k64 = k as i64;
                    pos[i + k] = k64 / (h * w) + st;
                    pos[s + i + k] = (k64 / w) % h + st;
                    pos[2 * s + i + k] = k64 % w + st;
                }
                st += t.max(h).max(w);
                i += n;
            } else {
                pos[i] = st;
                pos[s + i] = st;
                pos[2 * s + i] = st;
                st += 1;
                i += 1;
            }
        }
        (pos, st)
    }

    /// Slice a (3, S) position block down to `[lo, hi)`, keeping the layout the
    /// graph wants.
    fn slice_positions(pos: &[i64], s: usize, lo: usize, hi: usize) -> Vec<i64> {
        let mut out = Vec::with_capacity(3 * (hi - lo));
        for row in 0..3 {
            out.extend_from_slice(&pos[row * s + lo..row * s + hi]);
        }
        out
    }

    // -- prefix caching ------------------------------------------------------

    /// Run a fixed prompt prefix once and snapshot the resulting state.
    pub fn prime(&mut self, prefix: &str) -> Result<Primed, String> {
        let ids = self.encode(prefix)?;
        let s = ids.len();
        let embeds = self.embed_ids(&ids)?;
        let (pos, next) = Self::position_ids(&ids, &[], 0);

        let mut state = State::empty();
        let mut past = 0usize;
        let mut i = 0usize;
        while i < s {
            let j = (i + PRIME_CHUNK).min(s);
            let mut feeds = Self::head_feeds(
                &embeds[i * HIDDEN..j * HIDDEN],
                j - i,
                j,
                &Self::slice_positions(&pos, s, i, j),
            )?;
            state.drain_into(&mut feeds)?;
            let out = self.decoder.run(feeds).map_err(|e| e.to_string())?;
            state.roll(&out)?;
            past = j;
            i = j;
        }
        Ok(Primed { state, past, pos: next, text: prefix.to_string() })
    }

    /// The three non-state decoder inputs.
    fn head_feeds(
        embeds: &[f32],
        seq: usize,
        mask_len: usize,
        positions: &[i64],
    ) -> Result<Vec<(Cow<'static, str>, SessionInputValue<'static>)>, String> {
        let e = Tensor::from_array((vec![1i64, seq as i64, HIDDEN as i64], embeds.to_vec()))
            .map_err(|e| e.to_string())?;
        let m = Tensor::from_array((vec![1i64, mask_len as i64], vec![1i64; mask_len]))
            .map_err(|e| e.to_string())?;
        let p = Tensor::from_array((vec![3i64, 1, seq as i64], positions.to_vec()))
            .map_err(|e| e.to_string())?;
        Ok(vec![
            ("inputs_embeds".into(), e.into()),
            ("attention_mask".into(), m.into()),
            ("position_ids".into(), p.into()),
        ])
    }

    // -- generation ----------------------------------------------------------

    /// Greedy decode. Greedy rather than the config's temp-0.6 sampling because
    /// a labeler has to be reproducible across runs and machines.
    pub fn generate(
        &mut self,
        prompt: &str,
        max_new: usize,
        primed: Option<&Primed>,
        image: Option<&ImageFeatures>,
        stop: &[&str],
    ) -> Result<Generated, String> {
        let t0 = std::time::Instant::now();

        let body = match primed {
            Some(p) => prompt
                .strip_prefix(p.text.as_str())
                .ok_or("prompt does not start with the primed prefix")?,
            None => prompt,
        };
        let ids = self.encode(body)?;
        let mut embeds = self.embed_ids(&ids)?;

        let grids: Vec<(i64, i64, i64)> = match image {
            Some(f) => {
                // Scatter the vision tower's output over the <|image_pad|> run.
                let slots: Vec<usize> =
                    ids.iter().enumerate().filter(|(_, &t)| t == IMAGE_PAD).map(|(i, _)| i).collect();
                if slots.len() != f.n_tokens {
                    return Err(format!(
                        "image placeholder count {} != vision features {}",
                        slots.len(),
                        f.n_tokens
                    ));
                }
                for (k, &slot) in slots.iter().enumerate() {
                    embeds[slot * HIDDEN..(slot + 1) * HIDDEN]
                        .copy_from_slice(&f.features[k * HIDDEN..(k + 1) * HIDDEN]);
                }
                vec![f.merged_grid]
            }
            None => Vec::new(),
        };

        let (mut state, mut past, mut pos_next) = match primed {
            Some(p) => (p.state.clone(), p.past, p.pos),
            None => (State::empty(), 0usize, 0i64),
        };

        // Prefill positions come from the real token layout (images included);
        // every generated token after that is plain text, one position each.
        let s = ids.len();
        let (pos_block, next) = Self::position_ids(&ids, &grids, pos_next);
        pos_next = next;

        let mut cur_embeds = std::mem::take(&mut embeds);
        let mut cur_seq = s;
        let mut cur_pos = pos_block;
        let mut out_ids: Vec<u32> = Vec::new();
        let mut prefill_ms: Option<u64> = None;

        while out_ids.len() < max_new {
            let mut feeds = Self::head_feeds(&cur_embeds, cur_seq, past + cur_seq, &cur_pos)?;
            state.drain_into(&mut feeds)?;
            let out = self.decoder.run(feeds).map_err(|e| e.to_string())?;
            if prefill_ms.is_none() {
                prefill_ms = Some(t0.elapsed().as_millis() as u64);
            }

            let next_tok = argmax_last_row(&out["logits"])?;
            if next_tok == IM_END || next_tok == ENDOFTEXT {
                break;
            }
            out_ids.push(next_tok);

            if !stop.is_empty() {
                let text = self.tokenizer.decode(&out_ids, false).map_err(|e| e.to_string())?;
                if stop.iter().any(|x| text.contains(x)) {
                    break;
                }
            }

            state.roll(&out)?;
            drop(out);
            past += cur_seq;
            cur_embeds = self.embed_ids(&[next_tok])?;
            cur_seq = 1;
            cur_pos = vec![pos_next; 3];
            pos_next += 1;
        }

        let text = self.tokenizer.decode(&out_ids, false).map_err(|e| e.to_string())?;
        Ok(Generated {
            text,
            n_prompt: s,
            n_new: out_ids.len(),
            prefill_ms: prefill_ms.unwrap_or(0),
            total_ms: t0.elapsed().as_millis() as u64,
        })
    }

    // -- vision --------------------------------------------------------------

    /// Run the vision tower → features plus the **merged** grid.
    pub fn vision_features(
        &mut self,
        img: &image::DynamicImage,
        max_pixels: u32,
    ) -> Result<ImageFeatures, String> {
        let vision = self.vision.as_mut().ok_or("vision tower not loaded")?;
        let p = encode_image(img, max_pixels);
        let (t, h, w) = p.grid;
        let px = Tensor::from_array((
            vec![(t * h * w), PATCH_FEATURE_DIM as i64],
            p.pixel_values,
        ))
        .map_err(|e| e.to_string())?;
        let thw = Tensor::from_array((vec![1i64, 3], vec![t, h, w])).map_err(|e| e.to_string())?;
        let out = vision
            .run(ort::inputs!["pixel_values" => px, "image_grid_thw" => thw])
            .map_err(|e| e.to_string())?;
        let features = super::extract_f32(&out["image_features"]).map_err(|e| e.to_string())?.1;
        Ok(ImageFeatures {
            features,
            merged_grid: (t, h / MERGE as i64, w / MERGE as i64),
            n_tokens: p.n_tokens,
        })
    }
}

/// Round half to **even**, matching Python's `round()` / numpy. Rust's
/// `f64::round` breaks ties away from zero instead, which would occasionally
/// pick an image size one 32-px unit off from the reference implementation.
fn round_half_even(x: f64) -> f64 {
    let r = x.round();
    if (x - x.trunc()).abs() == 0.5 && r % 2.0 != 0.0 { r - x.signum() } else { r }
}

/// Qwen2-VL dynamic-resolution patchify. Sides snap to a multiple of
/// `PATCH * MERGE` (32) and the total area is capped, because the placeholder
/// count is area/(32×32) and decode cost is linear in it.
///
/// Note on parity: the reference uses PIL's BICUBIC and we use the `image`
/// crate's CatmullRom. Both are the Keys cubic at a = -0.5, so they agree on
/// intent, but their edge handling differs enough that resampled pixels are not
/// bit-identical. The text path reproduces Python token-for-token; the image
/// path is verified on *labels*, not bytes.
fn encode_image(img: &image::DynamicImage, max_pixels: u32) -> ImagePatches {
    let (w, h) = (img.width().max(1), img.height().max(1));
    let unit = PATCH * MERGE;
    let scale = (max_pixels as f64 / (w as f64 * h as f64)).sqrt().min(1.0);
    let snap = |v: u32| -> u32 {
        let n = round_half_even((v as f64 * scale) / unit as f64) as u32;
        n.max(1) * unit
    };
    let (nw, nh) = (snap(w), snap(h));
    // Skip the filter when the size is already right — PIL short-circuits an
    // identity resize and running CatmullRom anyway would perturb every pixel
    // slightly for nothing.
    let rgb = if (nw, nh) == (w, h) {
        img.to_rgb8()
    } else {
        img.resize_exact(nw, nh, image::imageops::FilterType::CatmullRom).to_rgb8()
    };

    let (grid_h, grid_w) = ((nh / PATCH) as usize, (nw / PATCH) as usize);
    let grid_t = 1usize;
    let patches = grid_t * grid_h * grid_w;
    let mut out = vec![0f32; patches * PATCH_FEATURE_DIM];

    // The reference does this as a 9-D reshape + transpose of a (T, C, H, W)
    // array. Written out, each patch row is
    //   [merge_h][merge_w] → [C][T][py][px]
    // over a `MERGE × MERGE` block of 16×16 patches, and the image is tiled
    // identically across the temporal axis (a still frame repeated T times).
    let p = PATCH as usize;
    let mh = MERGE as usize;
    let blocks_w = grid_w / mh;
    for row in 0..patches {
        // Patch index → (block, position within the 2×2 merge block).
        let block = row / (mh * mh);
        let within = row % (mh * mh);
        let (by, bx) = (block / blocks_w, block % blocks_w);
        let (my, mx) = (within / mh, within % mh);
        let patch_y = (by * mh + my) * p;
        let patch_x = (bx * mh + mx) * p;
        let base = row * PATCH_FEATURE_DIM;
        for c in 0..3 {
            for t in 0..TEMPORAL_PATCH {
                for py in 0..p {
                    for px in 0..p {
                        let pixel = rgb.get_pixel((patch_x + px) as u32, (patch_y + py) as u32);
                        let v = (pixel.0[c] as f32 / 255.0 - IMAGE_MEAN) / IMAGE_STD;
                        out[base + ((c * TEMPORAL_PATCH + t) * p + py) * p + px] = v;
                    }
                }
            }
        }
    }

    ImagePatches {
        pixel_values: out,
        grid: (grid_t as i64, grid_h as i64, grid_w as i64),
        n_tokens: patches / (mh * mh),
    }
}

/// Build an f16 tensor, tolerating a zero-length dimension.
///
/// `Tensor::from_array` rejects any dim < 1 ("all dimensions must be >= 1 when
/// creating a tensor from raw data"), but an empty KV cache is *exactly* a
/// (1, 2, 0, 256) tensor. Florence's decoder sidesteps this by feeding a
/// discarded length-1 dummy on the prefill step, which is safe there only
/// because `use_cache_branch=false` makes the graph ignore the past. There is
/// no such switch here — this graph concatenates past with present
/// unconditionally, so a dummy row would become a real attended token and
/// quietly poison the first step. The allocator path permits zero-size, so use
/// it for those slots.
fn f16_tensor(shape: Vec<i64>, data: Vec<f16>) -> Result<Tensor<f16>, String> {
    if shape.iter().any(|&d| d == 0) {
        return Tensor::new(&Allocator::default(), shape).map_err(|e| e.to_string());
    }
    Tensor::from_array((shape, data)).map_err(|e| e.to_string())
}

/// Extract an f16 tensor as (shape, flat data).
fn extract_f16(value: &ort::value::Value) -> Result<(Vec<i64>, Vec<f16>), String> {
    let (shape, data) = value.try_extract_tensor::<f16>().map_err(|e| e.to_string())?;
    Ok((shape.to_vec(), data.to_vec()))
}

/// Argmax over the last position of an f16 `[1, S, vocab]` logits tensor.
/// Reads the borrowed buffer directly — copying it out would be ~20 MB per
/// prefill at this vocab size, for one number.
fn argmax_last_row(value: &ort::value::Value) -> Result<u32, String> {
    let (shape, data) = value.try_extract_tensor::<f16>().map_err(|e| e.to_string())?;
    let (seq, vocab) = match &shape[..] {
        [_, s, v] => (*s as usize, *v as usize),
        other => return Err(format!("unexpected logits shape {other:?}")),
    };
    let row = &data[(seq - 1) * vocab..seq * vocab];
    let mut best = 0usize;
    let mut best_v = f32::NEG_INFINITY;
    for (i, x) in row.iter().enumerate() {
        let x = x.to_f32();
        if x > best_v {
            best_v = x;
            best = i;
        }
    }
    Ok(best as u32)
}

/// Pull the first balanced `{…}` out of a completion. Small models like to wrap
/// JSON in prose or a fenced block, and a strict parse of the whole string
/// throws away otherwise-good output.
pub fn extract_json(text: &str) -> Option<serde_json::Value> {
    let bytes = text.as_bytes();
    let start = text.find('{')?;
    let (mut depth, mut in_str, mut esc) = (0i32, false, false);
    for i in start..bytes.len() {
        let c = bytes[i];
        if in_str {
            if esc {
                esc = false;
            } else if c == b'\\' {
                esc = true;
            } else if c == b'"' {
                in_str = false;
            }
            continue;
        }
        match c {
            b'"' => in_str = true,
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return serde_json::from_str(&text[start..=i]).ok();
                }
            }
            _ => {}
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layer_types_match_config() {
        let full: Vec<usize> = (0..NUM_LAYERS).filter(|&i| is_full_attention(i)).collect();
        assert_eq!(full, vec![3, 7, 11, 15, 19, 23]);
        assert_eq!((0..NUM_LAYERS).filter(|&i| !is_full_attention(i)).count(), 18);
    }

    #[test]
    fn empty_state_matches_graph_inputs() {
        let s = State::empty();
        assert_eq!(s.slots.len(), NUM_LAYERS * 2);
        // Linear layers are fixed-size and start as real zeros; attention layers
        // start zero-LENGTH. Confusing the two is the classic port bug.
        let conv = s.slots.iter().find(|x| x.input == "past_conv.0").unwrap();
        assert_eq!(conv.shape, vec![1, CONV_DIM, CONV_KERNEL]);
        assert_eq!(conv.data.len(), (CONV_DIM * CONV_KERNEL) as usize);
        let rec = s.slots.iter().find(|x| x.input == "past_recurrent.0").unwrap();
        assert_eq!(rec.data.len(), (REC_HEADS * REC_K_DIM * REC_V_DIM) as usize);
        let kv = s.slots.iter().find(|x| x.input == "past_key_values.3.key").unwrap();
        assert_eq!(kv.shape, vec![1, KV_HEADS, 0, KV_HEAD_DIM]);
        assert!(kv.data.is_empty());
        // No dense 0..17 renumbering: layer 3 has no conv slot.
        assert!(!s.slots.iter().any(|x| x.input == "past_conv.3"));
        assert!(!s.slots.iter().any(|x| x.input == "past_key_values.0.key"));
    }

    #[test]
    fn text_positions_advance_in_lockstep() {
        let ids = vec![10u32, 11, 12];
        let (pos, next) = Qwen35::position_ids(&ids, &[], 0);
        assert_eq!(pos, vec![0, 1, 2, 0, 1, 2, 0, 1, 2]);
        assert_eq!(next, 3);
    }

    #[test]
    fn image_positions_use_grid_coords_and_resume_at_max() {
        // One text token, then a 1×2×3 image block, then one more text token.
        let mut ids = vec![10u32];
        ids.extend(std::iter::repeat(IMAGE_PAD).take(6));
        ids.push(11);
        let (pos, next) = Qwen35::position_ids(&ids, &[(1, 2, 3)], 0);
        let s = ids.len();
        // t is constant, h is [0,0,0,1,1,1], w is [0,1,2,0,1,2] — all offset by 1.
        assert_eq!(&pos[1..7], &[1, 1, 1, 1, 1, 1]);
        assert_eq!(&pos[s + 1..s + 7], &[1, 1, 1, 2, 2, 2]);
        assert_eq!(&pos[2 * s + 1..2 * s + 7], &[1, 2, 3, 1, 2, 3]);
        // Resumes at start + max(t,h,w) = 1 + 3, NOT start + 6 tokens. This is
        // where position and token count part ways.
        assert_eq!(pos[s - 1], 4);
        assert_eq!(next, 5);
    }

    #[test]
    fn patchify_shape_and_token_count() {
        let img = image::DynamicImage::new_rgb8(100, 60);
        let p = encode_image(&img, 448 * 448);
        // Sides snap to a multiple of 32; area is under the cap so no downscale.
        assert_eq!(p.grid, (1, 64 / PATCH as i64, 96 / PATCH as i64));
        let (_, h, w) = p.grid;
        assert_eq!(p.pixel_values.len(), (h * w) as usize * PATCH_FEATURE_DIM);
        assert_eq!(p.n_tokens, (h * w) as usize / 4);
    }

    /// The 9-D reshape+transpose the reference does is the easiest thing in
    /// this file to get subtly wrong — a swapped axis still produces a
    /// correctly-shaped tensor and a plausible-looking caption. So this pins
    /// the actual bytes against values dumped from `harness/qwen35.py`
    /// `encode_image` on the same procedurally-generated image.
    ///
    /// 96×64 is chosen so no resampling happens (already a multiple of 32, and
    /// under the area cap), which isolates the patchify math from the
    /// PIL-vs-`image` filter difference.
    #[test]
    fn patchify_matches_python_reference_bytes() {
        let (w, h) = (96u32, 64u32);
        let img = image::DynamicImage::ImageRgb8(image::ImageBuffer::from_fn(w, h, |x, y| {
            image::Rgb([0u32, 1, 2].map(|c| ((x * 7 + y * 13 + c * 29) % 256) as u8))
        }));
        let p = encode_image(&img, 448 * 448);
        assert_eq!(p.grid, (1, 4, 6));
        assert_eq!(p.n_tokens, 6);
        assert_eq!(p.pixel_values.len(), 24 * PATCH_FEATURE_DIM);

        let sum: f32 = p.pixel_values.iter().sum();
        let absum: f32 = p.pixel_values.iter().map(|x| x.abs()).sum();
        assert!((sum - 16.063_248).abs() < 1e-2, "sum {sum}");
        assert!((absum - 18406.668).abs() < 1.0, "absum {absum}");

        // Individual cells, so a transpose that happens to preserve the sum
        // still fails.
        for (row, k, want) in [
            (0usize, 0usize, -1.0f32),
            (0, 1535, -0.2),
            (1, 0, -0.121_569),
            (5, 777, 0.349_020),
            (23, 1535, -0.952_941),
        ] {
            let got = p.pixel_values[row * PATCH_FEATURE_DIM + k];
            assert!((got - want).abs() < 1e-5, "patch[{row}][{k}] = {got}, want {want}");
        }
    }

    #[test]
    fn patchify_caps_area() {
        let img = image::DynamicImage::new_rgb8(4000, 3000);
        let p = encode_image(&img, 448 * 448);
        let (_, h, w) = p.grid;
        let px = (h * PATCH as i64) * (w * PATCH as i64);
        assert!(px <= (448 * 448) as i64 * 2, "area {px} not capped");
        assert_eq!(p.n_tokens, (h * w) as usize / 4);
    }

    #[test]
    fn json_extracted_from_surrounding_prose() {
        let v = extract_json("Sure! {\"title\": \"a\", \"tags\": [\"b\"]} hope that helps")
            .expect("should parse");
        assert_eq!(v["title"], "a");
    }

    #[test]
    fn json_handles_braces_inside_strings() {
        let v = extract_json(r#"{"title": "a } b", "tags": []}"#).expect("should parse");
        assert_eq!(v["title"], "a } b");
    }

    #[test]
    fn json_none_when_unbalanced() {
        assert!(extract_json("{\"title\": \"a\"").is_none());
        assert!(extract_json("no json here").is_none());
    }
}
