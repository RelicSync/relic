//! PII detection (spec §5.1 / §6.1): typed entity spans with masked values.
//! Rule-based v0.1 (Presidio-class context models are an optional later add,
//! spec §16.4). Raw values never appear in searchable output — only
//! `value_masked` plus the span into the *original* text (spec §12).

use std::sync::LazyLock;

use regex::Regex;

use crate::record::Entity;

macro_rules! re {
    ($name:ident, $pattern:expr) => {
        static $name: LazyLock<Regex> = LazyLock::new(|| Regex::new($pattern).unwrap());
    };
}

re!(EMAIL, r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}");
re!(SSN, r"\b\d{3}-\d{2}-\d{4}\b");
re!(IBAN, r"\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b");
re!(CARD_CANDIDATE, r"\b(?:\d[ -]?){13,19}\b");
re!(PHONE_CANDIDATE, r"\+?\(?\d[\d\s().-]{6,17}\d");
re!(IPV4, r"\b(?:\d{1,3}\.){3}\d{1,3}\b");
re!(DATE_LIKE, r"^(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.]\d{4})$");

/// Scan text for PII entities. Returns entities sorted by span start;
/// overlapping matches resolve in priority order (card > ssn > email > phone > ip).
pub fn scan(text: &str) -> Vec<Entity> {
    let mut taken: Vec<[usize; 2]> = Vec::new();
    let mut out: Vec<Entity> = Vec::new();

    let mut claim = |span: [usize; 2], kind: &str, masked: String, taken: &mut Vec<[usize; 2]>| {
        if taken.iter().any(|t| span[0] < t[1] && t[0] < span[1]) {
            return;
        }
        taken.push(span);
        out.push(Entity { kind: kind.into(), span, value_masked: masked });
    };

    // Credit cards first (Luhn-checked), so card digits don't read as phones.
    for m in CARD_CANDIDATE.find_iter(text) {
        let digits: Vec<u8> = m.as_str().bytes().filter(u8::is_ascii_digit).map(|b| b - b'0').collect();
        if (13..=19).contains(&digits.len()) && luhn_ok(&digits) && !boundary_digit(text, m.start(), m.end()) {
            let last4: String = m.as_str().chars().filter(char::is_ascii_digit).collect::<String>()
                [digits.len() - 4..]
                .to_string();
            claim([m.start(), m.end()], "CREDIT_CARD", format!("•••• •••• •••• {last4}"), &mut taken);
        }
    }

    for m in SSN.find_iter(text) {
        let last4 = &m.as_str()[7..];
        claim([m.start(), m.end()], "US_SSN", format!("•••-••-{last4}"), &mut taken);
    }

    for m in IBAN.find_iter(text) {
        let s = m.as_str();
        if crate::stage_a::text::iban_valid(s) && !boundary_digit(text, m.start(), m.end()) {
            let last4 = &s[s.len() - 4..];
            claim([m.start(), m.end()], "IBAN", format!("{}••••{last4}", &s[..2]), &mut taken);
        }
    }

    for m in EMAIL.find_iter(text) {
        let s = m.as_str();
        let (local, domain) = s.split_once('@').unwrap();
        let tld = domain.rsplit('.').next().unwrap_or("");
        let first = local.chars().next().unwrap_or('•');
        claim([m.start(), m.end()], "EMAIL", format!("{first}•••@•••.{tld}"), &mut taken);
    }

    for m in IPV4.find_iter(text) {
        let s = m.as_str();
        if s.parse::<std::net::Ipv4Addr>().is_err() || boundary_digit(text, m.start(), m.end()) {
            continue;
        }
        let parts: Vec<&str> = s.split('.').collect();
        claim([m.start(), m.end()], "IP_ADDRESS", format!("{}.{}.•••.•••", parts[0], parts[1]), &mut taken);
    }

    for m in PHONE_CANDIDATE.find_iter(text) {
        let s = m.as_str();
        let digits = s.chars().filter(char::is_ascii_digit).count();
        if !(7..=15).contains(&digits)
            || DATE_LIKE.is_match(s.trim())
            || s.matches('.').count() >= 2 // version/IP-shaped
            || boundary_digit(text, m.start(), m.end())
        {
            continue;
        }
        let last2: String = s.chars().filter(char::is_ascii_digit).collect::<String>()[digits - 2..].to_string();
        claim([m.start(), m.end()], "PHONE", format!("{}{last2}", "•".repeat(digits - 2)), &mut taken);
    }

    out.sort_by_key(|e| e.span[0]);
    out
}

/// True when the match butts up against another digit (avoids matching the
/// middle of longer numbers — the `regex` crate has no lookarounds).
fn boundary_digit(text: &str, start: usize, end: usize) -> bool {
    let before = text[..start].chars().next_back();
    let after = text[end..].chars().next();
    before.is_some_and(|c| c.is_ascii_digit()) || after.is_some_and(|c| c.is_ascii_digit())
}

/// Entities that count toward the `pii_present` label (an IP alone doesn't).
pub fn implies_pii(entities: &[Entity]) -> bool {
    entities
        .iter()
        .any(|e| matches!(e.kind.as_str(), "EMAIL" | "PHONE" | "CREDIT_CARD" | "US_SSN" | "IBAN"))
}

fn luhn_ok(digits: &[u8]) -> bool {
    let sum: u32 = digits
        .iter()
        .rev()
        .enumerate()
        .map(|(i, &d)| {
            let mut d = d as u32;
            if i % 2 == 1 {
                d *= 2;
                if d > 9 {
                    d -= 9;
                }
            }
            d
        })
        .sum();
    sum % 10 == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_and_masks_email() {
        let e = scan("contact jane.doe@example.com for details");
        assert_eq!(e.len(), 1);
        assert_eq!(e[0].kind, "EMAIL");
        assert_eq!(e[0].value_masked, "j•••@•••.com");
        assert_eq!(&"contact jane.doe@example.com for details"[e[0].span[0]..e[0].span[1]], "jane.doe@example.com");
    }

    #[test]
    fn finds_credit_card_with_luhn() {
        let e = scan("card: 4111 1111 1111 1111 exp 12/28");
        assert!(e.iter().any(|x| x.kind == "CREDIT_CARD" && x.value_masked.ends_with("1111")));
        // Luhn-invalid number is not a card
        let e = scan("num: 4111 1111 1111 1112");
        assert!(!e.iter().any(|x| x.kind == "CREDIT_CARD"));
    }

    #[test]
    fn finds_phone_but_not_dates_or_versions() {
        let e = scan("call me at +1 (555) 123-4567 tomorrow");
        assert!(e.iter().any(|x| x.kind == "PHONE" && x.value_masked.ends_with("67")));
        assert!(scan("released 2026-06-11 at noon").iter().all(|x| x.kind != "PHONE"));
        assert!(scan("version 1.2.3.4567 changelog").iter().all(|x| x.kind != "PHONE"));
    }

    #[test]
    fn finds_ssn_and_ip() {
        let e = scan("ssn 123-45-6789, server 203.0.113.7");
        assert!(e.iter().any(|x| x.kind == "US_SSN" && x.value_masked == "•••-••-6789"));
        assert!(e.iter().any(|x| x.kind == "IP_ADDRESS" && x.value_masked == "203.0.•••.•••"));
    }

    #[test]
    fn pii_label_excludes_ip_only() {
        assert!(!implies_pii(&scan("server 203.0.113.7 is up")));
        assert!(implies_pii(&scan("mail x@y.com now")));
    }
}
