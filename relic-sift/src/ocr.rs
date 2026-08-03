//! OCR feeder (spec §6.2): runs on every image so extracted text re-enters
//! the text path — a screenshot of an API key is still caught as `api_key` —
//! and provides text-density / keyword signals that sharpen
//! `document_scan` / `receipt` vs `photo`.
//!
//! v0.1 uses the ocrs engine (pure Rust, permissive models). RapidOCR stays
//! the documented upgrade for camera-photo text (spec §8).

use std::path::Path;
use std::sync::LazyLock;

use image::DynamicImage;
use ocrs::{ImageSource, OcrEngine, OcrEngineParams};
use regex::Regex;

use crate::models;
use crate::record::{Stage, Vote};

/// OCR backend: the upgraded PP-OCRv6 engine when its models are present and
/// load cleanly, else the always-available `ocrs` engine. Both yield the same
/// [`OcrOutput`], so the pipeline is agnostic to which ran.
pub enum OcrBackend {
    Ocrs(OcrFeeder),
    Pp(crate::ppocr::PpOcr),
}

impl OcrBackend {
    pub fn load(model_dir: &Path) -> Result<Self, String> {
        if crate::models::ocr_v6_present(model_dir) {
            match crate::ppocr::PpOcr::load(model_dir) {
                Ok(p) => return Ok(OcrBackend::Pp(p)),
                Err(e) => eprintln!("PP-OCRv6 load failed, falling back to ocrs: {e}"),
            }
        }
        Ok(OcrBackend::Ocrs(OcrFeeder::load(model_dir)?))
    }

    pub fn run(&mut self, img: &DynamicImage) -> Result<OcrOutput, String> {
        let out = match self {
            OcrBackend::Ocrs(f) => f.run(img)?,
            OcrBackend::Pp(p) => p.run(img)?,
        };
        Ok(denoise(out))
    }

    pub fn model_version(&self) -> &str {
        match self {
            OcrBackend::Ocrs(f) => &f.model_version,
            OcrBackend::Pp(p) => &p.model_version,
        }
    }
}

pub struct OcrFeeder {
    engine: OcrEngine,
    pub model_version: String,
}

#[derive(Debug, Clone, Default)]
pub struct OcrOutput {
    pub text: String,
    pub word_count: usize,
    /// Fraction of image area covered by detected words.
    pub coverage: f32,
}

impl OcrFeeder {
    pub fn load(model_dir: &Path) -> Result<Self, String> {
        let det_path = models::file_path(model_dir, &models::OCR.files[0]);
        let rec_path = models::file_path(model_dir, &models::OCR.files[1]);
        let detection_model =
            rten::Model::load_file(&det_path).map_err(|e| format!("load {}: {e}", det_path.display()))?;
        let recognition_model =
            rten::Model::load_file(&rec_path).map_err(|e| format!("load {}: {e}", rec_path.display()))?;
        let engine = OcrEngine::new(OcrEngineParams {
            detection_model: Some(detection_model),
            recognition_model: Some(recognition_model),
            ..Default::default()
        })
        .map_err(|e| format!("ocr engine: {e}"))?;
        Ok(OcrFeeder { engine, model_version: models::OCR.version.to_string() })
    }

