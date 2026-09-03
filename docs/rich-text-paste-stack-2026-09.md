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
| macOS | yes, verified | yes, Swift bridge, verified on the pasteboard | yes, verified without the AX grant | yes, debug build compiles + runs (2026-09-02) |
| Linux | yes | yes, super_clipboard | yes, degraded on Wayland | yes, release build + runs |
| Android | tile path, HTML only | yes, HTML only | n/a (desktop only) | yes, release AAB |
| iOS | trigger paths, HTML only | yes, HTML + RTF | n/a (desktop only) | pending |

The test suite covers the pure logic (CF_HTML framing, the cap, the fingerprint,
the queue) and the storage and sync round-trip. It cannot cover "does Word see
it", so §8 answers that separately with a harness that drives real Office.

As of 2026-09-02 two columns of §8 are real. Windows: Word round-trips correctly
through both flavors, and clipboard content survives the writing process
exiting; Excel is unresolved and needs a human at a keyboard (§8b). macOS:
compiled, run, and verified on the pasteboard. Linux and Android are built and
green but have not been pasted into a real app.

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

**The source's skin is stripped on the way OUT.** `stripHtmlSkin` in
models/rich_body.dart removes colour, background, font-family/size, shadows and
every `*-color` property from the HTML just before it reaches the clipboard.
Bold, italic, links, lists, headings, tables and alignment all survive and take
the destination document's look.

This is not tidiness. Copying three sentences out of a dark-themed page carries
`color: #e6edf3` and `background-color: #0d1117` on every span, so pasting into
a white document gives white text in black boxes. A direct browser paste does
the same thing, so nothing was broken, but it is the wrong default for a
clipboard manager: you paste weeks later into a document you were not thinking
about when you copied. Confirmed against a real GitHub capture (9,381 bytes,
five different `*-color` properties, one link) which now pastes as ordinary
document text with the link intact.

It runs at write time, never at capture, so the stored HTML keeps everything the
source published and the decision stays reversible. **RTF is deliberately not
scrubbed**: the dark-page problem is a web problem and the web publishes HTML,
while RTF comes from Word and Pages where the formatting is the user's own, and
Word prefers RTF when both are offered. Pinned by tests in `rich_body_test.dart`.

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

**Status:** written, analyzed, release-built, and verified against real Word
(§8). Excel is unresolved (§8b). Items 1 and 4 below are covered by the harness;
2, 3, 5 and 6 still want a human.

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
   with Ctrl+Alt+B three times.

---

## 4. macOS

**Status: built, runs, pasteboard-verified 2026-09-02** on Apple silicon,
macOS 26, Flutter 3.44.9, against branch `e459b3b`. The Swift compiled first
time; `flutter analyze` is clean; `flutter test` under a sandboxed
`RELIC_DATA_DIR` is 797 pass, 20 skipped on a macOS host. What is left is the
part only a person at a Mac can do: pasting into Pages, Notes and Word.

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

**Verified, by driving `NSPasteboard.general` from a small Swift tool and
reading the sandbox `relics.db`:**

1. Compiles. `flutter build macos --debug` succeeds with the `writeRich` case.
2. Rich capture. A pasteboard carrying `public.rtf` + `public.html` +
   `public.utf8-plain-text` lands as one row whose `rich` column holds the
   HTML, the RTF (base64) and the fingerprint `h`.
3. Rich paste. Quick-paste (⌃⇧1) of that row writes, in this declaration
   order: `public.rtf`, `public.html` (with the charset marker prepended),
   `public.utf8-plain-text`, then the `org.nspasteboard.ConcealedType` and
   `TransientType` markers. Plain text is byte-identical to the stored
   content; RTF and HTML are byte-identical to what was captured.
4. Copy, quit Relic, paste. The content is real data on the pasteboard, not a
   promise: after `relic_app` exits the types and bytes are all still there.
