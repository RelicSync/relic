//! Write commands: add, tag, edit, promote/unpromote, copy, import. Writes go
//! into the app's local DB + sync queue (`pending_ops`); the running app uploads
//! blobs, pushes to the Worker, and enriches new relics with ML.

use std::io::Read;

use anyhow::{Context, Result};
use clap::Args;
use serde_json::json;

use crate::app_db::AppDb;
use crate::app_paths;
use crate::commands::read::resolve_uid;
use crate::error::ExitError;
use crate::models::{dedup, new_uid, now, Attachment, Relic};
use crate::output::{print_json, short_uid, OutputMode};
use crate::{safety, Ctx};

#[derive(Args)]
pub struct UidArg {
    /// Relic uid (full, or a unique prefix).
    pub uid: String,
}

#[derive(Args)]
pub struct AddArgs {
    /// Text body. If omitted and no --file, reads stdin.
    text: Option<String>,
    /// Attach file(s); one file → a file relic, many → a bundle relic.
    #[arg(long)]
    file: Vec<String>,
    /// Title.
    #[arg(long)]
    title: Option<String>,
    /// User tag(s) to apply. Repeatable.
    #[arg(long)]
    tag: Vec<String>,
    /// Save straight to the Vault (promoted).
    #[arg(long)]
    vault: bool,
    /// Annotation note.
    #[arg(long)]
    note: Option<String>,
}

pub fn add(args: AddArgs, ctx: &Ctx) -> Result<()> {
    let db = AppDb::open()?;

    if !args.file.is_empty() {
        let uid = if args.file.len() == 1 {
            add_single_file(&db, &args.file[0], &args, ctx)?
        } else {
            add_bundle(&db, &args, ctx)?
        };
        report_uids(ctx, &uid.into_iter().collect::<Vec<_>>());
        return Ok(());
    }

    let text = match args.text {
        Some(t) => t,
        None => read_stdin()?,
    };
    if text.trim().is_empty() {
        return Err(ExitError::new(2, "nothing to add (empty text)").into());
    }
    let ts = now();
    let relic = Relic {
        uid: new_uid(),
        created_at: ts,
        updated_at: ts,
        kind: "string".into(),
        source: "api".into(),
        promoted: args.vault,
        byte_size: text.len() as i64,
        device: None,
        mime: None,
        filename: None,
        blob_key: None,
        have_blob: false,
        tags: vec![],
        user_tags: dedup(args.tag.clone()),
        title: args.title.clone(),
        note: args.note.clone(),
        content: Some(text.clone()),
        preview: Some(preview_of(&text)),
        attachments: vec![],
    };
    if ctx.dry_run {
        safety::note_dry_run(ctx, &format!("add a {}-byte text relic", text.len()));
    } else {
        db.upsert(&relic, false, true)?;
    }
    safety::audit("add", &relic.uid, json!({"kind":"string","bytes":text.len()}), ctx.dry_run);
    report_uids(ctx, &[relic.uid]);
    Ok(())
}

fn add_single_file(db: &AppDb, path: &str, args: &AddArgs, ctx: &Ctx) -> Result<Option<String>> {
    let bytes = std::fs::read(path).with_context(|| format!("reading {path}"))?;
    let filename = file_name(path);
    let uid = new_uid();
    let ts = now();
    if ctx.dry_run {
        safety::note_dry_run(ctx, &format!("add file {path} ({} bytes)", bytes.len()));
        safety::audit("add", &uid, json!({"file":path,"bytes":bytes.len()}), true);
        return Ok(Some(uid));
    }
    let blob_key = new_uid();
    stage_blob(&blob_key, &bytes)?;
    let relic = Relic {
        uid: uid.clone(),
        created_at: ts,
        updated_at: ts,
        kind: "file".into(),
        source: "api".into(),
        promoted: args.vault,
        byte_size: bytes.len() as i64,
        device: None,
        mime: None,
        filename: filename.clone(),
        blob_key: Some(blob_key),
        have_blob: true,
        tags: vec![],
        user_tags: dedup(args.tag.clone()),
        title: args.title.clone(),
        note: args.note.clone(),
        content: None,
        preview: filename.or_else(|| Some("file".into())),
        attachments: vec![],
    };
    db.upsert(&relic, true, true)?;
    safety::audit("add", &uid, json!({"kind":"file","file":path,"bytes":bytes.len()}), false);
    Ok(Some(uid))
}