    pub fn run(&self, img: &DynamicImage) -> Result<OcrOutput, String> {
        let rgb = img.to_rgb8();
        let (w, h) = rgb.dimensions();
        let source =
            ImageSource::from_bytes(rgb.as_raw(), (w, h)).map_err(|e| format!("ocr input: {e}"))?;
        let input = self.engine.prepare_input(source).map_err(|e| format!("ocr prepare: {e}"))?;
        let words = self.engine.detect_words(&input).map_err(|e| format!("ocr detect: {e}"))?;
        let word_count = words.len();
        let img_area = (w as f32) * (h as f32);
        let coverage: f32 =
            words.iter().map(|r| r.area()).sum::<f32>() / img_area.max(1.0);

        let lines = self.engine.find_text_lines(&input, &words);
        let texts = self
            .engine
            .recognize_text(&input, &lines)
            .map_err(|e| format!("ocr recognize: {e}"))?;
        let text = texts
            .into_iter()
            .flatten()
            .map(|l| l.to_string())
            .filter(|l| !l.trim().is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        Ok(OcrOutput { text, word_count, coverage: coverage.clamp(0.0, 1.0) })
    }
}

/// Below this many alphanumeric characters the OCR output is treated as no
/// text at all. A textless photo (fur, foliage, faces) makes the detector fire
/// on high-contrast regions; the per-line confidence gate removes most of those
/// decodes, but an occasional confident single glyph survives. One or two stray
/// characters are never meaningful capture content — and they were the source
/// of titles like "P" / "A" and spurious OCR-fed category votes — so we drop
/// the whole output. Any real text (a word, a price, a line) clears this.
const MIN_ALNUM: usize = 3;

/// Suppress OCR output that carries no real text (see [`MIN_ALNUM`]).
fn denoise(out: OcrOutput) -> OcrOutput {
    let alnum = out.text.chars().filter(|c| c.is_alphanumeric()).count();
    if alnum < MIN_ALNUM {
        OcrOutput::default()
    } else {
        out
    }
}

static CURRENCY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[$€£]\s?\d+[.,]\d{2}|\b\d+[.,]\d{2}\b").unwrap());

const RECEIPT_WORDS: &[&str] = &[
    "total", "subtotal", "tax", "change", "cash", "visa", "mastercard", "receipt", "qty",
    "amount due", "invoice", "payment", "tender", "balance",
];

/// Density/keyword votes from OCR output (spec §6.2): weak evidence that
/// sharpens `document_scan` / `receipt`; CLIP arbitrates.
pub fn density_votes(ocr: &OcrOutput) -> Vec<Vote> {
    let mut votes = Vec::new();
    let lower = ocr.text.to_lowercase();
    let kw_hits = RECEIPT_WORDS.iter().filter(|w| lower.contains(**w)).count();
    let amounts = CURRENCY.find_iter(&ocr.text).count();
    if kw_hits >= 2 && amounts >= 2 {
        votes.push(Vote::new("receipt", 0.6, Stage::AImage, "ocr:receipt_keywords"));
    }
    if ocr.word_count >= 60 && ocr.coverage >= 0.12 {
        votes.push(Vote::new("document_scan", 0.45, Stage::AImage, "ocr:text_density"));
    }
    votes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn receipt_keywords_need_amounts_too() {
        let o = OcrOutput {
            text: "WALMART\nSUBTOTAL 23.48\nTAX 1.93\nTOTAL $25.41\nVISA 25.41".into(),
            word_count: 10,
            coverage: 0.1,
        };
        assert!(density_votes(&o).iter().any(|v| v.category == "receipt"));
        let o2 = OcrOutput { text: "total eclipse of the heart".into(), word_count: 5, coverage: 0.05 };
        assert!(density_votes(&o2).is_empty());
    }

    #[test]
    fn denoise_drops_stray_glyphs_keeps_real_text() {
        // Stray single/double glyphs from textless photos → no text. The floor
        // is 3 alphanumerics, so even a confident 2-glyph pair ("OK!", "S6") is
        // dropped — never a real image capture, always detector noise.
        for junk in ["P", "A", "S\n6", "日 m", "OK!", ""] {
            let o = OcrOutput { text: junk.into(), word_count: 1, coverage: 0.01 };
            assert!(denoise(o).text.is_empty(), "should drop {junk:?}");
        }
        // Any genuine word / price / line survives.
        for real in ["yes", "5.25", "hello", "CORNER CAFE"] {
            let o = OcrOutput { text: real.into(), word_count: 2, coverage: 0.05 };
            assert_eq!(denoise(o).text, real, "should keep {real:?}");
        }
    }
}