5. ⌃⇧D and ⌃⇧B are unclaimed. Nothing in `com.apple.symbolichotkeys` binds
   keycode 2 or 11 with control+shift, and both chords registered and fired.
   **This result is now stale**: the chords moved to ⌃⌥D and ⌃⌥B on 2026-09-02
   because Ctrl+Shift+D and Ctrl+Shift+B are Chrome's bookmark keys on every
   platform, and a global grab takes a chord silently. The same check needs
   redoing for control+option on keycodes 2 and 11.
6. Paste stack without the Accessibility grant. Push twice via ⌃⇧D (it queues
   what is on the clipboard, since the copy chord cannot be injected), then
   ⌃⇧B three times: the pasteboard reads item one, then item two, then is
   untouched on the third press. FIFO, consumed on the clipboard write, and an
   empty stack writes nothing. The chords are ⌃⌥D and ⌃⌥B now; the behaviour
   this pins is unchanged.

**App-level, verified 2026-09-03 on the 1.0.43 release build** (tag `7092a1e`,
signed and notarized, run against the real vault with the screen unlocked,
driven by AppleScript):

- TextEdit rich → Relic → TextEdit: capture stores RTF (TextEdit publishes no
  HTML); quick-paste into a fresh document reproduces the text exactly, and the
  bold red run reads back as Helvetica-Bold in red with plain Helvetica either
  side.
- Safari → Relic → Notes: capture stores Safari's HTML with its colour and font
  spans; the pasted note carries `<b>` and `<i>` and "café ünïcode naïve résumé"
  intact, no mojibake, and none of the page's colours (the `8ce0883` skin strip
  doing its job).
- Pages and Word are not installed on this Mac, so those two rows stay open.
  The "press ⌘V yourself" notice cannot fire here because Accessibility is
  granted.

**Not verified, needs a person:** Pages → Relic → Pages, Safari → Notes (the
mojibake check), Word → Relic → Word, and the one-per-run "press ⌘V yourself"
notice, which fires as a notification and was not observed from the shell.

**Two traps for whoever tests by hand on Jordan's Mac:**

- The onboarding window of a sandboxed instance pops up on first run. If you
  click through "Continue with Google" the sandbox binds to the real account
  and syncs every test capture into the real vault. Run the sandbox, close the
  onboarding, and if it does bind, delete `config.json` from the sandbox dir
  to detach it. Test rows that did sync can be tombstoned with
  `relic rm --allow-delete <uid>` from the app's bundled CLI.
- Parsec mirrors the clipboard between Jordan's Mac and the Windows box, and
  the Windows Relic captures every plain-text write the Mac makes (device
  "Desktop"). Every pasteboard test here shows up in the vault twice. Writes
  that carry the `org.nspasteboard.ConcealedType` marker are skipped by the
  Mac watcher but still mirrored, so the Windows copy needs cleaning either
  way.

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
`_keysymNames`, so `linuxAccelerator` yields `<Control><Alt>d` and
`<Control><Alt>b` (this read was done against the old `<Control><Shift>` chords
and the only thing that changed is the modifier); `_pasteRelic` returns off the
clipboard write alone, so the
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
   `<Control><Alt>d` and `<Control><Alt>b`, but the actual grab needs testing.
   A refused grab surfaces in `repo.failedHotkeys`. **Linux is the platform most
   likely to refuse these**: some desktops bind Ctrl+Alt+D to show-desktop. If
   the grab is refused, say so rather than working around it, because the chord
   is a cross-platform default and changing it again is a shared decision.
6. Terminal paste. The pop path reads `foregroundAppKey()` and sends
   Ctrl+Shift+V into terminals. Confirm the stack drains correctly into one.

---

## 6. Android

**Status:** written and built. Not tested on a device.

Landed 2026-09-02 in the Android pass: the tile capture upgrade named below as
the open question, plus a settings toggle for rich paste. Release AAB
**1.0.42+58**, signed with the real upload key.

