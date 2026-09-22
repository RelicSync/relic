# macOS Voice validation

Validated on an Apple Silicon Mac (M5 Pro, macOS 26.5.1, Xcode 26.6) on
2026-09-22, from the `feat/macos-voice` branch. The worker is the Windows one
frozen for arm64; the bridge is new Swift. No installer was published from
this branch.

## Worker

- transcribe.cpp at the pinned revision built as a CPU-only arm64 shared
  library (Metal, Accelerate, OpenMP and machine-native tuning all off). The
  four dylibs (transcribe, ggml, ggml-base, ggml-cpu) are gathered into
  `native/` with `@loader_path` rpaths; `engine.py` loads
  `native/libtranscribe.dylib` by explicit path.
- The same three model files as Windows (715,727,326 bytes) downloaded from
  `https://models.relic.space/relic-voice/v1/` into a fresh cache through the
  worker's own `ensure_models`, every file matching its byte count and
  SHA-256. The python.org Python 3.13 the bundle carries has no root store,
  so the download now runs with a verified TLS context backed by certifi
  (`model_store.tls_context`); the Windows path is unchanged.
- A 7.3 s spoken clip (macOS `say`, converted to 16 kHz mono) through the
  unfrozen worker and again through the frozen bundle: identical output,
  every word right, 181 ms recognition and 5 ms formatting on four CPU
  threads (`processing_ms` 186). Model loading is the same cost as Windows.
- The frozen bundle (`relic-voice/dist/relic-voice`, 114 MB, PyInstaller
  6.16 onedir, Python 3.13.13, numpy 2.2.6, onnxruntime 1.22.1, sounddevice
  0.5.5, sentencepiece 0.2.1) says `hello` on protocol 1 / backend `cpu`,
  loads the cached models, and lists `System default microphone` plus the
  MacBook Pro microphone through PortAudio (Core Audio).
- The nine Python worker tests (corrections, model delivery) pass on the
  Mac with the venv Python. The 17-test discover run reports one skip (a
  Windows-only resample fixture).

## App and gesture

- `VoiceGesture.swift` is a line-for-line port of `voice_gesture.h`; a
  Swift copy of the Windows fixture's assertions (`voice_gesture_test.cpp`,
  hold/latch timing, Left Ctrl mode, double-tap, forwarding, expired tap
  replay, chord interruption) passes unchanged.
- Strict `flutter analyze` is clean. The full Flutter suite on the Mac:
  934 passed, 72 environment-gated skips. The five Voice test files, run
  with an isolated `RELIC_DATA_DIR`: 9 passed, including the persistence
  cases in `voice_defaults_test.dart` now that it accepts macOS.
- `flutter build macos --release` compiles the three new bridge files from
  the Xcode project; the signed release build signs 522 files inside
  `Contents/Resources/voice` and the app verifies `--deep --strict`.

## Live checks on this Mac

Filled in below from the signed build launched in a sandbox data dir
(`RELIC_DATA_DIR`) with Voice already on and the models pre-cached.

- The signed app (Developer ID, hardened runtime, the worker under
  `Contents/Resources/voice` with `Voice.entitlements`) launched from a
  fresh `RELIC_DATA_DIR` with `voice.json` already on. The worker started
  as a child of the app, loaded the cached models and reported Ready; no
  microphone prompt was needed on this Mac because the bundle id already
  held the grant.
- Right Option held for nine seconds (a CGEvent press with the right-side
  device flag, exactly what the keyboard sends) while the spoken clip played
  through the speakers, then released, with a fresh TextEdit document
  frontmost. The pulsing mark showed at the bottom centre of the screen
  while recording. On release the transcript was saved to history first
  (tags `dictation` and `textedit`, the source-app key from the bridge's
  `appKey`) and then typed into TextEdit as Unicode key events with the
  trailing space: `The quick brown fox jumps over the lazy dog 1st. `. The
  clipboard was untouched.
- The same run with the speakers muted saved a nine-second recording of
  room silence as `Thank you.` and inserted it: the whole path works on
  silence too, and the model's silence habit is the same as on Windows.
- Words the built-in microphone missed from the speaker playback are a
  fact about playing audio at a laptop, not about the worker: the same clip
  fed to the worker directly transcribes in full (see Worker above).

## Boundaries

Apple Silicon only, English, one recording at a time, 60-second limit.
Audio stays in memory. The tap and the AX focus read need the Accessibility
grant; without it `enable` answers false, the shortcut is reported
unavailable and the menu-bar starts still work. Intel Macs get no worker
and Voice settings says the build has no Voice. Insertion is Unicode key
events; editors that reject those need manual Copy from Relic. Broader
accent, noise and editor coverage is the same open item as on Windows.
