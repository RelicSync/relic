//! Direct access to the desktop app's plaintext SQLite vault. Reads and writes
//! mirror `app/lib/data/relic_db.dart` exactly (schema, FTS maintenance, sync
//! queue) so the CLI is a true shim: it never migrates or reshapes the DB, and
//! its writes flow out through the app's normal sync (`pending_ops`).

use std::collections::BTreeMap;
use std::time::Duration;

use anyhow::{Context, Result};
use rusqlite::types::Value;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row, Transaction};

use crate::app_paths;
use crate::error::ExitError;
use crate::models::{json_attachments, json_list, Relic};

const COLS: &str = "r.uid, r.created_at, r.updated_at, r.kind, r.source, r.promoted,
                    r.byte_size, r.device, r.mime, r.filename, r.blob_key, r.have_blob,
                    r.tags, r.user_tags, r.title, r.note, r.content, r.preview, r.attachments";

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Order {
    Relevance,
    Newest,
    Oldest,
}

pub struct AppDb {
    conn: Connection,
    /// Whether this vault has the app's `rich` column (1.0.42 and later). The
    /// CLI never migrates, so it has to work against an older schema too.
    has_rich: bool,
}

impl AppDb {
    /// Open the app's vault DB. Errors (auth exit code) if the app isn't set up.
    /// Never migrates or alters the schema — the app owns that.
    pub fn open() -> Result<AppDb> {
        let path = app_paths::db_path()?;
        if !path.exists() {
            return Err(ExitError::auth(
                "Relic app data not found — is the desktop app installed and set up?",
            )
            .into());
        }
        let conn = Connection::open(&path).with_context(|| format!("opening {}", path.display()))?;
        conn.busy_timeout(Duration::from_secs(5))?;
        let has_rich = conn
            .prepare("SELECT 1 FROM pragma_table_info('relics') WHERE name = 'rich'")?
            .exists([])?;
        Ok(AppDb { conn, has_rich })
    }

    // --- reads ---

