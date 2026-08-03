//! Core relic types (SPEC §4, wire format `docs/wire-format.md`).

use serde::{Deserialize, Serialize};

/// Auto-assigned, deterministic content class (SPEC §4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    String,
    Photo,
    File,
    Other,
}

/// How a relic entered the system. Everything except `Clipboard` is born
/// promoted (SPEC §1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Clipboard,
    Upload,
    Hotkey,
    Share,
    Api,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::String => "string",
            Kind::Photo => "photo",
            Kind::File => "file",
            Kind::Other => "other",
        }
    }
}

impl std::str::FromStr for Kind {
    type Err = ();
    fn from_str(s: &str) -> Result<Self, ()> {
        match s {
            "string" => Ok(Kind::String),
            "photo" => Ok(Kind::Photo),
            "file" => Ok(Kind::File),
            "other" => Ok(Kind::Other),
            _ => Err(()),
        }
    }
}

impl Source {
    /// Deliberate captures skip the ephemeral stream stage.
    pub fn born_promoted(self) -> bool {
        !matches!(self, Source::Clipboard)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Source::Clipboard => "clipboard",
            Source::Upload => "upload",
            Source::Hotkey => "hotkey",
            Source::Share => "share",
            Source::Api => "api",
        }
    }
}

impl std::str::FromStr for Source {
    type Err = ();
    fn from_str(s: &str) -> Result<Self, ()> {
        match s {
            "clipboard" => Ok(Source::Clipboard),
            "upload" => Ok(Source::Upload),
            "hotkey" => Ok(Source::Hotkey),
            "share" => Ok(Source::Share),
            "api" => Ok(Source::Api),
            _ => Err(()),
        }
    }
}

/// One file attached to a relic. Multiple attachments are concatenated into a
/// single "bundle" blob (the relic's `blob_key`); this manifest entry gives the
/// name, type, and byte length used to slice the bundle back apart. The JSON
/// shape matches the Flutter app's `Attachment` (`{id,name,mime?,size}`) so
/// bundles round-trip between the two.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attachment {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mime: Option<String>,
    #[serde(default)]
    pub size: u64,
}

/// A decrypted relic — the unit of the local index (`relics.sql`).
/// The encrypted wire form is the envelope in `docs/wire-format.md`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Relic {
    pub uid: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub kind: Kind,
    pub source: Source,
    pub promoted: bool,
    pub byte_size: u64,
    pub device: Option<String>,
    pub mime: Option<String>,
    pub filename: Option<String>,
    pub blob_key: Option<String>,
    pub tags: Vec<String>,
    pub user_tags: Vec<String>,
    pub title: Option<String>,
    pub collection: Option<String>,
    pub note: Option<String>,
    pub content: Option<String>,
    pub preview: Option<String>,
    /// File attachments packed into the bundle blob (empty for most relics).
    #[serde(default)]
    pub attachments: Vec<Attachment>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kind_serializes_lowercase() {
        assert_eq!(serde_json::to_string(&Kind::Photo).unwrap(), "\"photo\"");
    }

    #[test]
    fn deliberate_sources_born_promoted() {
        assert!(!Source::Clipboard.born_promoted());
        for s in [Source::Upload, Source::Hotkey, Source::Share, Source::Api] {
            assert!(s.born_promoted());
        }
    }
}
