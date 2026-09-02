# Rich text and the paste stack: platform handoff

Written 2026-09-02, against public `a21534b` (merged at `5d6dd69`).

Two features landed together. Everything in them is written and green, but only
Windows has been built and only Windows can be hand-tested from the machine they
were written on. Clipboard interop is not machine-testable: whether Word accepts
our RTF is a question you answer by copying out of Word.

This doc is the handoff. Read §1 and §2, then go to your platform's section.

---

## 1. What landed, and where it stands

| Platform | Rich capture | Rich paste | Paste stack | Built? |
|---|---|---|---|---|
| Windows | yes | yes, native Win32 | yes | yes, release build |
| macOS | yes | yes, Swift bridge | yes | **never compiled** |
| Linux | yes | yes, super_clipboard | yes, degraded on Wayland | yes, release build + runs |
| Android | tile path only, not wired | yes, HTML only | n/a (desktop only) | no |
| iOS | no | no, falls back to plain | n/a | no |

Nothing here has been pasted into a real app on any platform yet, Windows
included. The test suite covers the pure logic (CF_HTML framing, the cap, the
fingerprint, the queue) and the storage and sync round-trip. It cannot cover
"does Word see it".

---

## 2. Shared facts you need before touching any platform

**Plain text is always authoritative.** A formatting flavor is a bonus that can
be dropped at any point without the relic becoming wrong. Every write puts plain
text on the clipboard too. If you are ever choosing between correct plain text
and styled text, choose plain.

**The fingerprint rule.** `RichBody.h` is a hash of the plain text the flavors
came from. Every read goes through `Relic.richIfCurrent`, never `Relic.rich`. A
writer that changes `content` without knowing the field exists (`relic-cli`'s
upsert, an import) leaves formatting behind that no longer matches, and the
mismatch makes it inert. If you add a read path, use the accessor.

**Secrets never carry formatting.** Enforced in three places, and all three are
load-bearing: capture drops it, `richIfCurrent` refuses to serve it, and
`exportVault` strips the key. The third one matters because a relic can be
marked secret after capture. Without it a redacted export scrubs the plaintext
body and ships the same secret inside the HTML.

**256 KiB cap** on the serialized `rich` JSON, enforced on the way in as well as
on capture. Over the cap RTF is dropped first and HTML kept, because HTML works
on more platforms. The number is set by the Worker's `caps.item * 1.5` envelope
gate, not by taste. Do not raise it without redoing that arithmetic.

**Both format constants are ours, not super_clipboard's.** `kRelicHtml` and
`kRelicRtf` live in `app/lib/platform/rich_formats.dart`. This is not
not-invented-here:

- `Formats.rtf` is a `SimpleFileFormat`, and a file format publishes only its
  first platform format. It can never offer both `text/rtf` and
  `application/rtf` on Linux, and it falls back to `mimeTypes` on Windows, which
  would register a format named `application/rtf` that no Windows app reads.
- `Formats.htmlText` lists both `text/html` and CF_HTML as Windows decoding
  formats and decodes anything that is not CF_HTML as UTF-16. Some Qt and
  Electron apps register a Windows format literally named `text/html` holding
  UTF-8, and the reader picks by the source app's priority order. Those apps
  come back as mojibake.

Both regressions are pinned by tests in `app/test/rich_body_test.dart`. If you
"simplify" back to the stock constants those tests fail, which is the point.

**The paste stack is FIFO** despite the name. Push appends, pop takes the head.
Copy 1, 2, 3 then paste 1, 2, 3.

**It consumes on the clipboard write, not on the keystroke.** `_pasteRelic`
returns a bool for exactly this. Where the paste chord cannot be injected, the
item is still on the clipboard and the user presses their own chord, so the
queue must still advance. Consuming only on successful injection would re-serve
the same item and they would paste it twice.

**An empty stack does nothing.** It never falls back to a normal paste. Silently
putting unqueued content into a document with no undo is the one genuinely
destructive option in this feature. Do not add the fallback.

---

## 3. Windows

**Status:** written, analyzed, release-built. Not hand-tested.

The write is raw Win32 in `app/lib/platform/src/windows/clipboard_win.dart`
(`writeRichToClipboard`), placing plain text, CF_HTML and `Rich Text Format`
inside one `OpenClipboard` session, then the privacy DWORDs.

