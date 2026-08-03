//! PP-OCRv6 mobile OCR backend (PaddleOCR det + rec via ONNX Runtime), an
//! optional upgrade over the default `ocrs` engine. Validated offline at CER
//! 0.084→0.030 / WER 0.218→0.049 and, crucially, it does not corrupt API keys
//! or receipt prices. Selected only when its models are present; the pipeline
//! keeps `ocrs` as the always-available fallback.
//!
//! Detection: DB probability map → threshold → horizontal close → connected
//! components → axis-aligned line boxes (good for the screenshots / receipts /
//! documents that dominate captures; rotated text degrades like ocrs).
//! Recognition: per-box crop → height-48 → CTC greedy decode against the
//! 18,708-entry dictionary (`["blank"] + dict + [" "]`, blank index 0).

use std::path::Path;

use image::DynamicImage;
use ort::session::Session;
use ort::value::Tensor;

use crate::models;
use crate::ocr::OcrOutput;
use crate::stage_b::extract_f32;

const DET_MAX_SIDE: u32 = 960;
const DET_THRESH: f32 = 0.3;
const REC_HEIGHT: u32 = 48;
const NORM_MEAN: f32 = 0.5;
const NORM_STD: f32 = 0.5;
/// Minimum mean per-character recognition confidence to keep a line. The DB
/// detector fires on any high-contrast region (dog fur, eyes, foliage), and the
/// CTC head will greedily decode such non-text crops into a stray glyph or two.
/// Those decodes are low-confidence; this gate drops them so junk text never
/// reaches the title/preview or the OCR-fed text classifier. 0.5 is PaddleOCR's
/// own default `drop_score`.
const REC_DROP_SCORE: f32 = 0.5;

pub struct PpOcr {
    det: Session,
    rec: Session,
    /// Full CTC class table: index 0 = blank, 1..=N = dict chars, last = space.
    chars: Vec<String>,
    pub model_version: String,
}

impl PpOcr {
    pub fn load(model_dir: &Path) -> Result<Self, String> {
        crate::ensure_runtime(model_dir)?;
        let det = make_session(&models::file_path(model_dir, &models::OCR_V6.files[0]))?;
        let rec = make_session(&models::file_path(model_dir, &models::OCR_V6.files[1]))?;
        // The keys file is the full PaddleOCR CTC table already: index 0 =
        // "blank" (skipped in decode), then the dictionary, then a trailing
        // space — index maps 1:1 to the rec head's 18,710 classes.
        let keys_path = models::file_path(model_dir, &models::OCR_V6.files[2]);
        let dict = std::fs::read_to_string(&keys_path)
            .map_err(|e| format!("load {}: {e}", keys_path.display()))?;
        let chars: Vec<String> = dict.split('\n').map(str::to_string).collect();
        Ok(PpOcr { det, rec, chars, model_version: models::OCR_V6.version.to_string() })
    }

    pub fn run(&mut self, img: &DynamicImage) -> Result<OcrOutput, String> {
        let rgb = img.to_rgb8();
        let (ow, oh) = rgb.dimensions();
        let boxes = self.detect(&rgb)?;
        if boxes.is_empty() {
            return Ok(OcrOutput::default());
        }
        let img_area = (ow as f32) * (oh as f32);
        let mut covered = 0f32;
        let mut lines: Vec<(i32, i32, String)> = Vec::new();
        for b in &boxes {
            let crop = image::imageops::crop_imm(&rgb, b.x, b.y, b.w, b.h).to_image();
            let (text, conf) = self.recognize(&crop)?;
            // Drop low-confidence decodes (non-text crops the detector picked up)
            // and count coverage only for the boxes we actually keep.
            if !text.trim().is_empty() && conf >= REC_DROP_SCORE {
                covered += (b.w as f32) * (b.h as f32);
                lines.push((b.y as i32, b.x as i32, text));
            }
        }
        // Reading order: top-to-bottom, then left-to-right within a line band.
        lines.sort_by(|a, b| {
            if (a.0 - b.0).abs() <= (REC_HEIGHT as i32 / 2) {
                a.1.cmp(&b.1)
            } else {
                a.0.cmp(&b.0)
            }
        });
        let text = lines.iter().map(|l| l.2.as_str()).collect::<Vec<_>>().join("\n");
        let word_count = text.split_whitespace().count();
        let coverage = (covered / img_area.max(1.0)).clamp(0.0, 1.0);
        Ok(OcrOutput { text, word_count, coverage })
    }