**Paste.** `WorkerRepo.putOnClipboard` writes through `DataWriterItem` with HTML
plus plain text, which maps to `ClipData.newHtmlText`. A clip captured with
formatting anywhere on the account pastes styled into Gmail or Docs. This is the
genuinely valuable half on mobile.

RTF is deliberately skipped on Android. Nothing there publishes or reads it and
leaving it out keeps `ClipDescription` clean.

**Note:** super_clipboard documents that Android may reject the write outright
if `plainText` is not in the same item. It is included. Do not remove it.

Settings now carries **Paste with formatting** (`_pasteRichTile` in
`mobile.dart`, stored as `relic.paste.richText`, default on), the mobile mirror
of the desktop toggle. `Copy as > Plain text` in the row menu is still the
one-off lever and works here already.

**Capture.** There is no clipboard watcher on Android, so the two entry points
are the share sheet and the `relic://capture` deep link from the Quick Settings
tile. The tile now captures formatting; the share sheet still cannot.

- `mobile.dart:_readClipboard` returns `({String? text, String? html})`. Each
  attempt goes through `_readClipboardOnce`, which reads `Formats.plainText` and
  then `kRelicHtml` off one super_clipboard reader, and falls back to
  `Clipboard.getData` when there is no reader or it throws. The twelve 250 ms
  attempts are unchanged: Android 10+ only lets a focused app read the
  clipboard, and a tile launch calls this before the window has focus.
  The HTML read has its own 400 ms budget and its own catch, so a slow or broken
  provider costs the flavor and never the capture.
- `WorkerRepo.captureText` takes `html:`, builds the `RichBody`, and drops it
  when the text is tagged `secret`. A re-copy of text already stored fills the
  formatting in rather than duplicating the row, and never the reverse: an
  existing body already matches this exact text, so replacing it buys nothing.
- The queue that holds a tile capture made before the repo is connected carries
  the HTML too, so a queued capture is not quietly poorer than a live one.
- The share sheet can never carry HTML. `receive_sharing_intent` delivers
  `SharedMediaFile` with a plain `String` for text and url types. Android does
  define `Intent.EXTRA_HTML_TEXT` and Chrome and Gmail do set it, so a custom
  `ACTION_SEND` receiver could read it, but that means native Kotlin plus
  forking or replacing the plugin. Still out of scope.

Tests: `app/test/mobile_rich_capture_test.dart` (8 tests: what is stored, the
secret rule, both directions of the re-copy, the cap, the fingerprint going
stale on an edit, and a cache round trip).

**To verify on a device:**
1. Capture styled text on a desktop, sync, paste into Gmail on the phone.
   Formatting should survive.
2. Paste into a plain text field. Should be clean text, not markup.
3. Confirm the write is not being rejected (that is the plainText requirement).
4. Copy styled text in Chrome on the phone, pull down the Quick Settings tile,
   and check the captured item carries formatting when you paste it back into
   Gmail. This is the new path and the one most likely to be wrong: whether a
   given app sets `htmlText` on copy is per-app behaviour we do not control.
5. The tile with a copied API key. The row must mask, and the item must have no
   formatting stored.
6. Settings, turn **Paste with formatting** off, copy a styled item, paste. It
   must come out plain. This toggle has no test: asserting it needs a real
   clipboard.

---

## 7. iOS

**Status:** written. Landed 2026-09-02 as the cheap route this section used to
prescribe: the `Platform.isLinux || Platform.isAndroid` branch in
`clipboard_bridge.dart` now includes iOS, and that is the entire paste-side
change. No native code; there is no iOS clipboard bridge and still no reason to
build one. The lazy-provider lifetime concern does not apply — super_clipboard
calls the iOS provider eagerly, and we always have the bytes in hand.

