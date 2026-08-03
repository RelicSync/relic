//! The CLI's own small state: capability grants for destructive ops, the audit
//! log, and trash backups. Lives under `relic-cli/` (never in the app's data).

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::app_paths::cli_state_dir;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Capabilities {
    #[serde(default)]
    pub allow_delete: bool,
    #[serde(default)]
    pub allow_purge: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub capabilities: Capabilities,
}

impl Config {
    /// Load the CLI config, or defaults (all capabilities denied) if absent.
    pub fn load() -> Config {
        let Ok(path) = config_path() else { return Config::default() };
        match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
            Err(_) => Config::default(),
        }
    }
}

pub fn config_path() -> Result<PathBuf> {
    Ok(cli_state_dir()?.join("config.json"))
}

pub fn audit_path() -> Result<PathBuf> {
    Ok(cli_state_dir()?.join("audit.log"))
}

pub fn trash_dir() -> Result<PathBuf> {
    Ok(cli_state_dir()?.join("trash"))
}

pub fn ensure_state_dir() -> Result<PathBuf> {
    let dir = cli_state_dir()?;
    fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    Ok(dir)
}

/// Write a file with best-effort owner-only permissions.
pub fn write_private(path: &Path, bytes: &[u8]) -> Result<()> {
    fs::write(path, bytes).with_context(|| format!("writing {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    Ok(())
}
