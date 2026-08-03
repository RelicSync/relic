import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Windows backend of platform/running_apps.dart: the applications the user
/// currently has open, for the capture-blocklist picker. One entry per
/// executable, keyed by the SAME lowercase exe stem the watcher gate compares
/// against (foreground_win.dart), so a picked entry always matches at
/// capture time.

typedef RunningWinApp = ({String key, String title});

// EnumWindows takes a C callback, so the accumulator has to be module state;
// enumeration is synchronous and single-threaded, so this never races.
final List<RunningWinApp> _acc = [];
final Set<String> _seenKeys = {};
int _selfPid = 0;

/// Executables the user actually has on screen: top-level, visible, unowned,
/// titled, non-cloaked windows, deduped by exe stem and sorted by stem.
/// Best-effort; returns [] on any failure.
List<RunningWinApp> runningWinApps() {
  if (!Platform.isWindows) return const [];
  try {
    _acc.clear();
    _seenKeys.clear();
    _selfPid = GetCurrentProcessId();
    EnumWindows(Pointer.fromFunction<WNDENUMPROC>(_onWindow, TRUE), 0);
    final out = List<RunningWinApp>.of(_acc)
      ..sort((a, b) => a.key.compareTo(b.key));
    _acc.clear();
    _seenKeys.clear();
    return out;
  } catch (_) {
    return const [];
  }
}

int _onWindow(int hwnd, int lparam) {
  try {
    if (IsWindowVisible(hwnd) == 0) return TRUE;
    // Owned windows are dialogs/palettes; the owner shows up on its own.
    if (GetWindow(hwnd, GW_OWNER) != 0) return TRUE;
    if (GetWindowLongPtr(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW != 0) {
      return TRUE;
    }
    // UWP leaves invisible "cloaked" frames for suspended apps; DWM knows.
    final cloaked = calloc<Uint32>();
    try {
      final hr = DwmGetWindowAttribute(
          hwnd, DWMWA_CLOAKED, cloaked.cast(), sizeOf<Uint32>());
      if (hr == 0 && cloaked.value != 0) return TRUE;
    } finally {
      free(cloaked);
    }
    final titleLen = GetWindowTextLength(hwnd);
    if (titleLen == 0) return TRUE;
    String title;
    final tbuf = wsalloc(titleLen + 1);
    try {
      GetWindowText(hwnd, tbuf, titleLen + 1);
      title = tbuf.toDartString().trim();
    } finally {
      free(tbuf);
    }
    if (title.isEmpty) return TRUE;
    final pid = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(hwnd, pid);
      if (pid.value == 0 || pid.value == _selfPid) return TRUE;
      final key = _exeStemOfPid(pid.value);
      if (key == null || key.isEmpty) return TRUE;
      if (_seenKeys.add(key)) _acc.add((key: key, title: title));
    } finally {
      free(pid);
    }
  } catch (_) {
    // one bad window must not stop the walk
  }
  return TRUE;
}

/// Lowercased exe stem for a pid — the same derivation as
/// foreground_win.dart's foregroundAppExe, so blocklist entries line up.
String? _exeStemOfPid(int pid) {
  // 0x1000 = PROCESS_QUERY_LIMITED_INFORMATION
  final h = OpenProcess(0x1000, FALSE, pid);
  if (h == 0) return null;
  final buf = wsalloc(MAX_PATH);
  final size = calloc<Uint32>()..value = MAX_PATH;
  try {
    if (QueryFullProcessImageName(h, 0, buf, size) == 0) return null;
    final base = buf.toDartString().split(RegExp(r'[\\/]')).last.toLowerCase();
    return base.endsWith('.exe') ? base.substring(0, base.length - 4) : base;
  } finally {
    free(buf);
    free(size);
    CloseHandle(h);
  }
}
