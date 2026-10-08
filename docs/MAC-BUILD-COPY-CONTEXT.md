# Mac build brief: new search model, t3 titler, copy context

**For the agent on Jordan's Mac.** Build this branch on macOS, prove the parts
that could not be checked on Windows, fix what breaks, and report back. Delete
this file from the branch before it merges.

## What you're building

Branch `feat/copy-context` of RelicSync/relic (draft PR #63), stacked on
`prep/model-swap` (draft PR #55). Together they add:

1. **ft2**, a fine-tuned search embedding model (new file names under
   `models.relic.space/relic-sift/v2/`). The app notices the model changed,
   drops every stored vector and re-embeds the whole vault in the background.
2. **t3**, a fine-tuned titler (Qwen3.5-0.8B) that titles a copy from where it
   came from. Also new files under `relic-sift/v2/`.
3. **Copy context**: at copy time the app reads the window title, the page link
   and the words around the selection, keeps them on this device only (table
   `copy_context`, never synced or backed up), and sends them to relic-sift.
4. Titles on for every new item by default, a "Improving search: N items left"
   banner during the re-embed, and model-download backoff.

Everything is built and tested on Windows. **Never compiled on a Mac:** the
Swift reader `copyContext()` in `app/macos/Runner/Bridge/ForegroundAppBridge.swift`
and its Dart client `copyContext()` in
`app/lib/platform/src/macos/foreground_macos.dart`.

## Rules

- Product code lives in the public repo. Commit fixes to `feat/copy-context`,
  stage files by name, push. Don't merge anything, don't release, don't touch
  `latest.json` or R2.
- **Don't let this build touch the real vault or the real model folder.** The
  installed (old) Relic can't tell its stored vectors came from a different
  model, and the new sift deletes the old model files once the new ones are in.
  Use the sandbox variables below for every run.
- Quit the installed Relic while the test build runs (both watch the
  clipboard). The sandbox build is signed out by design (its keychain entries
  are namespaced) and won't sync. Leave it signed out.

## Steps

1. Pull and build.
   ```bash
   git fetch origin && git checkout feat/copy-context && git pull
   cd app && flutter pub get && flutter analyze && flutter test   # expect ~1062 passing
   cd ../relic-sift && cargo test && cargo build --release --bin sift
   cd ../app && flutter build macos --release
   ```
   `app/scripts/build_release_macos.sh --skip-dmg` (unsigned) is the full
   bundle path if a plain `flutter build macos` can't find sift.

2. Make a sandbox copy of the vault and a sandbox models folder.
   ```bash
   SB="$HOME/relic-ft2dev"; mkdir -p "$SB/sift"
   cp -R "$HOME/Library/Application Support/relic" "$SB/data"
   rm -f "$SB/data/tag_vectors.json"
   # empty models folder: the build downloads ft2 + t3 from R2 (~1 GB)
   ```

3. Run the built app with the sandbox.
   ```bash
   RELIC_DATA_DIR="$SB/data" RELIC_SIFT_HOME="$SB/sift" RELIC_SEARCH_TUNING=1 \
     "app/build/macos/Build/Products/Release/relic_app.app/Contents/MacOS/relic_app"
   ```
   Grant Accessibility to the test build if macOS asks. The copy context reader
   needs it, the same grant paste uses.

## What to check

1. **It compiles.** The Swift uses `AXUIElementCopyAttributeValue`,
   `kAXSelectedTextAttribute`, `kAXSelectedTextRangeAttribute`,
   `kAXNumberOfCharactersAttribute`, `kAXStringForRangeParameterizedAttribute`
   and `kAXWindowAttribute` / `kAXTitleAttribute`, following the existing
   `caretScreenPoint()` in the same file. Fix whatever doesn't compile.
2. **Models download and load.** `"$SB/sift"` should end up with
   `embeddinggemma-300m-ft2.int8.onnx`, `embeddinggemma-300m-ft2.onnx_data` and
   the four `qwen35-labeler-t3.*` files. Check with:
   ```bash
   RELIC_SIFT_HOME="$SB/sift" <path to built sift> models status
   ```
3. **The re-embed runs and finishes.** The popup shows "Improving search: N
   items left", and the number falls (about 240 a minute). Track it from the
   database:
   ```bash
   sqlite3 "$SB/data/relics.db" "select count(*) from relics r where held_by is null and trim(coalesce(content,''))<>'' and exists(select 1 from vectors v where v.uid=r.uid)"
   ```
4. **Copy context, per app.** Copy a short value out of a longer passage in
   each app below, wait about 15 s, then look at what was kept:
   ```bash
   sqlite3 "$SB/data/relics.db" "select r.title, length(c.title), c.url is not null, length(c.before_text), length(c.after_text) from relics r join copy_context c on c.uid=r.uid order by r.created_at desc limit 5"
   ```
   Fill in the table:

   | App | window title? | link? | words around? | t3 title |
   |---|---|---|---|---|
   | TextEdit | | n/a | | |
   | Notes | | n/a | | |
   | Safari | | | | |
   | Chrome | | | | |
   | VS Code | | n/a | | |
   | Terminal | | n/a | | |
   | Slack or Messages | | n/a | | |

   Also check two things that must NOT happen: a password field copy (keep
   context off), and a copy whose selection was cleared before Relic read it
   (no borrowed words).
5. **Photos still title well.** Copy a couple of screenshots; their titles
   should read like "Workspace settings menu with user profile", not "image".

## Known so far (from Windows)

- Native text controls give all three pieces.
- The Claude desktop app (Electron) gave the window title only.
- Chrome and Edge test pages reported no selection to a window that had never
  been focused. A real copy in a focused tab is the open question on every
  platform.
- Relic's macOS Accessibility path goes through `kAXSelectedTextRangeAttribute`.
  Safari and Chrome web areas may only expose text markers
  (`AXSelectedTextMarkerRange`), not plain ranges. If so, the code falls back
  to `AXValue` plus a unique-match split. If both come back empty for web pages,
  say so. Text-marker support is the likely next step, not something to bolt
  on in this pass.

## Report back

Commit a short `docs/MAC-BUILD-RESULTS.md` to the branch with:
- the table above, filled in;
- anything you fixed, with commit hashes;
- whether the re-embed finished, and roughly how long it took for how many
  items;
- anything that looked wrong.

Then tell Jordan in plain words: works or doesn't, and what's left.