    /// Windowed query mirroring the app's `_runQuery`: `tag:` clauses + free
    /// text (FTS5 prefix terms, bm25 relevance), date range, vault scope.
    pub fn query(
        &self,
        search: &str,
        vault: bool,
        limit: usize,
        offset: usize,
        order: Order,
        after: Option<i64>,
        before: Option<i64>,
    ) -> Result<Vec<Relic>> {
        let (tags, text) = split_tags(search.trim());
        let order_date = if order == Order::Oldest { "ASC" } else { "DESC" };

        // No free text → browse / tag-only filter, ordered by date.
        if text.is_empty() {
            let mut p: Vec<Value> = Vec::new();
            let mut conds: Vec<String> = Vec::new();
            if vault {
                conds.push("r.promoted = 1".into());
            }
            push_tag_conds(&mut conds, &mut p, &tags);
            push_date_conds(&mut conds, &mut p, after, before);
            let where_sql = if conds.is_empty() { String::new() } else { format!("WHERE {}", conds.join(" AND ")) };
            p.push(Value::Integer(limit as i64));
            p.push(Value::Integer(offset as i64));
            let sql = format!(
                "SELECT {COLS} FROM relics r {where_sql} ORDER BY r.created_at {order_date} LIMIT ? OFFSET ?"
            );
            return self.select(&sql, p);
        }

        // Free text → FTS join.
        let Some(match_expr) = fts_expr(&text) else {
            // nothing tokenizable: fall back to tag-only if present, else empty.
            if tags.is_empty() {
                return Ok(Vec::new());
            }
            let mut p: Vec<Value> = Vec::new();
            let mut conds: Vec<String> = Vec::new();
            if vault {
                conds.push("r.promoted = 1".into());
            }
            push_tag_conds(&mut conds, &mut p, &tags);
            push_date_conds(&mut conds, &mut p, after, before);
            p.push(Value::Integer(limit as i64));
            p.push(Value::Integer(offset as i64));
            let sql = format!(
                "SELECT {COLS} FROM relics r WHERE {} ORDER BY r.created_at {order_date} LIMIT ? OFFSET ?",
                conds.join(" AND ")
            );
            return self.select(&sql, p);
        };

        let mut p: Vec<Value> = vec![Value::Text(match_expr)];
        let mut conds = String::new();
        if vault {
            conds.push_str(" AND r.promoted = 1");
        }
        for t in &tags {
            conds.push_str(" AND (lower(r.tags) LIKE ? OR lower(r.user_tags) LIKE ?)");
            let like = format!("%{t}%");
            p.push(Value::Text(like.clone()));
            p.push(Value::Text(like));
        }
        if let Some(a) = after {
            conds.push_str(" AND r.created_at >= ?");
            p.push(Value::Integer(a));
        }
        if let Some(b) = before {
            conds.push_str(" AND r.created_at < ?");
            p.push(Value::Integer(b));
        }
        let order_clause = match order {
            // weight the `body` column above `tags`, recency as the tiebreak.
            Order::Relevance => "bm25(relics_fts, 10.0, 5.0), r.created_at DESC".to_string(),
            _ => format!("r.created_at {order_date}"),
        };
        p.push(Value::Integer(limit as i64));
        p.push(Value::Integer(offset as i64));
        let sql = format!(
            "SELECT {COLS} FROM relics_fts JOIN relics r ON r.uid = relics_fts.uid
             WHERE relics_fts MATCH ?{conds} ORDER BY {order_clause} LIMIT ? OFFSET ?"
        );
        match self.select(&sql, p) {
            Ok(v) => Ok(v),
            // FTS rejected the expression — LIKE fallback so search never hard-fails.
            Err(_) => self.like_fallback(&text, &tags, vault, limit, offset, order_date, after, before),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn like_fallback(
        &self,
        text: &str,
        tags: &[String],
        vault: bool,
        limit: usize,
        offset: usize,
        order_date: &str,
        after: Option<i64>,
        before: Option<i64>,
    ) -> Result<Vec<Relic>> {
        let like = format!("%{}%", text.to_lowercase());
        let mut p: Vec<Value> = vec![
            Value::Text(like.clone()),
            Value::Text(like.clone()),
            Value::Text(like.clone()),
            Value::Text(like),
        ];
        let mut conds = String::from(
            "(lower(coalesce(r.content,'')) LIKE ? OR lower(coalesce(r.title,'')) LIKE ? \
             OR lower(coalesce(r.preview,'')) LIKE ? OR lower(coalesce(r.filename,'')) LIKE ?)",
        );
        if vault {
            conds.push_str(" AND r.promoted = 1");
        }
        for t in tags {
            conds.push_str(" AND (lower(r.tags) LIKE ? OR lower(r.user_tags) LIKE ?)");
            let l = format!("%{t}%");
            p.push(Value::Text(l.clone()));
            p.push(Value::Text(l));
        }
        if let Some(a) = after {
            conds.push_str(" AND r.created_at >= ?");
            p.push(Value::Integer(a));
        }
        if let Some(b) = before {
            conds.push_str(" AND r.created_at < ?");
            p.push(Value::Integer(b));
        }
        p.push(Value::Integer(limit as i64));
        p.push(Value::Integer(offset as i64));
        let sql = format!(
            "SELECT {COLS} FROM relics r WHERE {conds} ORDER BY r.created_at {order_date} LIMIT ? OFFSET ?"
        );
        self.select(&sql, p)
    }

    pub fn get_by_uid(&self, uid: &str) -> Result<Option<Relic>> {
        self.conn
            .query_row(&format!("SELECT {COLS} FROM relics r WHERE r.uid = ?1"), [uid], row_to_relic)
            .optional()
            .map_err(Into::into)
    }

    pub fn find_uids_by_prefix(&self, prefix: &str, limit: usize) -> Result<Vec<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT uid FROM relics WHERE uid LIKE ?1 ORDER BY uid LIMIT ?2")?;
        let rows = stmt.query_map(params![format!("{prefix}%"), limit as i64], |r| r.get::<_, String>(0))?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
    }

    pub fn tag_frequencies(&self) -> Result<(BTreeMap<String, u64>, BTreeMap<String, u64>)> {
        let mut stmt = self.conn.prepare("SELECT tags, user_tags FROM relics")?;
        let rows = stmt.query_map([], |r| {
            Ok((r.get::<_, Option<String>>(0)?, r.get::<_, Option<String>>(1)?))
        })?;
        let (mut machine, mut user) = (BTreeMap::new(), BTreeMap::new());
        for row in rows {
            let (m, u) = row?;
            for t in json_list(m) {
                *machine.entry(t).or_insert(0) += 1;
            }
            for t in json_list(u) {
                *user.entry(t).or_insert(0) += 1;
            }
        }
        Ok((user, machine))
    }

    pub fn count(&self) -> Result<i64> {
        Ok(self.conn.query_row("SELECT COUNT(*) FROM relics", [], |r| r.get(0))?)
    }

    /// (total bytes, vault/promoted count) — the app's `localAggregate`.
    pub fn local_aggregate(&self) -> Result<(i64, i64)> {
        self.conn
            .query_row(
                "SELECT COALESCE(SUM(byte_size),0), COALESCE(SUM(promoted),0) FROM relics",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(Into::into)
    }

    pub fn pending_count(&self) -> Result<i64> {
        Ok(self.conn.query_row("SELECT COUNT(*) FROM pending_ops", [], |r| r.get(0))?)
    }

    // --- writes (mirror the app's upsert / deleteAndQueue) ---

    /// Insert or update a relic plus its FTS + trigram rows, atomically. New
    /// inserts get `enrich_level = 0` (column default) so the app's background
    /// enrichment upgrades their tags/OCR/vector on its next run.
    ///
    /// `rich` (the app's HTML/RTF flavors) is cleared, never carried. The CLI
    /// never produces formatting, and an edit here would otherwise leave the
    /// old markup attached to new text: the app ignores it (it is fingerprinted
    /// against the body it came from) but `byte_size` would still be written
    /// from the plain text alone, and the sync Worker rejects a row whose
    /// declared size is that far under its sealed body.
    pub fn upsert(&self, r: &Relic, have_blob: bool, queue_push: bool) -> Result<()> {
        let tx = self.conn.unchecked_transaction()?;
        let content_hash: Option<i64> = r.content.as_deref().map(content_hash);
        let attachments_json = if r.attachments.is_empty() {
            None
        } else {
            Some(serde_json::to_string(&r.attachments).unwrap_or_default())
        };
        // Clearing `rich` is part of the same statement so an edit can never
        // leave markup behind that outlives the text it came from.
        let clear_rich = if self.has_rich { ", rich=NULL" } else { "" };
        tx.execute(
            &format!(
                "INSERT INTO relics
               (uid, created_at, updated_at, kind, source, promoted, byte_size,
                device, mime, filename, blob_key, content_hash, have_blob,
                tags, user_tags, title, note, content, preview, attachments)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20)
             ON CONFLICT(uid) DO UPDATE SET
               created_at=excluded.created_at, updated_at=excluded.updated_at,
               kind=excluded.kind, source=excluded.source, promoted=excluded.promoted,
               byte_size=excluded.byte_size, device=excluded.device, mime=excluded.mime,
               filename=excluded.filename, blob_key=excluded.blob_key,
               content_hash=excluded.content_hash, tags=excluded.tags,
               user_tags=excluded.user_tags, title=excluded.title, note=excluded.note,
               content=excluded.content, preview=excluded.preview,
               attachments=excluded.attachments{clear_rich}"
            ),
            params![
                r.uid,
                r.created_at,
                r.updated_at,
                r.kind,
                r.source,
                r.promoted as i64,
                r.byte_size,
                r.device,
                r.mime,
                r.filename,
                r.blob_key,
                content_hash,
                have_blob as i64,
                serde_json::to_string(&r.tags).unwrap_or_else(|_| "[]".into()),
                serde_json::to_string(&r.user_tags).unwrap_or_else(|_| "[]".into()),
                r.title,
                r.note,
                r.content,
                r.preview,
                attachments_json,
            ],
        )?;
        let body = body_text(r);
        let tag_text = tag_text(r);
        tx.execute("DELETE FROM relics_fts WHERE uid = ?1", [&r.uid])?;
        tx.execute(
            "INSERT INTO relics_fts (uid, body, tags) VALUES (?1,?2,?3)",
            params![r.uid, body, tag_text],
        )?;
        tx.execute("DELETE FROM relics_tri WHERE uid = ?1", [&r.uid])?;
        tx.execute(
            "INSERT INTO relics_tri (uid, body) VALUES (?1,?2)",
            params![r.uid, format!("{body} {tag_text}")],
        )?;
        if queue_push {
            queue_op_tx(&tx, &r.uid, "push", r.updated_at)?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Delete a relic everywhere and (optionally) queue a delete tombstone for
    /// sync — the app's `deleteAndQueue`.
    pub fn delete_and_queue(&self, uid: &str, deleted_at: i64, queue_delete: bool) -> Result<()> {
        let tx = self.conn.unchecked_transaction()?;
        tx.execute("DELETE FROM pending_ops WHERE uid = ?1 AND op = 'push'", [uid])?;
        tx.execute("DELETE FROM sync_rejections WHERE uid = ?1 AND op = 'push'", [uid])?;
        if queue_delete {
            queue_op_tx(&tx, uid, "delete", deleted_at)?;
        }
        tx.execute("DELETE FROM relics WHERE uid = ?1", [uid])?;
        tx.execute("DELETE FROM relics_fts WHERE uid = ?1", [uid])?;
        tx.execute("DELETE FROM relics_tri WHERE uid = ?1", [uid])?;
        tx.execute("DELETE FROM vectors WHERE uid = ?1", [uid])?;
        tx.commit()?;
        Ok(())
    }
}

// --- helpers ---

fn queue_op_tx(tx: &Transaction, uid: &str, op: &str, queued_at: i64) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT INTO pending_ops (uid, op, queued_at) VALUES (?1,?2,?3)
         ON CONFLICT(uid, op) DO UPDATE SET queued_at = excluded.queued_at",
        params![uid, op, queued_at],
    )?;
    tx.execute("DELETE FROM sync_rejections WHERE uid = ?1 AND op = ?2", params![uid, op])?;
    Ok(())
}

impl AppDb {
    fn select(&self, sql: &str, p: Vec<Value>) -> Result<Vec<Relic>> {
        let mut stmt = self.conn.prepare(sql)?;
        let rows = stmt.query_map(params_from_iter(p), row_to_relic)?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
    }
}

fn row_to_relic(row: &Row) -> rusqlite::Result<Relic> {
    Ok(Relic {
        uid: row.get(0)?,
        created_at: row.get(1)?,
        updated_at: row.get(2)?,
        kind: row.get::<_, Option<String>>(3)?.unwrap_or_else(|| "string".into()),
        source: row.get::<_, Option<String>>(4)?.unwrap_or_else(|| "clipboard".into()),
        promoted: row.get::<_, i64>(5)? != 0,
        byte_size: row.get(6)?,
        device: row.get(7)?,
        mime: row.get(8)?,
        filename: row.get(9)?,
        blob_key: row.get(10)?,
        have_blob: row.get::<_, i64>(11)? != 0,
        tags: json_list(row.get::<_, Option<String>>(12)?),
        user_tags: json_list(row.get::<_, Option<String>>(13)?),
        title: row.get(14)?,
        note: row.get(15)?,
        content: row.get(16)?,
        preview: row.get(17)?,
        attachments: json_attachments(row.get::<_, Option<String>>(18)?),
    })
}

/// Split a query into `tag:` clauses and the free-text remainder (whitespace
/// tokenized; mirrors the app's `tag:(\S+)` split).
fn split_tags(s: &str) -> (Vec<String>, String) {
    let mut tags = Vec::new();
    let mut rest: Vec<&str> = Vec::new();
    for tok in s.split_whitespace() {
        match tok.to_lowercase().strip_prefix("tag:") {
            Some(v) if !v.is_empty() => tags.push(v.to_string()),
            _ => rest.push(tok),
        }
    }
    (tags, rest.join(" "))
}

fn push_tag_conds(conds: &mut Vec<String>, p: &mut Vec<Value>, tags: &[String]) {
    for t in tags {
        conds.push("(lower(r.tags) LIKE ? OR lower(r.user_tags) LIKE ?)".into());
        let like = format!("%{t}%");
        p.push(Value::Text(like.clone()));
        p.push(Value::Text(like));
    }
}

fn push_date_conds(conds: &mut Vec<String>, p: &mut Vec<Value>, after: Option<i64>, before: Option<i64>) {
    if let Some(a) = after {
        conds.push("r.created_at >= ?".into());
        p.push(Value::Integer(a));
    }
    if let Some(b) = before {
        conds.push("r.created_at < ?".into());
        p.push(Value::Integer(b));
    }
}

/// FTS5 MATCH expression: each token → a quoted prefix term, space-joined.
/// Mirrors the app's `_ftsExpr` (strips `"()*:^`). None if nothing tokenizable.
fn fts_expr(s: &str) -> Option<String> {
    let terms: Vec<String> = s
        .to_lowercase()
        .split_whitespace()
        .map(|t| {
            t.chars().map(|c| if "\"()*:^".contains(c) { ' ' } else { c }).collect::<String>().trim().to_string()
        })
        .filter(|t| !t.is_empty())
        .map(|t| format!("\"{t}\"*"))
        .collect();
    if terms.is_empty() {
        None
    } else {
        Some(terms.join(" "))
    }
}

/// FTS `body` text: literal fields + attachment names. The app additionally
/// folds in synonym expansions (file-type / tag / in-prose terms); those are
/// re-applied when the app's background enrichment reindexes this relic.
fn body_text(r: &Relic) -> String {
    let mut parts: Vec<String> = Vec::new();
    for o in [&r.content, &r.title, &r.preview, &r.filename, &r.note] {
        if let Some(s) = o {
            parts.push(s.clone());
        }
    }
    for a in &r.attachments {
        parts.push(a.name.clone());
    }
    parts.join(" ")
}

fn tag_text(r: &Relic) -> String {
    let mut v = r.tags.clone();
    v.extend(r.user_tags.clone());
    v.join(" ")
}

/// The app's cheap sampled content fingerprint (`RelicDb._hash`), for dedupe.
fn content_hash(content: &str) -> i64 {
    let b = content.as_bytes();
    let mut h: i64 = b.len() as i64;
    let step = if b.is_empty() { 1 } else { (b.len() / 64).clamp(1, b.len()) };
    let mut i = 0;
    while i < b.len() {
        h = (h.wrapping_mul(31).wrapping_add(b[i] as i64)) & 0x7fff_ffff;
        i += step;
    }
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fts_expr_quotes_prefix_terms() {
        assert_eq!(fts_expr("kubectl rollout").as_deref(), Some("\"kubectl\"* \"rollout\"*"));
        assert_eq!(fts_expr("  *()  ").as_deref(), None);
        // metacharacters inside a token become a space (matches the app):
        // "foo:bar" is one whitespace-token, so it becomes the phrase "foo bar".
        assert_eq!(fts_expr("foo:bar").as_deref(), Some("\"foo bar\"*"));
    }

    #[test]
    fn split_tags_separates_clauses() {
        let (tags, text) = split_tags("deploy tag:ops staging");
        assert_eq!(tags, vec!["ops".to_string()]);
        assert_eq!(text, "deploy staging");
    }

    #[test]
    fn content_hash_matches_dart_shape() {
        // empty string → h = len = 0
        assert_eq!(content_hash(""), 0);
        // deterministic + stable
        assert_eq!(content_hash("hello"), content_hash("hello"));
        assert_ne!(content_hash("hello"), content_hash("world"));
    }
}
