//! Per-device local index (SPEC §6): decrypted relics in SQLite + FTS5 for
//! instant offline search. The canonical schema is `relics.sql` (embedded);
//! `scripts/test_schema.py` exercises the same checks against raw SQLite.

use std::collections::BTreeMap;
use std::path::Path;
use std::str::FromStr;

use rusqlite::types::Value;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row};

use crate::relic::{Kind, Relic, Source};

const SCHEMA: &str = include_str!("../relics.sql");
const SCHEMA_VERSION: i64 = 3;

#[derive(Debug, thiserror::Error)]
pub enum IndexError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("corrupt row: {0}")]
    Corrupt(&'static str),
    #[error("unsupported schema version {0}")]
    SchemaVersion(i64),
}

/// Result ordering. `Relevance` uses bm25 when a text query is present (and
/// falls back to newest-first otherwise); `Newest`/`Oldest` force a strict
/// created_at order even alongside a text match.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum Order {
    #[default]
    Relevance,
    Newest,
    Oldest,
}

/// Search parameters; all filters compose with AND.
#[derive(Debug, Default, Clone)]
pub struct Query {
    /// FTS5 match expression (prefix `tok*`, boolean, `"phrase"`, `tags:url`).
    pub text: Option<String>,
    pub kind: Option<Kind>,
    pub promoted: Option<bool>,
    pub collection: Option<String>,
    /// created_at range, unix seconds (inclusive).
    pub after: Option<i64>,
    pub before: Option<i64>,
    pub limit: usize,
    /// Rows to skip before `limit` (pagination).
    pub offset: usize,
    pub order: Order,
}

impl Query {
    pub fn new() -> Self {
        Query { limit: 100, ..Default::default() }
    }
}

pub struct LocalIndex {
    conn: Connection,
}

impl LocalIndex {
    pub fn open(path: &Path) -> Result<Self, IndexError> {
        Self::init(Connection::open(path)?)
    }

    pub fn open_in_memory() -> Result<Self, IndexError> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self, IndexError> {
        conn.pragma_update(None, "journal_mode", "WAL")?;
        // multiple connections share one db (watcher + UI threads)
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        // Cumulative migrations: each step falls through to the next so a DB at
        // any old version converges to SCHEMA_VERSION in a single open.
        let mut version: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version == 0 {
            conn.execute_batch(SCHEMA)?; // fresh DB: full schema at current version
            version = SCHEMA_VERSION;
        }
        if version == 1 {
            // v1 → v2: add the embedding-vector table for hybrid search.
            conn.execute_batch(
                "CREATE TABLE IF NOT EXISTS vectors (uid TEXT PRIMARY KEY, model TEXT NOT NULL, vec BLOB NOT NULL);
                 PRAGMA user_version = 2;",
            )?;
            version = 2;
        }
        if version == 2 {
            // v2 → v3: add the bundle-attachments manifest column.
            conn.execute_batch(
                "ALTER TABLE relics ADD COLUMN attachments TEXT NOT NULL DEFAULT '';
                 PRAGMA user_version = 3;",
            )?;
            version = 3;
        }
        if version != SCHEMA_VERSION {
            return Err(IndexError::SchemaVersion(version));
        }
        Ok(LocalIndex { conn })
    }

