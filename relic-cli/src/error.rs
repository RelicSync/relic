//! Exit-code mapping. Commands return `anyhow::Result<()>`; when they want a
//! specific process exit code they return an [`ExitError`] (wrapped in the
//! anyhow chain). `main` downcasts to recover the code.

use std::fmt;

/// Stable process exit codes (documented in the CLI help / for agents).
#[allow(dead_code)] // full set kept as the documented contract
pub mod codes {
    pub const OK: i32 = 0;
    pub const GENERIC: i32 = 1;
    // 2 is reserved: clap uses it for usage errors.
    pub const AUTH: i32 = 3;
    pub const NOT_FOUND: i32 = 4;
    pub const REJECTED: i32 = 5;
    pub const POLICY: i32 = 6;
}

#[derive(Debug)]
pub struct ExitError {
    pub code: i32,
    pub message: String,
}

impl ExitError {
    pub fn new(code: i32, message: impl Into<String>) -> Self {
        ExitError { code, message: message.into() }
    }
    pub fn auth(m: impl Into<String>) -> Self {
        Self::new(codes::AUTH, m)
    }
    pub fn not_found(m: impl Into<String>) -> Self {
        Self::new(codes::NOT_FOUND, m)
    }
    #[allow(dead_code)] // part of the helper set; used as the surface grows
    pub fn rejected(m: impl Into<String>) -> Self {
        Self::new(codes::REJECTED, m)
    }
    pub fn policy(m: impl Into<String>) -> Self {
        Self::new(codes::POLICY, m)
    }
}

impl fmt::Display for ExitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for ExitError {}

/// Recover an exit code from an error chain (defaults to GENERIC).
pub fn code_of(err: &anyhow::Error) -> i32 {
    err.downcast_ref::<ExitError>().map(|e| e.code).unwrap_or(codes::GENERIC)
}
