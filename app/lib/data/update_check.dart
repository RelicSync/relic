import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:io' show Platform, SocketException, HandshakeException;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

/// Where the desktop app looks for the latest published version: a small static
/// JSON file on the marketing site (website/public/latest.json), served at
/// /latest.json. No worker round-trip, no auth, no telemetry.
///
/// Manifest shape (v2): top-level `version`/`url`/`notes` (the pre-July-2026
/// Windows clients read only these, so `url` stays the Windows download), plus
/// an optional per-platform block the client prefers:
///   "platforms": { "windows": {"url": …, "sha256": …}, "macos": {"url": …} }
/// `sha256` (hex, of the installer bytes) is what gates one-click self-update
/// (self_update.dart): without it the app falls back to opening the browser.
///
/// The env override exists for testing the self-update path against a local
/// manifest + file server; production builds never set it.
String get _manifestUrl =>
    Platform.environment['RELIC_UPDATE_MANIFEST'] ??
    'https://relic.space/latest.json';

class UpdateInfo {
  final String version;
  final String url; // where to send the user to download
  final String notes;
  final String? sha256; // hex digest of the installer; enables self-update
  const UpdateInfo({
    required this.version,
    required this.url,
    this.notes = '',
    this.sha256,
  });
}

/// What a check actually concluded. "Couldn't check" is deliberately NOT the
/// same as "up to date": collapsing the two is how a machine sits on an old
/// build for weeks while cheerfully reporting it is current.
enum UpdateOutcome { available, upToDate, failed }

class UpdateResult {
  final UpdateOutcome outcome;

  /// Set only when [outcome] is [UpdateOutcome.available].
  final UpdateInfo? info;

  /// Set only when [outcome] is [UpdateOutcome.failed] — one plain sentence,
  /// safe to show verbatim in the UI, naming the thing that went wrong.
  final String? reason;

  const UpdateResult._(this.outcome, {this.info, this.reason});

  const UpdateResult.upToDate() : this._(UpdateOutcome.upToDate);
  UpdateResult.available(UpdateInfo i) : this._(UpdateOutcome.available, info: i);
  UpdateResult.failed(String why) : this._(UpdateOutcome.failed, reason: why);

  bool get isAvailable => outcome == UpdateOutcome.available;
  bool get isFailed => outcome == UpdateOutcome.failed;
}

/// Host shown in failure text, so "couldn't reach it" points somewhere the
/// user can actually try in a browser.
String get _manifestHost => Uri.parse(_manifestUrl).host;

/// Asks the manifest whether something newer exists. Never throws: every
/// failure comes back as [UpdateOutcome.failed] carrying a reason, which is
/// what the caller shows. Note the update manifest lives on the website
/// (relic.space) while sync talks to the API worker — a machine can sync
/// perfectly and still be unable to reach this, so the reason matters.
/// [client] is for tests only; production passes nothing and uses the default.
Future<UpdateResult> checkForUpdate(String current, {http.Client? client}) async {
  if (current.trim().isEmpty) {
    return UpdateResult.failed("Relic couldn't read its own version number.");
  }
  try {
    final r = await (client?.get(Uri.parse(_manifestUrl)) ??
            http.get(Uri.parse(_manifestUrl)))
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) {
      return UpdateResult.failed(
          '$_manifestHost answered HTTP ${r.statusCode}.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(r.body);
    } catch (_) {
      return UpdateResult.failed("The update file on $_manifestHost couldn't "
          'be read.');
    }
    if (decoded is! Map<String, dynamic>) {
      return UpdateResult.failed(
          'The update file on $_manifestHost was not in the expected format.');
    }
    // A manifest with no version at all is a broken publish, not "you're
    // current" — say so rather than quietly agreeing.
    final remote = (decoded['version'] as String?)?.trim();
    if (remote == null || remote.isEmpty) {
      return UpdateResult.failed(
          'The update file on $_manifestHost is missing a version.');
    }
    final info = updateFromManifest(decoded, current);
    return info == null
        ? const UpdateResult.upToDate()
        : UpdateResult.available(info);
  } on TimeoutException {
    return UpdateResult.failed(
        'The update check timed out reaching $_manifestHost.');
  } on SocketException catch (e) {
    final detail = e.osError?.message.trim();
    return UpdateResult.failed('Could not reach $_manifestHost'
        '${detail == null || detail.isEmpty ? '.' : ': $detail.'}');
  } on HandshakeException {
    return UpdateResult.failed(
        'The secure connection to $_manifestHost failed.');
  } catch (e) {
    return UpdateResult.failed('The update check failed: $e');
  }
}

/// Pure manifest → decision core of [checkForUpdate], split out for tests.
@visibleForTesting
UpdateInfo? updateFromManifest(Map<String, dynamic> j, String current) {
  final entry = _platformEntry(j);
  // Platforms release on their own cadence: an entry carrying its own
  // `version` is authoritative for this platform, the top-level version is
  // the shared fallback. Without this, a Windows-only release would offer
  // every Mac an "update" whose download is still the old Mac build.
  final remote = ((entry?['version'] as String?) ?? (j['version'] as String?))
      ?.trim();
  final url = entry == null ? null : (entry['url'] as String?)?.trim();
  if (remote == null || remote.isEmpty || url == null || url.isEmpty) {
    return null;
  }
  if (_compareVersions(remote, current) <= 0) return null;
  final sha = (entry!['sha256'] as String?)?.trim();
  return UpdateInfo(
    version: remote,
    url: url,
    notes: (j['notes'] as String?)?.trim() ?? '',
    sha256: (sha == null || sha.isEmpty) ? null : sha,
  );
}

/// This platform's manifest entry. With a `platforms` block, only this
/// platform's own entry counts (no entry → no update offer, so a macOS build
/// is never handed the Windows installer). A legacy single-`url` manifest is,
/// by definition, the Windows installer — only Windows uses it.
Map<String, dynamic>? _platformEntry(Map<String, dynamic> j) {
  final platforms = j['platforms'];
  if (platforms is Map<String, dynamic>) {
    final key = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
            ? 'macos'
            : Platform.isLinux
                ? 'linux'
                : null;
    final entry = key == null ? null : platforms[key];
    return entry is Map<String, dynamic> ? entry : null;
  }
  if (!Platform.isWindows) return null;
  return {'url': j['url'], 'sha256': j['sha256']};
}

/// Compare dotted numeric versions ("1.2.0" vs "1.10.0"). Build/pre-release
/// suffixes ("+1", "-beta") are ignored; missing components count as 0.
/// Returns >0 if a>b, <0 if a<b, 0 if equal.
int _compareVersions(String a, String b) {
  final pa = _parts(a), pb = _parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

List<int> _parts(String v) {
  final core = v.split(RegExp(r'[+\-]')).first;
  return core.split('.').map((s) => int.tryParse(s.trim()) ?? 0).toList();
}
