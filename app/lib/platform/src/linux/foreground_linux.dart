import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// X11 window attribution for Linux: the active window's WM_CLASS (feeding
/// `foregroundAppKey`) and the `_NET_CLIENT_LIST` walk (feeding the blocklist
/// picker), both over libX11 FFI — the first `DynamicLibrary.open` in the
/// tree, so the conventions are spelled out:
///
///   - Every public function self-guards (`Platform.isLinux`, Wayland, no
///     libX11) and returns a benign empty result; attribution is
///     best-effort, never break capture — same contract as foreground_win.
///   - A no-op X error handler is installed before the first request: the
///     default handler EXITS the process, and a window closing between the
///     client-list read and its property reads would otherwise kill us.
///   - Wayland sessions (WAYLAND_DISPLAY set, including WSLg) get null/empty
///     outright: XWayland only sees X clients, so its answers would be
///     confidently wrong about native-Wayland windows. Entries just get no
///     source tag there, and the blocklist picker stays empty.
///
/// Key derivation from the raw WM_CLASS lives in foreground_app.dart's
/// [linuxAppKey] (pure, tested from any host), NOT here.

typedef WmClass = ({String instance, String klass});
typedef X11Window = ({String instance, String klass, String title});

// -- library + error handler ------------------------------------------------

DynamicLibrary? _lib;
bool _libTried = false;

DynamicLibrary? _x11() {
  if (_libTried) return _lib;
  _libTried = true;
  try {
    _lib = DynamicLibrary.open('libX11.so.6');
    // Default X error handler exits the process; BadWindow is routine when a
    // window dies between enumeration and its property read.
    final setHandler = _lib!.lookupFunction<
        Pointer<Void> Function(
            Pointer<NativeFunction<Int32 Function(Pointer<Void>, Pointer<Void>)>>),
        Pointer<Void> Function(
            Pointer<NativeFunction<Int32 Function(Pointer<Void>, Pointer<Void>)>>)>(
      'XSetErrorHandler');
    setHandler(Pointer.fromFunction<Int32 Function(Pointer<Void>, Pointer<Void>)>(
        _ignoreXError, 0));
  } catch (_) {
    _lib = null;
  }
  return _lib;
}

int _ignoreXError(Pointer<Void> display, Pointer<Void> event) => 0;

bool get _waylandSession {
  final w = Platform.environment['WAYLAND_DISPLAY'];
  return w != null && w.isNotEmpty;
}

// -- thin bindings ----------------------------------------------------------

Pointer<Void> _openDisplay(DynamicLibrary lib) => lib.lookupFunction<
    Pointer<Void> Function(Pointer<Utf8>),
    Pointer<Void> Function(Pointer<Utf8>)>('XOpenDisplay')(nullptr);

void _closeDisplay(DynamicLibrary lib, Pointer<Void> dpy) => lib.lookupFunction<
    Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'XCloseDisplay')(dpy);

int _rootWindow(DynamicLibrary lib, Pointer<Void> dpy) => lib.lookupFunction<
    UnsignedLong Function(Pointer<Void>),
    int Function(Pointer<Void>)>('XDefaultRootWindow')(dpy);

int _atom(DynamicLibrary lib, Pointer<Void> dpy, String name) {
  final p = name.toNativeUtf8();
  try {
    return lib.lookupFunction<
        UnsignedLong Function(Pointer<Void>, Pointer<Utf8>, Int32),
        int Function(Pointer<Void>, Pointer<Utf8>, int)>(
            'XInternAtom')(dpy, p, 0);
  } finally {
    calloc.free(p);
  }
}

typedef _GetPropC = Int32 Function(
    Pointer<Void>, UnsignedLong, UnsignedLong, Long, Long, Int32, UnsignedLong,
    Pointer<UnsignedLong>, Pointer<Int32>, Pointer<UnsignedLong>,
    Pointer<UnsignedLong>, Pointer<Pointer<Uint8>>);
typedef _GetPropD = int Function(
    Pointer<Void>, int, int, int, int, int, int, Pointer<UnsignedLong>,
    Pointer<Int32>, Pointer<UnsignedLong>, Pointer<UnsignedLong>,
    Pointer<Pointer<Uint8>>);

