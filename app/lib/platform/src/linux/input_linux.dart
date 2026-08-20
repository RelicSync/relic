import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import '../../foreground_app.dart' show waylandSessionFrom;

/// Synthetic keystrokes on X11, via the XTEST extension (libXtst) over FFI —
/// the same house rules as foreground_linux.dart: self-guarding, never throws,
/// benign result when anything is missing.
///
/// Wayland has no equivalent: injection there needs uinput access (ydotool and
/// a privileged daemon), which Relic will not require. [injectionAvailable]
/// answers false in a Wayland session, and the caller falls back to the
/// copy-only path it already uses when macOS withholds the Accessibility
/// grant ("copied — press Ctrl+V"), so the degradation is a path that is
/// already tested rather than new UX.
///
/// This file opens its own Display connection per call, exactly like
/// foreground_linux.dart. A shared handle would be wrong: Xlib is not
/// thread-safe without XInitThreads, injection can run while attribution is
/// mid-read, and a stale handle would wedge both after an X server restart.

// X11 keysyms we synthesize. From keysymdef.h.
const int _xkControlL = 0xffe3;
const int _xkShiftL = 0xffe1;
const int _xkV = 0x0076; // 'v'
const int _xkC = 0x0063; // 'c'

DynamicLibrary? _x11;
DynamicLibrary? _xtst;
bool _tried = false;

void _load() {
  if (_tried) return;
  _tried = true;
  try {
    _x11 = DynamicLibrary.open('libX11.so.6');
    _xtst = DynamicLibrary.open('libXtst.so.6');
  } catch (_) {
    _x11 = null;
    _xtst = null;
  }
}

Pointer<Void> _open(DynamicLibrary lib) => lib.lookupFunction<
    Pointer<Void> Function(Pointer<Utf8>),
    Pointer<Void> Function(Pointer<Utf8>)>('XOpenDisplay')(nullptr);

void _close(DynamicLibrary lib, Pointer<Void> dpy) => lib.lookupFunction<
    Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'XCloseDisplay')(dpy);

void _flush(DynamicLibrary lib, Pointer<Void> dpy) => lib.lookupFunction<
    Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('XFlush')(dpy);

int _keycodeOf(DynamicLibrary lib, Pointer<Void> dpy, int keysym) =>
    lib.lookupFunction<Uint8 Function(Pointer<Void>, UnsignedLong),
        int Function(Pointer<Void>, int)>('XKeysymToKeycode')(dpy, keysym);

void _fakeKey(DynamicLibrary xtst, Pointer<Void> dpy, int keycode, bool down) =>
    xtst.lookupFunction<
        Int32 Function(Pointer<Void>, UnsignedInt, Int32, UnsignedLong),
        int Function(Pointer<Void>, int, int, int)>('XTestFakeKeyEvent')(
      dpy, keycode, down ? 1 : 0, 0 /* CurrentTime */,
    );

/// True when XTEST is usable right now: X11 session, both libraries present,
/// and the server actually advertises the extension.
bool injectionAvailable() {
  if (!Platform.isLinux) return false;
  if (waylandSessionFrom(Platform.environment['WAYLAND_DISPLAY'])) return false;
  _load();
  final x11 = _x11, xtst = _xtst;
  if (x11 == null || xtst == null) return false;
  try {
    final dpy = _open(x11);
    if (dpy == nullptr) return false;
    try {
      final ev = calloc<Int32>(), er = calloc<Int32>();
      final maj = calloc<Int32>(), min = calloc<Int32>();
      try {
        final ok = xtst.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>,
                Pointer<Int32>, Pointer<Int32>),
            int Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>,
                Pointer<Int32>, Pointer<Int32>)>('XTestQueryExtension')(
          dpy, ev, er, maj, min,
        );
        return ok != 0;
      } finally {
        calloc.free(ev);
        calloc.free(er);
        calloc.free(maj);
        calloc.free(min);
      }
    } finally {
      _close(x11, dpy);
    }
  } catch (_) {
    return false;
  }
}

