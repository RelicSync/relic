import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// The free plan's sync rule, as the apps see it (server: worker/src/syncplan.ts).
///
/// Free is one device. A new account syncs on every device for its first
/// week; after that one device keeps syncing and the others get 403
/// `sync_paused`. A paused device keeps everything it already has and keeps
/// capturing locally. Its outgoing changes stay queued, so they go up the
/// moment this device syncs again (it is picked, or the account pays).
///
/// Shared by LocalDeskRepo and WorkerRepo so the two hosts read the 403 and
/// make the pick the same way.
class SyncPause {
  /// Unix seconds the free week ended. Null from a server that did not say.
  final int? syncUntil;

  /// The device that is still syncing. Null if the server has not settled one.
  final String? syncDevice;

  /// The account's devices, newest first, as the server listed them.
  final List<SyncPlanDevice> devices;

  const SyncPause({this.syncUntil, this.syncDevice, this.devices = const []});

  /// The pause carried by a 403 body, or null when [body] is any other error.
  static SyncPause? fromBody(String body) {
    try {
      final j = jsonDecode(body);
      if (j is! Map || j['error'] != 'sync_paused') return null;
      return SyncPause(
        syncUntil: (j['sync_until'] as num?)?.toInt(),
        syncDevice: j['sync_device'] as String?,
        devices: [
          for (final d in (j['devices'] as List? ?? const []))
            if (d is Map) SyncPlanDevice.fromJson(d.cast<String, dynamic>()),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  /// The device that keeps syncing, as a person would name it.
  String? get syncDeviceName {
    for (final d in devices) {
      if (d.id == syncDevice) return d.name;
    }
    return null;
  }

  /// The banner line. Names the syncing device when the server listed it.
  String get message {
    final other = syncDeviceName;
    return other == null
        ? 'Sync is paused here. The free plan syncs one device. '
              'Everything on this device is still here.'
        : 'Sync is paused here. The free plan syncs one device, and '
              'yours is $other. Everything on this device is still here.';
  }
}

class SyncPlanDevice {
  final String id;
  final String? label;
  final String? platform;
  final bool thisDevice;

  const SyncPlanDevice({
    required this.id,
    this.label,
    this.platform,
    this.thisDevice = false,
  });

  factory SyncPlanDevice.fromJson(Map<String, dynamic> j) => SyncPlanDevice(
    id: j['device_id'] as String? ?? '',
    label: j['label'] as String?,
    platform: j['platform'] as String?,
    thisDevice: j['this_device'] == true,
  );

  /// "Jordan's PC", or "your Windows PC" when the device has no label.
  String get name {
    final l = label?.trim();
    if (l != null && l.isNotEmpty) return l;
    return switch (platform) {
      'windows' => 'your Windows PC',
      'macos' => 'your Mac',
      'linux' => 'your Linux PC',
      'android' => 'your Android phone',
      'ios' => 'your iPhone',
      _ => 'another device',
    };
  }
}

/// How often a paused device asks again whether it may sync. The answer only
/// changes when the person picks a device or pays, so a poll every few seconds
/// would be thousands of refused requests a day for nothing.
const kPausedRecheck = Duration(minutes: 5);

/// One host's view of the pause: the notifier the UI watches, plus the clock
/// that spaces out the re-checks. Each repo owns one.
class SyncPauseGate {
  /// The current pause, or null while this device syncs.
  final ValueNotifier<SyncPause?> paused = ValueNotifier(null);
  DateTime? _checkedAt;

  /// [kPausedRecheck], shortened by tests that need the re-check to happen.
  @visibleForTesting
  static Duration recheck = kPausedRecheck;

  /// True while this device may not sync.
  bool get holding => paused.value != null;

  /// True when a pull should not go out yet: paused, and asked recently.
  /// [force] is a person tapping "Sync now".
  bool skipPull({bool force = false, DateTime? now}) {
    final at = _checkedAt;
    if (force || paused.value == null || at == null) return false;
    return (now ?? DateTime.now()).difference(at) < recheck;
  }

  /// Reads a refused response. True when it was the pause, which is then
  /// published; false for any other error, which the caller handles as before.
  bool absorb(int status, String body, {DateTime? now}) {
    if (status != 403) return false;
    final p = SyncPause.fromBody(body);
    if (p == null) return false;
    paused.value = p;
    _checkedAt = now ?? DateTime.now();
    return true;
  }

  /// The server took a sync request from this device: not paused.
  void clear() {
    _checkedAt = null;
    if (paused.value != null) paused.value = null;
  }
}

/// What came of asking to sync this device instead.
enum SyncPickOutcome { ok, cooldown, failed }

class SyncPickResult {
  final SyncPickOutcome outcome;

  /// [SyncPickOutcome.cooldown] only: unix seconds a switch is allowed again.
  final int? retryAt;
  const SyncPickResult(this.outcome, {this.retryAt});

  /// The line to show the person after the tap.
  String message({DateTime? now}) {
    switch (outcome) {
      case SyncPickOutcome.ok:
        return 'This device syncs now.';
      case SyncPickOutcome.failed:
        return 'Could not switch right now. Try again in a minute.';
      case SyncPickOutcome.cooldown:
        final at = retryAt;
        if (at == null) return 'You can switch devices once a week.';
        final days = daysUntil(at, now: now);
        return days <= 1
            ? 'You can switch devices once a week. Try again tomorrow.'
            : 'You can switch devices once a week. Try again in $days days.';
    }
  }
}

/// POST /account/sync-device: make [deviceId] the device that keeps syncing.
Future<SyncPickResult> postSyncDevice({
  required Uri url,
  required Map<String, String> headers,
  required String deviceId,
  Duration timeout = const Duration(seconds: 15),
}) async {
  try {
    final r = await http
        .post(
          url,
          headers: {...headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'device_id': deviceId}),
        )
        .timeout(timeout);
    if (r.statusCode == 200) return const SyncPickResult(SyncPickOutcome.ok);
    if (r.statusCode == 429) {
      int? retryAt;
      try {
        final j = jsonDecode(r.body);
        if (j is Map && j['error'] == 'sync_switch_cooldown') {
          retryAt = (j['retry_at'] as num?)?.toInt();
        }
      } catch (_) {}
      // A 429 with no cooldown body is the route's rate limiter: plain failure.
      if (retryAt != null) {
        return SyncPickResult(SyncPickOutcome.cooldown, retryAt: retryAt);
      }
    }
    return const SyncPickResult(SyncPickOutcome.failed);
  } catch (_) {
    return const SyncPickResult(SyncPickOutcome.failed);
  }
}

/// Whole days from [now] until unix second [at], rounded up. 0 once it passed.
int daysUntil(int at, {DateTime? now}) {
  final n = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  if (at <= n) return 0;
  return ((at - n) + 86399) ~/ 86400;
}

/// The countdown line for the free week, or null outside it. [syncUntil] is
/// GET /account's `sync_until`, which the server only sends while the rule is
/// switched on, so this stays silent until launch day.
String? syncWeekLine(int? syncUntil, {DateTime? now}) {
  if (syncUntil == null) return null;
  final days = daysUntil(syncUntil, now: now);
  if (days == 0) return null;
  return days == 1
      ? 'Free sync on all your devices ends in 1 day.'
      : 'Free sync on all your devices ends in $days days.';
}
