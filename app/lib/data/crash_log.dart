import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/paths.dart';

/// Lightweight, offline crash/error logging to a rotating file under
/// <data dir>/logs (platform/paths.dart — %APPDATA%\relic on Windows,
/// ~/Library/Application Support/relic on macOS). No network, no account — a
/// release crash leaves a readable trace the user can hand to support ("Open
/// logs" in Settings → About). Every write is best-effort and never throws
/// into the app.

const _maxLogBytes = 1024 * 1024; // rotate at ~1 MB
const _keep = 3; // relic.1.log … relic.3.log

String _logDirPath() => logsPath();

/// The folder where logs are written, created on demand.
String crashLogDir() {
  final d = Directory(_logDirPath());
  if (!d.existsSync()) d.createSync(recursive: true);
  return d.path;
}

File _logFile() =>
    File('${crashLogDir()}${Platform.pathSeparator}relic.log');

void _rotateIfNeeded() {
  try {
    final f = _logFile();
    if (!f.existsSync() || f.lengthSync() < _maxLogBytes) return;
    final dir = crashLogDir();
    final sep = Platform.pathSeparator;
    // Drop the oldest, then shift each kept file up one slot.
    final oldest = File('$dir${sep}relic.$_keep.log');
    if (oldest.existsSync()) oldest.deleteSync();
    for (var i = _keep - 1; i >= 1; i--) {
      final src = File('$dir${sep}relic.$i.log');
      if (src.existsSync()) src.renameSync('$dir${sep}relic.${i + 1}.log');
    }
    f.renameSync('$dir${sep}relic.1.log');
  } catch (_) {}
}

bool _inited = false;

/// Install global error handlers. Call once at the very top of `main()`,
/// before `runApp`.
void initCrashLogging() {
  if (_inited) return;
  _inited = true;
  _rotateIfNeeded();

  final prev = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    appendCrash(
      details.exception,
      details.stack ?? StackTrace.current,
      context: details.context?.toString(),
    );
    if (prev != null) {
      prev(details);
    } else {
      FlutterError.presentError(details);
    }
  };

  // Errors that escape the Flutter framework (async, platform messages).
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    appendCrash(error, stack);
    return true; // handled — keep the app alive
  };
}

String? _lastSyncMsg;
DateTime _lastSyncAt = DateTime.fromMillisecondsSinceEpoch(0);

/// One-line trouble entry (sync HTTP status, refresh failure, transport
/// error, OAuth flow milestones). Sync entries fire from a periodic timer, so
/// a repeat of the same message within five minutes is dropped — the first
/// occurrence is the diagnostic, the repetition is just the retry loop.
void appendSyncLog(String message, {String tag = 'sync'}) {
  try {
    final now = DateTime.now();
    if (message == _lastSyncMsg &&
        now.difference(_lastSyncAt) < const Duration(minutes: 5)) {
      return;
    }
    _lastSyncMsg = message;
    _lastSyncAt = now;
    _logFile().writeAsStringSync(
      '[${now.toIso8601String()}] [$tag] $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

/// Append one timestamped entry. Never throws.
void appendCrash(Object error, StackTrace stack, {String? context}) {
  try {
    final ts = DateTime.now().toIso8601String();
    final ctx = (context == null || context.isEmpty) ? '' : ' [$context]';
    final entry = StringBuffer()
      ..writeln('[$ts]$ctx $error')
      ..writeln(stack.toString().trimRight())
      ..writeln();
    _logFile().writeAsStringSync(
      entry.toString(),
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}
