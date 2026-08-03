//! `A-text` (spec §5.1): secret/credential regex + Shannon entropy (ruleset
//! seeded from gitleaks / detect-secrets patterns), structural regex, and
//! format heuristics emitting weak priors for Stage B.
//!
//! Two kinds of output:
//! - **votes** — `(category, score, provenance)` evidence for fusion
//! - **structural tags** — whole-string facts in relic-core's SPEC §5 tag
//!   vocabulary (`url`, `email`, `phone`, …), kept byte-compatible with
//!   `relic_core::classify::detect_tags` so sift can supersede it in place.

use std::sync::LazyLock;

use regex::Regex;

use crate::record::{Stage, Vote};

macro_rules! re {
    ($name:ident, $pattern:expr) => {
        static $name: LazyLock<Regex> = LazyLock::new(|| Regex::new($pattern).unwrap());
    };
}

// ---------------------------------------------------------------------------
// Secret / credential rules (scan anywhere in the text, gitleaks-style).
// Each rule: pattern, category, min Shannon entropy over the matched token
// (0.0 = no floor; provider prefixes are specific enough), confidence.
// ---------------------------------------------------------------------------

struct SecretRule {
    name: &'static str,
    category: &'static str,
    re: &'static LazyLock<Regex>,
    min_entropy: f64,
    confidence: f32,
}