It is deliberately NOT super_clipboard, and this is the trap to not undo:
`super_native_extensions` publishes through `OleSetClipboard` with a live
delayed-rendering `IDataObject` and never calls `OleFlushClipboard`. Content
would die when Relic exits, and Relic is a tray app people quit. Also
`markClipboardSensitive` needs to own the clipboard, and under OLE the owner is
OLE's hidden window.

**To verify:**
1. Copy a styled paragraph out of Word. Paste into Notion or Slack. Formatting
   should survive.
2. Same item, row `⋯` menu, Copy as, Plain text. Paste again. Formatting should
   be gone.
3. Copy from Excel. Paste into Excel. Cells, not one blob of text.
4. Copy something, quit Relic from the tray, paste. It must still work. This is
   the regression that catches an accidental move to the OLE path.
5. Copy a card number or an API key. Confirm no formatting is stored (the row
   shows masked) and that the Windows clipboard-history flyout does not show it.
6. Fill a stack of three from the picker, dismiss it, drain into a spreadsheet
   with Ctrl+Shift+B three times.

---

## 4. macOS

**Status: the Swift has never been compiled.** This is the single most important
item in this doc. `app/macos/Runner/Bridge/ClipboardBridge.swift` gained a
`writeRich` case that was written on a Windows machine. Build it first, before
anything else.

The Dart side is `app/lib/platform/src/macos/clipboard_macos.dart` (`writeRich`),
sending `text`, optional `html`, optional `rtf` as `FlutterStandardTypedData`,
and `sensitive`.

Declaration order is the app's preference order, so rich types lead and
`.string` is last. The `<meta charset='utf-8'>` prefix on the HTML is
load-bearing: Notes and Mail assume latin-1 without it.

Same reason as Windows for not using super_clipboard here: it does
`clearContents()` plus a lazy `NSPasteboardWriter` promise, so the content dies
when Relic quits, and the `clearContents` would wipe the `org.nspasteboard.*`
privacy markers.

**To verify:**
1. It compiles.
2. Copy styled text from Pages or Safari, paste into Pages. Formatting survives.
3. Copy into Notes. Check the text is not mojibake (that is the charset marker).
4. Copy, quit Relic, paste.
5. **Confirm ⌃⇧D and ⌃⇧B are actually unclaimed on macOS.** The comment at
   `hotkeys.dart:196` records that ⌃⇧Q/W/E/Space/1-5 were verified. D and B were
   picked on Windows and have NOT been checked on macOS. If either is taken,
   `repo.failedHotkeys` will surface it in Settings, but check by hand too.
6. Paste stack without the Accessibility grant: the chord cannot be injected,
   so the item should land on the clipboard, the one-per-run notice should
   appear, and the queue should still advance when you press ⌘V yourself.

**While you are in there,** two pre-existing bugs surfaced by this work, both
worth their own commits rather than folding into this feature:

- `markClipboardSensitive()` is called after `clip.write()` in the `Kind.photo`
  branch of `_putOnClipboardInner`. Under OLE/NSPasteboard ownership it is
  probably already a silent no-op. Confirm with a debug print.
- Image copies probably do not survive quitting Relic, for the same
  no-`OleFlushClipboard` reason. Text does, and now stays that way.

---

## 5. Linux

**Status:** built, runs, tests green. No clipboard interop tested — that is all
of what is left, and it needs a real desktop session.

**Verified 2026-09-02** on WSL Ubuntu 24.04 with the pinned Flutter 3.44.2, the
same version and apt list `ci.yml`'s `flutter-linux` job uses. WSL is the compile
track from the port plan; the QA VM was not involved.

- `flutter analyze` clean, `flutter build linux --release` succeeds. The
  "never built" half of this section is closed.
- `flutter test` under a sandboxed `RELIC_DATA_DIR`: **794 pass** on a Linux
  host, including the new `rich_body`, `rich_capture` and `paste_stack` suites.
- The binary had never been run. It now does: every shared library resolves, it
  survives a 25s run with no output but WSLg's own software-rendering warnings,
  and it initializes a vault.
