//! `local` backend (SPEC §7): a directory of JSON files. Single-machine use
//! and the faithful test double for the Worker — it applies the same LWW and
//! tombstone rules as `docs/api.md` so sync tests exercise the real contract.

use std::fs;
use std::path::PathBuf;

use crate::envelope::EncryptedRelic;
use crate::store::{Page, RelicStore, StoreError, Tombstone};

pub struct LocalStore {
    root: PathBuf,
    relics: PathBuf,
    tombstones: PathBuf,
    blobs: PathBuf,
}

impl LocalStore {
    pub fn new(root: impl Into<PathBuf>) -> Result<Self, StoreError> {
        let root = root.into();
        let store = LocalStore {
            relics: root.join("relics"),
            tombstones: root.join("tombstones"),
            blobs: root.join("blobs"),
            root,
        };
        for dir in [&store.relics, &store.tombstones, &store.blobs] {
            fs::create_dir_all(dir)?;
        }
        Ok(store)
    }

    /// Key-params record, mirroring the Worker's `/keyparams` semantics.
    pub async fn get_keyparams(&self) -> Result<Option<crate::crypto::KeyParams>, StoreError> {
        match fs::read(self.root.join("keyparams.json")) {
            Ok(bytes) => Ok(Some(
                serde_json::from_slice(&bytes).map_err(|_| StoreError::Malformed("keyparams"))?,
            )),
            Err(_) => Ok(None),
        }
    }

    pub async fn put_keyparams(
        &self,
        params: &crate::crypto::KeyParams,
        replace: bool,
    ) -> Result<(), StoreError> {
        let path = self.root.join("keyparams.json");
        if path.exists() && !replace {
            return Err(StoreError::Rejected("keyparams already set".into()));
        }
        fs::write(path, serde_json::to_vec(params).map_err(|_| StoreError::Malformed("keyparams"))?)?;
        Ok(())
    }

    fn read_dir_json<T: serde::de::DeserializeOwned>(dir: &PathBuf) -> Result<Vec<T>, StoreError> {
        let mut out = Vec::new();
        for entry in fs::read_dir(dir)? {
            let bytes = fs::read(entry?.path())?;
            out.push(serde_json::from_slice(&bytes).map_err(|_| StoreError::Malformed("json"))?);
        }
        Ok(out)
    }
}

#[async_trait::async_trait]
impl RelicStore for LocalStore {
    async fn push(&self, env: &EncryptedRelic) -> Result<(), StoreError> {
        // tombstone guard: deletion wins over late pushes from offline devices
        if self.tombstones.join(format!("{}.json", env.uid)).exists() {
            return Ok(());
        }
        // LWW: ignore writes older than what's stored
        let path = self.relics.join(format!("{}.json", env.uid));
        if let Ok(bytes) = fs::read(&path) {
            let stored: EncryptedRelic =
                serde_json::from_slice(&bytes).map_err(|_| StoreError::Malformed("relic"))?;
            if stored.updated_at >= env.updated_at {
                return Ok(());
            }
        }
        fs::write(&path, serde_json::to_vec(env).map_err(|_| StoreError::Malformed("relic"))?)?;
        Ok(())
    }

    async fn list(&self, since: i64, cursor: Option<&str>, limit: usize) -> Result<Page, StoreError> {
        let mut items: Vec<EncryptedRelic> = Self::read_dir_json(&self.relics)?
            .into_iter()
            .filter(|e: &EncryptedRelic| e.updated_at > since)
            .collect();
        items.sort_by(|a, b| (a.updated_at, &a.uid).cmp(&(b.updated_at, &b.uid)));

        let offset: usize = cursor.map(|c| c.parse().unwrap_or(0)).unwrap_or(0);
        let has_more = items.len() > offset + limit;
        let page: Vec<_> = items.into_iter().skip(offset).take(limit).collect();
        Ok(Page {
            items: page,
            next: has_more.then(|| (offset + limit).to_string()),
        })
    }

    async fn delete(&self, uid: &str, deleted_at: i64) -> Result<(), StoreError> {
        let path = self.relics.join(format!("{uid}.json"));
        if let Ok(bytes) = fs::read(&path) {
            let stored: EncryptedRelic =
                serde_json::from_slice(&bytes).map_err(|_| StoreError::Malformed("relic"))?;
            if let Some(key) = &stored.blob_key {
                let _ = fs::remove_file(self.blobs.join(key));
            }
            fs::remove_file(&path)?;
        }
        let t = Tombstone { v: 1, uid: uid.to_string(), deleted_at };
        fs::write(
            self.tombstones.join(format!("{uid}.json")),
            serde_json::to_vec(&t).map_err(|_| StoreError::Malformed("tombstone"))?,
        )?;
        Ok(())
    }

    async fn tombstones(&self, since: i64) -> Result<Vec<Tombstone>, StoreError> {
        let mut out: Vec<Tombstone> = Self::read_dir_json(&self.tombstones)?
            .into_iter()
            .filter(|t: &Tombstone| t.deleted_at > since)
            .collect();
        out.sort_by(|a, b| (a.deleted_at, &a.uid).cmp(&(b.deleted_at, &b.uid)));
        Ok(out)
    }

    async fn push_blob(&self, id: &str, data: &[u8]) -> Result<String, StoreError> {
        if !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            return Err(StoreError::Malformed("blob id"));
        }
        fs::write(self.blobs.join(id), data)?;
        Ok(id.to_string())
    }

    async fn get_blob(&self, key: &str) -> Result<Vec<u8>, StoreError> {
        // local keys are bare ids; reject anything path-like
        if !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            return Err(StoreError::NotFound(key.to_string()));
        }
        fs::read(self.blobs.join(key)).map_err(|_| StoreError::NotFound(key.to_string()))
    }
}
