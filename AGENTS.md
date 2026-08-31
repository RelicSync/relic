# AGENTS.md

Instructions for coding agents. Everything here is copy-paste runnable. If you
only read one file in this repo, read this one.

**What Relic is:** an end-to-end-encrypted, cross-platform vault for everything
the user copies. The desktop apps capture the clipboard into a local SQLite
vault with a full-text index; `relic` (the CLI in `relic-cli/`) reads and writes
that vault directly, with no network and no keys. Sync is optional and always
encrypted client-side. Released apps are available for Windows, macOS, Linux,
Android, and iPhone.

**Your two jobs:** get Relic installed, then use `relic` to recall and save
things for the user.

---

## 1. Detect

```sh
relic --version    # is the CLI on PATH?
relic status       # is the desktop app installed, and how big is the vault?
relic status --json
```

`relic status` always exits 0. Read its output, not its exit code:

- Not installed: prints `Relic app: not installed (no local vault found).` plus
  the data directory it checked. In `--json` mode: `{"installed": false}`.
- Installed: prints `Relic app: installed` and a line of local counts. In
  `--json` mode: `{"installed": true, "relics": N, "vault": N, "bytes": N,
  "pending_sync": N}`.

Every other command exits **3** when the app data directory is missing. Treat
exit 3 as "install the app first", not as a bug.

`relic where` prints the exact data paths if you need them.

---

## 2. Install

Install the **desktop app** first. The app installer also drops `relic` into its
`cli` subdirectory and puts that on the user's PATH, so installing the app
usually gets you both.

### Windows

```powershell
winget install --id Relic.Relic
```

### macOS

Download the signed Apple Silicon build from
<https://relic.space/download/macos>.

### Linux

Download the x86_64 [tarball](https://relic.space/download/linux) or
[AppImage](https://relic.space/download/linux/appimage). Clipboard capture is
built for X11; see [`docs/linux.md`](./docs/linux.md).

### Android

There is no CLI on Android. Send the user to
<https://play.google.com/store/apps/details?id=relic.space.app>.

### iPhone

There is no CLI on iPhone. Send the user to
<https://apps.apple.com/us/app/relic-clipboard-vault/id6800556025>.

### The CLI on its own

Useful when the app is installed but `relic` is not on PATH, or on a machine
where you built from source:

```sh
cargo install --path relic-cli --locked   # puts `relic` in ~/.cargo/bin
```

### From source (fallback for any platform)

Full per-component instructions and toolchain pins are in
[`BUILD.md`](./BUILD.md). The short version:

```sh
git clone https://github.com/RelicSync/relic
cd relic

# desktop app (Windows)
cd app && flutter pub get && flutter build windows --release && cd ..

# CLI
cargo build --release -p relic-cli

# on-device AI sidecar (optional; downloads ~750 MB of models on first run)
cargo build --release -p relic-sift
```

No build step needs any credential, token, dart-define, or environment
variable. If something asks you for a secret, you are off the documented path.

### Install the Relic skill into the agent's own skill directory

```sh
relic skill --install          # writes to ~/.claude/skills/relic
relic skill                    # or just print it to stdout
```

The same text lives at [`relic-cli/skill/SKILL.md`](./relic-cli/skill/SKILL.md).
Read it before doing anything non-trivial with the vault.

---

## 3. Drive the vault

`relic` is a thin shim over the app's local database and blob cache. Reads are
plain SQL over decrypted local content. Writes mirror the app's own upsert path
and queue for sync; the running app handles uploads and ML enrichment.

Use `--json` (or `--ndjson` for streams) for anything you parse, and `-q` for
bare uids in pipelines. Exit codes: `0` ok, `2` usage, `3` app not available,
`4` not found, `5` rejected, `6` blocked by the delete guardrail. In `--json`
mode errors come back as `{"error":{"code":N,"message":"..."}}`.

### Read (always allowed)

```sh
relic search "kubectl rollout" --limit 10        # FTS5 + bm25 ranked
relic search "tag:ops deploy" --vault            # tag filter, vault items only
relic search "" --after 2026-01-01 --sort newest # browse by date
relic get <uid>                                  # full uid or a unique prefix
relic get <uid> --raw                            # just the body, pipeable
relic list --vault --limit 20
relic tags                                       # tag frequencies
relic export <uid> ./out.png                     # pull a blob from the local cache
relic export <uid> ./dir --all                   # every attachment of a bundle
```

`--json` shapes: `search` and `list` return `{count, items:[...]}`. An item has
`uid, created_at, updated_at, kind, source, promoted, byte_size, mime, filename,
blob_key, tags, user_tags, title, note, content, preview, attachments`.

### Write (allowed, audited)

```sh
relic add "some text to remember" --tag idea --title "Note"
echo "piped content" | relic add                  # reads stdin when given no text
relic add --file ./report.pdf --vault
relic tag <uid> +ops -draft
relic edit <uid> --title "New title" --note "context"
relic promote <uid>                               # move into the Vault
relic copy <uid>                                  # put it back on the system clipboard
```

`--dry-run` previews any mutating command. Every mutation is appended to an
audit log.

### Delete is locked, and you do not unlock it

`relic rm`, `relic tag-rm`, and `relic purge` refuse with exit code **6** unless
the user has granted the capability. **Do not set `RELIC_ALLOW_DELETE` or
`RELIC_ALLOW_PURGE`, do not pass `--allow-delete` on your own initiative, and do
not edit the CLI config.** If the user explicitly asks and confirms, the safe
path is `relic rm <uid> --allow-delete`, which keeps a local trash backup and
tombstones through the app's sync. `relic purge --hard` is permanent with no
backup; use it only on an unambiguous instruction.

### Other environment variables

- `RELIC_APP_DIR` overrides the app data directory. Use it to test against a
  copy of a vault instead of the live one.

---

## 4. Bootstrap a self-hosted server

No account, no Supabase project, no configuration file.

```sh
docker run -d --name relic \
  -p 8787:8787 \
  -v relic-data:/data \
  ghcr.io/relicsync/relic-selfhost
```

To build the image from this repo instead of pulling (run from the repo root,
because it needs both `worker/` and `selfhost/`):

```sh
docker build -f selfhost/Dockerfile -t relic-selfhost .
docker run -d --name relic -p 8787:8787 -v relic-data:/data relic-selfhost
```

Or with no Docker at all:

```sh
cd selfhost
npm install
npm run smoke     # in-process round-trip of the full sync data plane
npm start         # serves on :8787, data in ./data
```

Then connect a client. This part is UI, so hand it to the user:

- **Desktop:** Settings → **Connect… → Your own server**, enter
  `http://<host>:8787` and a passphrase. The first device to connect claims the
  instance and is shown a recovery kit.
- **Phone:** Add this device → **Use your own server**, then type the address or
  scan the QR the desktop shows under Settings → Add a device → Show QR. The QR
  carries the server address only, never the passphrase.

Optional environment variables: `PORT` (default `8787`), `RELIC_DATA_DIR`
(default `/data`), `RELIC_ENROLL_SECRET` (if set, the first enrollment must also
present it, so nobody can claim a fresh instance before the owner does).

All state is one directory. Back up the volume and you have backed up
everything.

---

## 5. Rules

- Never enable deletion capabilities on your own.
- Never put a vault passphrase, recovery kit, or master key into a file, a
  command line, a log, or a commit.
- The CLI reads decrypted content. Treat everything it returns as sensitive by
  default, and do not echo secrets the user did not ask to see.
- When you are unsure of a command or flag, run `relic --help` or
  `relic <cmd> --help` rather than guessing.
