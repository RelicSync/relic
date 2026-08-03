//! Stage 0 text extraction (spec §4): a *feeder*, not a classifier — its
//! output re-enters the text path as a `textblob`. v0.1 ships pure-Rust
//! extractors (pdf-extract, OOXML via zip, HTML tag-strip); a Docling-class
//! layout-aware extractor is a drop-in upgrade later.

use std::io::Read;

/// Cap extracted text so a giant document doesn't bloat records.
const MAX_TEXT: usize = 100 * 1024;

pub fn pdf(bytes: &[u8]) -> Option<String> {
    // pdf-extract can panic on exotic PDFs; contain it.
    let bytes = bytes.to_vec();
    let result = std::panic::catch_unwind(move || pdf_extract::extract_text_from_mem(&bytes));
    match result {
        Ok(Ok(text)) => clean(&text),
        _ => None,
    }
}

/// OOXML (docx/xlsx/pptx): read the XML parts that carry text and strip tags.
pub fn office(bytes: &[u8]) -> Option<String> {
    let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes)).ok()?;
    let names: Vec<String> = zip.file_names().map(str::to_string).collect();
    let mut text = String::new();
    let wanted = |n: &str| {
        n == "word/document.xml"
            || (n.starts_with("ppt/slides/slide") && n.ends_with(".xml"))
            || n == "xl/sharedStrings.xml"
    };
    for name in names.into_iter().filter(|n| wanted(n)) {
        let mut file = zip.by_name(&name).ok()?;
        let mut xml = String::new();
        file.read_to_string(&mut xml).ok()?;
        // Word/PowerPoint runs end with </w:t> / </a:t>; insert separators so
        // words don't fuse, then strip all tags.
        let xml = xml
            .replace("</w:p>", "\n")
            .replace("</a:p>", "\n")
            .replace("</w:t>", " ")
            .replace("</a:t>", " ")
            .replace("</t>", " ");
        text.push_str(&strip_tags(&xml));
        text.push('\n');
        if text.len() > MAX_TEXT {
            break;
        }
    }
    clean(&text)
}

pub fn html(text: &str) -> Option<String> {
    // Drop script/style bodies, then tags.
    let mut s = text.to_string();
    for tag in ["script", "style"] {
        let re = regex::Regex::new(&format!(r"(?is)<{tag}\b.*?</{tag}>")).unwrap();
        s = re.replace_all(&s, " ").into_owned();
    }
    clean(&strip_tags(&s))
}

fn strip_tags(xml: &str) -> String {
    let mut out = String::with_capacity(xml.len() / 2);
    let mut in_tag = false;
    for c in xml.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            c if !in_tag => out.push(c),
            _ => {}
        }
    }
    // minimal entity decode for readability
    out.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

fn clean(text: &str) -> Option<String> {
    let mut lines: Vec<&str> = text.lines().map(str::trim_end).collect();
    while lines.first().is_some_and(|l| l.trim().is_empty()) {
        lines.remove(0);
    }
    let mut joined = String::new();
    let mut blank_run = 0;
    for l in lines {
        if l.trim().is_empty() {
            blank_run += 1;
            if blank_run > 1 {
                continue;
            }
        } else {
            blank_run = 0;
        }
        joined.push_str(l);
        joined.push('\n');
        if joined.len() > MAX_TEXT {
            break;
        }
    }
    let trimmed = joined.trim();
    if trimmed.chars().filter(|c| c.is_alphanumeric()).count() < 8 {
        None
    } else {
        Some(trimmed.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn html_strips_tags_and_scripts() {
        let h = r#"<!doctype html><html><head><style>body{color:red}</style>
<script>var x = 1;</script></head><body><h1>Quarterly Report</h1>
<p>Revenue grew 14% over the previous quarter.</p></body></html>"#;
        let t = html(h).unwrap();
        assert!(t.contains("Quarterly Report"));
        assert!(t.contains("Revenue grew 14%"));
        assert!(!t.contains("var x"));
        assert!(!t.contains("color:red"));
    }

    #[test]
    fn clean_rejects_near_empty() {
        assert!(clean("  \n\n . \n").is_none());
        assert!(clean("hello world, enough text here").is_some());
    }
}