fn add_bundle(db: &AppDb, args: &AddArgs, ctx: &Ctx) -> Result<Option<String>> {
    let uid = new_uid();
    let ts = now();
    let mut parts: Vec<Vec<u8>> = Vec::new();
    let mut manifest: Vec<Attachment> = Vec::new();
    for path in &args.file {
        let bytes = std::fs::read(path).with_context(|| format!("reading {path}"))?;
        manifest.push(Attachment {
            id: new_uid(),
            name: file_name(path).unwrap_or_else(|| "file".into()),
            mime: None,
            size: bytes.len() as u64,
        });
        parts.push(bytes);
    }
    let bundle = crate::bundle::pack(&parts);
    let total = bundle.len() as i64;
    if ctx.dry_run {
        safety::note_dry_run(ctx, &format!("add a bundle of {} files ({total} bytes)", manifest.len()));
        safety::audit("add", &uid, json!({"attachments":manifest.len(),"bytes":total}), true);
        return Ok(Some(uid));
    }
    let blob_key = new_uid();
    stage_blob(&blob_key, &bundle)?;
    let relic = Relic {
        uid: uid.clone(),
        created_at: ts,
        updated_at: ts,
        kind: "file".into(),
        source: "api".into(),
        promoted: args.vault,
        byte_size: total,
        device: None,
        mime: None,
        filename: None,
        blob_key: Some(blob_key),
        have_blob: true,
        tags: vec![],
        user_tags: dedup(args.tag.clone()),
        title: args.title.clone(),
        note: args.note.clone(),
        content: None,
        preview: Some(format!("{} files", manifest.len())),
        attachments: manifest.clone(),
    };
    db.upsert(&relic, true, true)?;
    safety::audit("add", &uid, json!({"attachments":manifest.len(),"bytes":total}), false);
    Ok(Some(uid))
}

#[derive(Args)]
pub struct TagArgs {
    /// Relic uid (full, or a unique prefix).
    uid: String,
    /// Tag changes: `+tag` to add, `-tag` to remove (bare = add).
    specs: Vec<String>,
}

pub fn tag(args: TagArgs, ctx: &Ctx) -> Result<()> {
    let db = AppDb::open()?;
    let uid = resolve_uid(&db, &args.uid)?;
    let mut relic = db.get_by_uid(&uid)?.ok_or_else(|| ExitError::not_found(&uid))?;
    let (mut adds, mut removes) = (Vec::new(), Vec::new());
    for spec in &args.specs {
        if let Some(t) = spec.strip_prefix('-') {
            removes.push(t.trim_start_matches('#').to_string());
        } else {
            let t = spec.trim_start_matches('+').trim_start_matches('#').to_string();
            if !t.is_empty() {
                adds.push(t);
            }
        }
    }
    let mut tags = relic.user_tags.clone();
    tags.retain(|t| !removes.contains(t));
    tags.extend(adds);
    relic.user_tags = dedup(tags);
    relic.updated_at = now();
    commit_edit(&db, ctx, &relic, "tag", json!({ "tags": relic.user_tags }))
}

#[derive(Args)]
pub struct EditArgs {
    /// Relic uid (full, or a unique prefix).
    uid: String,
    /// New title.
    #[arg(long)]
    title: Option<String>,
    /// New note.
    #[arg(long)]
    note: Option<String>,
    /// Replace user tags with this comma-separated list.
    #[arg(long)]
    set_tags: Option<String>,
}

pub fn edit(args: EditArgs, ctx: &Ctx) -> Result<()> {
    let db = AppDb::open()?;
    let uid = resolve_uid(&db, &args.uid)?;
    let mut relic = db.get_by_uid(&uid)?.ok_or_else(|| ExitError::not_found(&uid))?;
    if let Some(t) = args.title {
        relic.title = Some(t);
    }
    if let Some(n) = args.note {
        relic.note = Some(n);
    }
    if let Some(tags) = args.set_tags {
        relic.user_tags = dedup(tags.split(',').map(|s| s.trim().to_string()).collect());
    }
    relic.updated_at = now();
    commit_edit(&db, ctx, &relic, "edit", json!({}))
}

pub fn promote(args: UidArg, ctx: &Ctx, promoted: bool) -> Result<()> {
    let db = AppDb::open()?;
    let uid = resolve_uid(&db, &args.uid)?;
    let mut relic = db.get_by_uid(&uid)?.ok_or_else(|| ExitError::not_found(&uid))?;
    relic.promoted = promoted;
    relic.updated_at = now();
    let op = if promoted { "promote" } else { "unpromote" };
    commit_edit(&db, ctx, &relic, op, json!({ "promoted": promoted }))
}

