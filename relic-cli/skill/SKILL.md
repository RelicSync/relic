---
name: relic
description: >-
  Search, recall, and add to the user's Relic vault (their end-to-end-encrypted
  clipboard and knowledge store) from the terminal via the `relic` CLI. Use when
  the user wants to find, save, tag, or recall things they copied: snippets,
  shell commands, links, notes, screenshots, files. Triggers include "what did I
  copy", "find that command/link/snippet", "check my vault", "save this to
  Relic", "did I copy a ...", "is relic installed", "my clipboard history".
  Deletion is OFF by default.
---

# Relic CLI

`relic` is a thin shim over the Relic desktop app's on-device vault. It reads and
writes the app's local database and blob cache directly (no network, no keys),
and the running app handles sync and ML enrichment. It is lightweight and meant
to be driven by an AI agent.

## Detect + get set up

- `relic --version` — confirms the CLI itself is installed and on PATH.
- `relic status` — shows whether the desktop **app** is installed and how many
  relics are in the local vault. It always exits **0**; check its output (or
  `--json`'s `"installed"` field). When the app isn't set up, OTHER commands
  fail with exit code **3** (tell the user to install/open the Relic desktop
  app).
- `relic where` — prints the data paths.
- `relic skill --install` — writes this skill into `~/.claude/skills/relic/` so a
  future agent session knows about `relic` automatically. `relic skill` prints it
  to stdout.

## Output + exit codes

Prefer `--json` (or `--ndjson` for streams) for anything you parse; `-q` prints
bare uids for pipelines. Exit codes: `0` ok, `2` usage, `3` app not
installed/available, `4` not found, `5` rejected, `6` blocked by the delete
guardrail. In `--json` mode, errors are `{"error":{"code":N,"message":"..."}}`.

## Reading (always allowed)

```bash
relic search "kubectl rollout" --limit 10        # FTS5 + bm25 ranked
relic search "tag:ops deploy" --vault            # tag filter + vault only
relic search "" --after 2026-01-01 --sort newest # browse by date
relic get <uid>                                  # full uid OR a unique prefix
relic get <uid> --raw                            # just the content body (pipeable)
relic list --vault --limit 20                    # recent Vault items
relic tags                                       # tag frequencies (user vs auto)
relic export <uid> ./out.png                     # a photo/file blob from the local cache
relic export <uid> ./dir --all                   # every attachment of a bundle
```

Search notes: `tag:x` (or `--tag x`) filters by tag; punctuation and natural
language are handled safely. uids may be given as a unique prefix.

## Writing (allowed, audited)

```bash
relic add "some text to remember" --tag idea --title "Note"
echo "piped content" | relic add                 # reads stdin when no text/--file
relic add --file ./report.pdf --vault            # a file relic
relic add --file a.png --file b.png --title "set" # many files → a bundle relic
relic tag <uid> +ops -draft                       # add/remove user tags
relic edit <uid> --title "New title" --note "context"
relic promote <uid>      # to Vault
relic unpromote <uid>    # back to the stream
relic copy <uid>         # put the relic's text back on the system clipboard
```

Writes land in the app's local vault and queue for sync; the running app uploads
any blobs, pushes to the cloud, and enriches new relics with ML (OCR, captions,
tags, embeddings). Use `--dry-run` to preview any mutating command. Every
mutation is recorded in an audit log.

## Deletion is locked by default (important)

`relic rm`, `relic tag-rm`, and `relic purge` refuse with **exit code 6** unless
the user has granted the capability. **Do not enable deletion on your own** (do
not set `RELIC_ALLOW_DELETE`, do not pass `--allow-delete`, do not edit config).
If the user explicitly asks to delete and confirms, the safe path is
`relic rm <uid> --allow-delete` (it keeps a local trash backup and tombstones
through the app's sync). `purge --hard` is permanent with no backup; use only on
explicit, unambiguous instruction.

## Tips for agents

- Chain: `relic -q search "tag:secret" | while read uid; do relic get "$uid" --raw; done`
- `--json` shapes: `search`/`list` → `{count, items:[<relic>...]}`. A relic has
  `uid, created_at, updated_at, kind, source, promoted, byte_size, mime,
  filename, blob_key, tags, user_tags, title, note, content, preview,
  attachments`. `content` is the text; photos/files carry a `blob_key`.
- When unsure of a command or flag, run `relic --help` or `relic <cmd> --help`.