/// Send Ctrl+[key], optionally with Shift. Terminals take Ctrl+Shift+V for
/// paste rather than Ctrl+V, which is why [shift] exists.
bool _sendChord(int keysym, {bool shift = false}) {
  if (!injectionAvailable()) return false;
  final x11 = _x11, xtst = _xtst;
  if (x11 == null || xtst == null) return false;
  try {
    final dpy = _open(x11);
    if (dpy == nullptr) return false;
    try {
      final ctrl = _keycodeOf(x11, dpy, _xkControlL);
      final shiftK = _keycodeOf(x11, dpy, _xkShiftL);
      final key = _keycodeOf(x11, dpy, keysym);
      if (ctrl == 0 || key == 0 || (shift && shiftK == 0)) return false;
      _fakeKey(xtst, dpy, ctrl, true);
      if (shift) _fakeKey(xtst, dpy, shiftK, true);
      _fakeKey(xtst, dpy, key, true);
      _fakeKey(xtst, dpy, key, false);
      if (shift) _fakeKey(xtst, dpy, shiftK, false);
      _fakeKey(xtst, dpy, ctrl, false);
      _flush(x11, dpy);
      return true;
    } finally {
      _close(x11, dpy);
    }
  } catch (_) {
    return false; // injection is best-effort, never break the paste path
  }
}

/// Whether any modifier the user could still be holding is physically down,
/// read from the X keymap rather than guessed. Returns false if we cannot ask.
bool _modifiersHeld(DynamicLibrary x11, Pointer<Void> dpy) {
  final keys = calloc<Uint8>(32); // XQueryKeymap fills a 256-bit bitmap
  try {
    x11.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint8>),
        int Function(Pointer<Void>, Pointer<Uint8>)>('XQueryKeymap')(dpy, keys);
    for (final sym in [_xkControlL, 0xffe4 /* Control_R */, _xkShiftL,
      0xffe2 /* Shift_R */, 0xffe9 /* Alt_L */, 0xffea /* Alt_R */]) {
      final kc = _keycodeOf(x11, dpy, sym);
      if (kc == 0) continue;
      if ((keys[kc >> 3] & (1 << (kc & 7))) != 0) return true;
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    calloc.free(keys);
  }
}

/// Paste into whatever now holds focus. [terminal] switches to Ctrl+Shift+V,
/// the chord every Linux terminal uses — plain Ctrl+V there is a no-op at
/// best (and in readline, quoted-insert).
bool sendPaste({bool terminal = false}) =>
    _sendChord(_xkV, shift: terminal);

/// Wait for the modifiers of the chord that got us here to be released.
///
/// Both chord-safe entry points run from a global-hotkey handler, so the
/// user's fingers are still on Ctrl+Shift: injecting straight away would land
/// a modified chord rather than the intended one. Waits up to half a second
/// and then proceeds regardless — the same "wait, then go" shape the Windows
/// and macOS backends use, because a paste that is late beats one that never
/// happens.
Future<void> _awaitModifierRelease() async {
  final x11 = _x11;
  if (x11 == null) return;
  try {
    final dpy = _open(x11);
    if (dpy == nullptr) return;
    try {
      for (var i = 0; i < 25 && _modifiersHeld(x11, dpy); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      _close(x11, dpy);
    }
  } catch (_) {
    // fall through and inject anyway
  }
}

/// Paste from inside a global-hotkey handler. See [_awaitModifierRelease].
Future<bool> sendPasteChordSafe({bool terminal = false}) async {
  if (!injectionAvailable()) return false;
  await _awaitModifierRelease();
  return _sendChord(_xkV, shift: terminal);
}

/// Copy from the focused app, from inside a global-hotkey handler.
///
/// Callers must not use this when the focused app is a terminal: Ctrl+C there
/// interrupts the running job. desktop.dart's existing srcApp == 'terminal'
/// guard covers it, and linuxAppKey maps every known terminal onto that key.
Future<bool> sendCopyChordSafe() async {
  if (!injectionAvailable()) return false;
  await _awaitModifierRelease();
  return _sendChord(_xkC);
}
