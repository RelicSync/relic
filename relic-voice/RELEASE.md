# Relic Voice: release and platform guide

Updated 2026-09-22. Windows shipped as 1.0.49 and 1.0.50. macOS is
implemented on `feat/macos-voice` (Apple Silicon only) and validated on a Mac;
see the macOS section for what was checked. Linux Voice is planned; the
existing Relic app there still works, but does not yet include Voice.

## What this release does

- Dictate into the current input with the Voice key (Right Alt on Windows,
  Right Option on a Mac); hold/release or double-tap/tap.
- Left Ctrl + Right Alt (Control + Right Option on a Mac) saves a voice note
  directly to the vault.
- Every dictation is saved before insertion, tagged `dictation`; direct notes
  use `voice-note`. Normal promotion, search and retention apply.
- Local CPU English recognition, automatic R2 model delivery, device-local word
  corrections, a volume-reactive mark and shadow-only recording/decoding feedback.
- Voice is off until the person turns it on. The first popup open on a build
  that ships the worker shows a one-time card: Turn on voice, or Not now.
  Either answer is remembered in `voice.json` (`offered`), and the Settings
  switch works at any time. Turning it on downloads about 716 MB and loads the
  models before Voice becomes ready. That prepares Voice; it does not start a
  microphone recording.

Source map: [controller](../app/lib/data/voice_controller.dart),
[Windows bridge](../app/windows/runner/native_voice.cpp),
[macOS bridge](../app/macos/Runner/Bridge/VoiceBridge.swift), [worker](worker.py),
[model manifest](models.json), validation reports for
[Windows](reports/windows-validation-2026-09-21.md) and
[macOS](reports/macos-validation-2026-09-22.md).

## Windows: ship in this order

1. **Land the product change in the canonical public repo first.** Review the
   branch diff, stage only intended source files and sign off the commit.
   Keep generated builds, model caches, test profiles and personal audio out.
   Mirror the public commit into the private release repo, naming its SHA.
   Build the signed installer from that same source revision.
2. **The release packaging gate is in place.** The public tagged-release
   workflow installs Python 3.11 and builds Voice before Flutter.
   `app/scripts/build_release.ps1` builds the worker first, refuses to package
   if `voice/relic-voice.exe` is missing from the Flutter output, and signs
   `voice/relic-voice.exe` plus our own `_internal/native/*.dll` with the other
   first-party executables before Inno Setup. `-SkipVoice` exists only for a
   deliberately voice-less build; never use it for a release that offers Voice.
3. **Choose a new version** in `app/pubspec.yaml`, include Voice in release notes,
   and run the checks below. Windows support for this bundle is x64 with
   AVX2/FMA/F16C; do not label it Windows ARM64 or legacy-CPU compatible.
4. **Build from the release checkout.** With Python 3.11, Visual Studio C++ tools,
   Flutter, Rust and Inno Setup available, use the sequence below. Pass the
   existing signing options to the final script on the maintainer machine.
   Do not put signing material in source control.

   ```powershell
   .\app\scripts\build_release.ps1 # builds the Voice worker itself; add the signing arguments
   ```

   Check `app/build/windows/x64/runner/Release/voice/relic-voice.exe`, its native
   libraries, Python runtime and third-party notices are included recursively
   in the installer. Models remain a first-run download, not installer content.
5. **Run a clean-install and upgrade smoke test on the signed installer.** Verify
   automatic setup, an existing opt-out, download interruption/resume, offline
   behavior, microphone denial/unplug/reconnect, Right Alt and AltGr, cancellation,
   history-before-insertion, direct vault notes and clipboard preservation.
   Check PyCharm terminal, browser fields and a native edit. Measure cold setup,
   resident memory and release-to-insertion latency on a typical laptop as well
   as the development machine. Current clean-speech results are not broad accent
   or noise coverage. Verify helper signatures and clean-machine runtime loading.
6. **Publish the new versioned installer**, then verify the served bytes match
   its SHA-256. Update the private website's `website/public/latest.json` with the
   new Windows URL, version, notes and `platforms.windows.sha256`; preserve the
   existing macOS/Linux entries until those artifacts are ready. Keep the legacy
   top-level URL pointing to Windows. Deploy the website, check the in-app update
   end to end, then publish release notes and the winget update. Never overwrite
   an already published versioned installer.

For the model release, the three pinned files already live at
`https://models.relic.space/relic-voice/v1/`. Verify their sizes and SHA-256 against
`models.json` from a fresh cache before launch. Use a new versioned prefix and
manifest for future changes; keep the old objects available to older clients.

Checks from the repository root:

```powershell
relic-voice/.venv/Scripts/python.exe -m unittest discover -s relic-voice -p 'test_*.py' -v
cd app
flutter analyze
flutter test
```

