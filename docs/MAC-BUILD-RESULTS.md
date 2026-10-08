# Mac build results: ft2, t3, copy context

Run on Jordan's Mac on 2026-10-08 against `feat/copy-context` at `fd05ebc`,
per `docs/MAC-BUILD-COPY-CONTEXT.md`. macOS 26 (Darwin 25.5), Apple Silicon,
Flutter 3.44, Rust 1.97.

## Verdict

Works. Two fixes landed on the branch (below), one of them a crash in sift that
hits every platform. Web pages give the window title only, as the brief
expected; words around the selection need text-marker support, which is not in
this pass.

## It compiles

`flutter analyze` clean, `flutter test` 999 passing (82 skipped), `cargo test`
104 passing in sift, `flutter build macos --release` built on the first try
with the untested Swift reader unchanged. No compile fix was needed.

One trap for the next person: `flutter build macos` does not place `sift` in
the bundle, and it leaves whatever `Contents/MacOS/sift` was already there. A
release build earlier in the day had left the 1.0.58 sift behind, so the dev
build quietly ran the old binary and started downloading the old
`embeddinggemma-300m` files. Copy `target/release/sift` into
`relic_app.app/Contents/MacOS/` (ad-hoc sign it) before a sandbox run, or
use `build_release_macos.sh --skip-dmg`.

## Models download and load

Fresh `RELIC_SIFT_HOME`, the app downloaded everything itself in under two
minutes on this connection:

```
embeddinggemma-300m      text-embedding                 329.8 MB  present
qwen3.5-0.8b             vision-language (labeling)     666.1 MB  present
```

The files are `embeddinggemma-300m-ft2.int8.onnx`,
`embeddinggemma-300m-ft2.onnx_data` and the four `qwen35-labeler-t3.*` files,
plus the OCR, CLIP and runtime files.

## The re-embed

The app noticed the model change at launch
(`embedding model changed (embeddinggemma-300m@int8-mrl256 ->
embeddinggemma-300m-ft2@int8-mrl256): rebuilding vectors`), dropped the
6,358 stored vectors and re-embedded the vault in the background.

- Vault: 6,775 items; the rebuild also picks up items the old pass had
  skipped, so the queue was nearer 8,000.
- Rate: about 250 items a minute on an M-series Mac with the labeler also
  titling new items.
- Elapsed: not a clean number. The Mac spent a stretch of the afternoon away
  from the keyboard with the display off and the rebuild all but stopped for
  it, then picked up again at the same rate, and the run was stopped at
  6918 vectors with 1813 items left once the release build needed the
  CPU. At the measured rate the whole vault is about half an hour.
- The popup banner read "Improving search: 5,026 items left. Results get
  better as it finishes." partway through (read from the app's accessibility
  tree; screen capture is off limits to this session). The count fell as
  expected.
- Restarting the app mid-rebuild resumed where it left off.

## Copy context, per app

A short value copied out of a longer passage in each app, then
`copy_context` read back.

| App | window title? | link? | words around? | t3 title |
|---|---|---|---|---|
| TextEdit | yes ("Untitled 4") | n/a | yes, 120 before / 180 after | "Warehouse lease reference code" |
| Notes | yes ("Notes – 2 notes") | n/a | yes, 193 before / 98 after | "Warehouse move meeting notes" |
| Safari | yes (page title) | no | no | "PO-77812-AX project identifier" |
| Chrome | yes, after the fix below (page title, "- Google Chrome - Jordan" suffix) | no | no | "Quarterly notes" copy, see below |
| VS Code | not installed on this Mac | n/a | | |
| Terminal | yes ("jordan — -zsh — 120×30") | n/a | no (select all, so nothing around) | "Shell command clearing a scratchpad passage" |
| Slack or Messages | not tested (Slack not installed; a Messages copy sends nothing but reads a real thread) | n/a | | |

The link column is empty everywhere: the page link comes from the clipboard's
own URL flavour, and neither Safari nor Chrome put one on the pasteboard for a
plain text selection from a `file://` page. Worth a second look with an
`https://` page.

What must not happen, both confirmed:

- A copy whose selection differs from the copied value: `pbcopy` of
  `orphan-value-9931` while TextEdit had "Meeting" selected gave the window
  title and no words (0 / 0).
- A password field: macOS refuses the copy itself in a secure field, so
  nothing is captured. The reader also returns the title only for an
  `AXSecureTextField`, so a field that did allow copy would still keep its
  text out.

Why the browsers give no words: Safari's focused element is an `AXWebArea`
that exposes `AXSelectedTextMarkerRange`, `AXStartTextMarker`, `AXEndTextMarker`
and `AXValue`, but not `AXSelectedText` or `AXSelectedTextRange`. The reader
walks five ancestors looking for `AXSelectedText` and finds none, so the
`AXValue` split never runs. Text-marker support is the next step, as the
brief guessed. Chrome goes further: it does not enable accessibility until an
assistive client asks for it, so `kAXFocusedUIElementAttribute` on the
system-wide element fails outright (`-25204`), which is also why the Claude
desktop app (Electron) gave nothing.

## Photos still title well

Copied `website/public/icon.png`: titled "A golden diamond icon" at enrich
level 4 within fifteen seconds. The two marketing screenshots from the brief
came back as "RELIC" and "Relio": they carry masked personal data (a
"Known traveler #" line), and the labeling gate in `pipeline.rs` withholds the
description for any capture with `pii_present`, so they fall back to the first
OCR line. That is by design, not a Mac problem; `sift label` run directly
(no gate) titles them "Relic software listing business expense categories"
and "Relic browser search results for business documents".

## Fixed on the branch

1. **Chromium apps give nothing at all.** `copyContext()` returned nil when
   the system-wide focused element could not be read, which is every Chrome
   and Electron window. It now falls back to the frontmost app's focused (else
   main) window title through the app element, which Chrome does answer. Same
   fallback when a focused element has no `kAXWindowAttribute`.
   `app/macos/Runner/Bridge/ForegroundAppBridge.swift`.
2. **sift panics while ordering OCR lines, and the classify server dies.**
   `ppocr.rs` sorted recognised boxes with a comparator that treated two
   boxes as the same band when their tops were within half a line height.
   That is not a total order (A near B and B near C does not make A near C),
   and Rust's sort panics when it detects one:
   `user-provided comparison function does not correctly implement a total
   order`. It hit on `marketing/website-shots/framed/desktop-popup-framed.png`
   about one run in two. The order is now computed in two passes (sort by
   top, assign bands, sort by band then left edge) with unit tests, including
   the staircase of close rows that broke the old one. Every platform runs
   this code.

Commits: `d99b2b1` (Swift fallback) and `3e3f443` (sift sort), on `feat/copy-context` after the 1.0.59 bump.

## Also seen

- A re-copy of text that already exists in the vault attaches context to the
  existing item when it has none. One of Jordan's own copies during the run
  was an API key, titled "An access credential" by the labeler, and it picked
  up a window title that way. `isSecret` on the row was false, so the
  `!touched.isSecret` guard did not apply. Worth deciding whether labeler-
  detected credentials should also block context.
- The sandbox copy of the vault captured whatever was on the clipboard while
  the installed Relic was quit for the copy tests, so those few minutes of
  Jordan's clipboard history are in the sandbox only.
