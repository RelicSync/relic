import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Windows backend of platform/foreground_app.dart: which application owns the
/// foreground window right now, read via GetForegroundWindow +
/// QueryFullProcessImageName. Windows-only.

/// Lowercased executable stem of the current foreground window's process
/// ("chrome", "code", "slack"), or null when it can't be determined.
String? foregroundAppExe() {
  if (!Platform.isWindows) return null;
  try {
    final hwnd = GetForegroundWindow();
    if (hwnd == 0) return null;
    final pid = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(hwnd, pid);
      if (pid.value == 0) return null;
      // 0x1000 = PROCESS_QUERY_LIMITED_INFORMATION
      final h = OpenProcess(0x1000, FALSE, pid.value);
      if (h == 0) return null;
      final buf = wsalloc(MAX_PATH);
      final size = calloc<Uint32>()..value = MAX_PATH;
      try {
        if (QueryFullProcessImageName(h, 0, buf, size) == 0) return null;
        final path = buf.toDartString();
        final base = path.split(RegExp(r'[\\/]')).last.toLowerCase();
        return base.endsWith('.exe')
            ? base.substring(0, base.length - 4)
            : base;
      } finally {
        free(buf);
        free(size);
        CloseHandle(h);
      }
    } finally {
      free(pid);
    }
  } catch (_) {
    return null; // attribution is best-effort, never break capture
  }
}

/// The focused control's text caret, in PHYSICAL screen pixels, as
/// `[x, y]` at the caret's bottom-left. Returns null when there is no reliable
/// caret: GetGUIThreadInfo only reports one for standard Win32/edit controls,
/// so Chromium/Electron apps (VS Code, Slack, Chrome) and many custom editors
/// come back empty. Callers fall back to the mouse. Best-effort, never throws.
List<double>? caretScreenPointPhysical() {
  if (!Platform.isWindows) return null;
  try {
    final hwnd = GetForegroundWindow();
    if (hwnd == 0) return null;
    final tid = GetWindowThreadProcessId(hwnd, nullptr);
    if (tid == 0) return null;
    final info = calloc<GUITHREADINFO>();
    try {
      info.ref.cbSize = sizeOf<GUITHREADINFO>();
      if (GetGUIThreadInfo(tid, info) == 0) return null;
      final caretHwnd = info.ref.hwndCaret;
      if (caretHwnd == 0) return null;
      final r = info.ref.rcCaret;
      // An empty caret rect means "no real caret" (common in web views).
      if ((r.right - r.left) == 0 && (r.bottom - r.top) == 0) return null;
      // rcCaret is client-space of hwndCaret; map its bottom-left to screen.
      final p = calloc<POINT>()
        ..ref.x = r.left
        ..ref.y = r.bottom;
      try {
        if (ClientToScreen(caretHwnd, p) == 0) return null;
        return [p.ref.x.toDouble(), p.ref.y.toDouble()];
      } finally {
        free(p);
      }
    } finally {
      free(info);
    }
  } catch (_) {
    return null;
  }
}

/// The mouse cursor in PHYSICAL screen pixels as `[x, y]`, or null. Used with a
/// logical cursor read to derive the effective scale for caret placement.
List<double>? cursorScreenPointPhysical() {
  if (!Platform.isWindows) return null;
  try {
    final p = calloc<POINT>();
    try {
      if (GetCursorPos(p) == 0) return null;
      return [p.ref.x.toDouble(), p.ref.y.toDouble()];
    } finally {
      free(p);
    }
  } catch (_) {
    return null;
  }
}