Also run the environment-gated real-audio/controller and persistence tests with
an isolated `RELIC_DATA_DIR` and consented human `RELIC_VOICE_FIXTURE`, plus the
native fixture built with `RELIC_VOICE_TESTS=ON`; see [README](README.md#test).
Default/upgrade checks live in `voice_defaults_test.dart`. Do not treat a skipped
hardware or real-audio check as passed. Keep test executables out of the package.

Rollback: remove the faulty artifact from update promotion and ship a higher
patch version with the fix or default disabled. Preserve users' vaults and Voice
preferences. Users can turn Voice off immediately in Settings. Never change the
bytes at an existing installer or model URL to implement rollback.

## macOS: what shipped and how to release it

The controller, persistence, corrections, model manifest and worker protocol
are shared. The platform checks became one capability,
`VoiceController.supported` (Windows and macOS), with the key names coming
from `VoiceController.keyLabel` and `modifierLabel`.

- **Worker.** `build_macos.sh` builds transcribe.cpp for arm64, CPU only
  (Metal off, `GGML_NATIVE` off) and freezes the same `worker.py` with the
  python.org Python 3.13, ONNX Runtime, sounddevice/PortAudio and
  sentencepiece. `engine.py` loads `libtranscribe.dylib` from `native/`. The
  model bytes are the Windows ones; the arm64 build's output on the same clip
  matches (see the report). Intel Macs are not supported and get no worker.
- **Bridge.** `VoiceBridge.swift` owns a CGEvent tap on the Right Option key
  (`kVK_RightOption`), the 20 ms gesture timer, the focused-target snapshot
  (frontmost app plus the AX focused element, secure fields refused), the
  clipboard and modifier checks, Unicode key-event insertion with the
  trailing space, the overlay and sleep/lock cancellation. Only Right Option's
  own flagsChanged events are swallowed, and only while a gesture owns them;
  a key pressed with Option held reaches the app with the Option flag, so
  Option-character entry works as before and the gesture forwards. The tap
  needs Accessibility, which Relic already asks for; without it `enable`
  answers false and Voice settings says the shortcut is unavailable.
- **Microphone.** Asked for when Voice is turned on (`microphone` /
  `requestMicrophone` on the channel), so the system prompt arrives then and
  not mid-sentence. `NSMicrophoneUsageDescription` is in Info.plist and
  `com.apple.security.device.audio-input` in the app entitlements. A denied
  or restricted answer keeps Voice off with an "Open Microphone settings"
  button. The worker records as a child of the app, so the grant is the
  app's.
- **Signing.** `build_release_macos.sh` runs `build_macos.sh` first, copies
  the bundle to `Contents/Resources/voice`, signs every Mach-O inside it, then
  the worker with `Runner/Voice.entitlements` (microphone,
  disable-library-validation, allow-unsigned-executable-memory,
  allow-dyld-environment-variables), then the app, then notarizes the DMG.
  `--skip-voice` is only for a deliberately voice-less build.
- **Release.** Same choreography as any macOS release: build from the tag,
  R2 at a new versioned key, `latest.json` `platforms.macos`, cask, parity
  doc. The 716 MB model download is unchanged and shared with Windows.

## Linux: separate X11 and Wayland acceptance

Build an x86_64 CPU worker with Linux `.so` loading and bundled runtime dependencies;
use the same protocol and R2 model checks. Extend
`app/scripts/build_release_linux.sh`, the AppImage packaging and the release CI.
Test microphone capture/device changes on the audio stacks actually supported.

- **X11:** integrate the Voice bridge with `app/linux/runner/my_application.cc`
  and existing `hotkeys.cc`/`window_focus.cc`. Implement hold/latch semantics,
  target validation, Unicode insertion and the nonactivating popup. Test AltGr,
  layout changes, terminals and multiple monitors; do not assume a Windows
  SendInput equivalent covers Unicode and selection semantics.
- **Wayland:** implement a separate capability/permission path. Investigate the
  [GlobalShortcuts portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html)
  for registered actions and activation/deactivation signals, and the
  [RemoteDesktop portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html)
  for authorized input injection. Shortcut binding may show a user configuration
  dialog. Validate actual backend support, grant persistence, key release events
  and Unicode delivery on GNOME and KDE; a modifier-only Right Alt gesture and
  arbitrary focused-text access are not established by these APIs alone.
- If the desktop cannot support global insertion, keep direct vault notes and
  explicit Copy usable and explain the missing capability. Do not claim
  dictate-anywhere support on an unvalidated compositor.

Offer Voice on each port only once its shipped worker, first-run
setup and native capabilities pass the same clean-install, upgrade, cancellation,
real-audio, focus, clipboard and UI checks as Windows. Recording must remain an
explicit user action. Suggested order: Windows release, macOS, Linux X11,
then verified Wayland support.
