import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:relic_app/data/sync_socket.dart';
import 'package:relic_app/data/worker_repo.dart';

/// Self-host checks that ONLY a real device can answer.
///
/// `test/selfhost_connect_test.dart` already drives a live server through the
/// whole protocol (enroll → keyparams → relic → blob), but it runs under
/// `flutter test`, which executes on the host Dart VM. There is no Android
/// manifest and no `NetworkSecurityPolicy` in that process, so it proves the
/// crypto and the wire format and says nothing about whether an installed
/// Android build can open the socket in the first place.
///
/// That gap matters because `selfhost/README.md` tells users to type
/// `http://<host>:8787`, the app manifest declares no `usesCleartextTraffic`,
/// and Android has blocked cleartext by default since API 28. Dart's `dart:io`
/// stack uses its own sockets and should not consult that policy — this file is
/// how we stop assuming. It is also the regression guard for the day someone
/// bumps `targetSdk` and Android tightens the default again.
///
/// Run it on a connected phone, with the server reachable from the phone (same
/// LAN, or a tunnel). A `localhost` URL cannot work: it would resolve to the
/// phone itself.
///
///     flutter test integration_test/selfhost_device_test.dart \
///       -d <device-id> --dart-define=SELFHOST_URL=http://192.168.1.50:8787
///
/// The reachability leg needs only `SELFHOST_URL` and is read-only (`GET
/// /health`). The connect leg additionally needs `SELFHOST_PASS`, and is opt-in
/// **on purpose**: enrolling claims the instance trust-on-first-use, so pointing
/// it at your real vault with the wrong passphrase gets a 403, and at a fresh
/// server it would claim the instance with a throwaway passphrase. Use a
/// disposable container for it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const url = String.fromEnvironment('SELFHOST_URL');
  const pass = String.fromEnvironment('SELFHOST_PASS');

  final base = url.replaceAll(RegExp(r'/+$'), '');
  // testWidgets' `skip` is bool-only (unlike `test`'s), so the reasons are
  // printed instead — otherwise an all-skipped run looks like an all-passed one.
  final noUrl = url.isEmpty;
  final noPass = noUrl || pass.isEmpty;
  if (noUrl) {
    debugPrint('SKIPPING: set --dart-define=SELFHOST_URL=http://<lan-ip>:8787');
  } else if (noPass) {
    debugPrint('SKIPPING the enrolling legs: set --dart-define=SELFHOST_PASS '
        '(it claims the instance — use a disposable server)');
  }

  group('self-host from a real device', () {
    testWidgets('a cleartext http:// request reaches the server', (_) async {
      // Guard against a vacuous pass: over https the platform policy this test
      // exists to probe is never exercised, so say so instead of going green.
      expect(base, startsWith('http://'),
          reason: 'this test only means something over cleartext http; '
              'an https URL proves nothing about the Android policy');

      final resp = await http
          .get(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 10));

      expect(resp.statusCode, 200, reason: 'GET /health: ${resp.body}');
      expect((jsonDecode(resp.body) as Map)['ok'], isTrue);
    }, skip: noUrl);

    testWidgets('connectSelfHost enrolls and unlocks the vault on-device',
        (_) async {
      // Exercises what the host-side test cannot: the platform HTTP stack, and
      // path_provider, which _saveCache needs and which has no desktop
      // equivalent in the app-support layout.
      final repo = await WorkerRepo.connectSelfHost(
        baseUrl: base,
        passphrase: pass,
        deviceLabel: 'Integration test',
        deviceId: 'integration-test-device',
      );

      expect(repo.isSelfHost, isTrue);
      expect(repo.masterKey, isNotNull,
          reason: 'the vault key was created or unwrapped');

      // A capture has to survive sealing, the cache write, and the upload.
      // captureText reports whether it stored anything, but that only covers
      // the local half; an empty outbox afterwards is what proves the upload.
      expect(await repo.captureText('captured from the device test'), isTrue,
          reason: 'the relic was sealed and queued');
      expect(repo.debugOutbox, isEmpty,
          reason: 'the outbox flushed to the real server; anything left means '
              'the upload failed and only the local cache has it');
    }, skip: noPass);

    testWidgets('the live-sync doorbell fails fast instead of hanging',
        (_) async {
      // Self-host has no Durable Object, so /sync/socket cannot upgrade. The
      // contract SyncSocket depends on (sync_socket.dart: "self-host has no
      // Durable Object") is that this fails quickly and it falls back to
      // polling. A hang here would be invisible in the UI and would silently
      // cost every self-host user their live sync.
      await expectLater(
        WebSocket.connect(SyncSocket.wsUrlFor(base))
            .timeout(const Duration(seconds: 8)),
        throwsA(anything),
        reason: 'a self-host server must refuse the upgrade promptly; if this '
            'connected, the doorbell is real here and the polling fallback '
            'is no longer the whole story',
      );
    }, skip: noUrl);
  });
}