    /// Insert or update by `uid`. Updates fire the FTS reindex triggers.
    pub fn upsert(&self, r: &Relic) -> Result<(), IndexError> {
        self.conn.execute(
            "INSERT INTO relics (uid, created_at, updated_at, kind, source, promoted,
                                 byte_size, device, mime, filename, blob_key, tags,
                                 user_tags, title, collection, note, content, preview, attachments)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
             ON CONFLICT(uid) DO UPDATE SET
                 created_at = excluded.created_at, updated_at = excluded.updated_at,
                 kind = excluded.kind, source = excluded.source, promoted = excluded.promoted,
                 byte_size = excluded.byte_size, device = excluded.device, mime = excluded.mime,
                 filename = excluded.filename, blob_key = excluded.blob_key, tags = excluded.tags,
                 user_tags = excluded.user_tags, title = excluded.title,
                 collection = excluded.collection, note = excluded.note,
                 content = excluded.content, preview = excluded.preview,
                 attachments = excluded.attachments",
            params![
                r.uid,
                r.created_at,
                r.updated_at,
                r.kind.as_str(),
                r.source.as_str(),
                r.promoted,
                r.byte_size as i64,
                r.device,
                r.mime,
                r.filename,
                r.blob_key,
                r.tags.join(","),
                r.user_tags.join(","),
                r.title,
                r.collection,
                r.note,
                r.content,
                r.preview,
                encode_attachments(&r.attachments),
            ],
        )?;
        Ok(())
    }

    /// Upsert only if `r.updated_at` is newer than the stored row (the sync
    /// path's LWW rule). Returns whether the write happened.
    pub fn upsert_if_newer(&self, r: &Relic) -> Result<bool, IndexError> {
        let stored: Option<i64> = self
            .conn
            .query_row("SELECT updated_at FROM relics WHERE uid = ?1", params![r.uid], |row| {
                row.get(0)
            })
            .optional()?;
        match stored {
            Some(t) if t >= r.updated_at => Ok(false),
            _ => {
                self.upsert(r)?;
                Ok(true)
            }
        }
    }

    pub fn delete(&self, uid: &str) -> Result<bool, IndexError> {
        self.conn.execute("DELETE FROM vectors WHERE uid = ?1", params![uid])?;
        Ok(self.conn.execute("DELETE FROM relics WHERE uid = ?1", params![uid])? > 0)
    }

    pub fn get(&self, uid: &str) -> Result<Option<Relic>, IndexError> {
        self.conn
            .query_row(
                &format!("SELECT {COLS} FROM relics r WHERE r.uid = ?1"),
                params![uid],
                row_to_relic,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn count(&self) -> Result<u64, IndexError> {
        Ok(self.conn.query_row("SELECT COUNT(*) FROM relics", [], |r| r.get::<_, i64>(0))? as u64)
    }

    /// Full uids matching a prefix. Reads only the `uid` column, so a
    /// prefix-resolve doesn't decrypt/materialize the whole corpus.
    pub fn find_uids_by_prefix(&self, prefix: &str, limit: usize) -> Result<Vec<String>, IndexError> {
        let mut stmt = self
            .conn
            .prepare("SELECT uid FROM relics WHERE uid LIKE ?1 ORDER BY uid LIMIT ?2")?;
        let rows = stmt
            .query_map(params![format!("{prefix}%"), limit as i64], |r| r.get::<_, String>(0))?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Tag frequencies as `(user_tags, machine_tags)`, reading only the two tag
    /// columns (no full-relic build). Empty entries are skipped.
    pub fn tag_frequencies(
        &self,
    ) -> Result<(BTreeMap<String, u64>, BTreeMap<String, u64>), IndexError> {
        let mut stmt = self.conn.prepare("SELECT user_tags, tags FROM relics")?;
        let rows = stmt.query_map([], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?;
        let mut user: BTreeMap<String, u64> = BTreeMap::new();
        let mut machine: BTreeMap<String, u64> = BTreeMap::new();
        for row in rows {
            let (u, m) = row?;
            for t in split_tags(u) {
                *user.entry(t).or_insert(0) += 1;
            }
            for t in split_tags(m) {
                *machine.entry(t).or_insert(0) += 1;
            }
        }
        Ok((user, machine))
    }

    /// Search the index. With `text`, results are bm25-ranked FTS matches;
    /// without, newest-first browsing. Filters always apply.
    pub fn search(&self, q: &Query) -> Result<Vec<Relic>, IndexError> {
        let mut sql = match &q.text {
            Some(_) => format!(
                "SELECT {COLS} FROM relics_fts f JOIN relics r ON r.id = f.rowid
                 WHERE relics_fts MATCH ?1"
            ),
            None => format!("SELECT {COLS} FROM relics r WHERE 1=1"),
        };
        let mut params_vec: Vec<Value> = Vec::new();
        if let Some(t) = &q.text {
            params_vec.push(Value::Text(t.clone()));
        }
        if let Some(k) = q.kind {
            params_vec.push(Value::Text(k.as_str().into()));
            sql.push_str(&format!(" AND r.kind = ?{}", params_vec.len()));
        }
        if let Some(p) = q.promoted {
            params_vec.push(Value::Integer(p as i64));
            sql.push_str(&format!(" AND r.promoted = ?{}", params_vec.len()));
        }
        if let Some(c) = &q.collection {
            params_vec.push(Value::Text(c.clone()));
            sql.push_str(&format!(" AND r.collection = ?{}", params_vec.len()));
        }
        if let Some(a) = q.after {
            params_vec.push(Value::Integer(a));
            sql.push_str(&format!(" AND r.created_at >= ?{}", params_vec.len()));
        }
        if let Some(b) = q.before {
            params_vec.push(Value::Integer(b));
            sql.push_str(&format!(" AND r.created_at <= ?{}", params_vec.len()));
        }
        // Rank user-assigned fields (title, user_tags, note) far above
        // machine-assigned ones (content, preview, filename, tags): a match in
        // the label a *person* put on a relic should beat a match the model
        // guessed. Weights are per-FTS-column, in `relics_fts` order:
        //   content, preview, filename, tags, | title, user_tags, note
        sql.push_str(match q.order {
            Order::Newest => " ORDER BY r.created_at DESC",
            Order::Oldest => " ORDER BY r.created_at ASC",
            // Relevance: bm25 when there's a text match, else newest-first.
            Order::Relevance if q.text.is_some() => {
                " ORDER BY bm25(relics_fts, 1.0, 0.5, 1.5, 1.0, 6.0, 6.0, 4.0)"
            }
            Order::Relevance => " ORDER BY r.created_at DESC",
        });
        params_vec.push(Value::Integer(q.limit.max(1) as i64));
        sql.push_str(&format!(" LIMIT ?{}", params_vec.len()));
        if q.offset > 0 {
            params_vec.push(Value::Integer(q.offset as i64));
            sql.push_str(&format!(" OFFSET ?{}", params_vec.len()));
        }

        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(params_vec), row_to_relic)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Store (or replace) a relic's embedding vector. Caller L2-normalizes so
    /// cosine reduces to a dot product. Only saved relics get one.
    pub fn upsert_vector(&self, uid: &str, model: &str, vec: &[f32]) -> Result<(), IndexError> {
        let mut bytes = Vec::with_capacity(vec.len() * 4);
        for f in vec {
            bytes.extend_from_slice(&f.to_le_bytes());
        }
        self.conn.execute(
            "INSERT INTO vectors (uid, model, vec) VALUES (?1, ?2, ?3)
             ON CONFLICT(uid) DO UPDATE SET model = excluded.model, vec = excluded.vec",
            params![uid, model, bytes],
        )?;
        Ok(())
    }

    /// Cosine-rank stored vectors against `query` (both L2-normalized, so this
    /// is a dot product). Brute force — only saved relics have vectors, a few
    /// thousand at most, so it's sub-millisecond. Returns `(uid, score)` desc.
    pub fn vector_search(&self, query: &[f32], limit: usize) -> Result<Vec<(String, f32)>, IndexError> {
        let mut stmt = self.conn.prepare("SELECT uid, vec FROM vectors")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?)))?;
        let mut scored: Vec<(String, f32)> = Vec::new();
        for row in rows {
            let (uid, blob) = row?;
            if blob.len() != query.len() * 4 {
                continue; // dim/model mismatch — skip until re-embedded
            }
            let dot: f32 = blob
                .chunks_exact(4)
                .zip(query)
                .map(|(c, q)| f32::from_le_bytes([c[0], c[1], c[2], c[3]]) * q)
                .sum();
            scored.push((uid, dot));
        }
        scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        scored.truncate(limit);
        Ok(scored)
    }

    /// Hybrid search: fuse the FTS (bm25) and vector (cosine) candidate rankings
    /// with Reciprocal Rank Fusion (k=60), then return relics in fused order.
    /// `q` drives the keyword half and the filters; `query_vec` the semantic
    /// half. RRF works on ranks, not scores, so the incompatible bm25/cosine
    /// scales never need normalizing. Only saved relics carry vectors, so the
    /// semantic half is inherently vault-scoped.
    pub fn hybrid_search(
        &self,
        q: &Query,
        query_vec: &[f32],
        limit: usize,
    ) -> Result<Vec<Relic>, IndexError> {
        const POOL: usize = 80;
        const K: f32 = 60.0;

        let keyword: Vec<String> = match q.text {
            Some(_) => self.search(&Query { limit: POOL, ..q.clone() })?.into_iter().map(|r| r.uid).collect(),
            None => Vec::new(),
        };
        let semantic: Vec<String> =
            self.vector_search(query_vec, POOL)?.into_iter().map(|(u, _)| u).collect();

        // RRF: score(d) = Σ 1/(k + rank), rank 1-based, over both lists.
        let mut score: std::collections::HashMap<String, f32> = std::collections::HashMap::new();
        for list in [&keyword, &semantic] {
            for (rank, uid) in list.iter().enumerate() {
                *score.entry(uid.clone()).or_insert(0.0) += 1.0 / (K + (rank as f32) + 1.0);
            }
        }
        let mut order: Vec<(String, f32)> = score.into_iter().collect();
        order.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        let mut out = Vec::with_capacity(limit);
        for (uid, _) in order {
            if out.len() >= limit {
                break;
            }
            // Apply non-text filters to the semantic hits (which never went
            // through the FTS WHERE clause).
            if let Some(r) = self.get(&uid)? {
                if relic_matches(&r, q) {
                    out.push(r);
                }
            }
        }
        Ok(out)
    }

    /// The recent stream (unpromoted), newest first.
    pub fn stream(&self, limit: usize) -> Result<Vec<Relic>, IndexError> {
        self.search(&Query { promoted: Some(false), limit, ..Query::new() })
    }

    /// The vault (promoted), newest first.
    pub fn vault(&self, limit: usize) -> Result<Vec<Relic>, IndexError> {
        self.search(&Query { promoted: Some(true), limit, ..Query::new() })
    }

    /// FTS5 external-content consistency check (the prune/delete invariant).
    pub fn check_integrity(&self) -> Result<(), IndexError> {
        self.conn
            .execute("INSERT INTO relics_fts(relics_fts) VALUES('integrity-check')", [])?;
        Ok(())
    }

    // --- sync bookkeeping ---

    pub fn state_get(&self, k: &str) -> Result<Option<String>, IndexError> {
        self.conn
            .query_row("SELECT v FROM sync_state WHERE k = ?1", params![k], |r| r.get(0))
            .optional()
            .map_err(Into::into)
    }

    pub fn state_set(&self, k: &str, v: &str) -> Result<(), IndexError> {
        self.conn.execute(
            "INSERT INTO sync_state (k, v) VALUES (?1, ?2)
             ON CONFLICT(k) DO UPDATE SET v = excluded.v",
            params![k, v],
        )?;
        Ok(())
    }

    /// Queue an outbound op (`push` / `delete`) for the sync store.
    pub fn queue_op(&self, uid: &str, op: &str, queued_at: i64) -> Result<(), IndexError> {
        self.conn.execute(
            "INSERT INTO pending_ops (uid, op, queued_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(uid, op) DO UPDATE SET queued_at = excluded.queued_at",
            params![uid, op, queued_at],
        )?;
        Ok(())
    }

    /// Pending ops, oldest first, as `(uid, op, queued_at)`. For `delete`
    /// ops, `queued_at` doubles as the tombstone's `deleted_at`.
    pub fn pending_ops(&self) -> Result<Vec<(String, String, i64)>, IndexError> {
        let mut stmt = self
            .conn
            .prepare("SELECT uid, op, queued_at FROM pending_ops ORDER BY queued_at, uid")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn clear_op(&self, uid: &str, op: &str) -> Result<(), IndexError> {
        self.conn
            .execute("DELETE FROM pending_ops WHERE uid = ?1 AND op = ?2", params![uid, op])?;
        Ok(())
    }
}

const COLS: &str = "r.uid, r.created_at, r.updated_at, r.kind, r.source, r.promoted,
                    r.byte_size, r.device, r.mime, r.filename, r.blob_key, r.tags,
                    r.user_tags, r.title, r.collection, r.note, r.content, r.preview,
                    r.attachments";

fn split_tags(joined: String) -> Vec<String> {
    joined.split(',').filter(|s| !s.is_empty()).map(str::to_string).collect()
}

fn encode_attachments(a: &[crate::relic::Attachment]) -> String {
    if a.is_empty() {
        String::new()
    } else {
        serde_json::to_string(a).unwrap_or_default()
    }
}

fn decode_attachments(s: String) -> Vec<crate::relic::Attachment> {
    if s.is_empty() {
        Vec::new()
    } else {
        serde_json::from_str(&s).unwrap_or_default()
    }
}

fn row_to_relic(row: &Row) -> rusqlite::Result<Relic> {
    let kind_s: String = row.get(3)?;
    let source_s: String = row.get(4)?;
    Ok(Relic {
        uid: row.get(0)?,
        created_at: row.get(1)?,
        updated_at: row.get(2)?,
        kind: Kind::from_str(&kind_s).unwrap_or(Kind::Other),
        source: Source::from_str(&source_s).unwrap_or(Source::Api),
        promoted: row.get(5)?,
        byte_size: row.get::<_, i64>(6)? as u64,
        device: row.get(7)?,
        mime: row.get(8)?,
        filename: row.get(9)?,
        blob_key: row.get(10)?,
        tags: split_tags(row.get(11)?),
        user_tags: split_tags(row.get(12)?),
        title: row.get(13)?,
        collection: row.get(14)?,
        note: row.get(15)?,
        content: row.get(16)?,
        preview: row.get(17)?,
        attachments: decode_attachments(row.get::<_, String>(18)?),
        // relic-core's own reference index (relics.sql) has no `rich` column.
        // The desktop app's SQLite does, but it never reads rows through here.
        // Envelope round-tripping is what matters for the field, and that path
        // (seal_relic / open_relic) carries it.
        rich: None,
    })
}

/// Non-text `Query` filters, applied to semantic hits that bypassed the FTS
/// WHERE clause (the keyword half already enforced them).
fn relic_matches(r: &Relic, q: &Query) -> bool {
    q.promoted.map_or(true, |p| r.promoted == p)
        && q.kind.map_or(true, |k| k.as_str() == r.kind.as_str())
        && q.collection.as_ref().map_or(true, |c| r.collection.as_deref() == Some(c.as_str()))
        && q.after.map_or(true, |a| r.created_at >= a)
        && q.before.map_or(true, |b| r.created_at <= b)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn relic(uid: &str, kind: Kind, content: Option<&str>, created_at: i64) -> Relic {
        Relic {
            uid: uid.into(),
            created_at,
            updated_at: created_at,
            kind,
            source: Source::Clipboard,
            promoted: false,
            byte_size: content.map_or(0, |c| c.len() as u64),
            device: None,
            mime: None,
            filename: None,
            blob_key: None,
            tags: vec![],
            user_tags: vec![],
            title: None,
            collection: None,
            note: None,
            content: content.map(Into::into),
            preview: content.map(|c| c.chars().take(20).collect()),
            attachments: vec![],
            rich: None,
        }
    }

    #[test]
    fn attachments_persist_through_index() {
        let idx = LocalIndex::open_in_memory().unwrap();
        let mut r = relic("u1", Kind::File, None, 100);
        r.attachments = vec![crate::relic::Attachment {
            id: "a".into(),
            name: "x.png".into(),
            mime: Some("image/png".into()),
            size: 3,
        }];
        idx.upsert(&r).unwrap();
        assert_eq!(idx.get("u1").unwrap().unwrap().attachments, r.attachments);
    }

    #[test]
    fn order_and_offset() {
        let idx = LocalIndex::open_in_memory().unwrap();
        for (u, t) in [("u1", 100), ("u2", 200), ("u3", 300)] {
            idx.upsert(&relic(u, Kind::String, Some("note"), t)).unwrap();
        }
        let newest = idx.search(&Query { order: Order::Newest, ..Query::new() }).unwrap();
        assert_eq!(newest.iter().map(|r| r.uid.as_str()).collect::<Vec<_>>(), ["u3", "u2", "u1"]);
        let oldest = idx.search(&Query { order: Order::Oldest, ..Query::new() }).unwrap();
        assert_eq!(oldest[0].uid, "u1");
        // offset paginates: page 2 of size 1 (newest order) is u2.
        let page2 =
            idx.search(&Query { order: Order::Newest, limit: 1, offset: 1, ..Query::new() }).unwrap();
        assert_eq!(page2.iter().map(|r| r.uid.as_str()).collect::<Vec<_>>(), ["u2"]);
    }

    #[test]
    fn prefix_and_tag_frequencies() {
        let idx = LocalIndex::open_in_memory().unwrap();
        let mut a = relic("abc123", Kind::String, Some("x"), 100);
        a.user_tags = vec!["ops".into()];
        a.tags = vec!["url".into()];
        idx.upsert(&a).unwrap();
        let mut b = relic("abd456", Kind::String, Some("y"), 101);
        b.user_tags = vec!["ops".into()];
        idx.upsert(&b).unwrap();
        assert_eq!(idx.find_uids_by_prefix("abc", 10).unwrap(), ["abc123"]);
        assert_eq!(idx.find_uids_by_prefix("ab", 10).unwrap().len(), 2);
        let (user, machine) = idx.tag_frequencies().unwrap();
        assert_eq!(user.get("ops"), Some(&2));
        assert_eq!(machine.get("url"), Some(&1));
    }

    #[test]
    fn vector_search_ranks_by_cosine() {
        let idx = LocalIndex::open_in_memory().unwrap();
        idx.upsert_vector("a", "bge", &[1.0, 0.0]).unwrap();
        idx.upsert_vector("b", "bge", &[0.0, 1.0]).unwrap();
        idx.upsert_vector("c", "bge", &[0.7071, 0.7071]).unwrap();
        let res = idx.vector_search(&[1.0, 0.0], 3).unwrap();
        let order: Vec<&str> = res.iter().map(|(u, _)| u.as_str()).collect();
        assert_eq!(order, vec!["a", "c", "b"], "cosine order wrong");
    }

    #[test]
    fn hybrid_surfaces_semantic_match_fts_misses() {
        let idx = LocalIndex::open_in_memory().unwrap();
        let mut kw = relic("kw", Kind::String, Some("deploy the kubernetes cluster today"), 100);
        kw.promoted = true;
        let mut sem = relic("sem", Kind::String, Some("ship the container orchestration rollout"), 200);
        sem.promoted = true;
        idx.upsert(&kw).unwrap();
        idx.upsert(&sem).unwrap();
        // Query vector aligns with the semantic item, which shares no keyword.
        idx.upsert_vector("kw", "bge", &[1.0, 0.0]).unwrap();
        idx.upsert_vector("sem", "bge", &[0.0, 1.0]).unwrap();

        let q = Query { text: Some("kubernetes".into()), promoted: Some(true), ..Query::new() };
        let res = idx.hybrid_search(&q, &[0.0, 1.0], 10).unwrap();
        let uids: Vec<&str> = res.iter().map(|r| r.uid.as_str()).collect();
        assert!(uids.contains(&"kw"), "keyword hit missing: {uids:?}");
        assert!(uids.contains(&"sem"), "semantic-only hit missing (FTS alone misses it): {uids:?}");
    }

    #[test]
    fn user_tags_outrank_machine_tags() {
        let idx = LocalIndex::open_in_memory().unwrap();
        // "alpha" is a MACHINE tag on one relic, a USER tag on the other.
        let mut machine = relic("m", Kind::String, Some("some unrelated body text"), 100);
        machine.tags = vec!["alpha".into()];
        let mut user = relic("u", Kind::String, Some("other unrelated body text"), 200);
        user.user_tags = vec!["alpha".into()];
        idx.upsert(&machine).unwrap();
        idx.upsert(&user).unwrap();

        let res = idx.search(&Query { text: Some("alpha".into()), ..Query::new() }).unwrap();
        let order: Vec<&str> = res.iter().map(|r| r.uid.as_str()).collect();
        assert_eq!(order.first(), Some(&"u"), "user-tag match must rank first: {order:?}");
    }

    #[test]
    fn migration_v1_upgrades_to_current() {
        // A pre-existing v1 database (real relics table, no vectors, no
        // attachments column) must upgrade cumulatively (v1 -> v2 -> v3) on open.
        let path = std::env::temp_dir().join(format!("relic-mig-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "PRAGMA user_version = 1;
                 CREATE TABLE relics (uid TEXT PRIMARY KEY, created_at INTEGER, updated_at INTEGER,
                     kind TEXT, source TEXT, promoted INTEGER, byte_size INTEGER, device TEXT,
                     mime TEXT, filename TEXT, blob_key TEXT, tags TEXT DEFAULT '',
                     user_tags TEXT DEFAULT '', title TEXT, collection TEXT, note TEXT,
                     content TEXT, preview TEXT);",
            )
            .unwrap();
        }
        let idx = LocalIndex::open(&path).unwrap(); // triggers v1 -> v2 -> v3
        // v2 gave us the vectors table:
        idx.upsert_vector("u", "bge", &[1.0, 0.0]).unwrap();
        assert_eq!(idx.vector_search(&[1.0, 0.0], 1).unwrap().len(), 1);
        // v3 gave the relics table an attachments column that round-trips:
        let mut r = relic("u", Kind::File, None, 100);
        r.attachments = vec![crate::relic::Attachment {
            id: "a".into(),
            name: "f.bin".into(),
            mime: None,
            size: 1,
        }];
        idx.upsert(&r).unwrap();
        assert_eq!(idx.get("u").unwrap().unwrap().attachments, r.attachments);
        drop(idx);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn delete_removes_vector() {
        let idx = LocalIndex::open_in_memory().unwrap();
        let mut r = relic("x", Kind::String, Some("hello"), 1);
        r.promoted = true;
        idx.upsert(&r).unwrap();
        idx.upsert_vector("x", "bge", &[1.0, 0.0]).unwrap();
        assert_eq!(idx.vector_search(&[1.0, 0.0], 5).unwrap().len(), 1);
        idx.delete("x").unwrap();
        assert!(idx.vector_search(&[1.0, 0.0], 5).unwrap().is_empty(), "vector not cleaned up");
    }

    /// Mirrors the corpus in scripts/test_schema.py.
    fn seeded() -> LocalIndex {
        let idx = LocalIndex::open_in_memory().unwrap();
        let mut u1 = relic("u1", Kind::String, Some("the quick brown fox jumps"), 100);
        u1.tags = vec![];
        let mut u2 = relic("u2", Kind::String, Some("SELECT * FROM users WHERE quicksand"), 200);
        u2.tags = vec!["code".into(), "sql".into()];
        let mut u3 = relic("u3", Kind::Photo, None, 300);
        u3.filename = Some("screenshot-quarterly.png".into());
        u3.preview = Some("screenshot.png".into());
        let mut u4 = relic("u4", Kind::File, None, 400);
        u4.filename = Some("quarterly-report.pdf".into());
        u4.promoted = true;
        u4.title = Some("Q2 board report".into());
        u4.note = Some("sent to finance".into());
        let mut u5 = relic("u5", Kind::String, Some("https://example.com/quick-start"), 500);
        u5.tags = vec!["url".into()];
        for r in [&u1, &u2, &u3, &u4, &u5] {
            idx.upsert(r).unwrap();
        }
        idx
    }

    fn uids(rs: &[Relic]) -> Vec<&str> {
        rs.iter().map(|r| r.uid.as_str()).collect()
    }

    fn text_query(t: &str) -> Query {
        Query { text: Some(t.into()), ..Query::new() }
    }

    #[test]
    fn roundtrip_get_preserves_all_fields() {
        let idx = LocalIndex::open_in_memory().unwrap();
        let mut r = relic("rt", Kind::String, Some("hello"), 42);
        r.tags = vec!["url".into(), "code".into()];
        r.user_tags = vec!["work".into()];
        r.collection = Some("Keys".into());
        r.device = Some("desktop".into());
        idx.upsert(&r).unwrap();
        let back = idx.get("rt").unwrap().unwrap();
        assert_eq!(serde_json::to_value(&back).unwrap(), serde_json::to_value(&r).unwrap());
        assert!(idx.get("missing").unwrap().is_none());
    }

    #[test]
    fn ranked_prefix_search_across_kinds() {
        let idx = seeded();
        let results = idx.search(&text_query("quick*")).unwrap();
        let got = uids(&results);
        for u in ["u1", "u2", "u5"] {
            assert!(got.contains(&u), "{u} missing from {got:?}");
        }
    }

    #[test]
    fn kind_filter_composes_with_match() {
        let idx = seeded();
        let q = Query { kind: Some(Kind::File), ..text_query("quarterly*") };
        assert_eq!(uids(&idx.search(&q).unwrap()), ["u4"]);
    }

    #[test]
    fn boolean_and_phrase_queries() {
        let idx = seeded();
        assert_eq!(uids(&idx.search(&text_query("quick AND fox")).unwrap()), ["u1"]);
        assert_eq!(uids(&idx.search(&text_query("\"quick brown fox\"")).unwrap()), ["u1"]);
    }

    #[test]
    fn filename_title_note_and_tag_search() {
        let idx = seeded();
        assert_eq!(uids(&idx.search(&text_query("screenshot*")).unwrap()), ["u3"]);
        assert_eq!(uids(&idx.search(&text_query("board OR finance")).unwrap()), ["u4"]);
        assert_eq!(uids(&idx.search(&text_query("tags:url")).unwrap()), ["u5"]);
    }

    #[test]
    fn sift_tags_and_hyphenated_user_tags_search() {
        // sift's extended tag vocabulary is single-word so `tags:<tag>` works
        // unquoted; hyphenated user tags are one FTS token (tokenchars '-_.')
        // but FTS5 column syntax requires quoting them.
        let idx = LocalIndex::open_in_memory().unwrap();
        let mut r = relic("t1", Kind::String, Some("hi all, quick update on the timeline"), 100);
        r.tags = vec!["mail".into(), "pii".into()];
        r.user_tags = vec!["tax-docs-2026".into()];
        idx.upsert(&r).unwrap();
        assert_eq!(uids(&idx.search(&text_query("tags:mail")).unwrap()), ["t1"]);
        assert_eq!(uids(&idx.search(&text_query("user_tags:\"tax-docs-2026\"")).unwrap()), ["t1"]);
        // bare quoted-prefix search (what the popup builds for hyphenated
        // input) reaches the user tag too
        assert_eq!(uids(&idx.search(&text_query("\"tax-docs-2026\"*")).unwrap()), ["t1"]);
        // auto tags and user tags stay distinguishable by column
        assert_eq!(uids(&idx.search(&text_query("tags:pii")).unwrap()), ["t1"]);
        assert!(idx.search(&text_query("tags:\"tax-docs-2026\"")).unwrap().is_empty());
    }

    #[test]
    fn stream_and_vault_views() {
        let idx = seeded();
        assert_eq!(uids(&idx.stream(100).unwrap()), ["u5", "u3", "u2", "u1"]);
        assert_eq!(uids(&idx.vault(100).unwrap()), ["u4"]);
    }

    #[test]
    fn date_range_and_limit() {
        let idx = seeded();
        let q = Query { after: Some(200), before: Some(400), ..Query::new() };
        assert_eq!(uids(&idx.search(&q).unwrap()), ["u4", "u3", "u2"]);
        let q = Query { limit: 2, ..Query::new() };
        assert_eq!(idx.search(&q).unwrap().len(), 2);
    }

    #[test]
    fn update_reindexes_fts() {
        let idx = seeded();
        let mut u1 = idx.get("u1").unwrap().unwrap();
        u1.promoted = true;
        u1.title = Some("fox pangram".into());
        u1.updated_at = 600;
        idx.upsert(&u1).unwrap();
        assert_eq!(uids(&idx.search(&text_query("pangram")).unwrap()), ["u1"]);
        // vault orders by created_at, not promotion time
        assert_eq!(uids(&idx.vault(100).unwrap()), ["u4", "u1"]);
        idx.check_integrity().unwrap();
    }

    #[test]
    fn delete_keeps_fts_consistent() {
        let idx = seeded();
        assert!(idx.delete("u2").unwrap());
        assert!(!idx.delete("u2").unwrap());
        assert!(idx.search(&text_query("quicksand")).unwrap().is_empty());
        idx.check_integrity().unwrap();
        assert_eq!(idx.count().unwrap(), 4);
    }

    #[test]
    fn lww_upsert_if_newer() {
        let idx = LocalIndex::open_in_memory().unwrap();
        let mut r = relic("x", Kind::String, Some("v1"), 100);
        assert!(idx.upsert_if_newer(&r).unwrap());

        r.updated_at = 50; // stale write from another device
        r.content = Some("stale".into());
        assert!(!idx.upsert_if_newer(&r).unwrap());
        assert_eq!(idx.get("x").unwrap().unwrap().content.as_deref(), Some("v1"));

        r.updated_at = 200;
        r.content = Some("v2".into());
        assert!(idx.upsert_if_newer(&r).unwrap());
        assert_eq!(idx.get("x").unwrap().unwrap().content.as_deref(), Some("v2"));
    }

    #[test]
    fn prune_oldest_unpromoted_pattern() {
        // the free-ring prune the server applies; locally used by mobile's window
        let idx = seeded();
        idx.conn
            .execute(
                "DELETE FROM relics WHERE promoted = 0 AND uid IN (
                     SELECT uid FROM relics WHERE promoted = 0
                     ORDER BY created_at ASC LIMIT 2)",
                [],
            )
            .unwrap();
        assert_eq!(uids(&idx.stream(100).unwrap()), ["u5", "u3"]);
        assert_eq!(uids(&idx.vault(100).unwrap()), ["u4"]); // vault untouched
        idx.check_integrity().unwrap();
    }
}