/// One XGetWindowProperty round trip. Returns the property's items as either
/// a byte list (format 8) or an int list (format 32 — stored by Xlib as one
/// C long PER 32-bit item on 64-bit, hence the UnsignedLong read), null when
/// absent. AnyPropertyType keeps it lenient about STRING vs UTF8_STRING.
({Uint8List? bytes, List<int>? words})? _getProp(
    DynamicLibrary lib, Pointer<Void> dpy, int window, int property) {
  final get = lib.lookupFunction<_GetPropC, _GetPropD>('XGetWindowProperty');
  final xfree = lib.lookupFunction<Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('XFree');
  final actualType = calloc<UnsignedLong>();
  final actualFormat = calloc<Int32>();
  final nitems = calloc<UnsignedLong>();
  final bytesAfter = calloc<UnsignedLong>();
  final prop = calloc<Pointer<Uint8>>();
  try {
    // 4096 longwords = 16 KB — plenty for names, classes, client lists.
    final status = get(dpy, window, property, 0, 4096, 0, 0 /* AnyPropertyType */,
        actualType, actualFormat, nitems, bytesAfter, prop);
    if (status != 0 /* Success */ || prop.value == nullptr) return null;
    try {
      final n = nitems.value;
      if (n == 0) return (bytes: Uint8List(0), words: const <int>[]);
      switch (actualFormat.value) {
        case 8:
          return (bytes: Uint8List.fromList(prop.value.asTypedList(n)),
              words: null);
        case 32:
          final longs = prop.value.cast<UnsignedLong>();
          return (bytes: null,
              words: [for (var i = 0; i < n; i++) longs[i] & 0xFFFFFFFF]);
        default:
          return null;
      }
    } finally {
      xfree(prop.value.cast());
    }
  } finally {
    calloc.free(actualType);
    calloc.free(actualFormat);
    calloc.free(nitems);
    calloc.free(bytesAfter);
    calloc.free(prop);
  }
}

// -- property readers -------------------------------------------------------

/// WM_CLASS is two null-terminated strings back to back: instance, class.
WmClass? _wmClassOf(DynamicLibrary lib, Pointer<Void> dpy, int window) {
  final raw = _getProp(lib, dpy, window, 67 /* XA_WM_CLASS */)?.bytes;
  if (raw == null || raw.isEmpty) return null;
  final parts = String.fromCharCodes(raw)
      .split('\x00')
      .where((s) => s.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  return (instance: parts[0], klass: parts.length > 1 ? parts[1] : parts[0]);
}

String _titleOf(DynamicLibrary lib, Pointer<Void> dpy, int window,
    int netWmName) {
  for (final atom in [netWmName, 39 /* XA_WM_NAME */]) {
    final raw = _getProp(lib, dpy, window, atom)?.bytes;
    if (raw != null && raw.isNotEmpty) {
      try {
        return String.fromCharCodes(raw); // UTF8_STRING decodes fine per-byte
      } catch (_) {}
    }
  }
  return '';
}

// -- public surface ---------------------------------------------------------

/// The active window's WM_CLASS, or null (Wayland, no X server, no active
/// window, error). Synchronous like the Windows read; a handful of X round
/// trips per capture event.
WmClass? foregroundWmClass() {
  if (!Platform.isLinux || _waylandSession) return null;
  final lib = _x11();
  if (lib == null) return null;
  try {
    final dpy = _openDisplay(lib);
    if (dpy == nullptr) return null;
    try {
      final active = _getProp(lib, dpy, _rootWindow(lib, dpy),
          _atom(lib, dpy, '_NET_ACTIVE_WINDOW'))?.words;
      if (active == null || active.isEmpty || active[0] == 0) return null;
      return _wmClassOf(lib, dpy, active[0]);
    } finally {
      _closeDisplay(lib, dpy);
    }
  } catch (_) {
    return null; // attribution is best-effort, never break capture
  }
}

/// Every managed top-level window per `_NET_CLIENT_LIST`, with WM_CLASS and
/// a best-effort title. Empty on Wayland / no X / errors. The facade derives
/// keys, filters noise and dedupes — same split as the macOS backend.
List<X11Window> runningX11Windows() {
  if (!Platform.isLinux || _waylandSession) return const [];
  final lib = _x11();
  if (lib == null) return const [];
  try {
    final dpy = _openDisplay(lib);
    if (dpy == nullptr) return const [];
    try {
      final root = _rootWindow(lib, dpy);
      final list = _getProp(lib, dpy, root,
          _atom(lib, dpy, '_NET_CLIENT_LIST'))?.words;
      if (list == null || list.isEmpty) return const [];
      final netWmName = _atom(lib, dpy, '_NET_WM_NAME');
      final out = <X11Window>[];
      for (final w in list) {
        final c = _wmClassOf(lib, dpy, w);
        if (c == null) continue; // one bad window must not stop the walk
        out.add((instance: c.instance, klass: c.klass,
            title: _titleOf(lib, dpy, w, netWmName)));
      }
      return out;
    } finally {
      _closeDisplay(lib, dpy);
    }
  } catch (_) {
    return const [];
  }
}
