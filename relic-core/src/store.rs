//! `RelicStore` — the sync-store abstraction (SPEC §7). Every backend is a
//! dumb byte store over the wire types in `docs/wire-format.md`; E2E works
//! across all of them unchanged.

use serde::{Deserialize, Serialize};

use crate::envelope::EncryptedRelic;

/// Deletion marker (docs/wire-format.md). Retained ~30 days server-side so
/// offline devices learn about deletions instead of resurrecting relics.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tombstone {
    pub v: u8,
    pub uid: String,
    pub deleted_at: i64,
}

/// One page of a `list` result; `next` is an opaque backend cursor.
#[derive(Debug, Clone)]
pub struct Page {
    pub items: Vec<EncryptedRelic>,
    pub next: Option<String>,
}

/// Tier + usage as reported by `GET /account` (docs/api.md) — quota UX.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountInfo {
    pub tier: String,
    pub storage_used: u64,
    pub storage_quota: u64,
    pub vault_count: u64,
    pub vault_cap: Option<u64>,
}

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("malformed stored object: {0}")]
    Malformed(&'static str),
    /// Permanently rejected (4xx like 400/402/409/413): retrying the same op
    /// can never succeed — the sync queue drops it instead of wedging.
    #[error("rejected: {0}")]
    Rejected(String),
    /// Transient (network, 401/429/5xx): the op stays queued and retries.
    #[error("backend: {0}")]
    Backend(String),
}

/// A sync backend. Implementations: `local` (directory of JSON files, also
/// the test double), `http` (the Worker, M5), `s3` (post-MVP).
#[async_trait::async_trait]
pub trait RelicStore: Send + Sync {
    /// Upsert an encrypted relic by `uid` (server applies LWW on `updated_at`).
    async fn push(&self, env: &EncryptedRelic) -> Result<(), StoreError>;

    /// Relics with `updated_at > since`, ascending, paginated.
    async fn list(&self, since: i64, cursor: Option<&str>, limit: usize) -> Result<Page, StoreError>;

    /// Delete a relic (and its blob) and record a tombstone. Idempotent.
    async fn delete(&self, uid: &str, deleted_at: i64) -> Result<(), StoreError>;

    /// Tombstones with `deleted_at > since`.
    async fn tombstones(&self, since: i64) -> Result<Vec<Tombstone>, StoreError>;

    /// Store an encrypted blob (`nonce ‖ ct`) under a client-generated id
    /// (`crypto::random_blob_id`; it's the AAD binding). Returns the full
    /// backend key to record in the envelope's `blob_key`.
    async fn push_blob(&self, id: &str, data: &[u8]) -> Result<String, StoreError>;

    async fn get_blob(&self, key: &str) -> Result<Vec<u8>, StoreError>;

    /// Tier/usage info where the backend has the concept (the Worker);
    /// `None` elsewhere.
    async fn account(&self) -> Result<Option<AccountInfo>, StoreError> {
        Ok(None)
    }
}

#[async_trait::async_trait]
impl RelicStore for Box<dyn RelicStore> {
    async fn account(&self) -> Result<Option<AccountInfo>, StoreError> {
        (**self).account().await
    }
    async fn push(&self, env: &EncryptedRelic) -> Result<(), StoreError> {
        (**self).push(env).await
    }
    async fn list(&self, since: i64, cursor: Option<&str>, limit: usize) -> Result<Page, StoreError> {
        (**self).list(since, cursor, limit).await
    }
    async fn delete(&self, uid: &str, deleted_at: i64) -> Result<(), StoreError> {
        (**self).delete(uid, deleted_at).await
    }
    async fn tombstones(&self, since: i64) -> Result<Vec<Tombstone>, StoreError> {
        (**self).tombstones(since).await
    }
    async fn push_blob(&self, id: &str, data: &[u8]) -> Result<String, StoreError> {
        (**self).push_blob(id, data).await
    }
    async fn get_blob(&self, key: &str) -> Result<Vec<u8>, StoreError> {
        (**self).get_blob(key).await
    }
}
