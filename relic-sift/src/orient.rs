//! Image decode that honors the camera's orientation.
//!
//! Phones store a portrait photo as landscape pixels plus an EXIF
//! `Orientation` tag that says "rotate before showing". Every viewer obeys the
//! tag, so the photo looks upright to the user, but `image::load_from_memory`
//! ignores it and hands back the raw sideways pixels. OCR then reads a page of
//! vertical text and returns noise ("S", "6A" off a full tax letter), and CLIP
//! and the labeler see a sideways scene.
//!
//! Every place sift turns image bytes into pixels goes through
//! [`decode_upright`] so no stage can see the raw orientation again.

use std::io::Cursor;

use image::metadata::Orientation;
use image::{DynamicImage, ImageDecoder, ImageReader};

/// Decode `bytes` and rotate/flip the pixels the way the file says to display
/// them. The orientation comes from the codec (JPEG, PNG, WebP, TIFF, AVIF
/// EXIF), and falls back to a direct EXIF read when the codec reports none, so
/// a tag in a container the codec does not look at still counts. A malformed
/// or missing tag leaves the pixels as decoded; it never fails the decode.
pub fn decode_upright(bytes: &[u8]) -> Result<DynamicImage, String> {
    let mut decoder = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|e| e.to_string())?
        .into_decoder()
        .map_err(|e| e.to_string())?;
    let from_codec = decoder.orientation().unwrap_or(Orientation::NoTransforms);
    let mut img = DynamicImage::from_decoder(decoder).map_err(|e| e.to_string())?;
    let orientation = match from_codec {
        Orientation::NoTransforms => exif_orientation(bytes).unwrap_or(Orientation::NoTransforms),
        o => o,
    };
    img.apply_orientation(orientation);
    Ok(img)
}

/// Read a file from disk and decode it upright (see [`decode_upright`]).
pub fn open_upright(path: &std::path::Path) -> Result<DynamicImage, String> {
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    decode_upright(&bytes)
}

/// The EXIF `Orientation` tag read straight from the container, independent of
/// the image codec.
fn exif_orientation(bytes: &[u8]) -> Option<Orientation> {
    let exif = exif::Reader::new()
        .read_from_container(&mut Cursor::new(bytes))
        .ok()?;
    let field = exif.get_field(exif::Tag::Orientation, exif::In::PRIMARY)?;
    let v = field.value.get_uint(0)?;
    Orientation::from_exif(u8::try_from(v).ok()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageFormat, Rgb, RgbImage};

    /// A 40x20 landscape JPEG with a dark left band, plus an APP1 EXIF segment
    /// carrying `orientation`, spliced in right after SOI.
    fn jpeg_with_orientation(orientation: u16) -> Vec<u8> {
        let mut img = RgbImage::from_pixel(40, 20, Rgb([255, 255, 255]));
        for y in 0..20 {
            for x in 0..10 {
                img.put_pixel(x, y, Rgb([0, 0, 0])); // dark left band
            }
        }
        let mut jpeg = Vec::new();
        DynamicImage::ImageRgb8(img)
            .write_to(&mut Cursor::new(&mut jpeg), ImageFormat::Jpeg)
            .unwrap();

        // Minimal big-endian TIFF: one IFD with a single Orientation (0x0112) SHORT.
        let mut tiff = vec![b'M', b'M', 0, 42, 0, 0, 0, 8];
        tiff.extend_from_slice(&[0, 1]); // one entry
        tiff.extend_from_slice(&[0x01, 0x12, 0, 3, 0, 0, 0, 1]);
        tiff.extend_from_slice(&orientation.to_be_bytes());
        tiff.extend_from_slice(&[0, 0]); // value padding
        tiff.extend_from_slice(&[0, 0, 0, 0]); // no next IFD
        let mut app1 = b"Exif\0\0".to_vec();
        app1.extend_from_slice(&tiff);
        let len = (app1.len() + 2) as u16;

        let mut out = jpeg[..2].to_vec(); // SOI
        out.extend_from_slice(&[0xFF, 0xE1]);
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(&app1);
        out.extend_from_slice(&jpeg[2..]);
        out
    }

    fn dark(img: &DynamicImage, x: u32, y: u32) -> bool {
        img.to_luma8().get_pixel(x, y).0[0] < 100
    }

    #[test]
    fn no_tag_keeps_the_pixels() {
        let img = decode_upright(&jpeg_with_orientation(1)).unwrap();
        assert_eq!((img.width(), img.height()), (40, 20));
        assert!(dark(&img, 2, 10));
    }

    #[test]
    fn rotate_90_tag_turns_the_photo_upright() {
        // Orientation 6: the stored pixels must be turned 90° clockwise, so the
        // left band ends up along the top.
        let img = decode_upright(&jpeg_with_orientation(6)).unwrap();
        assert_eq!((img.width(), img.height()), (20, 40));
        assert!(dark(&img, 10, 2));
        assert!(!dark(&img, 10, 37));
    }

    #[test]
    fn rotate_270_and_180_tags_are_honored() {
        let r270 = decode_upright(&jpeg_with_orientation(8)).unwrap();
        assert_eq!((r270.width(), r270.height()), (20, 40));
        assert!(dark(&r270, 10, 37)); // left band ends up along the bottom
        let r180 = decode_upright(&jpeg_with_orientation(3)).unwrap();
        assert_eq!((r180.width(), r180.height()), (40, 20));
        assert!(dark(&r180, 37, 10)); // left band ends up on the right
    }

    #[test]
    fn a_bogus_tag_value_is_ignored() {
        let img = decode_upright(&jpeg_with_orientation(42)).unwrap();
        assert_eq!((img.width(), img.height()), (40, 20));
    }

    #[test]
    fn garbage_is_an_error_not_a_panic() {
        assert!(decode_upright(b"not an image").is_err());
    }
}
