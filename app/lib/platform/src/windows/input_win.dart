import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Windows backends for platform/input_injector.dart, platform/sound.dart and
/// platform/login_item.dart: synthetic paste/copy (SendInput), the promotion
/// sound (PlaySound) and run-at-login (HKCU Run key). Windows-only.

const _vkControl = 0x11; // VK_CONTROL
const _vkV = 0x56; // 'V'

void _sendKey(int vk, int flags) {
  final p = calloc<INPUT>();
  try {
    p.ref.type = INPUT_KEYBOARD;
    p.ref.Anonymous.ki.wVk = vk;
    p.ref.Anonymous.ki.dwFlags = flags;
    SendInput(1, p, sizeOf<INPUT>());
  } finally {
    calloc.free(p);
  }
}

/// Synthesize Ctrl+V into the frontmost application. Used by "paste directly on
/// select": our window has already hidden, so the keystroke lands in whatever
/// app the user was in. Best-effort; failures are silent.
void sendPaste() {
  try {
    _sendKey(_vkControl, 0);
    _sendKey(_vkV, 0);
    _sendKey(_vkV, KEYEVENTF_KEYUP);
    _sendKey(_vkControl, KEYEVENTF_KEYUP);
  } catch (_) {}
}

const _vkC = 0x43; // 'C'
const _vkShift = 0x10; // VK_SHIFT
const _vkAlt = 0x12; // VK_MENU
const _vkLWin = 0x5B;
const _vkRWin = 0x5C;