**Paste.** `WorkerRepo.putOnClipboard` was already calling
`writeRichToClipboard` on mobile; it just returned false here. Now the plugin
path publishes `public.html` and `public.rtf` (via `kRelicHtml` / `kRelicRtf`,
whose iOS codecs predate this change) plus plain text. Unlike Android, RTF is
included: Pages, Notes and Mail all read it. The **Paste with formatting**
toggle and the row's `Copy as > Plain text` were never platform-gated, so both
already work.

**Capture.** Nothing to change: `_readClipboardOnce` is shared mobile code, so
the `relic://capture` trigger paths (Action Button, Back Tap, Shortcut) pick up
`public.html` through the same super_clipboard read the Android tile uses. The
share sheet stays plain on iOS for exactly the Android reason —
`receive_sharing_intent` hands over a bare String. RTF capture is skipped on
mobile (both platforms): `captureText` takes `html:` only, and HTML is the
flavor that round-trips to every other platform.

The iOS codec names are pinned in `rich_body_test.dart` ("iOS publishes the UTI
names") so a lost `ios:` arm fails loudly instead of falling back to MIME names
UIKit apps never look for.

**To verify on a device or simulator:**
1. Capture styled text on a desktop, sync, paste into Notes or Mail on the
   phone. Formatting should survive (that is the HTML flavor; RTF rides along).
2. Paste the same item into a plain text field. Clean text, not markup.
3. Copy styled text in Safari, trigger a capture (Shortcut or Action Button),
   then paste the captured item back into Notes. This is the capture path.
4. Copy an API key, capture it. The row must mask, no formatting stored.
5. Settings > Paste with formatting off, copy a styled item, paste. Plain.

The paste stack is desktop-only and stays that way.

---

## 8. The interop matrix

The actual acceptance test. Windows was run 2026-09-02 against real Word and
Excel over COM; §8a is the harness, §8b is the one question it could not
settle.

| Source → target | Win | mac | Linux | Android | iOS |
|---|---|---|---|---|---|
| Word → Relic → Word (RTF) | pass | | n/a | n/a | n/a |
| Word → Relic → Word (HTML) | pass | | | | |
| Browser → Relic → Word or Pages (HTML) | not run | Safari → Notes: pass, 1.0.43 | | | |
| Excel → Relic → Excel | **unresolved, see §8b** | | | n/a | n/a |
| Relic → plain text editor | pass | TextEdit rich round trip (RTF): pass, 1.0.43 | | | |
| Copy, quit Relic, paste | pass | yes (pasteboard) | n/a | n/a | n/a |
| Secret → any target: plain only, marker set | not run | | | | |
| Desktop rich capture → phone paste into Gmail | n/a | n/a | n/a | | |
| Phone trigger capture in the browser → paste into Gmail | n/a | n/a | n/a | | |
| Stack of 3 drained into a form | not run | 2 drained, no AX grant | | n/a | n/a |

"Copy, quit Relic, paste" passes by construction and was observed: the harness
is a short-lived `dart run` process, and its clipboard contents outlive it and
paste correctly into Word. That is the `GlobalAlloc` write from C1 doing its
job, and it is the thing `super_clipboard` would have broken.

### 8a. The harness

`app/tool/rich_interop_win.dart` and `app/tool/rich_interop_win.ps1`. The Dart
half drives the real shipping code (`cfHtmlEncode`, `cfHtmlDecode`,
`RichBody.capture`, `writeRichToClipboard`); the PowerShell half drives real
Word and Excel over COM. Neither can run in CI, because both need a live
clipboard and an Office install.

```
dart run tool/rich_interop_win.dart write       # our payload onto the clipboard
powershell -File tool/rich_interop_win.ps1      # Word pastes it, per flavor
dart run tool/rich_interop_win.dart read        # decode what a source published
dart run tool/rich_interop_win.dart roundtrip   # capture -> JSON -> replay
dart run tool/rich_interop_win.dart raw         # full CF_HTML vs the fragment
```

Run the write and the paste in **one** shell session. The clipboard is shared
machine state and anything else that copies in between invalidates the run.

`PasteSpecial` with an explicit `wdPasteRTF` / `wdPasteHTML` is what makes this
worth trusting: a plain paste lets Word pick, so a passing plain paste can hide
a completely broken flavor.

### 8b. Excel is unresolved, and COM cannot settle it

**Do not treat this as a known bug. It is a known unknown.** An earlier pass of
this section claimed a confirmed design bug here. That claim was wrong and has
been removed; what follows is what the evidence actually supports.

**What is solid.** Excel's CF_HTML puts the load-bearing parts *outside* the
fragment markers:

```
<style> ... .xl63 {font-weight:700;} </style>   <- in <head>, outside
<table><tr>                                      <- outside
<!--StartFragment-->
  <td>plain</td><td class=xl63>bold</td>...      <- all we keep
<!--EndFragment-->
```

We store only the fragment and re-wrap it in a bare `<html><body>`, so our
stored HTML is orphaned `<td>` elements referencing a stylesheet that no longer
exists. That is a real structural fact, confirmed from a raw dump
(`dart run tool/rich_interop_win.dart raw` with Excel content on the clipboard).
Word is not exposed to it because its formatting is inline `style=` attributes
and a real `<b>` tag.

**What is NOT established: that any user ever sees it.** Excel also receives the
source's RTF, replayed byte for byte, and RTF carries the table structure and
the bold. In practice Excel appears to prefer it. Round-tripping through Excel
gave three correct cells with bold on most runs and one merged cell on some,
with **identical inputs**, so the failures are not deterministic and cannot be
pinned on the fragment loss.

**Why COM cannot close this.** `Worksheet.Paste()` depends on Excel's internal
copy-mode state, which our clipboard write cancels, so it is not a clean proxy
for a user pressing Ctrl+V. `Worksheet.PasteSpecial("HTML")`, which would
isolate the HTML flavor the way `wdPasteHTML` does for Word, throws "Unable to
get the PasteSpecial property" on most invocations. Neither path yields a
repeatable answer, and the intermittency is in the automation, not visibly in
our code. Ruled out as causes: nothing else on the machine overwrites the
clipboard after our write (`dart run tool/rich_interop_win.dart watch` holds the
sequence number steady for 3s across runs), and the harness's own missing
`OpenClipboard` retry, which produced a batch of fake "format absent" failures
before it was fixed.

**How to actually settle it, in about two minutes.** A human, at a keyboard:

1. Copy `A1:C1` from a sheet with one cell bold.
2. Capture it in Relic, then paste it back into a fresh sheet with Ctrl+V.
3. Three cells with the bold intact means the fragment loss is masked by RTF and
   this is a non-issue. One merged unformatted cell means it is real.
4. Repeat pasting into Google Sheets in a browser, which has no RTF to fall back
   on and is therefore the case most likely to expose it.

If it turns out to be real, the fix is known and was measured: keep the whole
CF_HTML document and recompute the offsets from the document's own markers
(`_cfHtmlFullDocument` in the harness is a working implementation). Two things
come with it. It must strip the `<link ...file:///C:/Users/<name>/AppData/...>`
element Office writes into the head, or captures start syncing the user's
account name and local paths. And it grows stored HTML by about two orders of
magnitude: Word's fragment for fifteen characters is 289 chars against a 39 KB
full document, which with Word's 42.5 KB of RTF puts one short styled sentence
at roughly 82 KB against the 256 KB cap. The cap still degrades correctly, but
it would start being reached by ordinary selections. §2's derivation of 256 KB
is about the Worker envelope gate and stays correct either way.

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
| Android tile capture | `app/lib/mobile.dart` `_readClipboard`, `_readClipboardOnce`, `_captureFromTrigger`; `worker_repo.dart` `captureText` |
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