    /// DB detection → axis-aligned line boxes in original-image coordinates.
    fn detect(&mut self, rgb: &image::RgbImage) -> Result<Vec<Box2>, String> {
        let (ow, oh) = rgb.dimensions();
        // Resize: cap the long side at DET_MAX_SIDE, round both to a multiple of 32.
        let scale = (DET_MAX_SIDE as f32 / ow.max(oh) as f32).min(1.0);
        let rw = (((ow as f32 * scale) as u32).max(32) + 31) / 32 * 32;
        let rh = (((oh as f32 * scale) as u32).max(32) + 31) / 32 * 32;
        let resized =
            image::imageops::resize(rgb, rw, rh, image::imageops::FilterType::Triangle);

        let hw = (rw * rh) as usize;
        let mut input = vec![0f32; 3 * hw];
        for (i, px) in resized.pixels().enumerate() {
            for c in 0..3 {
                input[c * hw + i] = (px.0[c] as f32 / 255.0 - NORM_MEAN) / NORM_STD;
            }
        }
        let t = Tensor::from_array((vec![1i64, 3, rh as i64, rw as i64], input))
            .map_err(|e| e.to_string())?;
        let outputs = self.det.run(ort::inputs!["x" => t]).map_err(|e| e.to_string())?;
        let (shape, prob) = extract_f32(&outputs[0]).map_err(|e| e.to_string())?;
        // [1,1,H,W]
        let (ph, pw) = (shape[2], shape[3]);

        // Threshold → binary, then a horizontal close to join glyphs into lines.
        let mut bin = vec![false; ph * pw];
        for i in 0..ph * pw {
            bin[i] = prob[i] > DET_THRESH;
        }
        let dilate = (pw as f32 * 0.012).round().max(2.0) as usize;
        let closed = hclose(&bin, ph, pw, dilate);

        // Connected components → boxes; map back to original coords.
        let sx = ow as f32 / pw as f32;
        let sy = oh as f32 / ph as f32;
        let mut boxes = Vec::new();
        for (x0, y0, x1, y1) in components(&closed, ph, pw) {
            let bw = (x1 - x0 + 1) as u32;
            let bh = (y1 - y0 + 1) as u32;
            if bw < 4 || bh < 4 {
                continue; // noise
            }
            // Map to original coords, padding in ORIGINAL pixels (the box is in
            // detection space, so scale the pad by sx/sy). A small vertical pad
            // recovers ascenders/descenders the tight DB map clips; minimal
            // horizontal pad avoids bleeding in neighbouring glyphs.
            let padx = (bh as f32 * 0.10 * sy) as i32;
            let pady = (bh as f32 * 0.30 * sy) as i32;
            let ox = (((x0 as f32) * sx) as i32 - padx).max(0) as u32;
            let oy = (((y0 as f32) * sy) as i32 - pady).max(0) as u32;
            let ox1 = ((((x1 + 1) as f32) * sx) as i32 + padx).min(ow as i32) as u32;
            let oy1 = ((((y1 + 1) as f32) * sy) as i32 + pady).min(oh as i32) as u32;
            if ox1 > ox && oy1 > oy {
                boxes.push(Box2 { x: ox, y: oy, w: ox1 - ox, h: oy1 - oy });
            }
        }
        Ok(boxes)
    }

    /// CTC recognition of a single text-line crop. Returns the decoded string
    /// and the mean softmax confidence over the emitted (non-blank) timesteps —
    /// the caller uses that to drop garbage decoded from non-text crops.
    fn recognize(&mut self, crop: &image::RgbImage) -> Result<(String, f32), String> {
        let (cw, ch) = crop.dimensions();
        if cw == 0 || ch == 0 {
            return Ok((String::new(), 0.0));
        }
        let rw = ((REC_HEIGHT as f32 * cw as f32 / ch as f32).round() as u32).clamp(8, 2400);
        let resized =
            image::imageops::resize(crop, rw, REC_HEIGHT, image::imageops::FilterType::Triangle);
        let hw = (rw * REC_HEIGHT) as usize;
        let mut input = vec![0f32; 3 * hw];
        for (i, px) in resized.pixels().enumerate() {
            for c in 0..3 {
                input[c * hw + i] = (px.0[c] as f32 / 255.0 - NORM_MEAN) / NORM_STD;
            }
        }
        let t = Tensor::from_array((vec![1i64, 3, REC_HEIGHT as i64, rw as i64], input))
            .map_err(|e| e.to_string())?;
        let outputs = self.rec.run(ort::inputs!["x" => t]).map_err(|e| e.to_string())?;
        let (shape, probs) = extract_f32(&outputs[0]).map_err(|e| e.to_string())?;
        // [1, T, C] — the PP-OCRv6 rec head emits per-step softmax
        // probabilities, so the argmax value IS the class confidence (no extra
        // softmax needed; that's how PaddleOCR computes its `drop_score`).
        let (steps, classes) = (shape[1], shape[2]);
        let mut out = String::new();
        let mut prev = usize::MAX;
        let mut conf_sum = 0f32;
        let mut emitted = 0usize;
        for s in 0..steps {
            let row = &probs[s * classes..s * classes + classes];
            let mut best = 0usize;
            let mut bestv = f32::NEG_INFINITY;
            for (j, &v) in row.iter().enumerate() {
                if v > bestv {
                    bestv = v;
                    best = j;
                }
            }
            if best != 0 && best != prev {
                if let Some(ch) = self.chars.get(best) {
                    out.push_str(ch);
                    conf_sum += bestv.clamp(0.0, 1.0);
                    emitted += 1;
                }
            }
            prev = best;
        }
        let conf = if emitted > 0 { conf_sum / emitted as f32 } else { 0.0 };
        Ok((out, conf))
    }
}