- **First-run registration is correct**, which matters because this was the
  first real Linux run and the port plan flagged the data dir as a landmine.
  The vault lands in `~/.local/share/relic` and `~/.config/relic` is never
  created; the `.desktop` entry is written with the `relic://` handler and
  `StartupWMClass`; the hicolor icon is written at a true 256x256.
  (Watch out when re-testing this by hand: the entry is `space.relic.app.desktop`,
  so a `relic*` glob misses it, and a stale entry makes `ensureRegistered` take
  its early return and skip the icon write entirely. That looks exactly like a
  broken icon and is not one.)

Confirmed by reading rather than running, so listed as evidence and not as a
test: `kRelicRtf` really does publish `text/rtf` and `application/rtf` together
on the fallback codec; D is `0x00070007` and B is `0x00070005` and both are in
`_keysymNames`, so `linuxAccelerator` yields `<Control><Shift>d` and
`<Control><Shift>b`; `_pasteRelic` returns off the clipboard write alone, so the
queue advances on Wayland whether or not injection fires, behind a one-per-run
notice; `_readRichFlavors` is not platform-gated, so Linux gets rich capture
through the ordinary super_clipboard reader; and `foregroundAppKey()` has a real
Linux arm, so the terminal Ctrl+Shift+V branch is wired rather than stubbed.

**Not tested, and not testable here.** Everything below in this section that
touches the clipboard. WSLg proxies the clipboard through Windows, so a paste
fidelity result measured under it would be describing Windows. The X grab is
likewise only half-answered: the accelerator strings parse and an XWayland
server accepts them, which is not the same as a desktop where another app may
already hold the chord.

Linux had no native clipboard write at all before this: every write fell through
to `Clipboard.setData`. Rich text is the first path that writes real formats
here, and it goes through `super_clipboard`'s `DataWriterItem` in
`app/lib/platform/clipboard_bridge.dart`. That is correct on Linux, because
there is no OLE lifetime problem and nothing that owns privacy markers.

`kRelicRtf` publishes both `text/rtf` and `application/rtf` on the fallback
codec, because LibreOffice and GTK look for different ones.

**To verify:**
1. Build. Then copy styled text out of LibreOffice Writer and paste it back in.
2. Copy from Firefox, paste into LibreOffice. HTML path.
3. Both X11 and Wayland. The capture side goes through the GTK `owner-change`
   signal in `linux/runner/clipboard_watch.cc`, which carries no payload, so
   rich reads happen on the normal super_clipboard read and should behave the
   same on both.
4. **Paste stack on Wayland.** Injection is unavailable there
   (`inputInjectionAvailable()` is false), so this is the degraded path that
   matters most: the item must land on the clipboard, the queue must still
   advance, and the one-per-run Wayland notice should appear once.
5. Hotkeys. Relic owns `XGrabKey` itself in `linux/runner/hotkeys.cc` because
   both hotkey libraries are broken here. D (`0x00070007`) and B (`0x00070005`)
   are already in `_keysymNames`, so `linuxAccelerator` produces
   `<Control><Shift>d` and `<Control><Shift>b`, but the actual grab needs
   testing. A refused grab surfaces in `repo.failedHotkeys`.
6. Terminal paste. The pop path reads `foregroundAppKey()` and sends
   Ctrl+Shift+V into terminals. Confirm the stack drains correctly into one.

---

## 6. Android

**Status:** paste is written and not tested. Capture is not wired at all.

**What works:** `WorkerRepo.putOnClipboard` writes through `DataWriterItem` with
HTML plus plain text, which maps to `ClipData.newHtmlText`. A clip captured with
formatting on the desktop should paste styled into Gmail or Docs. This is the
genuinely valuable half on mobile.

RTF is deliberately skipped on Android. Nothing there publishes or reads it and
leaving it out keeps `ClipDescription` clean.

**Note:** super_clipboard documents that Android may reject the write outright
if `plainText` is not in the same item. It is included. Do not remove it.

**What does not work, and why:** there is no clipboard watcher on Android. The
two capture entry points are the share sheet and the `relic://capture` deep link
from the Quick Settings tile.