re!(AWS_KEY, r"\b(A3T[A-Z0-9]|AKIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ASIA)[0-9A-Z]{16}\b");
re!(GH_TOKEN, r"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b");
re!(GITLAB_PAT, r"\bglpat-[A-Za-z0-9_-]{20,}\b");
re!(SLACK_TOKEN, r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b");
re!(STRIPE_KEY, r"\b[sr]?[sp]k_(live|test)_[A-Za-z0-9]{16,}\b");
re!(GOOGLE_API, r"\bAIza[0-9A-Za-z_-]{35}\b");
re!(ANTHROPIC_KEY, r"\bsk-ant-[A-Za-z0-9_-]{20,}\b");
re!(OPENAI_KEY, r"\bsk-(proj-)?[A-Za-z0-9]{20,}T3BlbkFJ[A-Za-z0-9]{20,}\b");
re!(NPM_TOKEN, r"\bnpm_[A-Za-z0-9]{36}\b");
re!(SENDGRID_KEY, r"\bSG\.[A-Za-z0-9_-]{16,32}\.[A-Za-z0-9_-]{16,64}\b");
re!(TWILIO_KEY, r"\bSK[0-9a-f]{32}\b");
re!(JWT, r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*");
re!(PEM_KEY, r"-----BEGIN [A-Z ]*PRIVATE KEY-----");
// `key = value`-style assignment with a secret-ish name on the left.
re!(
    ASSIGNED_SECRET,
    r#"(?i)\b(api[_-]?key|apikey|secret[_-]?key|client[_-]?secret|access[_-]?key|secret|token|passwd|password|auth)\b["']?\s*[:=]\s*["']?([A-Za-z0-9+/=_.\-]{12,128})"#
);
// A whole-string single high-entropy token (relic-core's generic rule).
re!(LONE_TOKEN, r"^[A-Za-z0-9+/=_.\-]{20,128}$");

// ---- granular structural shapes (v1.2) -------------------------------------
re!(UUID_RE, r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
re!(SEMVER, r"^[vV]?\d+\.\d+\.\d+([-+][0-9A-Za-z.\-]+)?$");
re!(ETH_ADDR, r"^0x[0-9a-fA-F]{40}$");
re!(BTC_ADDR, r"^(bc1[ac-hj-np-z02-9]{20,60}|[13][A-HJ-NP-Za-km-z1-9]{25,34})$");
re!(GEO_PAIR, r"^(-?\d{1,2}(?:\.\d+)?),\s*(-?\d{1,3}(?:\.\d+)?)$");
// Carrier tracking numbers: UPS is unambiguous; USPS by its 92/93/94/95
// prefix; anything else needs the word "tracking" nearby.
re!(UPS_TRACKING, r"\b1Z[0-9A-Z]{16}\b");
re!(USPS_TRACKING, r"\b9[2-5]\d{2}[ ]?\d{4}[ ]?\d{4}[ ]?\d{4}[ ]?\d{4}(?:[ ]?\d{2})?\b");
re!(CTX_TRACKING, r"(?i)\btrack(?:ing)?(?:\s*(?:number|no|#|id))?\s*[:\s]\s*([0-9]{10,22})\b");
// One-time codes: a bare 5–6 digit string (4 digits would catch years and
// PINs), or 4–8 digits near "code"-ish words.
re!(OTP_BARE, r"^\d{5,6}$|^\d{3}[ -]\d{3}$");
re!(CTX_OTP, r"(?i)\b(?:verification|auth(?:entication)?|one[- ]?time|2fa|login|security)\s+code\b\D{0,20}(\d{4,8})\b|\b(?:code|otp|passcode)\s*(?:is|:)\s*(\d{4,8})\b");

// ---- v1.3 broad-coverage facts (finance / IT / publishing / automotive) ----
re!(MAC_ADDR, r"^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$");
re!(VIN_SHAPE, r"^[A-HJ-NPR-Z0-9]{17}$"); // VINs exclude I, O, Q
re!(CC_SHAPE, r"^[0-9][0-9 \-]{11,21}[0-9]$");

static SECRET_RULES: &[SecretRule] = &[
    SecretRule { name: "aws_access_key", category: "api_key", re: &AWS_KEY, min_entropy: 0.0, confidence: 0.97 },
    SecretRule { name: "github_token", category: "api_key", re: &GH_TOKEN, min_entropy: 0.0, confidence: 0.97 },
    SecretRule { name: "gitlab_pat", category: "api_key", re: &GITLAB_PAT, min_entropy: 0.0, confidence: 0.97 },
    SecretRule { name: "slack_token", category: "api_key", re: &SLACK_TOKEN, min_entropy: 0.0, confidence: 0.97 },
    SecretRule { name: "stripe_key", category: "api_key", re: &STRIPE_KEY, min_entropy: 0.0, confidence: 0.97 },
    SecretRule { name: "google_api_key", category: "api_key", re: &GOOGLE_API, min_entropy: 0.0, confidence: 0.97 },
    SecretRule { name: "anthropic_key", category: "api_key", re: &ANTHROPIC_KEY, min_entropy: 0.0, confidence: 0.97 },
    SecretRule { name: "openai_key", category: "api_key", re: &OPENAI_KEY, min_entropy: 0.0, confidence: 0.97 },
    SecretRule { name: "npm_token", category: "api_key", re: &NPM_TOKEN, min_entropy: 0.0, confidence: 0.97 },
    SecretRule { name: "sendgrid_key", category: "api_key", re: &SENDGRID_KEY, min_entropy: 0.0, confidence: 0.97 },
    SecretRule { name: "twilio_key", category: "api_key", re: &TWILIO_KEY, min_entropy: 0.0, confidence: 0.97 },
    SecretRule { name: "jwt", category: "secret_other", re: &JWT, min_entropy: 3.0, confidence: 0.97 },
    SecretRule { name: "private_key_pem", category: "secret_other", re: &PEM_KEY, min_entropy: 0.0, confidence: 0.97 },
];

/// A secret match found in the text (also drives masking in the output).
#[derive(Debug, Clone)]
pub struct SecretMatch {
    pub rule: &'static str,
    pub category: &'static str,
    pub span: [usize; 2],
    pub confidence: f32,
}

pub fn find_secrets(text: &str) -> Vec<SecretMatch> {
    let mut out: Vec<SecretMatch> = Vec::new();
    for rule in SECRET_RULES {
        for m in rule.re.find_iter(text) {
            if rule.min_entropy > 0.0 && shannon_entropy(m.as_str().as_bytes()) < rule.min_entropy {
                continue;
            }
            out.push(SecretMatch {
                rule: rule.name,
                category: rule.category,
                span: [m.start(), m.end()],
                confidence: rule.confidence,
            });
        }
    }
    // `NAME = value` assignment with a secret-ish name and an entropic value.
    for c in ASSIGNED_SECRET.captures_iter(text) {
        let value = c.get(2).unwrap();
        if value.as_str().chars().any(|ch| ch.is_ascii_digit())
            && value.as_str().chars().any(|ch| ch.is_ascii_alphabetic())
            && shannon_entropy(value.as_str().as_bytes()) > 3.3
            && !covered(&out, value.start())
        {
            out.push(SecretMatch {
                rule: "assigned_secret",
                category: "api_key",
                span: [value.start(), value.end()],
                confidence: 0.95,
            });
        }
    }
    // Whole string is one key-shaped high-entropy token — but not when the
    // shape is a known *public* identifier (UUID, crypto address, tracking
    // number): hex/base58 entropy clears 3.7 and would false-positive.
    let t = text.trim();
    if LONE_TOKEN.is_match(t)
        && t.chars().any(|c| c.is_ascii_digit())
        && t.chars().any(|c| c.is_ascii_alphabetic())
        && shannon_entropy(t.as_bytes()) > 3.7
        && !UUID_RE.is_match(t)
        && !ETH_ADDR.is_match(t)
        && !BTC_ADDR.is_match(t)
        && !UPS_TRACKING.is_match(t)
        && !iban_valid(t)
        && out.is_empty()
    {
        let start = text.len() - text.trim_start().len();
        out.push(SecretMatch {
            rule: "high_entropy_token",
            category: "secret_other",
            span: [start, start + t.len()],
            confidence: 0.9,
        });
    }
    out.sort_by_key(|m| m.span[0]);
    out
}

fn covered(matches: &[SecretMatch], pos: usize) -> bool {
    matches.iter().any(|m| m.span[0] <= pos && pos < m.span[1])
}

// ---------------------------------------------------------------------------
// Structural whole-string tags — byte-compatible with relic-core SPEC §5.
// ---------------------------------------------------------------------------

re!(URL, r"(?i)^https?://\S+$");
re!(EMAIL, r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$");
re!(PHONE, r"^[+(]?\d[\d\s().-]{5,18}\d$");

// In-prose scanners: high-precision patterns found ANYWHERE in the clip (the
// matchers above are whole-string — they only fire when the clip *is* the fact).
// A URL or email mentioned inside an email/note should still earn its tag.
re!(URL_IN, r"(?i)\bhttps?://\S+");
re!(URI_IN, r"(?i)\b[a-z][a-z0-9+.-]*://\S+"); // any scheme:// (postgres://, redis://…)
re!(EMAIL_IN, r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b");
re!(IBAN_IN, r"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){11,30}\b");
// Phone numbers in prose — only the three *distinctive* shapes (international +,
// parenthesized area code, or dash/dot-separated 10-digit). Space-grouped digit
// runs are excluded so credit cards / version strings can't masquerade as phones.
re!(PHONE_IN, r"\+\d[\d ().-]{7,}\d|\(\d{3}\)[ ]?\d{3}[-. ]\d{4}|\b\d{3}[-.]\d{3}[-.]\d{4}\b");
// Credit-card number embedded in prose: a 13–19 digit run (space/dash separated).
// Luhn-validated at the call site, so false positives are rare.
re!(CC_IN, r"\b\d(?:[ -]?\d){12,18}\b");
// A conversation line — `Speaker: a full sentence` (key + ≥3 words). These match
// the YAML `key:` shape, so they're used to keep a chat from being read as config.
re!(PROSE_COLON_LINE, r"(?m)^[ \t]*[A-Za-z][\w'.-]*:\s+\S+\s+\S+\s+\S");
// Checklist shape → `todo` (multi-label, independent of the prose category): a
// markdown checkbox line, or an explicit line-leading TODO marker. Requires real
// checkboxes/markers so a bulleted prose note doesn't over-fire as a to-do.
re!(CHECKBOX_LINE, r"(?m)^\s*(?:[-*+]\s+)?\[[ xX]?\]\s+\S");
re!(TODO_MARKER, r"(?mi)^\s*(?:#+\s*)?(?:todo|to-do)\b");
re!(DATE_LIKE, r"^(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.]\d{4})$");
re!(COLOR, r"^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$");
re!(WIN_PATH, r#"^(?:[A-Za-z]:[\\/]|\\\\\w)[^<>:"|?*\n]*$"#);
re!(UNIX_PATH, r"^(/|~/)[^ \n]+$");
re!(MD_HEADING, r"(?m)^#{1,6} \S");
re!(MD_LINK, r"\[[^\]]+\]\([^)]+\)");
re!(MD_LIST, r"(?m)^[-*] \S");
re!(CODE_KEYWORD, r"(?m)\b(fn|def|function|class|struct|impl|import|return|const|let|var|pub|void|if|else|for|while)\b");
re!(CODE_LINE_END, r"(?m)[;{}]\s*$");
re!(CODE_ARROW, r"(=>|->|::|!=|==)");

/// Whole-string subtype tags — facts where the *entire* trimmed clip IS the fact
/// (a bare URL, email, UUID, credit card…). Same semantics and order as
/// `relic_core::classify::detect_tags`. The in-prose scanners (which fire on
/// prose that merely *contains* a fact) are layered on separately by
/// `structural_tags`, so this set alone answers "is the clip a bare fact?".
fn whole_string_tags(text: &str) -> Vec<String> {
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
    let is_ip = t.parse::<std::net::IpAddr>().is_ok();
    // ip/isbn guard phone: relic-core tags `192.168.1.1` as both (a known false
    // positive), and a dashed ISBN looks phone-shaped — sift corrects both.
    if is_phone(t) && !is_ip && !is_isbn(t) {
        tags.push("phone".into());
    }
    if is_ip {
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
    if !find_secrets(t).is_empty() {
        tags.push("secret".into());
    }
    if !is_url && (WIN_PATH.is_match(t) || UNIX_PATH.is_match(t)) {
        tags.push("path".into());
    }
    if is_markdown(t) {
        tags.push("markdown".into());
    }
    let is_code = !is_json && code_score(t) >= 2;
    if is_code {
        tags.push("code".into());
    }

    // ---- v1.2 granular extensions (appended after the core vocabulary so
    // existing relic-core consumers see an unchanged prefix) ----------------
    if let Some((tag, _, _)) = format_shape(t) {
        if tag != "json" {
            tags.push(tag.into()); // json already emitted by the core block
        }
    }
    if UUID_RE.is_match(t) {
        tags.push("uuid".into());
    }
    if SEMVER.is_match(t) {
        tags.push("version".into());
    }
    if DATE_LIKE.is_match(t) {
        tags.push("date".into());
    }
    if let Some(c) = GEO_PAIR.captures(t) {
        let lat: f64 = c[1].parse().unwrap_or(999.0);
        let lon: f64 = c[2].parse().unwrap_or(999.0);
        if lat.abs() <= 90.0 && lon.abs() <= 180.0 && t.contains('.') {
            tags.push("geo".into());
        }
    }
    if ETH_ADDR.is_match(t) || BTC_ADDR.is_match(t) {
        tags.push("crypto".into());
    }
    if iban_valid(t) {
        tags.push("iban".into());
    }
    if UPS_TRACKING.is_match(t) || USPS_TRACKING.is_match(t) || CTX_TRACKING.is_match(t) {
        tags.push("tracking".into());
    }
    if OTP_BARE.is_match(t) || CTX_OTP.is_match(t) {
        tags.push("otp".into());
    }

    // ---- v1.3 broad-coverage facts (whole-string, checksum-validated where
    // possible to keep false positives low) ----
    if MAC_ADDR.is_match(t) {
        tags.push("mac-address".into());
    }
    if is_vin(t) {
        tags.push("vin".into());
    }
    if is_credit_card(t) {
        tags.push("credit-card".into());
    }
    if is_isbn(t) {
        tags.push("isbn".into());
    }
    // JWT is already caught as a secret (→ `secret` tag); add the specific
    // `jwt` tag so it's searchable as such.
    if JWT.is_match(t) {
        tags.push("jwt".into());
    }

    if let Some(lang) = code_language(t, is_code) {
        tags.push(lang.into());
    }
    tags
}

/// Deterministic subtype tags for string content: the whole-string facts plus the
/// additive multi-label signals — a `todo` from a checklist shape, and url/email/
/// iban/phone/credit-card found ANYWHERE in the clip (not just whole-string).
pub fn structural_tags(text: &str) -> Vec<String> {
    let mut tags = whole_string_tags(text);
    let t = text.trim();
    if t.is_empty() {
        return tags;
    }
    // Checklist shape → `todo`, regardless of the prose category (an email or
    // note containing a checklist is also a to-do). ≥2 checkbox lines or an
    // explicit TODO marker; bare bullets don't count (a bulleted note isn't a
    // to-do).
    if CHECKBOX_LINE.find_iter(t).count() >= 2 || TODO_MARKER.is_match(t) {
        tags.push("todo".into());
    }
    // In-prose structural extraction (scan within the whole clip). Additive: only
    // ever adds a tag, never changes the category.
    inprose_structural(t, &mut tags);
    tags
}

/// True when the whole (single-line) clip IS one structural fact — not prose that
/// merely contains one. Drives skipping the semantic head: a bare email/phone/
/// card isn't prose, but a sentence mentioning one is.
pub fn is_bare_fact(text: &str) -> bool {
    if text.contains('\n') {
        return false;
    }
    const FACTS: &[&str] = &[
        "path", "email", "phone", "ip", "color", "uuid", "version", "date", "geo",
        "crypto", "iban", "tracking", "otp", "mac-address", "vin", "credit-card", "isbn",
    ];
    whole_string_tags(text).iter().any(|t| FACTS.contains(&t.as_str()))
}

/// Add high-precision structural tags found ANYWHERE in `t` (URLs, emails, IPs,
/// IBANs embedded in prose). Deduplicates against tags already present.
fn inprose_structural(t: &str, tags: &mut Vec<String>) {
    let add = |tag: &str, tags: &mut Vec<String>| {
        if !tags.iter().any(|x| x == tag) {
            tags.push(tag.into());
        }
    };
    if URL_IN.is_match(t) {
        add("url", tags);
    }
    // Strip all scheme:// URIs before the email scan so `user:pass@host` inside a
    // connection string (e.g. postgres://app:secret@db) isn't read as an email.
    let no_uris = URI_IN.replace_all(t, " ");
    if EMAIL_IN.is_match(&no_uris) {
        add("email", tags);
    }
    // NB: in-prose IPv4 is intentionally NOT scanned — a 4-part version string
    // (`1.2.3.4`) is shape-identical to an IP, and version strings are common in
    // this (developer) domain. The whole-string `ip` path still tags a clipped
    // bare IP, where the intent is unambiguous.
    // IBAN: checksum-validate each shaped candidate.
    if IBAN_IN.find_iter(t).any(|m| iban_valid(m.as_str())) {
        add("iban", tags);
    }
    // Phone (distinctive shapes only — see PHONE_IN), but not if the whole clip
    // is already a single phone (handled by the whole-string PHONE matcher).
    if PHONE_IN.is_match(t) {
        add("phone", tags);
    }
    // Credit-card number embedded in prose (Luhn-validated → high precision).
    if CC_IN.find_iter(t).any(|m| {
        let digits: String = m.as_str().chars().filter(char::is_ascii_digit).collect();
        (13..=19).contains(&digits.len()) && luhn_ok(&digits)
    }) {
        add("credit-card", tags);
    }
}

/// Luhn checksum (credit cards, some IDs).
fn luhn_ok(digits: &str) -> bool {
    let (mut sum, mut alt) = (0u32, false);
    for c in digits.bytes().rev() {
        let mut d = (c - b'0') as u32;
        if alt {
            d *= 2;
            if d > 9 {
                d -= 9;
            }
        }
        sum += d;
        alt = !alt;
    }
    !digits.is_empty() && sum % 10 == 0
}

/// A bare payment-card number: 13–19 digits (spaces/dashes allowed) passing Luhn.
fn is_credit_card(t: &str) -> bool {
    if !CC_SHAPE.is_match(t) {
        return false;
    }
    let digits: String = t.chars().filter(char::is_ascii_digit).collect();
    (13..=19).contains(&digits.len()) && luhn_ok(&digits)
}

/// A 17-character VIN (no I/O/Q) that mixes letters and digits.
fn is_vin(t: &str) -> bool {
    VIN_SHAPE.is_match(t)
        && t.bytes().any(|c| c.is_ascii_alphabetic())
        && t.bytes().any(|c| c.is_ascii_digit())
}

/// ISBN-10 or ISBN-13 (dashes/spaces and an optional `ISBN` prefix allowed),
/// validated by its checksum.
fn is_isbn(t: &str) -> bool {
    let mut c: String = t.chars().filter(|c| !c.is_whitespace() && *c != '-').collect();
    for p in ["ISBN", "isbn", "Isbn"] {
        if let Some(rest) = c.strip_prefix(p) {
            c = rest.to_string();
            break;
        }
    }
    isbn13_ok(&c) || isbn10_ok(&c)
}

fn isbn13_ok(c: &str) -> bool {
    if c.len() != 13 || !c.bytes().all(|b| b.is_ascii_digit()) {
        return false;
    }
    if !(c.starts_with("978") || c.starts_with("979")) {
        return false;
    }
    let sum: u32 = c
        .bytes()
        .enumerate()
        .map(|(i, b)| (b - b'0') as u32 * if i % 2 == 0 { 1 } else { 3 })
        .sum();
    sum % 10 == 0
}

fn isbn10_ok(c: &str) -> bool {
    if c.len() != 10 {
        return false;
    }
    let mut sum = 0u32;
    for (i, b) in c.bytes().enumerate() {
        let v = match b {
            b'0'..=b'9' => (b - b'0') as u32,
            b'X' | b'x' if i == 9 => 10,
            _ => return false,
        };
        sum += v * (10 - i as u32);
    }
    sum % 11 == 0
}

/// Detected structured-text shape: `(relic tag, stage-A signal, prior score)`.
/// Parsed/shape-matched structure is near-deterministic, hence high priors.
fn format_shape(t: &str) -> Option<(&'static str, &'static str, f32)> {
    let is_json = matches!(t.as_bytes().first(), Some(b'{') | Some(b'['))
        && serde_json::from_str::<serde_json::Value>(t).is_ok();
    if is_json {
        return Some(("json", "format:json", 0.9));
    }
    let yaml_lines = YAML_LINE.find_iter(t).count();
    let line_count = t.lines().count().max(1);
    if t.starts_with('<') && t.trim_end().ends_with('>') && t.contains("</") {
        return Some(("xml", "format:xml", 0.65));
    }
    if INI_SECTION.is_match(t) && yaml_lines + t.matches('=').count() >= 2 {
        // TOML is INI-shaped with quoted values / cargo-style sections.
        return if t.contains("= \"") || t.contains("[dependencies]") || t.contains("[package]") {
            Some(("toml", "format:toml", 0.6))
        } else {
            Some(("ini", "format:ini", 0.6))
        };
    }
    if yaml_lines >= 3 && yaml_lines * 2 >= line_count && code_score(t) < 2 {
        // Don't read a conversation as config: chat lines (`Speaker: a full
        // sentence`) match the `key:` shape. Only call it YAML when most colon
        // lines are scalar-valued, not multi-word prose.
        if PROSE_COLON_LINE.find_iter(t).count() * 2 < yaml_lines {
            return Some(("yaml", "format:yaml", 0.6));
        }
    }
    if is_csv_like(t) {
        return Some(("csv", "format:csv", 0.6));
    }
    None
}

/// IBAN: country prefix + mod-97 checksum over the rearranged alphanumerics.
pub(crate) fn iban_valid(t: &str) -> bool {
    static IBAN_SHAPE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$").unwrap());
    let compact: String = t.chars().filter(|c| !c.is_whitespace()).collect();
    if !IBAN_SHAPE.is_match(&compact) {
        return false;
    }
    let rearranged = format!("{}{}", &compact[4..], &compact[..4]);
    let mut rem: u32 = 0;
    for c in rearranged.chars() {
        let v = c.to_digit(36).unwrap_or(99);
        if v >= 36 {
            return false;
        }
        rem = if v < 10 { (rem * 10 + v) % 97 } else { (rem * 100 + v) % 97 };
    }
    rem == 1
}

/// Heuristic programming-language identification for code-shaped text.
/// Returns a tag only on a clear winner (≥2 distinct signatures and strictly
/// ahead of the runner-up; ≥3 when the text didn't earn the `code` tag).
fn code_language(t: &str, is_code: bool) -> Option<&'static str> {
    static SIGS: LazyLock<Vec<(&'static str, Vec<Regex>)>> = LazyLock::new(|| {
        let table: &[(&str, &[&str])] = &[
            ("python", &[r"\bdef \w+\(", r"(?m)^import \w+|(?m)^from \w+ import ", r"\bself\.", r"\belif\b", r"\basync def\b", r"\blambda \w+:"]),
            ("rust", &[r"\bfn \w+\(", r"\blet mut\b", r"\bimpl \w", r"\bpub fn\b", r"println!|\bvec!\[", r"-> (Result|Option)\b", r"&(str|mut)\b"]),
            ("javascript", &[r"\bconst \w+\s*=", r"=>\s*\{?", r"\bfunction\s+\w*\(", r"console\.log", r"\blet \w+\s*=", r"===|!=="]),
            ("go", &[r"\bfunc \w+\(", r":=", r"(?m)^package \w+", r"\bfmt\.\w", r"\bgo func\b", r"\bchan \w"]),
            ("java", &[r"\bpublic (class|static|void|final)\b", r"System\.out\.", r"@Override", r"\bprivate \w+ \w+\s*;", r"\bextends \w+|\bimplements \w+"]),
            ("sql", &[r"(?is)\bselect\b.+\bfrom\b", r"(?i)\bwhere \w", r"(?i)\b(left |inner |outer )?join \w+ on\b", r"(?i)\binsert into\b", r"(?i)\b(group|order) by\b", r"(?i)\bcreate (table|index)\b"]),
            ("shell", &[r"(?m)^#!/bin/(ba|z|da)?sh", r"\$\(\w", r"(?m)^\s*(echo|cd|sudo|curl|grep) ", r"\| (grep|awk|sed|xargs)\b", r"(?m)^\s*export \w+=", r"\bfi\b|\bdone\b|\besac\b"]),
            ("powershell", &[r"\$env:\w+", r"\b(Write|Get|Set|New|Remove|Invoke|Test)-[A-Z]\w+", r"-ErrorAction\b|-Recurse\b|-Force\b", r"\[Parameter\(|\bparam\(", r"\$PS\w+"]),
            ("cpp", &[r"#include\s*<", r"\bstd::\w", r"\bint main\s*\(", r"\bprintf\s*\(", r"\btemplate\s*<", r"\bnullptr\b|->\s*\w+\(\)"]),
        ];
        table
            .iter()
            .map(|(lang, pats)| (*lang, pats.iter().map(|p| Regex::new(p).unwrap()).collect()))
            .collect()
    });
    let mut scored: Vec<(&'static str, usize)> = SIGS
        .iter()
        .map(|(lang, pats)| (*lang, pats.iter().filter(|p| p.is_match(t)).count()))
        .collect();
    scored.sort_by(|a, b| b.1.cmp(&a.1));
    let (best, best_n) = scored[0];
    let runner_n = scored[1].1;
    let floor = if is_code { 2 } else { 3 };
    (best_n >= floor && best_n > runner_n).then_some(best)
}

fn is_phone(t: &str) -> bool {
    let digits = t.chars().filter(char::is_ascii_digit).count();
    PHONE.is_match(t) && (7..=15).contains(&digits) && !DATE_LIKE.is_match(t)
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

fn code_score(t: &str) -> u32 {
    let mut score = 0;
    score += CODE_KEYWORD.is_match(t) as u32;
    score += (CODE_LINE_END.find_iter(t).count() >= 2) as u32;
    score += CODE_ARROW.is_match(t) as u32;
    score += t.lines().any(|l| l.starts_with("    ") || l.starts_with('\t')) as u32;
    score
}

// ---------------------------------------------------------------------------
// Format heuristics — weak priors (confidence ≤ 0.6) passed to Stage B.
// ---------------------------------------------------------------------------

re!(LOG_TS_LINE, r"(?m)^[\[\(]?\d{4}[-/]\d{2}[-/]\d{2}[ T]\d{2}:\d{2}");
re!(SYSLOG_LINE, r"(?m)^[A-Z][a-z]{2} +\d{1,2} \d{2}:\d{2}:\d{2} ");
re!(LOG_LEVEL, r"\b(ERROR|WARN(ING)?|INFO|DEBUG|TRACE|FATAL|PANIC)\b");
re!(STACK_TRACE, r"(Traceback \(most recent call last\)|^\s+at [\w.$<>]+\(|panicked at |^\s+File \x22)");
re!(YAML_LINE, r"(?m)^[ \t]*[A-Za-z0-9_.-]+:\s");
re!(INI_SECTION, r"(?m)^\[[^\]\n]+\]\s*$");

/// Votes from text content. `demote` scales scores down (used when the text
/// came out of an image via OCR — image categories should usually win, but
/// the evidence still enriches the record; spec §6.2).
pub fn votes(text: &str, demote: f32) -> Vec<Vote> {
    let mut votes: Vec<Vote> = Vec::new();
    let t = text.trim();
    if t.is_empty() {
        return votes;
    }

    // Hard rules first (spec §5.1, confidence 0.95–0.97). Secrets are never
    // demoted: a screenshot of an API key must still be caught (spec §6.2).
    let secrets = find_secrets(text);
    if let Some(best) = secrets.iter().max_by(|a, b| a.confidence.total_cmp(&b.confidence)) {
        votes.push(Vote::new(best.category, best.confidence, Stage::AText, &format!("rule:{}", best.rule)));
    }
    if URL.is_match(t) {
        votes.push(Vote::new("url", 0.97 * demote.max(0.5), Stage::AText, "rule:url"));
    }

    // Carrier tracking numbers and one-time codes (v1.2): carrier-prefixed
    // forms are deterministic; a bare digit code is only a prior.
    if UPS_TRACKING.is_match(t) {
        votes.push(Vote::new("tracking_number", 0.97, Stage::AText, "rule:ups_tracking"));
    } else if USPS_TRACKING.is_match(t) {
        votes.push(Vote::new("tracking_number", 0.95, Stage::AText, "rule:usps_tracking"));
    } else if CTX_TRACKING.is_match(t) {
        votes.push(Vote::new("tracking_number", 0.9, Stage::AText, "rule:tracking_context"));
    }
    if CTX_OTP.is_match(t) {
        votes.push(Vote::new("otp_code", 0.9, Stage::AText, "rule:otp_context"));
    } else if OTP_BARE.is_match(t) {
        votes.push(Vote::new("otp_code", 0.65 * demote, Stage::AText, "rule:otp_bare"));
    }

    // Format heuristics — priors passed to Stage B.
    let mut prior = |cat: &str, score: f32, signal: &str| {
        votes.push(Vote::new(cat, score * demote, Stage::AText, signal));
    };

    let line_count = t.lines().count().max(1);
    // Parsed/shape-matched structure is near-deterministic — these priors sit
    // high enough that a semantic head guess can't override without a clear
    // margin (fusion holds the prior on ambiguous conflicts).
    let is_json = match format_shape(t) {
        Some((tag, signal, score)) => {
            prior("structured_data", score, signal);
            tag == "json"
        }
        None => false,
    };

    let ts_lines = LOG_TS_LINE.find_iter(t).count() + SYSLOG_LINE.find_iter(t).count();
    if ts_lines * 2 >= line_count && ts_lines >= 1 && LOG_LEVEL.is_match(t) {
        prior("log_line", 0.6, "format:log_timestamps");
    } else if STACK_TRACE.is_match(t) {
        prior("log_line", 0.55, "format:stack_trace");
    } else if ts_lines * 2 >= line_count && ts_lines >= 2 {
        prior("log_line", 0.5, "format:timestamp_lines");
    }

    let code = code_score(t);
    if code >= 3 {
        prior("code", 0.6, "format:code_density");
    } else if code == 2 && !is_json {
        prior("code", 0.5, "format:code_density");
    }

    if is_markdown(t) {
        prior("note_prose", 0.45, "format:markdown");
    }

    votes
}

fn is_csv_like(t: &str) -> bool {
    let lines: Vec<&str> = t.lines().take(10).collect();
    if lines.len() < 2 {
        return false;
    }
    let counts: Vec<usize> = lines.iter().map(|l| l.matches(',').count()).collect();
    let first = counts[0];
    first >= 1 && counts.iter().all(|&c| c == first)
}

pub fn shannon_entropy(bytes: &[u8]) -> f64 {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn cats(text: &str) -> Vec<(String, f32)> {
        votes(text, 1.0).into_iter().map(|v| (v.category, v.score)).collect()
    }

    #[test]
    fn provider_keys_hit_api_key_at_097() {
        for s in [
            "AKIAIOSFODNN7EXAMPLE",
            "ghp_AbCdEf0123456789AbCdEf0123456789",
            "github_pat_11ABCDEFG0123456789abcdefgh",
            "glpat-aB3dE5fG7hJ9kL1mN3pQ",
            "xoxb-1234567890-abcdefghijklm",
            "sk_live_4eC39HqLyjWDarjtT1zdp7dc",
            "AIzaSyA1bC2dE3fG4hI5jK6lM7nO8pQ9rS0tUvW",
            "sk-ant-api03-aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY",
            "npm_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5",
            "SG.aB3dE5fG7hJ9kL1mN3pQ.aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5cE7g",
            "SK0123456789abcdef0123456789abcdef",
        ] {
            let v = cats(s);
            assert!(
                v.iter().any(|(c, s)| c == "api_key" && *s >= 0.95),
                "{s}: expected api_key vote, got {v:?}"
            );
        }
    }

    #[test]
    fn jwt_and_pem_hit_secret_other() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        assert!(cats(jwt).iter().any(|(c, s)| c == "secret_other" && *s >= 0.95));
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----";
        assert!(cats(pem).iter().any(|(c, s)| c == "secret_other" && *s >= 0.95));
    }

    #[test]
    fn secrets_found_inside_larger_text() {
        let env = "DB_HOST=localhost\nAPI_KEY=q7zP2vXr9kT4wY8mB3nF6hJ1dL5gC0aS\nDEBUG=false";
        let m = find_secrets(env);
        assert!(!m.is_empty(), "assigned secret should match in .env content");
        assert_eq!(m[0].rule, "assigned_secret");
    }

    #[test]
    fn lone_high_entropy_token_is_secretish() {
        assert!(!find_secrets("xK9mP2vQ7rT4wY8zB3nF6hJ1").is_empty());
        assert!(find_secrets("aaaaaaaaaaaaaaaaaaaa1111").is_empty()); // low entropy
        assert!(find_secrets("hello world this is prose").is_empty());
    }

    #[test]
    fn format_priors() {
        assert!(cats(r#"{"a": 1, "b": [true, null]}"#).iter().any(|(c, _)| c == "structured_data"));
        assert!(cats("server:\n  host: 0.0.0.0\n  port: 8080\nlogging:\n  level: info")
            .iter()
            .any(|(c, _)| c == "structured_data"));
        assert!(cats("2026-06-11T14:23:01Z ERROR api request failed\n2026-06-11T14:23:02Z INFO retrying")
            .iter()
            .any(|(c, s)| c == "log_line" && *s >= 0.55));
        assert!(cats("fn main() {\n    println!(\"hi\");\n}").iter().any(|(c, _)| c == "code"));
        assert!(cats("id,name,email\n1,Ana,a@x.com\n2,Ben,b@x.com")
            .iter()
            .any(|(c, _)| c == "structured_data"));
    }

    #[test]
    fn structural_tags_match_relic_core_semantics() {
        assert_eq!(structural_tags("https://example.com/a?b=1"), vec!["url"]);
        assert_eq!(structural_tags("jane.doe@example.co.uk"), vec!["email"]);
        assert_eq!(structural_tags("+1 (555) 123-4567"), vec!["phone"]);
        assert_eq!(structural_tags("192.168.1.1"), vec!["ip"]);
        assert_eq!(structural_tags("#A3F2D1"), vec!["color"]);
        assert!(structural_tags(r"C:\Users\jorda\file.txt").contains(&"path".to_string()));
        assert_eq!(structural_tags("2026-06-11"), vec!["date"]); // date ≠ phone
        assert!(structural_tags("").is_empty());
    }

    #[test]
    fn v12_structural_tags() {
        let tags = |s: &str| structural_tags(s);
        assert!(tags("550e8400-e29b-41d4-a716-446655440000").contains(&"uuid".to_string()));
        assert!(!tags("550e8400-e29b-41d4-a716-446655440000").contains(&"secret".to_string()));
        assert!(tags("v2.14.3").contains(&"version".to_string()));
        assert!(tags("1.0.0-rc.12").contains(&"version".to_string()));
        assert!(tags("2026-06-15").contains(&"date".to_string()));
        assert!(tags("37.8199, -122.4804").contains(&"geo".to_string()));
        assert!(!tags("100.5, 200.9").contains(&"geo".to_string())); // out of range
        let eth = tags("0x71C7656EC7ab88b098defB751B7401B5f6d8976F");
        assert!(eth.contains(&"crypto".to_string()) && !eth.contains(&"secret".to_string()));
        assert!(tags("GB82WEST12345698765432").contains(&"iban".to_string()));
        assert!(!tags("GB82WEST12345698765431").contains(&"iban".to_string())); // bad checksum
        assert!(tags("1Z999AA10123456784").contains(&"tracking".to_string()));
        assert!(tags("Tracking number: 9405511206218889777712").contains(&"tracking".to_string()));
        assert!(tags("482913").contains(&"otp".to_string()));
        assert!(!tags("2026").contains(&"otp".to_string())); // year, not a code
        assert!(tags("server:\n  host: 0.0.0.0\n  port: 8080\nlogging:\n  level: info")
            .contains(&"yaml".to_string()));
        assert!(tags("id,name\n1,Ana\n2,Ben").contains(&"csv".to_string()));
        assert!(tags("[package]\nname = \"relic\"\nedition = \"2021\"").contains(&"toml".to_string()));
    }

    #[test]
    fn v13_broad_coverage_tags() {
        let tags = |s: &str| structural_tags(s);
        // MAC address
        assert!(tags("3C:22:FB:8A:1D:09").contains(&"mac-address".to_string()));
        assert!(tags("3c-22-fb-8a-1d-09").contains(&"mac-address".to_string()));
        // VIN (mixes letters+digits, no I/O/Q, 17 chars)
        assert!(tags("1HGCM82633A004352").contains(&"vin".to_string()));
        assert!(!tags("COUNTERREVOLUTION").contains(&"vin".to_string())); // no digit
        // Credit card — Luhn-valid test numbers
        assert!(tags("4111 1111 1111 1111").contains(&"credit-card".to_string()));
        assert!(tags("4111-1111-1111-1111").contains(&"credit-card".to_string()));
        assert!(!tags("4111 1111 1111 1112").contains(&"credit-card".to_string())); // bad Luhn
        // ISBN-13 and ISBN-10 (checksum-validated)
        assert!(tags("978-3-16-148410-0").contains(&"isbn".to_string()));
        assert!(tags("0-306-40615-2").contains(&"isbn".to_string()));
        assert!(!tags("978-3-16-148410-1").contains(&"isbn".to_string())); // bad checksum
        // JWT keeps `secret` and gains `jwt`
        let jwt = tags("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcDEF123");
        assert!(jwt.contains(&"jwt".to_string()) && jwt.contains(&"secret".to_string()));
    }

    #[test]
    fn inprose_structural_extraction() {
        let tags = |s: &str| structural_tags(s);
        // URLs / emails / IBANs embedded in prose now earn their tag (the
        // whole-string matchers only fire when the clip *is* the fact).
        assert!(tags("Hi team, the staging server is at https://staging.relic.app — thanks")
            .contains(&"url".to_string()));
        assert!(tags("ping me at lena.ortiz@bayclinic.example when you get a sec")
            .contains(&"email".to_string()));
        assert!(tags("please wire the deposit to IBAN DE89 3704 0044 0532 0130 00 by friday")
            .contains(&"iban".to_string()));
        // A `user:pass@host` inside a connection URI must NOT read as an email.
        assert!(!tags("connect via postgres://app:secret@db.internal:5432/prod")
            .contains(&"email".to_string()));
        // A 4-part version string must NOT be mistaken for an IP in prose.
        assert!(!tags("we shipped version 1.2.3.4 to the beta channel today")
            .contains(&"ip".to_string()));
        // Distinctive phone shapes in prose are tagged...
        assert!(tags("my new number is +1 (415) 555-0193, save it").contains(&"phone".to_string()));
        assert!(tags("call the front desk at 503-555-0148 before noon").contains(&"phone".to_string()));
        // ...but a space-grouped credit card is NOT a phone.
        assert!(!tags("card on file 4111 1111 1111 1111 exp 12/28").contains(&"phone".to_string()));
        // Credit-card number in prose → credit-card (Luhn-validated).
        assert!(tags("Card on file: 4111 1111 1111 1111, exp 12/28").contains(&"credit-card".to_string()));
        assert!(!tags("Order #4111 1111 1111 1112 shipped").contains(&"credit-card".to_string())); // bad Luhn
        // A chat with `speaker:` lines must NOT be read as YAML/structured data.
        let chat = tags("mike: did you push the fix yet\nana: yeah it's on main now\nmike: nice");
        assert!(!chat.contains(&"yaml".to_string()) && !chat.contains(&"data".to_string()));
        // ...while real (scalar-valued) config still is YAML.
        assert!(tags("server:\n  host: 0.0.0.0\n  port: 8080\nlogging:\n  level: info")
            .contains(&"yaml".to_string()));
        // Bad IBAN checksum still rejected even in prose.
        assert!(!tags("the (fake) iban GB82WEST12345698765431 is invalid")
            .contains(&"iban".to_string()));
    }

    #[test]
    fn bare_fact_vs_prose_containing_a_fact() {
        // The whole clip IS the fact → bare (the head gets skipped).
        assert!(is_bare_fact("lena.ortiz@bayclinic.example"));
        assert!(is_bare_fact("+1 (415) 555-0193"));
        assert!(is_bare_fact("4111 1111 1111 1111"));
        // Prose that merely *contains* a fact is NOT bare → the head still runs,
        // so the clip keeps its prose category (this was the credit-card-note bug).
        assert!(!is_bare_fact("email me at lena.ortiz@bayclinic.example when you can"));
        assert!(!is_bare_fact("Card on file: 4111 1111 1111 1111, cancel by the 14th"));
        // Multi-line is never a single bare fact.
        assert!(!is_bare_fact("server:\n  host: 0.0.0.0"));
    }

    #[test]
    fn checklist_shape_tags_todo() {
        let tags = |s: &str| structural_tags(s);
        // checkbox list (even inside an email) → todo
        assert!(tags("Hi team, action items:\n- [ ] ship the fix\n- [ ] write the doc\nThanks")
            .contains(&"todo".to_string()));
        assert!(tags("- [x] book flights\n- [ ] renew passport").contains(&"todo".to_string()));
        // explicit TODO marker
        assert!(tags("TODO: rotate the key\nTODO: re-embed the corpus").contains(&"todo".to_string()));
        // a bulleted prose NOTE (no checkboxes) must NOT become a to-do
        assert!(!tags("# Meeting notes\n- Budget approved\n- Sarah owns the migration")
            .contains(&"todo".to_string()));
        // ordinary prose isn't a to-do
        assert!(!tags("Let's grab lunch tomorrow and talk about the roadmap.")
            .contains(&"todo".to_string()));
    }

    #[test]
    fn v12_category_votes() {
        assert!(cats("1Z999AA10123456784").iter().any(|(c, s)| c == "tracking_number" && *s >= 0.95));
        assert!(cats("Your verification code is 482913. It expires in 10 minutes.")
            .iter()
            .any(|(c, s)| c == "otp_code" && *s >= 0.85));
        assert!(cats("482913").iter().any(|(c, s)| c == "otp_code" && *s >= 0.6));
    }

    #[test]
    fn language_tags() {
        let lang = |s: &str| {
            structural_tags(s)
                .into_iter()
                .find(|t| {
                    matches!(
                        t.as_str(),
                        "python" | "rust" | "javascript" | "go" | "java" | "sql" | "shell"
                            | "powershell" | "cpp"
                    )
                })
        };
        assert_eq!(
            lang("def fib(n):\n    if n <= 1:\n        return n\n    return fib(n - 1) + fib(n - 2)\nimport sys"),
            Some("python".into())
        );
        assert_eq!(
            lang("pub fn parse(input: &str) -> Result<u32, Error> {\n    let mut acc = 0;\n    Ok(acc)\n}"),
            Some("rust".into())
        );
        assert_eq!(
            lang("const f = async (x) => {\n  console.log(x);\n  let y = x + 1;\n  return y;\n};"),
            Some("javascript".into())
        );
        assert_eq!(
            lang("SELECT id, name FROM users WHERE active = true GROUP BY id ORDER BY name;"),
            Some("sql".into())
        );
        assert_eq!(lang("just some prose about programming languages"), None);
    }

    #[test]
    fn prose_has_no_votes_above_weak() {
        let v = cats("We talked about the trip and decided to leave early on Saturday morning.");
        assert!(v.iter().all(|(_, s)| *s < 0.5), "{v:?}");
    }
}