bool _isDown(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;

/// Synthesize Ctrl+C into the frontmost application, SAFELY from inside a
/// global-hotkey handler: when the handler fires the user is still physically
/// holding the chord's modifiers (Ctrl+Alt+…), and a naive Ctrl+C synthesis
/// would land as Ctrl+Alt+C — a dead chord in most apps, or on layouts where
/// Ctrl+Alt = AltGr, a character INSERTED into the user's document.
///
/// Strategy: wait briefly for Alt/Shift/Win to be released (a normal hotkey
/// tap clears within ~100ms, so the common case adds no latency). If they're
/// still held after the timeout, inject KEYUPs — with Ctrl already down FIRST
/// so the lone Alt-up can't trigger the target app's menu bar (the classic
/// menu-mask ordering). Best-effort; failures are silent.
Future<void> sendCopyChordSafe() async {
  try {
    for (var i = 0; i < 15; i++) {
      if (!_isDown(_vkAlt) &&
          !_isDown(_vkShift) &&
          !_isDown(_vkLWin) &&
          !_isDown(_vkRWin)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // Ctrl down first: it doubles as the menu-mask if we must force Alt up.
    _sendKey(_vkControl, 0);
    for (final vk in [_vkAlt, _vkShift, _vkLWin, _vkRWin]) {
      if (_isDown(vk)) _sendKey(vk, KEYEVENTF_KEYUP);
    }
    _sendKey(_vkC, 0);
    _sendKey(_vkC, KEYEVENTF_KEYUP);
    _sendKey(_vkControl, KEYEVENTF_KEYUP);
  } catch (_) {}
}

/// Synthesize Ctrl+V into the frontmost application, SAFELY from inside a
/// global-hotkey handler — the "paste latest" hotkey. Mirrors
/// [sendCopyChordSafe]: when the handler fires the user is still physically
/// holding the chord (Ctrl+Shift+R), so a naive Ctrl+V would land as
/// Ctrl+Shift+V (paste-without-formatting in some apps, a dead chord in
/// others). Wait briefly for Alt/Shift/Win to clear, then inject KEYUPs for
/// any still held — Ctrl DOWN first (it doubles as the menu-mask and is the
/// modifier we actually want held for the paste). Best-effort; silent on
/// failure.
Future<void> sendPasteChordSafe() async {
  try {
    for (var i = 0; i < 15; i++) {
      if (!_isDown(_vkAlt) &&
          !_isDown(_vkShift) &&
          !_isDown(_vkLWin) &&
          !_isDown(_vkRWin)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    _sendKey(_vkControl, 0);
    for (final vk in [_vkAlt, _vkShift, _vkLWin, _vkRWin]) {
      if (_isDown(vk)) _sendKey(vk, KEYEVENTF_KEYUP);
    }
    _sendKey(_vkV, 0);
    _sendKey(_vkV, KEYEVENTF_KEYUP);
    _sendKey(_vkControl, KEYEVENTF_KEYUP);
  } catch (_) {}
}

File _bundledSound(String relPath) {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final sep = Platform.pathSeparator;
  final parts = relPath.split('/');
  return File([exeDir, 'data', 'flutter_assets', ...parts].join(sep));
}

/// Play Relic's bundled promotion sound. Best-effort, async, no fallback beep.
bool playPromotionSound() {
  if (!Platform.isWindows) return false;
  final wav = _bundledSound('assets/sounds/relic-sound.wav');
  if (!wav.existsSync()) return false;
  final path = wav.path.toNativeUtf16();
  try {
    return PlaySound(path, 0, SND_FILENAME | SND_ASYNC | SND_NODEFAULT) != 0;
  } catch (_) {
    return false;
  } finally {
    calloc.free(path);
  }
}

// --- run at login: HKCU\...\Run value pointing at our exe ---

const _runSubKey = r'Software\Microsoft\Windows\CurrentVersion\Run';
const _runValueName = 'Relic';

/// Enable or disable launching Relic when the user signs in, by writing/clearing
/// our entry under the per-user Run key. Returns whether the change stuck.
bool setLaunchAtStartup(bool enable) {
  // A sandboxed instance (RELIC_DATA_DIR set) must never touch the real
  // user's autostart — same namespacing rule as WindowsSecureStore._target.
  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  if (sandbox != null && sandbox.isNotEmpty) return false;
  final subKey = _runSubKey.toNativeUtf16();
  final valueName = _runValueName.toNativeUtf16();
  final phKey = calloc<IntPtr>();
  try {
    final opened = RegOpenKeyEx(
      HKEY_CURRENT_USER,
      subKey,
      0,
      KEY_SET_VALUE | KEY_QUERY_VALUE,
      phKey,
    );
    if (opened != ERROR_SUCCESS) return false;
    final hKey = phKey.value;
    try {
      if (enable) {
        // quote the path so a Program Files space doesn't break the command,
        // and pass --autostart so the login launch settles straight into the
        // tray instead of surfacing a window (see RealApp.autostart).
        final cmd = '"${Platform.resolvedExecutable}" --autostart';
        final data = cmd.toNativeUtf16();
        try {
          final cbData = (cmd.length + 1) * 2; // bytes incl. null terminator
          final r = RegSetValueEx(
            hKey,
            valueName,
            0,
            REG_SZ,
            data.cast<Uint8>(),
            cbData,
          );
          return r == ERROR_SUCCESS;
        } finally {
          calloc.free(data);
        }
      } else {
        final r = RegDeleteValue(hKey, valueName);
        return r == ERROR_SUCCESS || r == ERROR_FILE_NOT_FOUND;
      }
    } finally {
      RegCloseKey(hKey);
    }
  } catch (_) {
    return false;
  } finally {
    calloc.free(subKey);
    calloc.free(valueName);
    calloc.free(phKey);
  }
}

/// The exe path currently registered under our Run value (quotes stripped),
/// or null when absent. Lets startup tell "our entry" from another copy's
/// registration before deciding whether to (re)claim it.
String? launchAtStartupCommand() {
  if (!Platform.isWindows) return null;
  final subKey = _runSubKey.toNativeUtf16();
  final valueName = _runValueName.toNativeUtf16();
  final data = wsalloc(1024);
  final cbData = calloc<Uint32>()..value = 1024 * 2;
  try {
    final r = RegGetValue(
      HKEY_CURRENT_USER,
      subKey,
      valueName,
      RRF_RT_REG_SZ,
      nullptr,
      data.cast(),
      cbData,
    );
    if (r != ERROR_SUCCESS) return null;
    // The value is `"<exe>" [--flags]`. Return just the exe path so the caller
    // can compare it against resolvedExecutable regardless of the autostart
    // flag (added by setLaunchAtStartup).
    final raw = data.toDartString().trim();
    if (raw.isEmpty) return null;
    String exe;
    if (raw.startsWith('"')) {
      final end = raw.indexOf('"', 1);
      exe = end > 1 ? raw.substring(1, end) : raw.replaceAll('"', '');
    } else {
      final sp = raw.indexOf(' ');
      exe = sp >= 0 ? raw.substring(0, sp) : raw;
    }
    exe = exe.trim();
    return exe.isEmpty ? null : exe;
  } catch (_) {
    return null;
  } finally {
    free(subKey);
    free(valueName);
    free(data);
    free(cbData);
  }
}

/// Whether our Run entry is present AND already carries the `--autostart`
/// flag. False when the value is absent or is the older bare-exe form, so
/// startup can migrate an existing entry in place (add the flag) without
/// otherwise disturbing the anti-hijack ownership rules.
bool launchAtStartupHasAutostart() {
  final subKey = _runSubKey.toNativeUtf16();
  final valueName = _runValueName.toNativeUtf16();
  final data = wsalloc(1024);
  final cbData = calloc<Uint32>()..value = 1024 * 2;
  try {
    final r = RegGetValue(
      HKEY_CURRENT_USER,
      subKey,
      valueName,
      RRF_RT_REG_SZ,
      nullptr,
      data.cast(),
      cbData,
    );
    if (r != ERROR_SUCCESS) return false;
    return data.toDartString().contains('--autostart');
  } catch (_) {
    return false;
  } finally {
    free(subKey);
    free(valueName);
    free(data);
    free(cbData);
  }
}

/// Whether our Run entry is currently present.
bool isLaunchAtStartupEnabled() {
  final subKey = _runSubKey.toNativeUtf16();
  final valueName = _runValueName.toNativeUtf16();
  final phKey = calloc<IntPtr>();
  try {
    if (RegOpenKeyEx(HKEY_CURRENT_USER, subKey, 0, KEY_QUERY_VALUE, phKey) !=
        ERROR_SUCCESS) {
      return false;
    }
    final hKey = phKey.value;
    try {
      final r = RegQueryValueEx(
        hKey,
        valueName,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
      );
      return r == ERROR_SUCCESS;
    } finally {
      RegCloseKey(hKey);
    }
  } catch (_) {
    return false;
  } finally {
    calloc.free(subKey);
    calloc.free(valueName);
    calloc.free(phKey);
  }
}
