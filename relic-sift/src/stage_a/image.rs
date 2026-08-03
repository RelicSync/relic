//! `A-image` (spec §5.3): EXIF presence + dimensions → *priors* (≤ 0.75),
//! not finals — Stage B confirms, because EXIF can be stripped from photos
//! and present on edited screenshots.

use std::io::Cursor;

use crate::record::{Stage, Vote};

#[derive(Debug, Clone, Default)]
pub struct ImageMeta {
    pub width: u32,
    pub height: u32,
    pub mime: Option<String>,
    pub has_camera_exif: bool,
}

/// Typical device widths (desktop monitors + phones) for the screenshot prior.
const SCREEN_WIDTHS: &[u32] = &[
    1024, 1280, 1366, 1440, 1512, 1536, 1600, 1680, 1728, 1920, 2048, 2560, 2880, 3024, 3440,
    3840, 720, 750, 828, 1080, 1125, 1170, 1179, 1284, 1290, 1344,
];

const SCREEN_ASPECTS: &[f64] = &[
    16.0 / 9.0,
    16.0 / 10.0,
    4.0 / 3.0,
    3.0 / 2.0,
    21.0 / 9.0,
    19.5 / 9.0,
    20.0 / 9.0,
];

pub fn analyze(bytes: &[u8], width: u32, height: u32, mime: Option<&str>) -> (ImageMeta, Vec<Vote>) {
    let mut meta = ImageMeta {
        width,
        height,
        mime: mime.map(str::to_string),
        has_camera_exif: false,
    };

    if let Ok(exif) = exif::Reader::new().read_from_container(&mut Cursor::new(bytes)) {
        let has = |tag| exif.get_field(tag, exif::In::PRIMARY).is_some();
        meta.has_camera_exif = has(exif::Tag::Make)
            || has(exif::Tag::Model)
            || has(exif::Tag::DateTimeOriginal)
            || has(exif::Tag::FNumber);
    }

    let mut votes = Vec::new();
    let is_png = mime == Some("image/png");
    if meta.has_camera_exif {
        votes.push(Vote::new("photo", 0.75, Stage::AImage, "exif_camera_tags"));
    } else if is_png && screen_like(width, height) {
        votes.push(Vote::new("screenshot", 0.7, Stage::AImage, "no_exif+screen_dims"));
    } else if is_png {
        // Cameras don't write PNG; a PNG with no EXIF is usually rendered or
        // captured. Weak prior — Stage B decides.
        votes.push(Vote::new("screenshot", 0.55, Stage::AImage, "png_no_exif"));
    } else {
        // JPEG/WebP/HEIC without EXIF: cameras and photo pipelines own these
        // formats, and camera aspect ratios (4:3, 3:2) overlap screen ratios,
        // so dimensions say nothing here. CLIP can still override clearly.
        votes.push(Vote::new("photo", 0.5, Stage::AImage, "jpeg_no_exif"));
    }
    (meta, votes)
}

fn screen_like(w: u32, h: u32) -> bool {
    if w.min(h) < 480 {
        return false;
    }
    let (long, short) = (w.max(h) as f64, w.min(h) as f64);
    let aspect = long / short;
    let aspect_ok = SCREEN_ASPECTS.iter().any(|a| (aspect - a).abs() / a < 0.02);
    let width_ok = SCREEN_WIDTHS.contains(&w.max(h)) || SCREEN_WIDTHS.contains(&w.min(h));
    aspect_ok || width_ok
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_screen_dims_get_screenshot_prior() {
        // 1x1 transparent png (no exif)
        let png: &[u8] = &[
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
            0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00,
            0x00, 0x1F, 0x15, 0xC4, 0x89,
        ];
        let (_, votes) = analyze(png, 1920, 1080, Some("image/png"));
        assert!(votes.iter().any(|v| v.category == "screenshot" && v.score >= 0.7), "{votes:?}");

        let (_, votes) = analyze(png, 833, 521, Some("image/png"));
        assert!(votes.iter().any(|v| v.category == "screenshot" && v.score >= 0.5), "{votes:?}");
    }

    #[test]
    fn screen_like_table() {
        assert!(screen_like(1920, 1080));
        assert!(screen_like(2560, 1440));
        assert!(screen_like(1170, 2532)); // iPhone portrait
        assert!(!screen_like(4032, 3024) || SCREEN_ASPECTS.iter().any(|a| (4032.0 / 3024.0 - a).abs() / a < 0.02));
        assert!(!screen_like(100, 80)); // tiny icon
    }
}
