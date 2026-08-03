# relic-cli

`relic` is a thin, agent-facing shim over the Relic desktop app's on-device
vault. It lets a person or an AI agent search, add, tag, promote, export, and
recall vault content from the terminal.

## How it works

The CLI is a **shim into the app's backend**, not its own client. It reads and
writes the app's local plaintext SQLite database (`%APPDATA%\relic\relics.db`)
and blob cache (`%APPDATA%\relic\blobs\`) directly:

- **Reads** are plain SQL over the decrypted local index — no crypto, no keys,
  no network. Always current with what the app has.
- **Writes** mirror the app's own `upsert` exactly (the `relics` row plus the
  `relics_fts` / `relics_tri` full-text indexes and the `pending_ops` sync
  queue). New relics are left un-enriched so the app's background ML (OCR,
  captions, tags, embeddings) upgrades them on its next run, and blobs are
  staged into the cache so the app uploads them. Nothing is re-implemented that
  the app already does.
- **No relic-core, no crypto, no async, no credentials.** It requires the
  desktop app to be installed (that is the point of a shim).

## Install

```powershell
cargo install --path relic-cli --locked   # puts `relic` on PATH (~/.cargo/bin)
```

The Relic app installer also bundles `relic` (into `{app}\cli`) and adds that
directory to your per-user PATH, so an installed app means `relic` is already on
PATH — no separate step. See `app/installer/relic.iss` and
`app/scripts/build_release.ps1`.

## Use

```powershell
relic --version             # is the CLI installed?
relic status                # is the app installed? local vault stats
relic where                 # data paths
relic skill --install       # install the agent skill (~/.claude/skills/relic)
relic search "kubectl" --vault --limit 10
relic get <uid> --raw       # uid may be a unique prefix
relic add "remember this" --tag idea
relic --help                # full command list
```

Output: `--json` / `--ndjson` for machine parsing, `-q` for bare uids. Exit
codes: `0` ok, `2` usage, `3` app not available, `4` not found, `5` rejected,
`6` blocked by the delete guardrail.

## Safety: deletion is locked by default

`rm`, `tag-rm`, and `purge` refuse with exit code `6` unless granted via
`config.json` (`capabilities.allow_delete` / `allow_purge`), env
(`RELIC_ALLOW_DELETE` / `RELIC_ALLOW_PURGE`), or an explicit flag (which also
prompts unless `--yes`). `rm` writes a local trash backup before tombstoning;
`purge --hard` is permanent. Every mutation is appended to an audit log under
`%APPDATA%\relic-cli\`.

## Agent skill

`skill/SKILL.md` (embedded in the binary) teaches an AI agent how and when to use
this CLI. `relic skill` prints it; `relic skill --install` writes it into the
agent's skills directory. See `skill/README.md`.

## Testing note

`RELIC_APP_DIR` overrides the app data directory — used to run write tests
against a *copy* of a real vault DB rather than the live one.

## Development

```powershell
cargo test -p relic-cli
```
