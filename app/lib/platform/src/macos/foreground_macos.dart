import 'package:flutter/services.dart';

import '../../../models/copy_context.dart';

/// macOS backend of platform/foreground_app.dart and platform/running_apps.dart:
/// a thin client over the `relic/frontmost` MethodChannel implemented by
/// macos/Runner/Bridge/ForegroundAppBridge.swift (NSWorkspace). No special
/// permission required.

const _ch = MethodChannel('relic/frontmost');

/// An app as macOS reports it: [bundleId] is the identity ("com.google.Chrome"),
/// [name] its localized name ("Google Chrome"), empty when macOS has none.
typedef MacApp = ({String bundleId, String name});

/// The frontmost application, or null when it can't be determined.
Future<MacApp?> frontmostApp() async {
  try {
    return _appOf(await _ch.invokeMapMethod<String, String>('frontmost'));
  } catch (_) {
    return null;
  }
}

/// The applications with a Dock presence right now (activation policy
/// `.regular`), for the capture-blocklist picker. Empty on any failure.
Future<List<MacApp>> runningMacApps() async {
  try {
    final rows = await _ch.invokeListMethod<Object?>('runningApps') ?? const [];
    return rows
        .map((r) => _appOf((r as Map?)?.cast<String, Object?>()))
        .nonNulls
        .toList();
  } catch (_) {
    return const [];
  }
}

MacApp? _appOf(Map<String, Object?>? m) {
  final id = m?['bundleId'] as String?;
  if (id == null || id.isEmpty) return null;
  return (bundleId: id, name: (m?['name'] as String?) ?? '');
}

/// The focused control's text caret as `[x, y]` in global screen POINTS
/// (top-left origin, caret bottom-left), read through the Accessibility API —
/// so it answers null without the AX grant, and for apps that don't expose
/// their text (many Chromium/Electron surfaces, same holes as Windows).
Future<List<double>?> caretScreenPoint() async {
  try {
    final p = await _ch.invokeListMethod<double>('caretScreenPoint');
    return (p != null && p.length == 2) ? p : null;
  } catch (_) {
    return null;
  }
}

/// Where the current copy came from (ForegroundAppBridge.swift copyContext):
/// the window title, and the words around the selection when it really is
/// [copied]. Null without the AX grant or when nothing is readable.
Future<CopyContext?> copyContext(String copied) async {
  try {
    final m = await _ch.invokeMapMethod<String, String>('copyContext');
    if (m == null) return null;
    final title = m['title'];
    final selected = m['selected'];
    CopyContext? around;
    if (selected != null && CopyContext.sameSelection(selected, copied)) {
      if (m.containsKey('before') || m.containsKey('after')) {
        around = CopyContext(before: m['before'] ?? '', after: m['after'] ?? '');
      } else if (m['value'] case final v?) {
        around = CopyContext.splitAround(v, copied);
      }
    }
    return CopyContext(
      title: title,
      before: around?.before ?? '',
      after: around?.after ?? '',
    );
  } catch (_) {
    return null;
  }
}