pub fn copy(args: UidArg, ctx: &Ctx) -> Result<()> {
    let db = AppDb::open()?;
    let uid = resolve_uid(&db, &args.uid)?;
    let relic = db.get_by_uid(&uid)?.ok_or_else(|| ExitError::not_found(&uid))?;
    let text = relic
        .content
        .clone()
        .or_else(|| relic.filename.clone())
        .ok_or_else(|| ExitError::new(1, "nothing copyable on this relic (no text)"))?;
    crate::clipboard::set_text(&text)?;
    if !ctx.out.is_machine() {
        println!("copied {} to the clipboard", short_uid(&uid));
    }
    Ok(())
}

#[derive(Args)]
pub struct ImportArgs {
    /// NDJSON file (or - for stdin). Each line: {content, title?, note?, tags?, vault?}.
    file: String,
}

pub fn import(args: ImportArgs, ctx: &Ctx) -> Result<()> {
    let db = AppDb::open()?;
    let raw = if args.file == "-" {
        read_stdin()?
    } else {
        std::fs::read_to_string(&args.file).with_context(|| format!("reading {}", args.file))?
    };
    let mut uids = Vec::new();
    for (i, line) in raw.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let v: serde_json::Value =
            serde_json::from_str(line).with_context(|| format!("line {}: invalid JSON", i + 1))?;
        let content = v.get("content").and_then(|c| c.as_str()).unwrap_or("");
        if content.trim().is_empty() {
            continue;
        }
        let ts = now();
        let tags = v
            .get("tags")
            .and_then(|t| t.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .unwrap_or_default();
        let relic = Relic {
            uid: new_uid(),
            created_at: ts,
            updated_at: ts,
            kind: "string".into(),
            source: "api".into(),
            promoted: v.get("vault").and_then(|b| b.as_bool()).unwrap_or(false),
            byte_size: content.len() as i64,
            device: None,
            mime: None,
            filename: None,
            blob_key: None,
            have_blob: false,
            tags: vec![],
            user_tags: dedup(tags),
            title: v.get("title").and_then(|c| c.as_str()).map(String::from),
            note: v.get("note").and_then(|c| c.as_str()).map(String::from),
            content: Some(content.to_string()),
            preview: Some(preview_of(content)),
            attachments: vec![],
        };
        if !ctx.dry_run {
            db.upsert(&relic, false, true)?;
            safety::audit("import", &relic.uid, json!({ "bytes": content.len() }), false);
        }
        uids.push(relic.uid);
    }
    if ctx.out.is_machine() {
        print_json(&json!({ "added": uids.len(), "uids": uids }));
    } else {
        println!("imported {} relics", uids.len());
    }
    Ok(())
}

// --- helpers ---

/// Write a blob into the app's cache so its sync loop uploads it. The app names
/// blob files by their key and pushes them from `pending_ops`.
fn stage_blob(blob_key: &str, bytes: &[u8]) -> Result<()> {
    let dir = app_paths::blobs_dir()?;
    std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    let path = dir.join(blob_key);
    std::fs::write(&path, bytes).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

fn file_name(path: &str) -> Option<String> {
    std::path::Path::new(path).file_name().map(|s| s.to_string_lossy().into_owned())
}

/// First non-empty line, capped (matches the app's preview shape).
fn preview_of(text: &str) -> String {
    text.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("").chars().take(200).collect()
}

fn read_stdin() -> Result<String> {
    let mut buf = String::new();
    std::io::stdin().read_to_string(&mut buf).context("reading stdin")?;
    Ok(buf)
}

fn report_uids(ctx: &Ctx, uids: &[String]) {
    match ctx.out {
        OutputMode::Quiet => {
            for u in uids {
                println!("{u}");
            }
        }
        m if m.is_machine() => print_json(&json!({ "uids": uids })),
        _ => {
            for u in uids {
                println!("added {u}");
            }
        }
    }
}

fn commit_edit(db: &AppDb, ctx: &Ctx, relic: &Relic, op: &str, detail: serde_json::Value) -> Result<()> {
    if ctx.dry_run {
        safety::note_dry_run(ctx, &format!("{op} {}", short_uid(&relic.uid)));
    } else {
        db.upsert(relic, relic.have_blob, true)?;
    }
    safety::audit(op, &relic.uid, detail, ctx.dry_run);
    if ctx.out.is_machine() {
        print_json(&json!({ "ok": true, "uid": relic.uid, "op": op, "dry_run": ctx.dry_run }));
    } else if !ctx.dry_run {
        println!("{op}: {}", short_uid(&relic.uid));
    }
    Ok(())
}
