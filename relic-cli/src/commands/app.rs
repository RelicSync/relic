//! Install detection, status, and the self-vending agent skill.

use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Args;
use serde_json::json;

use crate::app_db::AppDb;
use crate::app_paths;
use crate::output::print_json;
use crate::Ctx;

/// The agent skill, compiled into the binary so `relic skill [--install]` works
/// with no network or repo checkout.
const SKILL_MD: &str = include_str!("../../skill/SKILL.md");

pub fn status(ctx: &Ctx) -> Result<()> {
    if !app_paths::is_installed() {
        if ctx.out.is_machine() {
            print_json(&json!({ "installed": false }));
        } else {
            println!("Relic app: not installed (no local vault found).");
            println!("Data dir checked: {}", app_paths::app_data_dir()?.display());
        }
        return Ok(());
    }
    let db = AppDb::open()?;
    let count = db.count()?;
    let (bytes, vault) = db.local_aggregate()?;
    let pending = db.pending_count()?;
    if ctx.out.is_machine() {
        print_json(&json!({
            "installed": true,
            "relics": count,
            "vault": vault,
            "bytes": bytes,
            "pending_sync": pending,
        }));
    } else {
        println!("Relic app: installed");
        println!("Local:     {count} relics ({vault} in Vault, {bytes} bytes)");
        if pending > 0 {
            println!("Sync:      {pending} change(s) queued (the app pushes these)");
        }
    }
    Ok(())
}

pub fn where_cmd(ctx: &Ctx) -> Result<()> {
    if ctx.out.is_machine() {
        print_json(&json!({
            "installed": app_paths::is_installed(),
            "app_data_dir": app_paths::app_data_dir()?.display().to_string(),
            "db": app_paths::db_path()?.display().to_string(),
            "blobs": app_paths::blobs_dir()?.display().to_string(),
            "cli_state_dir": app_paths::cli_state_dir()?.display().to_string(),
        }));
    } else {
        println!("app data:  {}", app_paths::app_data_dir()?.display());
        println!("database:  {}", app_paths::db_path()?.display());
        println!("blobs:     {}", app_paths::blobs_dir()?.display());
        println!("cli state: {}", app_paths::cli_state_dir()?.display());
        println!("installed: {}", if app_paths::is_installed() { "yes" } else { "no" });
    }
    Ok(())
}

#[derive(Args)]
pub struct SkillArgs {
    /// Install the skill into an agent's skills dir instead of printing it.
    #[arg(long)]
    install: bool,
    /// Target directory for --install (default: ~/.claude/skills/relic).
    #[arg(long)]
    dir: Option<String>,
}

pub fn skill(args: SkillArgs, ctx: &Ctx) -> Result<()> {
    if !args.install {
        // Print the skill so an agent can read it straight from the CLI.
        print!("{SKILL_MD}");
        return Ok(());
    }
    let dir = match args.dir {
        Some(d) => PathBuf::from(d),
        None => default_skill_dir()?,
    };
    std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    let path = dir.join("SKILL.md");
    std::fs::write(&path, SKILL_MD).with_context(|| format!("writing {}", path.display()))?;
    if ctx.out.is_machine() {
        print_json(&json!({ "installed": true, "path": path.display().to_string() }));
    } else {
        println!("Installed the relic skill to {}", path.display());
        println!("Start a new agent session to pick it up.");
    }
    Ok(())
}

fn default_skill_dir() -> Result<PathBuf> {
    let home = dirs::home_dir().context("could not resolve your home directory")?;
    Ok(home.join(".claude").join("skills").join("relic"))
}
