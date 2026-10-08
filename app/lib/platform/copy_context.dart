import 'dart:async';
import 'dart:io' show Platform;

import '../models/copy_context.dart';
import 'src/linux/foreground_linux.dart' as lin;
import 'src/macos/foreground_macos.dart' as mac;
import 'src/windows/copy_context_win.dart' as win;

/// Where [copied] was copied from, read at the moment of the copy while the
/// source app still owns the foreground and its selection: the window title
/// and, where the OS exposes it, the words around the selection. The page link
/// comes from the clipboard itself (rich_formats.dart kRelicSourceUrl) and is
/// added by the caller.
///
/// Per platform:
/// - Windows: window title + UI Automation text around the selection.
/// - macOS: window title + Accessibility text around the selection (needs the
///   Accessibility permission Relic already asks for to paste; without it,
///   nothing).
/// - Linux/X11: window title only. Wayland: nothing.
///
/// Best-effort and bounded: anything slower than [budget] is dropped, and it
/// never throws. Null when there is nothing at all.
Future<CopyContext?> readCopyContext(
  String copied, {
  Duration budget = const Duration(milliseconds: 700),
}) async {
  try {
    if (Platform.isWindows) {
      final title = win.foregroundWindowTitle();
      final around = await win
          .surroundingText(copied)
          .timeout(budget, onTimeout: () => null);
      return _merge(title, around);
    }
    if (Platform.isMacOS) {
      final m = await mac
          .copyContext(copied)
          .timeout(budget, onTimeout: () => null);
      return _merge(m?.title, m);
    }
    if (Platform.isLinux) {
      return _merge(lin.foregroundWindowTitle(), null);
    }
  } catch (_) {/* capture must never fail because of this */}
  return null;
}

CopyContext? _merge(String? title, CopyContext? around) {
  final c = CopyContext(
    title: title,
    before: around?.before ?? '',
    after: around?.after ?? '',
  ).trimmed();
  return c.isEmpty ? null : c;
}
