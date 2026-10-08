//! What was around a copy when it was made: the window title, the page link
//! and the words on either side of the selection.
//!
//! The app reads these at copy time and keeps them on that device only. When
//! it sends an item here it may attach them, and they change two things:
//!
//! - the labeler sees the copy *in place* ("... [[COPIED: value]] ...") with
//!   the page in the title slot, so it can say what the copy is FOR;
//! - the item gets two extra search chunks: the marked copy and the page
//!   around it.
//!
//! The text formats are exactly the ones the ft2 embedder and the t3 labeler
//! were trained on (relic-sift-next/traingen/gen/render.py): `title: <window
//! title> <url> | text: <before> [[COPIED: <value>]] <after>` and, for the page,
//! `title: <...> | text: <before> ... <after>`. Change them only together with
//! a retrain.

use serde::Deserialize;

/// Words either side of the copy in the search chunks (render.doc(r, 25)).
pub const EMBED_WORDS: usize = 25;
/// Words either side for the labeler (the t3 training export used 50).
pub const LABEL_WORDS: usize = 50;

/// One copy's surroundings. Every field is optional; an empty context is the
/// same as none.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct CopyContext {
    /// Window title, browser name included ("Invoice 1184 - Google Chrome").
    #[serde(default)]
    pub title: Option<String>,
    /// The page link, when the source was a browser.
    #[serde(default)]
    pub url: Option<String>,
    /// Text right before the copy (any length; only the nearest words are used).
    #[serde(default)]
    pub before: String,
    /// Text right after the copy.
    #[serde(default)]
    pub after: String,
}

impl CopyContext {
    pub fn is_empty(&self) -> bool {
        self.meta().is_none() && self.before.trim().is_empty() && self.after.trim().is_empty()
    }

    /// The title slot: window title then link, or None when neither exists.
    pub fn meta(&self) -> Option<String> {
        let parts: Vec<&str> = [self.title.as_deref(), self.url.as_deref()]
            .into_iter()
            .flatten()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .collect();
        (!parts.is_empty()).then(|| parts.join(" "))
    }

    fn title_slot(&self) -> String {
        self.meta().unwrap_or_else(|| "none".into())
    }

    /// The last `n` words before and the first `n` after.
    fn window(&self, n: usize) -> (String, String) {
        let b: Vec<&str> = self.before.split_whitespace().collect();
        let a: Vec<&str> = self.after.split_whitespace().take(n).collect();
        (b[b.len().saturating_sub(n)..].join(" "), a.join(" "))
    }

    fn has_words(&self) -> bool {
        !self.before.trim().is_empty() || !self.after.trim().is_empty()
    }

    /// `<before> [[COPIED: value]] <after>` with `n` words each side. With no
    /// surrounding words (or `n` = 0) the copy stands alone, unmarked, which is
    /// how training rendered a window of 0.
    pub fn marked(&self, value: &str, n: usize) -> String {
        if n == 0 || !self.has_words() {
            return value.to_string();
        }
        let (b, a) = self.window(n);
        format!("{b} [[COPIED: {value}]] {a}").trim().to_string()
    }

    /// The `(title slot, text)` pairs to embed as extra search chunks: the
    /// marked copy, plus the page around it when there are surrounding words.
    pub fn embed_chunks(&self, value: &str) -> Vec<(String, String)> {
        let slot = self.title_slot();
        let mut out = vec![(slot.clone(), self.marked(value, EMBED_WORDS))];
        if self.has_words() {
            let (b, a) = self.window(EMBED_WORDS);
            out.push((slot, format!("{b} ... {a}").trim().to_string()));
        }
        out
    }

    /// The labeler's input: the copy in place with the page in the title slot,
    /// fitted under `max_chars` by narrowing the window rather than cutting the
    /// end off. A value too long to fit even alone is cut, like a bare body.
    pub fn labeler_input(&self, value: &str, max_chars: usize) -> String {
        let slot = self.title_slot();
        for n in [LABEL_WORDS, 25, 10, 0] {
            let s = format!("title: {slot} | text: {}", self.marked(value, n));
            if s.chars().count() <= max_chars {
                return s;
            }
        }
        format!("title: {slot} | text: {value}").chars().take(max_chars).collect()
    }

    /// A copy with every field passed through `f` (used to mask secrets).
    pub fn map(&self, f: impl Fn(&str) -> String) -> CopyContext {
        CopyContext {
            title: self.title.as_deref().map(&f),
            url: self.url.as_deref().map(&f),
            before: f(&self.before),
            after: f(&self.after),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx() -> CopyContext {
        CopyContext {
            title: Some("Stripe Dashboard - Google Chrome".into()),
            url: Some("https://dashboard.stripe.com/webhooks".into()),
            before: "Signing secret for the orders endpoint".into(),
            after: "Reveal Roll secret".into(),
        }
    }

    /// The exact strings render.py trained on.
    #[test]
    fn formats_match_training() {
        let c = ctx();
        assert_eq!(
            c.labeler_input("whsec_x", 2000),
            "title: Stripe Dashboard - Google Chrome https://dashboard.stripe.com/webhooks | text: \
             Signing secret for the orders endpoint [[COPIED: whsec_x]] Reveal Roll secret"
        );
        let chunks = c.embed_chunks("whsec_x");
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[1].1, "Signing secret for the orders endpoint ... Reveal Roll secret");
    }

    #[test]
    fn window_keeps_the_nearest_words() {
        let c = CopyContext {
            before: (0..100).map(|i| format!("b{i}")).collect::<Vec<_>>().join(" "),
            after: (0..100).map(|i| format!("a{i}")).collect::<Vec<_>>().join(" "),
            ..Default::default()
        };
        let m = c.marked("V", 2);
        assert_eq!(m, "b98 b99 [[COPIED: V]] a0 a1");
    }

    #[test]
    fn title_only_context_puts_the_page_in_the_title_slot() {
        let c = CopyContext { title: Some("notes.md - Visual Studio Code".into()), ..Default::default() };
        assert!(!c.is_empty());
        assert_eq!(c.labeler_input("x = 1", 2000), "title: notes.md - Visual Studio Code | text: x = 1");
        assert_eq!(c.embed_chunks("x = 1").len(), 1, "no page chunk without surrounding words");
        assert!(CopyContext::default().is_empty());
    }

    #[test]
    fn labeler_input_fits_by_narrowing_the_window() {
        let long = "word ".repeat(400);
        let c = CopyContext { before: long.clone(), after: long, ..ctx() };
        let s = c.labeler_input("VALUE", 300);
        assert!(s.chars().count() <= 300, "{}", s.len());
        assert!(s.contains("[[COPIED: VALUE]]"));
    }
}
