//! Read commands: search, get, list, export, tags. Always permitted, read-only.

use std::io::Write;

use anyhow::{Context, Result};
use clap::{Args, ValueEnum};

use crate::app_db::{AppDb, Order};
use crate::app_paths;
use crate::error::ExitError;
use crate::models::{now, Relic};
use crate::output::{print_json, render_relics};
use crate::Ctx;
use serde_json::json;

#[derive(Copy, Clone, ValueEnum)]
pub enum Sort {
    Relevance,
    Newest,
    Oldest,
}

impl Sort {
    fn to_order(self) -> Order {
        match self {
            Sort::Relevance => Order::Relevance,
            Sort::Newest => Order::Newest,
            Sort::Oldest => Order::Oldest,
        }
    }
}

#[derive(Args)]
pub struct SearchArgs {
    /// Free-text query. `tag:x` filters by tag; punctuation is handled safely.
    query: Option<String>,
    /// Filter to relics carrying this tag (machine or user). Repeatable.
    #[arg(long)]
    tag: Vec<String>,
    /// Only Vault (promoted) relics.
    #[arg(long)]
    vault: bool,
    /// Created on/after this date (YYYY-MM-DD or epoch seconds).
    #[arg(long)]
    after: Option<String>,
    /// Created on/before this date (YYYY-MM-DD or epoch seconds).
    #[arg(long)]
    before: Option<String>,
    /// Max results.
    #[arg(long, default_value_t = 50)]
    limit: usize,
    /// Skip this many results (pagination).
    #[arg(long, default_value_t = 0)]
    offset: usize,
    /// Result ordering.
    #[arg(long, value_enum, default_value_t = Sort::Relevance)]
    sort: Sort,
}

pub fn search(args: SearchArgs, ctx: &Ctx) -> Result<()> {
    let db = AppDb::open()?;
    let mut search = args.query.unwrap_or_default();
    for t in &args.tag {
        search.push_str(&format!(" tag:{}", t.trim_start_matches('#')));
    }
    let hits = db.query(
        search.trim(),
        args.vault,
        args.limit.max(1),
        args.offset,
        args.sort.to_order(),
        parse_date(args.after.as_deref())?,
        parse_date(args.before.as_deref())?,
    )?;
    render_relics(ctx.out, &hits, now());
    Ok(())
}

#[derive(Args)]
pub struct GetArgs {
    /// Relic uid (full, or a unique prefix).
    uid: String,
    /// Print only the content body (pipeable).
    #[arg(long)]
    raw: bool,
}

pub fn get(args: GetArgs, ctx: &Ctx) -> Result<()> {
    let db = AppDb::open()?;
    let uid = resolve_uid(&db, &args.uid)?;
    let relic = db.get_by_uid(&uid)?.ok_or_else(|| ExitError::not_found(format!("no relic {uid}")))?;
    if args.raw {
        std::io::stdout().write_all(relic.content.clone().unwrap_or_default().as_bytes())?;
        return Ok(());
    }
    if ctx.out.is_machine() {
        print_json(&relic);
    } else {
        print_human_relic(&relic);
    }
    Ok(())
}

#[derive(Args)]
pub struct ListArgs {
    /// Only Vault (promoted) relics.
    #[arg(long)]
    vault: bool,
    /// Max results.
    #[arg(long, default_value_t = 50)]
    limit: usize,
    /// Skip this many results (pagination).
    #[arg(long, default_value_t = 0)]
    offset: usize,
}

pub fn list(args: ListArgs, ctx: &Ctx) -> Result<()> {
    let db = AppDb::open()?;
    let hits = db.query("", args.vault, args.limit.max(1), args.offset, Order::Newest, None, None)?;
    render_relics(ctx.out, &hits, now());
    Ok(())
}

#[derive(Args)]
pub struct ExportArgs {
    /// Relic uid (full, or a unique prefix).
    uid: String,
    /// Output path, or - for stdout. With --all, this is a directory.
    out: String,
    /// For a bundle relic: which attachment to extract (its id or name).
    #[arg(long)]
    attachment: Option<String>,
    /// Extract every attachment of a bundle into the output directory.
    #[arg(long)]
    all: bool,
}

pub fn export(args: ExportArgs, ctx: &Ctx) -> Result<()> {
    let db = AppDb::open()?;
    let uid = resolve_uid(&db, &args.uid)?;
    let relic = db.get_by_uid(&uid)?.ok_or_else(|| ExitError::not_found(format!("no relic {uid}")))?;
    let blob_key = relic
        .blob_key
        .as_deref()
        .ok_or_else(|| ExitError::new(1, "this relic has no blob to export"))?;

    // Blobs are cached decrypted in the app's blobs/ dir. If not present, the
    // app hasn't downloaded it yet.
    let path = app_paths::blob_file(blob_key)?;
    if !path.exists() {
        return Err(ExitError::new(
            1,
            "blob is not cached locally yet — open the relic in the app to download it",
        )
        .into());
    }
    let bytes = std::fs::read(&path).with_context(|| format!("reading {}", path.display()))?;

    if !relic.attachments.is_empty() {
        return export_bundle(&args, ctx, &relic, &bytes);
    }
    write_bytes(&args.out, &bytes, ctx)
}

