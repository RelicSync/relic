import 'dart:convert' show jsonEncode;
import 'dart:io' show Platform, SocketException;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart' show MockClient;

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/update_check.dart';

void main() {
  // The parse core is platform-sensitive: a build only ever accepts its own
  // platform's entry. So the fixture keys on the host we're running on and the
  // assertions hold on every desktop — keying it to 'windows' meant the whole
  // parse core went unasserted the moment the suite ran on a Mac.
  final onWindows = Platform.isWindows;
  final hostKey = Platform.isWindows
      ? 'windows'
      : Platform.isMacOS
          ? 'macos'
          : 'linux';

  Map<String, dynamic> manifest({String? sha}) => {
        'version': '1.2.0',
        'url': 'https://relic.space/download/windows',
        'notes': 'notes',
        'platforms': {
          hostKey: {
            'url': 'https://relic.space/download/$hostKey',
            'sha256': ?sha,
          },
        },
      };

  test('newer version with sha256 yields a self-updatable UpdateInfo', () {
    final info = updateFromManifest(manifest(sha: 'AB12'), '1.1.9');
    expect(info, isNotNull);
    expect(info!.version, '1.2.0');
    expect(info.sha256, 'AB12');
    expect(info.url, 'https://relic.space/download/$hostKey',
        reason: 'the offer must be this platform\'s own artifact');
  });

  test('missing sha256 still offers the update, just without self-install',
      () {
    final info = updateFromManifest(manifest(), '1.0.0');
    expect(info, isNotNull);
    expect(info!.sha256, isNull);
  });

  test('another platform\'s entry is never offered to this build', () {
    final other = Platform.isWindows ? 'macos' : 'windows';
    final info = updateFromManifest({
      'version': '9.9.9',
      'platforms': {
        other: {'url': 'https://relic.space/download/$other', 'sha256': 'AB'},
      },
    }, '1.0.0');
    expect(info, isNull);
  });

  test('same or older version yields nothing', () {
    expect(updateFromManifest(manifest(sha: 'AB'), '1.2.0'), isNull);
    expect(updateFromManifest(manifest(sha: 'AB'), '1.10.0'), isNull);
  });

  test('legacy single-url manifest still parses (Windows only)', () {
    final info = updateFromManifest({
      'version': '9.9.9',
      'url': 'https://relic.space/download/windows',
    }, '1.0.0');
    if (onWindows) {
      expect(info, isNotNull);
      expect(info!.sha256, isNull);
    } else {
      expect(info, isNull);
    }
  });

  test('a platforms block without our platform offers nothing', () {
    final info = updateFromManifest({
      'version': '9.9.9',
      'platforms': {'solaris': {'url': 'https://x'}},
    }, '1.0.0');
    expect(info, isNull);
  });

  // Platforms release on their own cadence: the entry's own version must beat
  // the top-level one, or a Windows-only release "updates" every Mac to a
  // download that is still the old Mac build.
  test('platform entry version outranks the shared top-level version', () {
    final m = {
      'version': '9.9.9', // another platform just shipped
      'platforms': {
        hostKey: {'url': 'https://relic.space/download/$hostKey', 'version': '1.2.0'},
      },
    };
    expect(updateFromManifest(m, '1.2.0'), isNull,
        reason: 'our platform has nothing newer, whatever the top level says');
    final offered = updateFromManifest(m, '1.1.0');
    expect(offered, isNotNull);
    expect(offered!.version, '1.2.0');
  });

  test('entry without its own version still falls back to top-level', () {
    final info = updateFromManifest(manifest(sha: 'AB12'), '1.1.0');
    expect(info, isNotNull);
    expect(info!.version, '1.2.0');
  });


  // ---- checkForUpdate outcomes -------------------------------------------
  // The whole point of UpdateResult: "couldn't check" must never be dressed up
  // as "you're on the latest version". Every one of these used to return null,
  // which the UI rendered as reassurance.

  test('blank running version is a failure, not up-to-date', () async {
    final res = await checkForUpdate('');
    expect(res.outcome, UpdateOutcome.failed);
    expect(res.reason, isNotNull);
    expect(res.info, isNull);
  });

  test('non-200 from the manifest host is a failure carrying the code',
      () async {
    final res = await checkForUpdate('1.0.0',
        client: MockClient((_) async => http.Response('nope', 503)));
    expect(res.outcome, UpdateOutcome.failed);
    expect(res.reason, contains('503'));
  });

  test('unparseable manifest body is a failure', () async {
    final res = await checkForUpdate('1.0.0',
        client: MockClient((_) async => http.Response('<html>oops', 200)));
    expect(res.outcome, UpdateOutcome.failed);
  });

  test('manifest missing a version is a failure, not up-to-date', () async {
    final res = await checkForUpdate('1.0.0',
        client: MockClient((_) async => http.Response('{"url":"x"}', 200)));
    expect(res.outcome, UpdateOutcome.failed);
    expect(res.reason, contains('version'));
  });

  test('a dropped connection is a failure naming the host', () async {
    final res = await checkForUpdate('1.0.0',
        client: MockClient((_) async => throw const SocketException('no route')));
    expect(res.outcome, UpdateOutcome.failed);
    expect(res.reason, contains('relic.space'));
  });

  test('a genuinely current version reports up-to-date', () async {
    final res = await checkForUpdate('1.2.0',
        client: MockClient((_) async => http.Response(jsonEncode(manifest()), 200)));
    expect(res.outcome, UpdateOutcome.upToDate);
    expect(res.isFailed, isFalse);
  });

  test('an older version reports the available update', () async {
    final res = await checkForUpdate('1.1.0',
        client: MockClient(
            (_) async => http.Response(jsonEncode(manifest(sha: 'AB12')), 200)));
    if (!onWindows) return; // no windows entry accepted elsewhere
    expect(res.outcome, UpdateOutcome.available);
    expect(res.info!.version, '1.2.0');
  });
}