- The share sheet can never carry HTML. `receive_sharing_intent` delivers
  `SharedMediaFile` with a plain `String` for text and url types. Android does
  define `Intent.EXTRA_HTML_TEXT` and Chrome and Gmail do set it, so a custom
  `ACTION_SEND` receiver could read it, but that means native Kotlin plus
  forking or replacing the plugin. Out of scope unless someone decides it is
  worth it.
- The tile path CAN be upgraded. `mobile.dart:_readClipboard` polls
  `Clipboard.getData(kTextPlain)` twelve times at 250 ms, because Android 10+
  only lets a focused app read the clipboard. Reading `kRelicHtml` through
  super_clipboard alongside it, with the same retry loop, would give HTML
  capture from the tile. That is the one piece of Android capture worth doing.

**To verify:**
1. Capture styled text on a desktop, sync, paste into Gmail on the phone.
   Formatting should survive.
2. Paste into a plain text field. Should be clean text, not markup.
3. Confirm the write is not being rejected (that is the plainText requirement).

---

## 7. iOS

**Status: untouched.**

`writeRichToClipboard` returns false on iOS, so it falls through to
`Clipboard.setData` and pastes plain. Nothing is broken, the feature just is not
there.

`Formats.htmlText` and `public.rtf` both work on iOS through super_clipboard
with no native code, so the cheapest route is extending the
`Platform.isLinux || Platform.isAndroid` branch in `clipboard_bridge.dart` to
include iOS. There is no iOS clipboard bridge to add a native case to, and there
is probably no reason to build one.

One note if you do: super_clipboard's iOS lazy provider is called eagerly, which
is fine here because we always have the bytes in hand.

The paste stack is desktop-only and stays that way.

---

## 8. The interop matrix

Nobody has filled this in. It is the actual acceptance test.

| Source → target | Win | mac | Linux | Android |
|---|---|---|---|---|
| Word → Relic → Word (RTF) | | | n/a | n/a |
| Browser → Relic → Word or Pages (HTML) | | | | |
| Excel → Relic → Excel | | | | n/a |
| Relic → plain text editor | | | | |
| Copy, quit Relic, paste | | | n/a | n/a |
| Secret → any target: plain only, marker set | | | | |
| Desktop rich capture → phone paste into Gmail | n/a | n/a | n/a | |
| Stack of 3 drained into a form | | | | n/a |

---

## 9. Where things are

| Concern | File |
|---|---|
| The value type, cap, fingerprint, CF_HTML | `app/lib/models/rich_body.dart` |
| The two format constants | `app/lib/platform/rich_formats.dart` |
| Write dispatch | `app/lib/platform/clipboard_bridge.dart` |
| Windows write | `app/lib/platform/src/windows/clipboard_win.dart` |
| macOS write | `app/lib/platform/src/macos/clipboard_macos.dart` + `app/macos/Runner/Bridge/ClipboardBridge.swift` |
| Capture ladders (keep in step) | `app/lib/desktop.dart` `onClipboardChanged`, `_readClipboardContent`, `_readRichFlavors` |
| Capture, dedupe, secret rule | `app/lib/data/local_desk_repo.dart` `captureText`, `_resolveCapturedUid` |
| Paste path | `local_desk_repo.dart` `_putOnClipboardInner`, `worker_repo.dart` `putOnClipboard` |
| Storage | `app/lib/data/relic_db.dart` (`rich` column, both halves of `upsert`, `bulkLoad`) |
| Sync payload (written twice) | `worker_repo.dart:_push`, `local_desk_repo.dart` push |
| Stack state and API | `local_desk_repo.dart` `_stack`, `pushStack`/`popStack`/`peekStack` |
| Stack hotkeys | `app/lib/data/hotkeys.dart`, `desktop.dart` `_initHotkeys`, `_pushToStack`, `_popStackPaste` |
| Stack UI | `app/lib/ui/popup.dart` `_stackBar`, `_loadStack`; `app/lib/ui/settings.dart` |
| Tests | `rich_body_test`, `rich_capture_test`, `paste_stack_test`, plus additions to `relic_db_test`, `relic_model_test`, `hotkeys_test`, `text_transforms_test` |

Run the repo-level tests under a sandbox:

```sh
RELIC_DATA_DIR=$(mktemp -d) flutter test
```

They are written to survive a dirty sandbox, so a reused directory is fine, but
a fresh one is cleaner.
