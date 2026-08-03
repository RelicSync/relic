//! The relic shape as stored in the desktop app's SQLite (`app/lib/data/
//! relic_db.dart`). Tags/attachments are JSON-encoded in their columns.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Attachment {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mime: Option<String>,
    #[serde(default)]
    pub size: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Relic {
    pub uid: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub kind: String,
    pub source: String,
    pub promoted: bool,
    pub byte_size: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mime: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blob_key: Option<String>,
    pub have_blob: bool,
    pub tags: Vec<String>,
    pub user_tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<Attachment>,
}

impl Relic {
    /// User-facing tags: user tags first, then machine tags minus `secret`.
    pub fn display_tags(&self) -> Vec<String> {
        let mut out = self.user_tags.clone();
        out.extend(self.tags.iter().filter(|t| t.as_str() != "secret").cloned());
        out
    }

    pub fn display_title(&self) -> String {
        self.title
            .clone()
            .or_else(|| self.preview.clone())
            .or_else(|| self.filename.clone())
            .or_else(|| self.content.clone())
            .unwrap_or_else(|| "(untitled)".into())
            .lines()
            .next()
            .unwrap_or("")
            .chars()
            .take(72)
            .collect()
    }
}

/// Parse a JSON string array column (`tags`/`user_tags`) into a Vec, tolerating
/// null/empty/malformed as an empty list (matches the app's `_jsonList`).
pub fn json_list(s: Option<String>) -> Vec<String> {
    match s {
        Some(s) if !s.is_empty() => serde_json::from_str(&s).unwrap_or_default(),
        _ => Vec::new(),
    }
}

pub fn json_attachments(s: Option<String>) -> Vec<Attachment> {
    match s {
        Some(s) if !s.is_empty() => serde_json::from_str(&s).unwrap_or_default(),
        _ => Vec::new(),
    }
}

// --- shared construction helpers ---

pub fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

/// UUIDv7 (time-ordered), matching the app's uid scheme conceptually.
pub fn new_uid() -> String {
    uuid::Uuid::now_v7().to_string()
}

pub fn dedup(mut v: Vec<String>) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    v.retain(|t| !t.is_empty() && seen.insert(t.clone()));
    v
}
