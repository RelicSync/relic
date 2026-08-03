//! Output rendering: human tables vs machine JSON/NDJSON. Schemas are stable so
//! agents can parse them.

use serde::Serialize;
use serde_json::{json, Value};

use crate::models::Relic;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputMode {
    Human,
    Json,
    Ndjson,
    /// Minimal: ids only, for shell pipelines.
    Quiet,
}

impl OutputMode {
    pub fn resolve(json: bool, ndjson: bool, quiet: bool) -> OutputMode {
        if quiet {
            OutputMode::Quiet
        } else if ndjson {
            OutputMode::Ndjson
        } else if json {
            OutputMode::Json
        } else {
            OutputMode::Human
        }
    }
    pub fn is_machine(self) -> bool {
        matches!(self, OutputMode::Json | OutputMode::Ndjson)
    }
}

pub fn relic_json(r: &Relic) -> Value {
    serde_json::to_value(r).unwrap_or(Value::Null)
}

pub fn relic_line(r: &Relic, now: i64) -> String {
    let uid = short_uid(&r.uid);
    let age = relative_age(r.created_at, now);
    let star = if r.promoted { "★" } else { " " };
    let title = r.display_title();
    let tags = r.display_tags();
    let tagstr = if tags.is_empty() { String::new() } else { format!("  #{}", tags.join(" #")) };
    format!("{star} {uid}  {age:>5}  {kind:<6}  {title}{tagstr}", kind = r.kind)
}

/// Render a result set per the mode.
pub fn render_relics(mode: OutputMode, items: &[Relic], now: i64) {
    match mode {
        OutputMode::Quiet => {
            for r in items {
                println!("{}", r.uid);
            }
        }
        OutputMode::Ndjson => {
            for r in items {
                println!("{}", relic_json(r));
            }
        }
        OutputMode::Json => {
            let v = json!({ "count": items.len(), "items": items.iter().map(relic_json).collect::<Vec<_>>() });
            println!("{}", serde_json::to_string_pretty(&v).unwrap_or_default());
        }
        OutputMode::Human => {
            if items.is_empty() {
                println!("(no matches)");
            }
            for r in items {
                println!("{}", relic_line(r, now));
            }
        }
    }
}

pub fn print_json<T: Serialize>(value: &T) {
    println!("{}", serde_json::to_string_pretty(value).unwrap_or_default());
}

pub fn short_uid(uid: &str) -> String {
    uid.chars().take(8).collect()
}

/// "now" / "14m" / "2h" / "3d" / "45d".
pub fn relative_age(created_at: i64, now: i64) -> String {
    let age = now - created_at;
    if age < 8 {
        "now".into()
    } else if age < 60 {
        format!("{age}s")
    } else if age < 3600 {
        format!("{}m", age / 60)
    } else if age < 86400 {
        format!("{}h", age / 3600)
    } else {
        format!("{}d", age / 86400)
    }
}
