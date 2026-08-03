//! Deterministic classification (SPEC §5): kind from magic bytes, subtype
//! tags from cheap heuristics. Rule-based only — runs client-side, costs
//! nothing, and behaves identically on every platform. AI classification is
//! explicitly out of scope here (future sift pipeline).

use std::sync::LazyLock;

use regex::Regex;

use crate::relic::Kind;

/// Result of content sniffing for a binary payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sniffed {
    pub kind: Kind,
    pub mime: Option<String>,
}

/// Classify raw bytes by magic-byte signature (SPEC §4 table). Extensions and
/// declared MIME types are never trusted.
///
/// - recognized `image/*` → `Photo`
/// - any other recognized format → `File` (with its true MIME)
/// - valid UTF-8 with no NUL bytes → `String`
/// - everything else → `Other`
pub fn sniff_kind(bytes: &[u8]) -> Sniffed {
    if let Some(t) = infer::get(bytes) {
        let kind = if t.mime_type().starts_with("image/") { Kind::Photo } else { Kind::File };
        return Sniffed { kind, mime: Some(t.mime_type().to_string()) };
    }
    if !bytes.contains(&0) && std::str::from_utf8(bytes).is_ok() {
        return Sniffed { kind: Kind::String, mime: Some("text/plain".into()) };
    }
    Sniffed { kind: Kind::Other, mime: None }
}

macro_rules! re {
    ($name:ident, $pattern:expr) => {
        static $name: LazyLock<Regex> = LazyLock::new(|| Regex::new($pattern).unwrap());
    };
}

