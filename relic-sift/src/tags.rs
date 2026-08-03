//! The searchable tag vocabulary + a natural-language gloss per tag, used to
//! build the query-side tag-expansion table (`sift tags vectors`). The gloss is
//! embedded (document prefix) so a conceptual query can match a tag in the same
//! space the query matches documents — e.g. "scribbled notes" → `handwriting`.
//!
//! The gloss unit is the **tag string**, not the category: several categories
//! map to one tag (`api_key` + `secret_other` → `secret`), and structural /
//! language tags come from `stage_a`, not the taxonomy. So glosses live in one
//! table here, keyed by tag, and a test asserts every searchable tag has one.

use crate::taxonomy::Taxonomy;

/// Structural (whole-string) tags emitted by `stage_a::text::structural_tags`.
pub const STRUCTURAL_TAGS: &[&str] = &[
    "url", "email", "phone", "ip", "color", "json", "secret", "path", "markdown", "code", "xml",
    "toml", "ini", "yaml", "csv", "uuid", "version", "date", "geo", "crypto", "iban", "tracking",
    "otp", "mac-address", "vin", "credit-card", "isbn", "jwt",
];

/// Programming-language tags emitted by `stage_a::text::code_language`.
pub const LANGUAGE_TAGS: &[&str] =
    &["python", "rust", "javascript", "go", "java", "sql", "shell", "powershell", "cpp"];

/// tag → gloss. A concise description of what the tag means, written for query
/// matching (not for the image classifier). Must cover every searchable tag.
const TAG_GLOSSES: &[(&str, &str)] = &[
    // category tags
    ("secret", "a password, API key, token, or other credential"),
    ("url", "a web link or URL"),
    ("tracking", "a package or shipment tracking number"),
    ("otp", "a one-time passcode or verification code"),
    ("address", "a street or mailing address"),
    ("todo", "a to-do list or list of tasks"),
    ("note", "a personal note or written memo"),
    ("mail", "an email message"),
    ("chat", "a chat or text-message conversation"),
    ("code", "source code or a programming snippet"),
    ("log", "a log line or application log output"),
    ("data", "structured data such as JSON, CSV, or a table"),
    ("screenshot", "a screenshot of a screen or app"),
    ("photo", "a photograph"),
    ("scan", "a scanned document or page"),
    ("receipt", "a store receipt or purchase invoice"),
    ("diagram", "a diagram, flowchart, or chart"),
    ("meme", "an internet meme image"),
    ("file", "a saved file or document"),
    ("archive", "a zip or compressed archive file"),
    // image content tags
    ("people", "a photo of a person or group of people"),
    ("animal", "a photo of an animal or pet"),
    ("food", "a photo of food or a meal"),
    ("nature", "a photo of nature, landscape, or scenery"),
    ("city", "a photo of a city, street, or buildings"),
    ("vehicle", "a photo of a car, truck, or vehicle"),
    ("whiteboard", "a photo of a whiteboard with notes or diagrams"),
    ("qrcode", "a QR code or barcode"),
    ("chart", "a chart or graph"),
    ("product", "a product or item for sale"),
    ("handwriting", "handwritten notes, cursive, or scribbled writing"),
    ("id-document", "an ID card, passport, or driver's license"),
    ("map", "a map or navigation view"),
    ("art", "a painting, drawing, or piece of artwork"),
    ("plant", "a plant, flower, or garden"),
    ("logo", "a brand logo or app icon"),
    ("sign", "a street sign, poster, or other signage"),
    ("device", "an electronic device or gadget"),
    ("medical", "a medical image, x-ray, or health document"),
    ("book", "a book or book cover"),
    // structural tags
    ("email", "an email address"),
    ("phone", "a phone number"),
    ("ip", "an IP address"),
    ("color", "a color or hex color code"),
    ("json", "JSON data"),
    ("path", "a file path or directory location"),
    ("markdown", "Markdown-formatted text"),
    ("xml", "XML data or markup"),
    ("toml", "a TOML configuration"),
    ("ini", "an INI configuration file"),
    ("yaml", "YAML configuration or data"),
    ("csv", "CSV or comma-separated tabular data"),
    ("uuid", "a UUID or unique identifier"),
    ("version", "a software version number"),
    ("date", "a calendar date"),
    ("geo", "geographic coordinates (latitude and longitude)"),
    ("crypto", "a cryptocurrency wallet address"),
    ("iban", "a bank account number (IBAN)"),
    ("mac-address", "a network MAC address"),
    ("vin", "a vehicle identification number (VIN)"),
    ("credit-card", "a credit or debit card number"),
    ("isbn", "a book ISBN number"),
    ("jwt", "a JWT authentication token"),
    // language tags
    ("python", "Python programming-language code"),
    ("rust", "Rust programming-language code"),
    ("javascript", "JavaScript code"),
    ("go", "Go programming-language code"),
    ("java", "Java programming-language code"),
    ("sql", "a SQL database query"),
    ("shell", "a shell or bash script"),
    ("powershell", "a PowerShell script"),
    ("cpp", "C++ programming-language code"),
];

/// The natural-language gloss for `tag`, if known.
pub fn gloss(tag: &str) -> Option<&'static str> {
    TAG_GLOSSES.iter().find(|(t, _)| *t == tag).map(|(_, g)| *g)
}

/// The full searchable tag vocabulary: category + label `relic_tags`, image
/// content-tag ids, and the structural + language tags — deduped, sorted.
pub fn searchable_tags(tax: &Taxonomy) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut push = |t: &str| {
        if !t.is_empty() && !out.iter().any(|x| x == t) {
            out.push(t.to_string());
        }
    };
    for c in &tax.categories {
        for t in &c.relic_tags {
            push(t);
        }
    }
    for l in &tax.labels {
        for t in &l.relic_tags {
            push(t);
        }
    }
    if let Some(bank) = &tax.image_tags {
        for t in &bank.tags {
            push(&t.id);
        }
    }
    for t in STRUCTURAL_TAGS.iter().chain(LANGUAGE_TAGS) {
        push(t);
    }
    out.sort();
    out
}

/// Stable fingerprint of the (tag, gloss) pairs that feed the tag-vector table,
/// used to invalidate the cached vectors when the vocabulary or glosses change.
pub fn gloss_fingerprint(tax: &Taxonomy) -> String {
    let mut h = blake3::Hasher::new();
    for tag in searchable_tags(tax) {
        h.update(tag.as_bytes());
        h.update(gloss(&tag).unwrap_or("").as_bytes());
    }
    h.finalize().to_hex().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every searchable tag must have a gloss — a missing one is a build break,
    /// not a silent gap in the expansion table.
    #[test]
    fn every_searchable_tag_has_a_gloss() {
        let tax = Taxonomy::embedded();
        for tag in searchable_tags(&tax) {
            assert!(gloss(&tag).is_some(), "tag '{tag}' has no gloss in TAG_GLOSSES");
        }
    }
}
