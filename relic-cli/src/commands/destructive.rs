//! Destructive commands: rm, tag-rm, purge. Default-deny: they refuse with exit
//! code 6 unless a capability is granted (config / env / explicit flag).

use anyhow::Result;
use clap::Args;
use serde_json::json;

use crate::app_db::{AppDb, Order};
use crate::commands::read::resolve_uid;
use crate::config::{trash_dir, write_private, Config};
use crate::error::ExitError;
use crate::models::{now, Relic};
use crate::output::print_json;
use crate::safety::{self, Capability};
use crate::Ctx;

#[derive(Args)]
pub struct RmArgs {
    /// Relic uid(s) (full or unique prefix).
    uids: Vec<String>,
    /// Explicit per-invocation grant (prompts unless --yes).
    #[arg(long)]
    allow_delete: bool,
}

pub fn rm(args: RmArgs, ctx: &Ctx) -> Result<()> {
    if args.uids.is_empty() {
        return Err(ExitError::new(2, "no uids given").into());
    }
    let cfg = Config::load();
    safety::require_capability(Capability::Delete, &cfg, args.allow_delete, ctx)?;
    let db = AppDb::open()?;

    let mut removed = Vec::new();
    for needle in &args.uids {
        let uid = resolve_uid(&db, needle)?;
        let relic = db.get_by_uid(&uid)?.ok_or_else(|| ExitError::not_found(&uid))?;
        if ctx.dry_run {
            safety::note_dry_run(ctx, &format!("delete {uid} (with local trash backup)"));
            safety::audit("rm", &uid, json!({}), true);
            removed.push(uid);
            continue;
        }
        backup_to_trash(&relic)?;
        db.delete_and_queue(&uid, now(), true)?;
        safety::audit("rm", &uid, json!({ "trash": true }), false);
        removed.push(uid);
    }

    if ctx.out.is_machine() {
        print_json(&json!({ "removed": removed, "trash_dir": trash_dir()?.display().to_string() }));
    } else {
        println!("deleted {} relic(s); backups in {}", removed.len(), trash_dir()?.display());
    }
    Ok(())
}

#[derive(Args)]
pub struct TagRmArgs {
    /// The tag to remove from every relic that carries it.
    tag: String,
    /// Explicit per-invocation grant (prompts unless --yes).
    #[arg(long)]
    allow_delete: bool,
}

pub fn tag_rm(args: TagRmArgs, ctx: &Ctx) -> Result<()> {
    let cfg = Config::load();
    safety::require_capability(Capability::Delete, &cfg, args.allow_delete, ctx)?;
    let db = AppDb::open()?;
    let target = args.tag.trim_start_matches('#').to_string();

    // Candidate set via the tag filter, then exact-match in Rust.
    let candidates =
        db.query(&format!("tag:{target}"), false, 1_000_000, 0, Order::Newest, None, None)?;
    let mut changed = 0;
    for mut relic in candidates {
        if !relic.tags.contains(&target) && !relic.user_tags.contains(&target) {
            continue;
        }
        relic.tags.retain(|t| t != &target);
        relic.user_tags.retain(|t| t != &target);
        relic.updated_at = now();
        if !ctx.dry_run {
            db.upsert(&relic, relic.have_blob, true)?;
        }
        changed += 1;
    }
    safety::audit("tag-rm", &target, json!({ "changed": changed }), ctx.dry_run);
    if ctx.out.is_machine() {
        print_json(&json!({ "tag": target, "changed": changed, "dry_run": ctx.dry_run }));
    } else {
        println!("removed #{target} from {changed} relic(s)");
    }
    Ok(())
}

#[derive(Args)]
pub struct PurgeArgs {
    /// Relic uid (full or unique prefix).
    uid: String,
    /// Required acknowledgement that this is permanent and not backed up.
    #[arg(long)]
    hard: bool,
}

pub fn purge(args: PurgeArgs, ctx: &Ctx) -> Result<()> {
    let cfg = Config::load();
    safety::require_capability(Capability::Purge, &cfg, args.hard, ctx)?;
    if !args.hard {
        return Err(ExitError::policy("purge requires --hard (permanent, no trash backup)").into());
    }
    let db = AppDb::open()?;
    let uid = resolve_uid(&db, &args.uid)?;
    if ctx.dry_run {
        safety::note_dry_run(ctx, &format!("PERMANENTLY purge {uid} (no backup)"));
        safety::audit("purge", &uid, json!({}), true);
        return Ok(());
    }
    db.delete_and_queue(&uid, now(), true)?;
    safety::audit("purge", &uid, json!({ "trash": false }), false);
    if ctx.out.is_machine() {
        print_json(&json!({ "purged": uid }));
    } else {
        println!("purged {uid} (permanent)");
    }
    Ok(())
}

fn backup_to_trash(relic: &Relic) -> Result<()> {
    let dir = trash_dir()?;
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{}.json", relic.uid));
    write_private(&path, &serde_json::to_vec_pretty(relic)?)?;
    Ok(())
}
