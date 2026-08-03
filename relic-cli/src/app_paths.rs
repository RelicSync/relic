//! Locating the desktop app's on-device data. The CLI is a shim over these; it
//! never creates or migrates them (that is the app's job).

use std::path::PathBuf;

use anyhow::{Context, Result};

/// `%APPDATA%\relic` on Windows (`dirs::config_dir()` = Roaming), the app's data
/// dir on other platforms. `RELIC_APP_DIR` overrides it (used for tests against
/// a DB copy, and for non-standard installs).
pub fn app_data_dir() -> Result<PathBuf> {
    if let Ok(dir) = std::env::var("RELIC_APP_DIR") {
        if !dir.is_empty() {
            return Ok(PathBuf::from(dir));
        }
    }
    let base = dirs::config_dir().context("could not resolve the app data directory")?;
    Ok(base.join("relic"))
}

pub fn db_path() -> Result<PathBuf> {
    Ok(app_data_dir()?.join("relics.db"))
}

pub fn blobs_dir() -> Result<PathBuf> {
    Ok(app_data_dir()?.join("blobs"))
}

/// One cached, decrypted blob file (named by its `blob_key`).
pub fn blob_file(blob_key: &str) -> Result<PathBuf> {
    Ok(blobs_dir()?.join(blob_key))
}

/// The CLI's own small state dir (trash backups, audit log) — kept separate
/// from the app's data so we never pollute it.
pub fn cli_state_dir() -> Result<PathBuf> {
    let base = dirs::config_dir().context("could not resolve a config directory")?;
    Ok(base.join("relic-cli"))
}

/// Whether the desktop app appears installed + set up on this machine (its
/// local vault database exists).
pub fn is_installed() -> bool {
    db_path().map(|p| p.exists()).unwrap_or(false)
}