struct Box2 {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
}

fn make_session(path: &Path) -> Result<Session, String> {
    Session::builder()
        .map_err(|e| e.to_string())?
        .with_optimization_level(ort::session::builder::GraphOptimizationLevel::Level3)
        .map_err(|e| e.to_string())?
        .with_intra_threads(2)
        .map_err(|e| e.to_string())?
        .commit_from_file(path)
        .map_err(|e| format!("load {}: {e}", path.display()))
}

/// Horizontal morphological close (dilate then erode by `r`) to connect glyphs
/// on the same text line into one component without bridging separate lines.
fn hclose(bin: &[bool], h: usize, w: usize, r: usize) -> Vec<bool> {
    let dil = hmorph(bin, h, w, r, true);
    hmorph(&dil, h, w, r, false)
}

fn hmorph(src: &[bool], h: usize, w: usize, r: usize, dilate: bool) -> Vec<bool> {
    let mut out = vec![false; h * w];
    for y in 0..h {
        let row = y * w;
        for x in 0..w {
            let lo = x.saturating_sub(r);
            let hi = (x + r).min(w - 1);
            let mut hit = false;
            for k in lo..=hi {
                if src[row + k] {
                    hit = true;
                    break;
                }
            }
            // dilate: any neighbor set; erode: out set only if all neighbors set.
            out[row + x] = if dilate {
                hit
            } else {
                let mut all = true;
                for k in lo..=hi {
                    if !src[row + k] {
                        all = false;
                        break;
                    }
                }
                all
            };
        }
    }
    out
}

/// Two-pass connected components (4/8-neighbour via union-find), returning
/// (x0,y0,x1,y1) bounding boxes.
fn components(bin: &[bool], h: usize, w: usize) -> Vec<(usize, usize, usize, usize)> {
    let mut parent: Vec<usize> = (0..h * w).collect();
    fn find(p: &mut [usize], mut i: usize) -> usize {
        while p[i] != i {
            p[i] = p[p[i]];
            i = p[i];
        }
        i
    }
    fn union(p: &mut [usize], a: usize, b: usize) {
        let (ra, rb) = (find(p, a), find(p, b));
        if ra != rb {
            p[ra] = rb;
        }
    }
    for y in 0..h {
        for x in 0..w {
            let i = y * w + x;
            if !bin[i] {
                continue;
            }
            if x > 0 && bin[i - 1] {
                union(&mut parent, i, i - 1);
            }
            if y > 0 && bin[i - w] {
                union(&mut parent, i, i - w);
            }
            if y > 0 && x > 0 && bin[i - w - 1] {
                union(&mut parent, i, i - w - 1);
            }
            if y > 0 && x + 1 < w && bin[i - w + 1] {
                union(&mut parent, i, i - w + 1);
            }
        }
    }
    use std::collections::HashMap;
    let mut boxes: HashMap<usize, (usize, usize, usize, usize)> = HashMap::new();
    for y in 0..h {
        for x in 0..w {
            let i = y * w + x;
            if !bin[i] {
                continue;
            }
            let r = find(&mut parent, i);
            let e = boxes.entry(r).or_insert((x, y, x, y));
            e.0 = e.0.min(x);
            e.1 = e.1.min(y);
            e.2 = e.2.max(x);
            e.3 = e.3.max(y);
        }
    }
    boxes.into_values().collect()
}
