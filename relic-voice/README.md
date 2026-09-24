# Relic Voice

Relic Voice is local English dictation on Windows and macOS. It is off until the person
turns it on: the first time the popup opens on a build that ships the worker,
a one-time card offers "Turn on voice" or "Not now", and either answer is
remembered (`offered` in `voice.json`). Voice settings keeps the switch. First
setup downloads 715,727,326 bytes of pinned models from `https://models.relic.space/relic-voice/v1/`.
Downloads resume and every completed file is checked against its embedded SHA-256.
The three files are hosted on Relic's R2 bucket. There is no cloud speech service.

- Hold the Voice key (physical Right Alt on Windows, Right Option on a Mac),
  speak when the shadow pulses, release to finish.
- Double-tap the Voice key to keep recording, then tap once to finish.
- Hold Left Ctrl (Control on a Mac) first for a voice note saved directly to
  the vault.
- Escape cancels. The tray (menu bar on a Mac) also has start, stop, cancel
  and Voice settings.
- Dictation saves to history before attempting insertion. Existing auto-vault
  and promotion flows still apply. Full vaults fall back to history, with the destination shown in Voice settings.
- The Relic mark grows smoothly with normalized microphone volume and settles
  back in silence. A soft shadow pulses slowly while recording and quickly
  while transcribing. Windows reduced-motion settings disable these animations. No text or recording dot appears. The popup hides
  as soon as transcription completes. Sessions stop at 10 minutes. Audio stays
  in memory only until its phrase is transcribed, then it is discarded.
- Preferred spelling and explicit whole-phrase corrections are available in
  Voice settings. Recognition boosting and LLM rewriting are deferred.

The worker contains its own Python runtime and uses native transcribe.cpp and
ONNX Runtime on CPU. Microphone audio is resampled to 16 kHz by a small
numpy polyphase filter in `resample.py`; the worker does not ship scipy. End users need no Python, package manager or GPU. Windows
x64 with AVX2/FMA/F16C, or an Apple Silicon Mac, is required. Model weights stay resident while enabled.
After at least five seconds of speech capture, a quiet pause lets the worker
decode that completed segment while recording continues. The final result is
still saved and inserted only after release. There are no forced cuts through
continuous speech; uninterrupted long utterances can still take longer to finish.
Corrections and punctuation run once on the joined text.
New background enrichment work yields while a voice session is active.

## Try the Windows preview

Double-click `relic-voice/Try Windows Voice.cmd`. It opens Voice
settings with a separate profile at `%LOCALAPPDATA%\RelicVoicePreview`.
The first popup open offers Voice; accept it to prepare the models. A saved
answer in this preview profile is kept. The installed Relic profile is not changed. The preview stays in the tray until you quit it.

## Build

Windows, from the repository root, with Python 3.11 and Visual Studio C++ build tools:

```powershell
powershell -ExecutionPolicy Bypass -File relic-voice/build.ps1
cd app
flutter pub get
flutter build windows --release
```

The Windows CMake install step copies the built worker to `voice/` beside the
app. Windows release CI builds this bundle before Flutter. A plain source app
build remains usable without the optional worker and explains its absence in
Voice settings.

macOS (Apple Silicon), with python3, cmake and the Xcode command line tools:

```sh
relic-voice/build_macos.sh
app/scripts/build_release_macos.sh --identity "Developer ID Application: …" --notary-profile relic-notary
```

`build_macos.sh` builds the CPU-only transcribe.cpp library for arm64 and
freezes the same worker into `relic-voice/dist/relic-voice`. The release script
runs it first, copies the bundle to `Relic.app/Contents/Resources/voice`, signs
every binary inside it with `Runner/Voice.entitlements` (microphone plus the
loader relaxations a frozen Python needs under the hardened runtime), then
notarizes the DMG. `--skip-voice` builds without it. The macOS bridge is
`app/macos/Runner/Bridge/VoiceBridge.swift` (a CGEvent tap on Right Option,
which needs the Accessibility grant the paste injection already has), with the
overlay in `VoiceOverlayPanel.swift` and the gesture state machine in
`VoiceGesture.swift`, a line-for-line port of `voice_gesture.h`. For a dev
tree, `RELIC_VOICE_WORKER=/path/to/relic-voice/dist/relic-voice/relic-voice`
points `flutter run -d macos` at a bundle built here.

