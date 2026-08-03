//! `A-file` (spec §5.2): magic-byte signature → canonical MIME → route to
//! extraction or the image path. Extensions and declared MIME are never
//! trusted (matches relic-core `sniff_kind` policy).

use crate::record::{Stage, Vote};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileRoute {
    /// Raster image container → image path.
    Image { mime: String },
    /// PDF → Stage 0 text extraction.
    Pdf,
    /// OOXML office docs (docx/xlsx/pptx) → text extraction.
    Office { mime: String },
    /// UTF-8 text (md/txt/html/csv/source) → text path.
    Text,
    /// Archive container — metadata-only classify.
    Archive { mime: String },
    /// Unknown or non-extractable binary — metadata-only classify.
    Binary { mime: Option<String> },
}

pub fn route(bytes: &[u8]) -> (FileRoute, Option<String>, Vec<Vote>) {
    if let Some(t) = infer::get(bytes) {
        let mut mime = t.mime_type().to_string();
        // A plain zip may really be an OOXML doc whose marker entry infer
        // missed (e.g. minimal writers order parts differently) — peek inside.
        if mime == "application/zip" {
            if let Some(office_mime) = sniff_ooxml(bytes) {
                mime = office_mime.to_string();
            }
        }
        let (route, vote) = match mime.as_str() {
            m if m.starts_with("image/") => (FileRoute::Image { mime: mime.clone() }, None),
            "application/pdf" => (FileRoute::Pdf, Some(("file_pdf", "magic:pdf"))),
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            | "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            | "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            | "application/msword" => {
                (FileRoute::Office { mime: mime.clone() }, Some(("file_office", "magic:office")))
            }
            "application/zip" | "application/gzip" | "application/x-tar"
            | "application/vnd.rar" | "application/x-7z-compressed"
            | "application/x-bzip2" | "application/zstd" | "application/x-xz" => {
                (FileRoute::Archive { mime: mime.clone() }, Some(("file_archive", "magic:archive")))
            }
            // infer recognizes some text formats (html, xml, …) — those are
            // still text-path content, not opaque binaries.
            m if m.starts_with("text/") && std::str::from_utf8(bytes).is_ok() => {
                (FileRoute::Text, None)
            }
            _ => (FileRoute::Binary { mime: Some(mime.clone()) }, Some(("file_binary", "magic:binary"))),
        };
        let votes = vote
            .map(|(cat, signal)| vec![Vote::new(cat, 0.9, Stage::AFile, signal)])
            .unwrap_or_default();
        return (route, Some(mime), votes);
    }
    if !bytes.contains(&0) && std::str::from_utf8(bytes).is_ok() {
        return (FileRoute::Text, Some("text/plain".into()), vec![]);
    }
    (
        FileRoute::Binary { mime: None },
        None,
        vec![Vote::new("file_binary", 0.7, Stage::AFile, "magic:unknown_binary")],
    )
}

/// Look inside a zip for OOXML marker entries.
fn sniff_ooxml(bytes: &[u8]) -> Option<&'static str> {
    let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes)).ok()?;
    let mut has_word = false;
    let mut has_xl = false;
    let mut has_ppt = false;
    for i in 0..zip.len() {
        let Ok(f) = zip.by_index_raw(i) else { continue };
        let name = f.name();
        has_word |= name == "word/document.xml";
        has_xl |= name == "xl/workbook.xml";
        has_ppt |= name.starts_with("ppt/presentation.xml");
    }
    if has_word {
        Some("application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    } else if has_xl {
        Some("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    } else if has_ppt {
        Some("application/vnd.openxmlformats-officedocument.presentationml.presentation")
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes_by_magic_bytes() {
        let (r, mime, _) = route(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00");
        assert_eq!(r, FileRoute::Image { mime: "image/png".into() });
        assert_eq!(mime.as_deref(), Some("image/png"));

        let (r, _, v) = route(b"%PDF-1.7\n%binary\n1 0 obj");
        assert_eq!(r, FileRoute::Pdf);
        assert_eq!(v[0].category, "file_pdf");

        let (r, _, v) = route(b"PK\x03\x04\x14\x00\x00\x00\x08\x00\x00\x00");
        assert!(matches!(r, FileRoute::Archive { .. }));
        assert_eq!(v[0].category, "file_archive");

        let (r, _, _) = route("plain old text".as_bytes());
        assert_eq!(r, FileRoute::Text);

        let (r, _, v) = route(b"\xff\xfe\x13\x37\x00\x01\x02\xfa");
        assert!(matches!(r, FileRoute::Binary { .. }));
        assert_eq!(v[0].category, "file_binary");
    }
}