re!(URL, r"(?i)^https?://\S+$");
re!(EMAIL, r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$");
re!(PHONE, r"^[+(]?\d[\d\s().-]{5,18}\d$");
re!(DATE_LIKE, r"^(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.]\d{4})$");
re!(COLOR, r"^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$");
re!(JWT, r"^eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*$");
re!(AWS_KEY, r"\bAKIA[0-9A-Z]{16}\b");
re!(GH_TOKEN, r"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b");
re!(SECRET_TOKEN, r"^[A-Za-z0-9+/=_.-]{20,128}$");
re!(WIN_PATH, r#"^(?:[A-Za-z]:[\\/]|\\\\\w)[^<>:"|?*\n]*$"#);
re!(UNIX_PATH, r"^(/|~/)[^ \n]+$");
re!(MD_HEADING, r"(?m)^#{1,6} \S");
re!(MD_LINK, r"\[[^\]]+\]\([^)]+\)");
re!(MD_LIST, r"(?m)^[-*] \S");
re!(CODE_KEYWORD, r"(?m)\b(fn|def|function|class|struct|impl|import|return|const|let|var|pub|void|if|else|for|while)\b");
re!(CODE_LINE_END, r"(?m)[;{}]\s*$");
re!(CODE_ARROW, r"(=>|->|::|!=|==)");

/// Deterministic subtype tags for string content (SPEC §5). Order is fixed so
/// output is stable. JWTs and key-shaped strings both emit `secret`.
pub fn detect_tags(text: &str) -> Vec<String> {
    let t = text.trim();
    if t.is_empty() {
        return vec![];
    }
    let mut tags: Vec<String> = Vec::new();

    let is_url = URL.is_match(t);
    if is_url {
        tags.push("url".into());
    }
    if EMAIL.is_match(t) {
        tags.push("email".into());
    }
    if is_phone(t) {
        tags.push("phone".into());
    }
    if t.parse::<std::net::IpAddr>().is_ok() {
        tags.push("ip".into());
    }
    if COLOR.is_match(t) {
        tags.push("color".into());
    }
    let is_json = matches!(t.as_bytes().first(), Some(b'{') | Some(b'['))
        && serde_json::from_str::<serde_json::Value>(t).is_ok();
    if is_json {
        tags.push("json".into());
    }
    if is_secretish(t) {
        tags.push("secret".into());
    }
    if !is_url && (WIN_PATH.is_match(t) || UNIX_PATH.is_match(t)) {
        tags.push("path".into());
    }
    if is_markdown(t) {
        tags.push("markdown".into());
    }
    if !is_json && is_code(t) {
        tags.push("code".into());
    }
    tags
}

fn is_phone(t: &str) -> bool {
    let digits = t.chars().filter(char::is_ascii_digit).count();
    PHONE.is_match(t) && (7..=15).contains(&digits) && !DATE_LIKE.is_match(t)
}

fn is_secretish(t: &str) -> bool {
    if JWT.is_match(t) || AWS_KEY.is_match(t) || GH_TOKEN.is_match(t) {
        return true;
    }
    if t.contains("-----BEGIN") && t.contains("PRIVATE KEY-----") {
        return true;
    }
    // generic: one high-entropy key-shaped token with mixed character classes
    SECRET_TOKEN.is_match(t)
        && t.chars().any(|c| c.is_ascii_digit())
        && t.chars().any(|c| c.is_ascii_alphabetic())
        && shannon_entropy(t.as_bytes()) > 3.7
}

fn is_markdown(t: &str) -> bool {
    if !t.contains('\n') && !t.contains("```") {
        return false;
    }
    let mut score = 0;
    score += MD_HEADING.is_match(t) as u32;
    score += t.contains("```") as u32;
    score += MD_LINK.is_match(t) as u32;
    score += (MD_LIST.find_iter(t).count() >= 2) as u32;
    score >= 2
}

fn is_code(t: &str) -> bool {
    let mut score = 0;
    score += CODE_KEYWORD.is_match(t) as u32;
    score += (CODE_LINE_END.find_iter(t).count() >= 2) as u32;
    score += CODE_ARROW.is_match(t) as u32;
    score += t.lines().any(|l| l.starts_with("    ") || l.starts_with('\t')) as u32;
    score >= 2
}

fn shannon_entropy(bytes: &[u8]) -> f64 {
    let mut counts = [0u32; 256];
    for &b in bytes {
        counts[b as usize] += 1;
    }
    let len = bytes.len() as f64;
    counts
        .iter()
        .filter(|&&c| c > 0)
        .map(|&c| {
            let p = c as f64 / len;
            -p * p.log2()
        })
        .sum()
}

/// Short list title for the popup: first non-empty line, capped at 80 chars
/// (char-boundary safe).
pub fn make_preview(text: &str) -> String {
    let line = text.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    let mut preview: String = line.chars().take(80).collect();
    if line.chars().count() > 80 {
        preview.push('…');
    }
    preview
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kind_sniffing_table() {
        let cases: &[(&str, &[u8], Kind, Option<&str>)] = &[
            ("png", b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00", Kind::Photo, Some("image/png")),
            ("jpeg", b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x00\x00", Kind::Photo, Some("image/jpeg")),
            ("gif", b"GIF89a\x01\x00\x01\x00\x00\x00\x00", Kind::Photo, Some("image/gif")),
            ("webp", b"RIFF\x24\x00\x00\x00WEBPVP8 \x00\x00", Kind::Photo, Some("image/webp")),
            ("pdf", b"%PDF-1.7\n%binary\n1 0 obj", Kind::File, Some("application/pdf")),
            ("zip", b"PK\x03\x04\x14\x00\x00\x00\x08\x00\x00\x00", Kind::File, Some("application/zip")),
            ("utf8 text", "plain old text, copied".as_bytes(), Kind::String, Some("text/plain")),
            ("unknown binary", b"\xff\xfe\x13\x37\x00\x01\x02\xfa", Kind::Other, None),
            ("text with NUL", b"looks\x00texty", Kind::Other, None),
        ];
        for (name, bytes, kind, mime) in cases {
            let s = sniff_kind(bytes);
            assert_eq!(s.kind, *kind, "kind for {name}");
            assert_eq!(s.mime.as_deref(), *mime, "mime for {name}");
        }
    }

    fn assert_tags(input: &str, expect: &[&str], reject: &[&str]) {
        let tags = detect_tags(input);
        for e in expect {
            assert!(tags.iter().any(|t| t == e), "{input:?}: expected {e:?} in {tags:?}");
        }
        for r in reject {
            assert!(!tags.iter().any(|t| t == r), "{input:?}: unexpected {r:?} in {tags:?}");
        }
    }

    #[test]
    fn tag_url() {
        assert_tags("https://example.com/a?b=1#c", &["url"], &["path"]);
        assert_tags("HTTP://EXAMPLE.COM", &["url"], &[]);
        assert_tags("see https://example.com for more", &[], &["url"]); // embedded ≠ whole
        assert_tags("htp://typo.com", &[], &["url"]);
    }

    #[test]
    fn tag_email() {
        assert_tags("jane.doe+filter@sub.example.co.uk", &["email"], &[]);
        assert_tags("not@valid", &[], &["email"]);
        assert_tags("two@example.com words@example.com", &[], &["email"]);
    }

    #[test]
    fn tag_phone() {
        assert_tags("+1 (555) 123-4567", &["phone"], &[]);
        assert_tags("555-123-4567", &["phone"], &[]);
        assert_tags("2026-06-11", &[], &["phone"]); // date, not phone
        assert_tags("12345", &[], &["phone"]); // too few digits
    }

    #[test]
    fn tag_ip() {
        assert_tags("192.168.1.1", &["ip"], &[]);
        assert_tags("2001:db8::1", &["ip"], &[]);
        assert_tags("999.1.1.1", &[], &["ip"]);
        assert_tags("1.2.3", &[], &["ip"]);
    }

    #[test]
    fn tag_color() {
        assert_tags("#a3f", &["color"], &[]);
        assert_tags("#A3F2D1", &["color"], &[]);
        assert_tags("#A3F2D1FF", &["color"], &[]);
        assert_tags("#GGG", &[], &["color"]);
        assert_tags("#12345", &[], &["color"]);
    }

    #[test]
    fn tag_json() {
        assert_tags(r#"{"a": 1, "b": [true, null]}"#, &["json"], &["code"]);
        assert_tags("[1, 2, 3]", &["json"], &[]);
        assert_tags("{not json at all", &[], &["json"]);
        assert_tags("42", &[], &["json"]); // bare scalar isn't json-the-artifact
    }

    #[test]
    fn tag_secret() {
        assert_tags(
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
            &["secret"],
            &[],
        );
        assert_tags("AKIAIOSFODNN7EXAMPLE", &["secret"], &[]);
        assert_tags("ghp_AbCdEf0123456789AbCdEf0123456789", &["secret"], &[]);
        assert_tags("-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----", &["secret"], &[]);
        assert_tags("xK9mP2vQ7rT4wY8zB3nF6hJ1", &["secret"], &[]); // high-entropy token
        assert_tags("aaaaaaaaaaaaaaaaaaaa1111", &[], &["secret"]); // low entropy
        assert_tags("hello world this is prose", &[], &["secret"]);
    }

    #[test]
    fn tag_path() {
        assert_tags(r"C:\Users\jorda\file.txt", &["path"], &[]);
        assert_tags(r"\\server\share\doc.pdf", &["path"], &[]);
        assert_tags("/usr/local/bin/relic", &["path"], &[]);
        assert_tags("~/notes/todo.md", &["path"], &[]);
        assert_tags("and/or", &[], &["path"]);
    }

    #[test]
    fn tag_markdown() {
        assert_tags("# Title\n\nSome text with a [link](https://x.com).", &["markdown"], &[]);
        assert_tags("## Notes\n- first\n- second", &["markdown"], &[]);
        assert_tags("#hashtag not a heading", &[], &["markdown"]);
        assert_tags("just two\nplain lines", &[], &["markdown"]);
    }

    #[test]
    fn tag_code() {
        assert_tags("fn main() {\n    println!(\"hi\");\n}", &["code"], &[]);
        assert_tags("const x = 1;\nlet y = () => x + 1;", &["code"], &[]);
        assert_tags("def f(n):\n    return n * 2", &["code"], &[]);
        assert_tags("We should let the function return early.", &[], &["code"]); // prose with keywords
    }

    #[test]
    fn empty_and_whitespace_yield_no_tags() {
        assert!(detect_tags("").is_empty());
        assert!(detect_tags("   \n  ").is_empty());
    }

    #[test]
    fn preview_truncates_on_char_boundary() {
        assert_eq!(make_preview("  \n  hello world  \nrest"), "hello world");
        let long = "é".repeat(100);
        let p = make_preview(&long);
        assert_eq!(p.chars().count(), 81); // 80 + ellipsis
        assert!(p.ends_with('…'));
        assert_eq!(make_preview(""), "");
    }
}
