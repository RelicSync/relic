import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A timeline of what the launch actually spends its time on.
///
/// Why this exists: the mobile launch screen sits for ~10s, and reading the
/// code produced a confident diagnosis (the boot awaited a full network sync)
/// that turned out to be real but NOT the dominant cost — removing it changed
/// nothing the user could feel. Guessing again is worse than measuring, and the
/// device can't be attached for a logcat, so the numbers have to come back
/// through the UI: Settings -> About -> Startup.
///
/// Monotonic (Stopwatch), not wall-clock, so an NTP step can't corrupt it.
class BootTrace {
  BootTrace._();

  static final Stopwatch _sw = Stopwatch();
  static final List<BootMark> _marks = [];

  /// ms from process start (Android `Process.getStartUptimeMillis`) to the
  /// moment Dart called [begin]. This is the part no Dart-side timer can see:
  /// zygote fork, native library load, Flutter engine init, and all 18 plugin
  /// registrations. Null until the platform answers (or off Android).
  static int? nativeToDartMs;

  /// Whether the first frame has been reported yet, so the post-frame callback
  /// only records the FIRST one.
  static bool _firstFramed = false;

  /// Start the clock. Called at the very top of main().
  static void begin() {
    if (_sw.isRunning) return;
    _sw.start();
    mark('main()');
  }

  static void mark(String label) {
    if (!_sw.isRunning) return;
    _marks.add(BootMark(label, _sw.elapsedMilliseconds));
  }

  /// Record the first painted frame exactly once.
  static void markFirstFrame() {
    if (_firstFramed) return;
    _firstFramed = true;
    mark('first frame');
  }

  static List<BootMark> get marks => List.unmodifiable(_marks);

  /// Total from main() to the last recorded mark.
  static int get dartMs => _marks.isEmpty ? 0 : _marks.last.atMs;

  /// Everything, including the native startup we can't otherwise see.
  static int get totalMs => (nativeToDartMs ?? 0) + dartMs;

  /// Ask the platform how long the process had been alive when Dart started.
  /// Best-effort: any failure just leaves [nativeToDartMs] null.
  static Future<void> loadNativeStartup() async {
    if (nativeToDartMs != null) return;
    try {
      final ms = await const MethodChannel('relic/save')
          .invokeMethod<int>('millisSinceProcessStart');
      if (ms == null) return;
      // The channel answers "now", which is some way past main(); subtract the
      // Dart time already elapsed to get the pre-Dart portion.
      final pre = ms - _sw.elapsedMilliseconds;
      nativeToDartMs = pre < 0 ? 0 : pre;
    } catch (_) {
      // Not Android, or the channel isn't up — the Dart timeline still stands.
    }
  }

  /// The timeline as lines of "label  +delta  (total)", newest last. Rendered
  /// in About and safe to copy into a bug report: no vault content, just names
  /// and durations.
  static List<String> report() {
    final out = <String>[];
    if (nativeToDartMs != null) {
      out.add('engine + plugins   ${nativeToDartMs}ms');
    }
    var prev = 0;
    for (final m in _marks) {
      final delta = m.atMs - prev;
      prev = m.atMs;
      out.add('${m.label.padRight(18)} +${delta}ms   (${m.atMs}ms)');
    }
    out.add('TOTAL              ${totalMs}ms');
    return out;
  }

  @visibleForTesting
  static void reset() {
    _sw.reset();
    _sw.stop();
    _marks.clear();
    _firstFramed = false;
    nativeToDartMs = null;
  }
}

@immutable
class BootMark {
  final String label;
  final int atMs;
  const BootMark(this.label, this.atMs);
}
