//! Sync engine (SPEC §7): seal-and-push outbound through an offline-tolerant
//! queue; pull-since-cursor inbound with LWW upserts and tombstone reconcile.
//! Owns the device's local index, store handle, and master key.

use crate::crypto::MasterKey;
use crate::envelope::{open_relic, seal_relic, EnvelopeError};
use crate::index::{IndexError, LocalIndex};
use crate::relic::Relic;
use crate::store::{RelicStore, StoreError};

const CURSOR_RELICS: &str = "cursor_relics";
const CURSOR_TOMBSTONES: &str = "cursor_tombstones";
const PAGE_SIZE: usize = 500;

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error(transparent)]
    Index(#[from] IndexError),
    #[error(transparent)]
    Envelope(#[from] EnvelopeError),
    #[error(transparent)]
    Store(#[from] StoreError),
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct PullStats {
    /// relics upserted (newer than local)
    pub applied: usize,
    /// relics deleted via tombstones
    pub deleted: usize,
    /// envelopes that failed to decrypt (wrong key / corrupt) — counted, never fatal
    pub undecryptable: usize,
}

pub struct SyncEngine<S: RelicStore> {
    index: LocalIndex,
    store: S,
    mk: MasterKey,
}

impl<S: RelicStore> SyncEngine<S> {
    pub fn new(index: LocalIndex, store: S, mk: MasterKey) -> Self {
        SyncEngine { index, store, mk }
    }

    /// Search/browse surface — all reads go straight to the local index.
    pub fn index(&self) -> &LocalIndex {
        &self.index
    }

    pub fn store(&self) -> &S {
        &self.store
    }

    pub fn mk(&self) -> &MasterKey {
        &self.mk
    }

    /// Capture or edit: upsert locally, queue, then try to push. A store
    /// failure (offline) leaves the op queued; the relic is already safe in
    /// the local index.
    pub async fn save(&self, relic: &Relic) -> Result<(), SyncError> {
        self.index.upsert(relic)?;
        self.index.queue_op(&relic.uid, "push", relic.updated_at)?;
        self.flush().await?;
        Ok(())
    }

    /// Delete locally and propagate. Offline-tolerant like `save`.
    pub async fn delete(&self, uid: &str, deleted_at: i64) -> Result<(), SyncError> {
        self.index.delete(uid)?;
        self.index.clear_op(uid, "push")?;
        self.index.queue_op(uid, "delete", deleted_at)?;
        self.flush().await?;
        Ok(())
    }

    /// Drain the outbound queue. Store errors are not fatal: draining stops
    /// (ops stay queued for the next flush) and the count of completed ops is
    /// returned. Only local index errors propagate.
    pub async fn flush(&self) -> Result<usize, SyncError> {
        let mut done = 0;
        for (uid, op, queued_at) in self.index.pending_ops()? {
            let result = match op.as_str() {
                "push" => match self.index.get(&uid)? {
                    Some(relic) => {
                        let env = seal_relic(&self.mk, &relic)?;
                        self.store.push(&env).await
                    }
                    None => Ok(()), // deleted locally since queueing
                },
                _ => self.store.delete(&uid, queued_at).await,
            };
            match result {
                Ok(()) => {
                    self.index.clear_op(&uid, &op)?;
                    done += 1;
                }
                // permanently rejected (size cap, quota…): drop the op so it
                // can't wedge the queue; the relic stays in the local index.
                // Recorded in sync_state so the UI can surface it (quota UX).
                Err(StoreError::Rejected(reason)) => {
                    self.index.clear_op(&uid, &op)?;
                    self.index.state_set("last_drop", &format!("{op} {uid}: {reason}"))?;
                }
                Err(_) => break, // offline — retry on next flush
            }
        }
        Ok(done)
    }

    /// Sync down: page through relics newer than the cursor, LWW-upsert each,
    /// then apply tombstones. Cursors advance to `max - 1` so items sharing
    /// the boundary second are re-examined next pull (idempotent) rather than
    /// skipped forever.
    pub async fn pull(&self) -> Result<PullStats, SyncError> {
        let mut stats = PullStats::default();

        let since = self.cursor(CURSOR_RELICS)?;
        let mut max = since;
        let mut cursor: Option<String> = None;
        loop {
            let page = self.store.list(since, cursor.as_deref(), PAGE_SIZE).await?;
            for env in &page.items {
                max = max.max(env.updated_at);
                match open_relic(&self.mk, env) {
                    Ok(relic) => {
                        if self.index.upsert_if_newer(&relic)? {
                            stats.applied += 1;
                        }
                    }
                    Err(_) => stats.undecryptable += 1,
                }
            }
            match page.next {
                Some(c) => cursor = Some(c),
                None => break,
            }
        }
        self.index.state_set(CURSOR_RELICS, &(max - 1).max(since).to_string())?;

        let tsince = self.cursor(CURSOR_TOMBSTONES)?;
        let mut tmax = tsince;
        for t in self.store.tombstones(tsince).await? {
            tmax = tmax.max(t.deleted_at);
            self.index.clear_op(&t.uid, "push")?;
            if self.index.delete(&t.uid)? {
                stats.deleted += 1;
            }
        }
        self.index.state_set(CURSOR_TOMBSTONES, &(tmax - 1).max(tsince).to_string())?;

        Ok(stats)
    }

    fn cursor(&self, key: &str) -> Result<i64, SyncError> {
        Ok(self.index.state_get(key)?.and_then(|v| v.parse().ok()).unwrap_or(0))
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    use super::*;
    use crate::crypto::KeyParams;
    use crate::envelope::EncryptedRelic;
    use crate::index::Query;
    use crate::relic::{Kind, Source};
    use crate::store::{Page, Tombstone};
    use crate::store_local::LocalStore;

    fn relic(uid: &str, content: &str, ts: i64) -> Relic {
        Relic {
            uid: uid.into(),
            created_at: ts,
            updated_at: ts,
            kind: Kind::String,
            source: Source::Clipboard,
            promoted: false,
            byte_size: content.len() as u64,
            device: None,
            mime: None,
            filename: None,
            blob_key: None,
            tags: vec![],
            user_tags: vec![],
            title: None,
            collection: None,
            note: None,
            content: Some(content.into()),
            preview: Some(content.into()),
            attachments: vec![],
            rich: None,
        }
    }

    fn engine(dir: &std::path::Path, mk_bytes: [u8; 32]) -> SyncEngine<LocalStore> {
        SyncEngine::new(
            LocalIndex::open_in_memory().unwrap(),
            LocalStore::new(dir).unwrap(),
            MasterKey::from_bytes(mk_bytes),
        )
    }

    #[tokio::test]
    async fn two_devices_converge() {
        let dir = tempfile::tempdir().unwrap();
        let a = engine(dir.path(), [7; 32]);
        let b = engine(dir.path(), [7; 32]);

        // capture on A → appears on B
        a.save(&relic("r1", "hello from A", 100)).await.unwrap();
        let stats = b.pull().await.unwrap();
        assert_eq!(stats.applied, 1);
        assert_eq!(b.index().get("r1").unwrap().unwrap().content.as_deref(), Some("hello from A"));

        // promote + retitle on B → A converges
        let mut r1 = b.index().get("r1").unwrap().unwrap();
        r1.promoted = true;
        r1.title = Some("keeper".into());
        r1.updated_at = 110;
        b.save(&r1).await.unwrap();
        a.pull().await.unwrap();
        let on_a = a.index().get("r1").unwrap().unwrap();
        assert!(on_a.promoted);
        assert_eq!(on_a.title.as_deref(), Some("keeper"));

        // own writes echo back as no-ops
        let stats = b.pull().await.unwrap();
        assert_eq!(stats.applied, 0);
    }

    #[tokio::test]
    async fn out_of_order_delivery_resolves_lww() {
        let dir = tempfile::tempdir().unwrap();
        let a = engine(dir.path(), [7; 32]);
        let b = engine(dir.path(), [7; 32]);

        a.save(&relic("r1", "newer", 200)).await.unwrap();
        // a stale write arrives at the store afterwards (delayed device)
        let stale = engine(dir.path(), [7; 32]);
        stale.save(&relic("r1", "older", 150)).await.unwrap();

        b.pull().await.unwrap();
        assert_eq!(b.index().get("r1").unwrap().unwrap().content.as_deref(), Some("newer"));
    }

    #[tokio::test]
    async fn delete_propagates_and_blocks_resurrection() {
        let dir = tempfile::tempdir().unwrap();
        let a = engine(dir.path(), [7; 32]);
        let b = engine(dir.path(), [7; 32]);

        a.save(&relic("r1", "doomed", 100)).await.unwrap();
        b.pull().await.unwrap();

        a.delete("r1", 120).await.unwrap();
        let stats = b.pull().await.unwrap();
        assert_eq!(stats.deleted, 1);
        assert!(b.index().get("r1").unwrap().is_none());
        b.index().check_integrity().unwrap();

        // offline device C pushes the deleted relic afterwards — tombstone wins
        let c = engine(dir.path(), [7; 32]);
        c.save(&relic("r1", "zombie", 90)).await.unwrap();
        let stats = b.pull().await.unwrap();
        assert_eq!(stats.applied, 0);
        assert!(b.index().get("r1").unwrap().is_none());
    }

    /// Store wrapper that fails every call while `down` is set.
    struct FlakyStore {
        inner: LocalStore,
        down: Arc<AtomicBool>,
    }

    impl FlakyStore {
        fn check(&self) -> Result<(), StoreError> {
            if self.down.load(Ordering::SeqCst) {
                Err(StoreError::Backend("offline".into()))
            } else {
                Ok(())
            }
        }
    }

    #[async_trait::async_trait]
    impl RelicStore for FlakyStore {
        async fn push(&self, env: &EncryptedRelic) -> Result<(), StoreError> {
            self.check()?;
            self.inner.push(env).await
        }
        async fn list(&self, since: i64, cursor: Option<&str>, limit: usize) -> Result<Page, StoreError> {
            self.check()?;
            self.inner.list(since, cursor, limit).await
        }
        async fn delete(&self, uid: &str, deleted_at: i64) -> Result<(), StoreError> {
            self.check()?;
            self.inner.delete(uid, deleted_at).await
        }
        async fn tombstones(&self, since: i64) -> Result<Vec<Tombstone>, StoreError> {
            self.check()?;
            self.inner.tombstones(since).await
        }
        async fn push_blob(&self, id: &str, data: &[u8]) -> Result<String, StoreError> {
            self.check()?;
            self.inner.push_blob(id, data).await
        }
        async fn get_blob(&self, key: &str) -> Result<Vec<u8>, StoreError> {
            self.check()?;
            self.inner.get_blob(key).await
        }
    }

    #[tokio::test]
    async fn offline_captures_queue_and_flush_later() {
        let dir = tempfile::tempdir().unwrap();
        let down = Arc::new(AtomicBool::new(true));
        let a = SyncEngine::new(
            LocalIndex::open_in_memory().unwrap(),
            FlakyStore { inner: LocalStore::new(dir.path()).unwrap(), down: down.clone() },
            MasterKey::from_bytes([7; 32]),
        );

        // captures while offline: locally visible, queued, nothing remote
        a.save(&relic("r1", "captured offline", 100)).await.unwrap();
        a.save(&relic("r2", "also offline", 101)).await.unwrap();
        assert_eq!(a.index().pending_ops().unwrap().len(), 2);
        assert_eq!(a.index().count().unwrap(), 2);

        let b = engine(dir.path(), [7; 32]);
        assert_eq!(b.pull().await.unwrap().applied, 0);

        // back online: flush drains the queue in order
        down.store(false, Ordering::SeqCst);
        assert_eq!(a.flush().await.unwrap(), 2);
        assert!(a.index().pending_ops().unwrap().is_empty());
        assert_eq!(b.pull().await.unwrap().applied, 2);
    }

    /// Rejects any push with byte_size > 100 (stand-in for 413/402).
    struct RejectingStore {
        inner: LocalStore,
    }

    #[async_trait::async_trait]
    impl RelicStore for RejectingStore {
        async fn push(&self, env: &EncryptedRelic) -> Result<(), StoreError> {
            if env.byte_size > 100 {
                return Err(StoreError::Rejected("413: too large".into()));
            }
            self.inner.push(env).await
        }
        async fn list(&self, since: i64, cursor: Option<&str>, limit: usize) -> Result<Page, StoreError> {
            self.inner.list(since, cursor, limit).await
        }
        async fn delete(&self, uid: &str, deleted_at: i64) -> Result<(), StoreError> {
            self.inner.delete(uid, deleted_at).await
        }
        async fn tombstones(&self, since: i64) -> Result<Vec<Tombstone>, StoreError> {
            self.inner.tombstones(since).await
        }
        async fn push_blob(&self, id: &str, data: &[u8]) -> Result<String, StoreError> {
            self.inner.push_blob(id, data).await
        }
        async fn get_blob(&self, key: &str) -> Result<Vec<u8>, StoreError> {
            self.inner.get_blob(key).await
        }
    }

    #[tokio::test]
    async fn rejected_ops_drop_instead_of_wedging() {
        let dir = tempfile::tempdir().unwrap();
        let a = SyncEngine::new(
            LocalIndex::open_in_memory().unwrap(),
            RejectingStore { inner: LocalStore::new(dir.path()).unwrap() },
            MasterKey::from_bytes([7; 32]),
        );

        let mut big = relic("too-big", "x", 100);
        big.byte_size = 5000;
        a.save(&big).await.unwrap();
        a.save(&relic("fine", "small enough", 101)).await.unwrap();

        // the rejected op is gone, the good one landed, queue is clean,
        // and the drop is visible to the UI
        assert!(a.index().pending_ops().unwrap().is_empty());
        assert!(a.index().state_get("last_drop").unwrap().unwrap().contains("too-big"));
        let b = engine(dir.path(), [7; 32]);
        b.pull().await.unwrap();
        assert!(b.index().get("fine").unwrap().is_some());
        assert!(b.index().get("too-big").unwrap().is_none());
        // ...but the relic survives locally
        assert!(a.index().get("too-big").unwrap().is_some());
    }

    #[tokio::test]
    async fn blob_roundtrip_and_delete_removes_blob() {
        let dir = tempfile::tempdir().unwrap();
        let a = engine(dir.path(), [7; 32]);
        let store = LocalStore::new(dir.path()).unwrap();

        let key = store.push_blob("blob-id-1", b"encrypted-bytes").await.unwrap();
        let mut r = relic("p1", "", 100);
        r.kind = Kind::Photo;
        r.blob_key = Some(key.clone());
        a.save(&r).await.unwrap();

        assert_eq!(store.get_blob(&key).await.unwrap(), b"encrypted-bytes");
        a.delete("p1", 110).await.unwrap();
        assert!(matches!(store.get_blob(&key).await, Err(StoreError::NotFound(_))));
    }

    #[tokio::test]
    async fn wrong_key_counts_undecryptable_not_fatal() {
        let dir = tempfile::tempdir().unwrap();
        let a = engine(dir.path(), [1; 32]);
        let b = engine(dir.path(), [2; 32]); // different key

        a.save(&relic("r1", "sealed with key 1", 100)).await.unwrap();
        let stats = b.pull().await.unwrap();
        assert_eq!(stats, PullStats { applied: 0, deleted: 0, undecryptable: 1 });
    }

    #[tokio::test]
    async fn full_resync_via_search_after_fresh_device() {
        let dir = tempfile::tempdir().unwrap();
        let (params, mk) = KeyParams::create("passphrase").map(|(p, m)| (p, m)).unwrap();
        let a = SyncEngine::new(
            LocalIndex::open_in_memory().unwrap(),
            LocalStore::new(dir.path()).unwrap(),
            mk,
        );
        for i in 0..25 {
            a.save(&relic(&format!("r{i}"), &format!("note number {i}"), 100 + i)).await.unwrap();
        }

        // brand-new device: unlock from stored params, pull everything, search
        let mk2 = params.unlock("passphrase").unwrap();
        let fresh = SyncEngine::new(
            LocalIndex::open_in_memory().unwrap(),
            LocalStore::new(dir.path()).unwrap(),
            mk2,
        );
        assert_eq!(fresh.pull().await.unwrap().applied, 25);
        let hits = fresh
            .index()
            .search(&Query { text: Some("note AND number".into()), ..Query::new() })
            .unwrap();
        assert_eq!(hits.len(), 25);
    }
}
