import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:win32/win32.dart';

import '../../../models/copy_context.dart';

/// Windows backend of platform/copy_context.dart.
///
/// The window title comes from the foreground window. The words around the
/// copy come from UI Automation: the focused control's text selection (or the
/// nearest ancestor that has one) is widened by [CopyContext.keepWords] words
/// on each side. Controls without a text pattern fall back to their value,
/// split around the copied text when it occurs exactly once. Password fields
/// are never read.

/// The foreground window's title ("Invoice 1184 - Google Chrome"), or null.
String? foregroundWindowTitle() {
  if (!Platform.isWindows) return null;
  try {
    final hwnd = GetForegroundWindow();
    if (hwnd == 0) return null;
    final n = GetWindowTextLength(hwnd);
    if (n <= 0) return null;
    final buf = wsalloc(n + 1);
    try {
      GetWindowText(hwnd, buf, n + 1);
      final t = buf.toDartString().trim();
      return t.isEmpty ? null : t;
    } finally {
      free(buf);
    }
  } catch (_) {
    return null;
  }
}

/// The words around [copied] in the focused control, read on a background
/// isolate (a UI Automation call into a busy app can take a while, and must
/// never stall Relic's UI). Null when nothing usable was found.
Future<CopyContext?> surroundingText(String copied) =>
    Isolate.run(() => _surroundingSync(copied, 0));

/// The same read rooted at a given window instead of the focus, so a test can
/// drive it against a window it owns without touching the user's focus.
@visibleForTesting
Future<CopyContext?> surroundingTextOfWindow(int hwnd, String copied) =>
    Isolate.run(() => _surroundingSync(copied, hwnd));

CopyContext? _surroundingSync(String copied, int hwnd) {
  if (copied.trim().isEmpty) return null;
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  final com = _Com();
  try {
    final uia = com.own(CUIAutomation.createInstance());
    final hr = com.out((slot) => hwnd == 0
        ? uia.getFocusedElement(slot.cast())
        : uia.elementFromHandle(hwnd, slot.cast()));
    if (hr == null) return null;
    var el = com.own(IUIAutomationElement(hr));
    final walker = com.own(IUIAutomationTreeWalker(uia.controlViewWalker));
    // The focused element is often a link or a span inside the document that
    // actually owns the selection, so look a few ancestors up.
    for (var depth = 0; depth < 6; depth++) {
      if (el.currentIsPassword != 0) return null;
      final got = _fromTextPattern(com, el, copied) ?? _fromValuePattern(com, el, copied);
      if (got != null) return got;
      final parent = com.out((slot) => walker.getParentElement(_raw(el), slot.cast()));
      if (parent == null) break;
      el = com.own(IUIAutomationElement(parent));
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    com.releaseAll();
    CoUninitialize();
  }
}

/// Owns every COM object of one read. win32's wrappers free their slot from
/// a GC finalizer, which could run after COM is torn down on this thread, so
/// each one is detached and released here, in order, before CoUninitialize.
class _Com {
  final _objects = <IUnknown>[];
  final scratch = Arena();

  T own<T extends IUnknown>(T o) {
    o.detach();
    _objects.add(o);
    return o;
  }

  /// Run a call that fills an interface out-slot; the filled slot, or null
  /// (and the slot freed) when it failed or came back empty.
  Pointer<COMObject>? out(int Function(Pointer<COMObject> slot) call) {
    final slot = calloc<COMObject>();
    if (FAILED(call(slot)) || slot.ref.isNull) {
      free(slot);
      return null;
    }
    return slot;
  }

  void releaseAll() {
    for (final o in _objects.reversed) {
      if (!o.ptr.ref.isNull) o.release();
      free(o.ptr);
    }
    _objects.clear();
    scratch.releaseAll();
  }
}

CopyContext? _fromTextPattern(_Com com, IUIAutomationElement el, String copied) {
  final iid = GUIDFromString(IID_IUIAutomationTextPattern, allocator: com.scratch);
  final pat = com.out((slot) => el.getCurrentPatternAs(UIA_TextPatternId, iid, slot.cast()));
  if (pat == null) return null;
  final tp = com.own(IUIAutomationTextPattern(pat));
  final arrSlot = com.out((slot) => tp.getSelection(slot.cast()));
  if (arrSlot == null) return null;
  final arr = com.own(IUIAutomationTextRangeArray(arrSlot));
  if (arr.length < 1) return null;
  final selSlot = com.out((slot) => arr.getElement(0, slot.cast()));
  if (selSlot == null) return null;
  final sel = com.own(IUIAutomationTextRange(selSlot));
  if (!CopyContext.sameSelection(_text(com, sel, 20000) ?? '', copied)) {
    return null; // the selection moved on, or this control isn't the source
  }
  final words = CopyContext.keepWords;
  final b = com.out((slot) => sel.clone(slot.cast()));
  final a = com.out((slot) => sel.clone(slot.cast()));
  if (b == null || a == null) return null;
  final before = com.own(IUIAutomationTextRange(b));
  final after = com.own(IUIAutomationTextRange(a));
  final moved = com.scratch<Int32>();
  // before: collapse to the selection's start, then reach back N words
  before.moveEndpointByRange(
      TextPatternRangeEndpoint_End, _raw(sel), TextPatternRangeEndpoint_Start);
  before.moveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Word, -words, moved);
  // after: collapse to the selection's end, then reach forward N words
  after.moveEndpointByRange(
      TextPatternRangeEndpoint_Start, _raw(sel), TextPatternRangeEndpoint_End);
  after.moveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Word, words, moved);
  return CopyContext(
    before: _text(com, before, 4000) ?? '',
    after: _text(com, after, 4000) ?? '',
  );
}

CopyContext? _fromValuePattern(_Com com, IUIAutomationElement el, String copied) {
  final iid = GUIDFromString(IID_IUIAutomationValuePattern, allocator: com.scratch);
  final pat = com.out((slot) => el.getCurrentPatternAs(UIA_ValuePatternId, iid, slot.cast()));
  if (pat == null) return null;
  final vp = com.own(IUIAutomationValuePattern(pat));
  final p = vp.currentValue;
  if (p.address == 0) return null;
  final value = p.toDartString();
  SysFreeString(p);
  return CopyContext.splitAround(value, copied);
}

/// win32's wrappers hold a pointer to the slot that holds the interface;
/// a COM argument wants the interface pointer itself.
Pointer<COMObject> _raw(IUnknown o) => o.ptr.ref.lpVtbl.cast();

String? _text(_Com com, IUIAutomationTextRange r, int max) {
  final p = com.scratch<Pointer<Utf16>>();
  if (FAILED(r.getText(max, p)) || p.value.address == 0) return null;
  final s = p.value.toDartString();
  SysFreeString(p.value);
  return s;
}
