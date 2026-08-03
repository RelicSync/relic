//! relic — a thin, agent-facing shim over the Relic desktop app's on-device
//! vault. Reads and writes the app's local plaintext SQLite + blob cache
//! directly (no crypto/keys/network); the app handles sync and ML enrichment.

mod app_db;
mod app_paths;
mod bundle;
mod clipboard;
mod commands;
mod config;
mod error;
mod models;
mod output;
mod safety;

use clap::{Args, Parser, Subcommand};
use clap_complete::Shell;

use error::code_of;
use output::OutputMode;

#[derive(Parser)]
#[command(
    name = "relic",
    version,
    about = "Agent-facing shim over the local Relic vault",
    long_about = "Search, add, tag, promote, export and copy Relic vault content from the \
                  terminal. Requires the Relic desktop app installed. Deletion is locked \
                  off unless explicitly granted."
)]
struct Cli {
    #[command(flatten)]
    global: GlobalArgs,
    #[command(subcommand)]
    command: Commands,
}

#[derive(Args, Clone)]
struct GlobalArgs {
    /// Machine-readable JSON output.
    #[arg(long, global = true)]
    json: bool,
    /// Newline-delimited JSON (one object per line) for streaming.
    #[arg(long, global = true)]
    ndjson: bool,
    /// Minimal output (ids only) for shell pipelines.
    #[arg(short, long, global = true)]
    quiet: bool,
    /// Increase logging detail.
    #[arg(short, long, global = true, action = clap::ArgAction::Count)]
    verbose: u8,
    /// Print what a mutating command would do, without writing.
    #[arg(long, global = true)]
    dry_run: bool,
    /// Skip interactive confirmation prompts.
    #[arg(short = 'y', long, global = true)]
    yes: bool,
}

pub struct Ctx {
    pub out: OutputMode,
    pub dry_run: bool,
    pub yes: bool,
    pub verbose: u8,
}

impl GlobalArgs {
    fn ctx(&self) -> Ctx {
        Ctx {
            out: OutputMode::resolve(self.json, self.ndjson, self.quiet),
            dry_run: self.dry_run,
            yes: self.yes,
            verbose: self.verbose,
        }
    }
}

#[derive(Subcommand)]
enum Commands {
    /// Show whether the app is installed + local vault stats.
    Status,
    /// Print the app data dir and database path.
    Where,
    /// Print or install the agent skill for this CLI.
    Skill(commands::app::SkillArgs),

    /// Search the vault (FTS5 + bm25). Supports tag:/kind/date/vault filters.
    Search(commands::read::SearchArgs),
    /// Print one relic's content and metadata.
    Get(commands::read::GetArgs),
    /// List recent relics (stream or vault).
    List(commands::read::ListArgs),
    /// Write a relic's blob/attachment(s) to a path (from the local cache).
    Export(commands::read::ExportArgs),
    /// Show tag frequencies (user vs machine tags).
    Tags,

    /// Add a relic from text, stdin, or file(s).
    Add(commands::write::AddArgs),
    /// Add/remove user tags on a relic (e.g. `tag <uid> +ops -draft`).
    Tag(commands::write::TagArgs),
    /// Edit a relic's title, note, or tags.
    Edit(commands::write::EditArgs),
    /// Promote a relic to the Vault.
    Promote(commands::write::UidArg),
    /// Remove a relic from the Vault (back to the stream).
    Unpromote(commands::write::UidArg),
    /// Put a stored relic back on the system clipboard.
    Copy(commands::write::UidArg),
    /// Bulk add relics from an NDJSON file (or - for stdin).
    Import(commands::write::ImportArgs),

    /// Soft-delete relics (tombstone). Requires the delete capability.
    Rm(commands::destructive::RmArgs),
    /// Remove a tag across the whole corpus. Requires the delete capability.
    TagRm(commands::destructive::TagRmArgs),
    /// Permanently purge a relic. Requires the purge capability.
    Purge(commands::destructive::PurgeArgs),

    /// Generate a shell completion script.
    Completions { shell: Shell },
}

fn main() {
    let cli = Cli::parse();
    let ctx = cli.global.ctx();
    if let Err(err) = dispatch(cli.command, &ctx) {
        let code = code_of(&err);
        if ctx.out.is_machine() {
            let body = serde_json::json!({ "error": { "code": code, "message": format!("{err:#}") } });
            eprintln!("{}", serde_json::to_string(&body).unwrap_or_default());
        } else {
            eprintln!("error: {err:#}");
        }
        std::process::exit(code);
    }
}

fn dispatch(cmd: Commands, ctx: &Ctx) -> anyhow::Result<()> {
    use commands::{app, destructive, read, write};
    match cmd {
        Commands::Status => app::status(ctx),
        Commands::Where => app::where_cmd(ctx),
        Commands::Skill(a) => app::skill(a, ctx),

        Commands::Search(a) => read::search(a, ctx),
        Commands::Get(a) => read::get(a, ctx),
        Commands::List(a) => read::list(a, ctx),
        Commands::Export(a) => read::export(a, ctx),
        Commands::Tags => read::tags(ctx),

        Commands::Add(a) => write::add(a, ctx),
        Commands::Tag(a) => write::tag(a, ctx),
        Commands::Edit(a) => write::edit(a, ctx),
        Commands::Promote(a) => write::promote(a, ctx, true),
        Commands::Unpromote(a) => write::promote(a, ctx, false),
        Commands::Copy(a) => write::copy(a, ctx),
        Commands::Import(a) => write::import(a, ctx),

        Commands::Rm(a) => destructive::rm(a, ctx),
        Commands::TagRm(a) => destructive::tag_rm(a, ctx),
        Commands::Purge(a) => destructive::purge(a, ctx),

        Commands::Completions { shell } => {
            use clap::CommandFactory;
            let mut cmd = Cli::command();
            let name = cmd.get_name().to_string();
            clap_complete::generate(shell, &mut cmd, name, &mut std::io::stdout());
            Ok(())
        }
    }
}