fn export_bundle(args: &ExportArgs, ctx: &Ctx, relic: &Relic, bundle: &[u8]) -> Result<()> {
    if args.all {
        let dir = std::path::Path::new(&args.out);
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        for a in &relic.attachments {
            let bytes = crate::bundle::slice(bundle, &relic.attachments, &a.id)
                .ok_or_else(|| ExitError::new(1, "bundle manifest does not match blob"))?;
            let p = dir.join(&a.name);
            std::fs::write(&p, bytes).with_context(|| format!("writing {}", p.display()))?;
        }
        if !ctx.out.is_machine() {
            println!("wrote {} attachment(s) to {}", relic.attachments.len(), dir.display());
        }
        return Ok(());
    }
    let att = match &args.attachment {
        Some(sel) => relic
            .attachments
            .iter()
            .find(|a| a.id == *sel || a.name == *sel)
            .ok_or_else(|| ExitError::not_found(format!("no attachment '{sel}' on this relic")))?,
        None if relic.attachments.len() == 1 => &relic.attachments[0],
        None => {
            return Err(ExitError::new(
                2,
                format!(
                    "relic is a bundle of {} files; pass --attachment <name|id> or --all <dir>",
                    relic.attachments.len()
                ),
            )
            .into())
        }
    };
    let bytes = crate::bundle::slice(bundle, &relic.attachments, &att.id)
        .ok_or_else(|| ExitError::new(1, "bundle manifest does not match blob"))?;
    write_bytes(&args.out, bytes, ctx)
}

fn write_bytes(out: &str, bytes: &[u8], ctx: &Ctx) -> Result<()> {
    if out == "-" {
        std::io::stdout().write_all(bytes)?;
    } else {
        std::fs::write(out, bytes).with_context(|| format!("writing {out}"))?;
        if !ctx.out.is_machine() {
            println!("wrote {} bytes to {out}", bytes.len());
        }
    }
    Ok(())
}

pub fn tags(ctx: &Ctx) -> Result<()> {
    let db = AppDb::open()?;
    let (user, machine) = db.tag_frequencies()?;
    if ctx.out.is_machine() {
        print_json(&json!({ "user": user, "machine": machine }));
    } else {
        println!("Your tags:");
        for (t, n) in &user {
            println!("  #{t}  ({n})");
        }
        println!("\nAuto tags:");
        for (t, n) in &machine {
            println!("  {t}  ({n})");
        }
    }
    Ok(())
}

// --- helpers ---

/// Resolve a full uid or a unique prefix to a full uid.
pub fn resolve_uid(db: &AppDb, needle: &str) -> Result<String> {
    if db.get_by_uid(needle)?.is_some() {
        return Ok(needle.to_string());
    }
    let matches = db.find_uids_by_prefix(needle, 50)?;
    match matches.as_slice() {
        [] => Err(ExitError::not_found(format!("no relic matching '{needle}'")).into()),
        [one] => Ok(one.clone()),
        many => {
            Err(ExitError::new(2, format!("'{needle}' matches {} relics; use a longer id", many.len()))
                .into())
        }
    }
}

/// Accept epoch seconds or a YYYY-MM-DD date (UTC midnight).
fn parse_date(s: Option<&str>) -> Result<Option<i64>> {
    let Some(s) = s.map(str::trim).filter(|s| !s.is_empty()) else { return Ok(None) };
    if let Ok(epoch) = s.parse::<i64>() {
        return Ok(Some(epoch));
    }
    let date = chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .map_err(|_| ExitError::new(2, format!("invalid date '{s}' (use YYYY-MM-DD or epoch)")))?;
    Ok(Some(date.and_hms_opt(0, 0, 0).unwrap().and_utc().timestamp()))
}

fn print_human_relic(r: &Relic) {
    println!("uid:      {}", r.uid);
    println!("kind:     {}", r.kind);
    println!("created:  {}", r.created_at);
    println!("updated:  {}", r.updated_at);
    println!("vault:    {}", r.promoted);
    if let Some(t) = &r.title {
        println!("title:    {t}");
    }
    if let Some(f) = &r.filename {
        println!("filename: {f}");
    }
    if !r.user_tags.is_empty() {
        println!("tags:     {}", r.user_tags.join(", "));
    }
    if !r.tags.is_empty() {
        println!("auto:     {}", r.tags.join(", "));
    }
    if let Some(n) = &r.note {
        println!("note:     {n}");
    }
    if !r.attachments.is_empty() {
        println!("attachments:");
        for a in &r.attachments {
            println!("  {}  ({} bytes)  [{}]", a.name, a.size, a.id);
        }
    }
    if let Some(c) = &r.content {
        println!("\n{c}");
    }
}
