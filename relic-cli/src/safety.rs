//! Guardrails for mutating + destructive operations.
//!
//! Deletion is structurally locked off: destructive commands refuse unless a
//! capability is granted via config, env, or an explicit flag (the flag also
//! demands confirmation). Every mutation is recorded in an append-only audit
//! log so an agent's actions are reviewable and reversible.

use std::fs::OpenOptions;
use std::io::{IsTerminal, Write};

use anyhow::Result;
use serde_json::json;

use crate::config::{audit_path, ensure_state_dir, Config};
use crate::error::ExitError;
use crate::Ctx;

#[derive(Clone, Copy)]
pub enum Capability {
    /// Soft delete (`rm`) and tag removal (`tag-rm`).
    Delete,
    /// Hard purge (`purge --hard`).
    Purge,
}

impl Capability {
    fn label(self) -> &'static str {
        match self {
            Capability::Delete => "delete",
            Capability::Purge => "purge",
        }
    }
    fn env_var(self) -> &'static str {
        match self {
            Capability::Delete => "RELIC_ALLOW_DELETE",
            Capability::Purge => "RELIC_ALLOW_PURGE",
        }
    }
    fn config_grant(self, cfg: &Config) -> bool {
        match self {
            Capability::Delete => cfg.capabilities.allow_delete,
            Capability::Purge => cfg.capabilities.allow_purge,
        }
    }
}

fn env_truthy(name: &str) -> bool {
    matches!(
        std::env::var(name).ok().map(|v| v.to_ascii_lowercase()).as_deref(),
        Some("1") | Some("true") | Some("yes") | Some("on")
    )
}

/// Enforce a capability before a destructive op. `flag_grant` is the command's
/// own `--allow-delete`/`--hard`-style opt-in. Policy grants (config/env) are
/// pre-authorized by the human and need no prompt; a bare flag grant requires
/// interactive confirmation unless `--yes`.
pub fn require_capability(
    cap: Capability,
    cfg: &Config,
    flag_grant: bool,
    ctx: &Ctx,
) -> Result<()> {
    let by_policy = cap.config_grant(cfg) || env_truthy(cap.env_var());
    if !by_policy && !flag_grant {
        return Err(ExitError::policy(format!(
            "{} is not permitted. Grant it with `{}=1`, `capabilities.allow_{}` in config, \
             or pass the explicit flag.",
            cap.label(),
            cap.env_var(),
            cap.label(),
        ))
        .into());
    }
    if !by_policy && flag_grant && !ctx.yes {
        confirm(&format!("Really {} (this is destructive)?", cap.label()))?;
    }
    Ok(())
}

/// Block on a yes/no prompt. Non-interactive sessions without `--yes` abort.
pub fn confirm(prompt: &str) -> Result<()> {
    if !std::io::stdin().is_terminal() {
        return Err(ExitError::policy(format!(
            "{prompt} (refusing in a non-interactive session without --yes)"
        ))
        .into());
    }
    print!("{prompt} type 'yes' to continue: ");
    std::io::stdout().flush().ok();
    let mut line = String::new();
    std::io::stdin().read_line(&mut line)?;
    if line.trim().eq_ignore_ascii_case("yes") {
        Ok(())
    } else {
        Err(ExitError::policy("aborted").into())
    }
}

/// Append one JSONL record to the audit log. Best effort; never blocks the op.
pub fn audit(op: &str, uid: &str, detail: serde_json::Value, dry_run: bool) {
    if ensure_state_dir().is_err() {
        return;
    }
    let Ok(path) = audit_path() else { return };
    let record = json!({
        "ts": chrono::Utc::now().to_rfc3339(),
        "op": op,
        "uid": uid,
        "dry_run": dry_run,
        "detail": detail,
    });
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{record}");
    }
}

/// Emit a dry-run notice (human mode) and signal the caller to stop.
pub fn note_dry_run(ctx: &Ctx, what: &str) {
    if !ctx.out.is_machine() {
        eprintln!("[dry-run] would {what}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Capabilities;
    use crate::error::{code_of, codes};
    use crate::output::OutputMode;

    fn cfg(allow_delete: bool, allow_purge: bool) -> Config {
        Config { capabilities: Capabilities { allow_delete, allow_purge } }
    }

    fn ctx(yes: bool) -> Ctx {
        Ctx { out: OutputMode::Json, dry_run: false, yes, verbose: 0 }
    }

    #[test]
    fn delete_denied_by_default() {
        let err = require_capability(Capability::Delete, &cfg(false, false), false, &ctx(true))
            .unwrap_err();
        assert_eq!(code_of(&err), codes::POLICY);
    }

    #[test]
    fn delete_allowed_by_config() {
        assert!(require_capability(Capability::Delete, &cfg(true, false), false, &ctx(false)).is_ok());
    }

    #[test]
    fn flag_grant_with_yes_skips_prompt() {
        assert!(require_capability(Capability::Delete, &cfg(false, false), true, &ctx(true)).is_ok());
    }

    #[test]
    fn flag_grant_without_yes_blocks_noninteractive() {
        // tests run with a non-terminal stdin → confirm refuses.
        let err = require_capability(Capability::Delete, &cfg(false, false), true, &ctx(false))
            .unwrap_err();
        assert_eq!(code_of(&err), codes::POLICY);
    }

    #[test]
    fn purge_needs_its_own_capability() {
        // delete grant does not imply purge.
        let err = require_capability(Capability::Purge, &cfg(true, false), false, &ctx(true))
            .unwrap_err();
        assert_eq!(code_of(&err), codes::POLICY);
        assert!(require_capability(Capability::Purge, &cfg(true, true), false, &ctx(true)).is_ok());
    }
}