The model download verifies TLS through certifi when the Python build ships
no root store (the python.org build on macOS), see `model_store.tls_context`. Models are downloaded during first setup, not during the build. Automatic
setup loads the models; it does not start recording. The microphone opens only
for a recording gesture or an explicit start action.

## Test

The [Windows validation report](reports/windows-validation-2026-09-21.md) records
the completed checks and preview boundaries.

```powershell
relic-voice/.venv/Scripts/python.exe -m unittest discover -s relic-voice -p 'test_*.py' -v
cd app
flutter analyze
flutter test
```

On a Mac the same, with `relic-voice/.venv/bin/python`. The gesture port is
checked against the Windows fixture's assertions (see
`reports/macos-validation-2026-09-22.md`).

`voice_capture_test.dart` and `voice_controller_audio_test.dart` require a fresh
`RELIC_DATA_DIR` to exercise real persistence. The latter also requires
`RELIC_VOICE_FIXTURE` pointing to a consented human FLAC/WAV and verified models
in `relic-voice/test-output/r2-models`. It replaces the microphone boundary with
that recording while running the real worker protocol and CPU engine. It tests
both capture modes, save-before-insert, canceled results and disk-failure retry.

`evaluate.py` runs a manifest of human audio through the frozen worker itself.
The observed [73-clip result](reports/windows-cpu-2026-09-21.json) is 6.17% WER,
266 ms median and 619 ms p95 processing on a Ryzen 7 9800X3D. This is one speaker
reading clean speech, not representative product accuracy. It includes
punctuation and found no punctuation-induced word changes.

Native fixtures are opt-in with CMake `-DRELIC_VOICE_TESTS=ON`. Build targets
`voice_gesture_test` and `voice_native_test`; the latter needs `flutter_windows.dll`
on PATH and briefly opens its own test edit control. The shipping hook ignores
all injected input. Only the separate fixture executable accepts test-tagged
events to exercise Windows key delivery. Test binaries are never installed.

## Insertion and data

This implementation sends Unicode text directly with Windows SendInput, or
CGEvent Unicode key events on a Mac. It does not change the clipboard or
synthesize a paste chord. The original window
and focused native control must still match. Typing after stop, clicks, changed
clipboard contents, held modifiers, detected password edits, and failed or
partial injection leave the saved item available in Relic. No automatic retry
follows a partial injection. Controls that ignore Unicode input need manual Copy.
Accepted Windows events do not prove a custom editor consumed the text.

On Windows the keyboard hook runs on its own thread that does nothing else.
Windows holds every keystroke on the machine until a low-level hook answers,
so a hook on the app's main thread made typing wait whenever the app was busy.
Text goes out in batches of 32 characters. Each batch must pass through the
hook before the next one is sent. A key press, a click, or a change of window
between batches stops the rest. A Right Alt release is never hidden while
Windows thinks the key is down, so Right Alt cannot get stuck. A watchdog
reinstalls the hook if Windows drops it.

Every inserted transcript ends with one space, so the next dictation or the
next thing you type never runs into it. Only the keystrokes get that space;
the saved transcript is unchanged. Relic does not read the text around the
caret and never adds a leading space, so dictating straight after a word you
typed joins to it. An earlier build looked up the character before the caret
through Windows accessibility and tracked consecutive dictations per window;
that was removed in 1.0.50.

Voice metadata travels inside the ordinary encrypted item payload and is stored
with the item locally. Raw text is not separately indexed. Existing local data
encryption and retention behavior still apply. Known metadata is preserved when
an older payload updates a local row. An old client that has never learned the
new field can still strip it from a later upload, so complete provenance across
old-client edits is not guaranteed. The final text remains ordinary searchable
content, including through the existing CLI.

Vocabulary and corrections live in device-local `voice.json`. They apply only
to new voice sessions. Corrections never automatically learn edits in other
apps. App-scoped corrections use the foreground executable name. Preferred
spelling does not turn “clawed” into “Claude”; acoustic boosting is deferred.

Portable CPU packaging, live microphone start/cancel, R2 verification, native
edit-control insertion and real-audio save flows have automated coverage.
Edge input, textarea and contenteditable fields also passed exact-text and
clipboard-preservation checks using `node relic-voice/browser_smoke.mjs`.
Broader editor, keyboard-layout, noisy speech and multiple-speaker
acceptance remain beta compatibility testing. This branch does not publish an
installer or alter the installed Relic app.

See [the release and platform guide](RELEASE.md) for the Windows rollout steps
and the remaining macOS and Linux implementation work.
