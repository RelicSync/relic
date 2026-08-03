import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_crypto/relic_crypto.dart';
import 'package:relic_app/data/supabase_auth.dart';
import 'package:relic_app/data/worker_repo.dart';
import 'package:relic_app/widgets/chrome.dart' show SyncKind;

// Mobile used to require a live network to open at all: _silentSupabaseRepo
// began with SupabaseAuth.refresh, and any failure there returned null, which
// dropped the user on the "Reconnect" wall even though the vault and its master
// key were both already on the device. The fix binds an offline repo from the
// cached key with an already-expired access token, letting _maybeRefresh
// re-authenticate on its own once the network is back.
//
// These tests pin the shape that fix depends on. See clear_history_test.dart
// for why real networking has to be restored: flutter_test answers every
// HttpClient with 400, which the outbox treats as a PERMANENT rejection and
// drops; a discard-port baseUrl gives us a transient failure instead.
class _RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealNetwork();

  final mk = Uint8List.fromList(List.generate(32, (i) => i * 3 & 0xff));

  /// Exactly how mobile.dart binds when the token refresh could not be reached:
  /// no access token, expiry in the past, the stored refresh token carried over.
  Future<WorkerRepo> offlineRepo() => WorkerRepo.bindSupabaseWithMk(
        baseUrl: 'http://127.0.0.1:9', // discard port — every request fails
        session: const SupabaseSession(
          accessToken: '',
          refreshToken: 'stored-refresh',
          expiresAt: 0, // already expired -> _maybeRefresh retries each sync
          userId: 'test-user',
          email: 'user@example.com',
        ),
        mk: mk,
      );

  test('binds with the cached key even though the token could not be refreshed',
      () async {
    final r = await offlineRepo();
    // The vault is openable: the master key came from secure storage, not from
    // the network round-trip that used to gate the whole launch.
    expect(r.masterKey, isNotNull);
    expect(r.masterKey, equals(mk));
    expect(r.supabaseUserId, 'test-user');
    expect(r.accountEmail, 'user@example.com');
  });

  test('syncing offline degrades to the offline state instead of throwing',
      () async {
    final r = await offlineRepo();
    // _maybeRefresh runs first and fails (no network), then every request to
    // the discard port fails. None of that may escape as an exception, or the
    // launch path would abort again.
    await expectLater(r.syncDelta(), completes);
    expect(r.sync.kind, SyncKind.offline);
  });

  test('a capture made while offline stays queued for the next sync', () async {
    final r = await offlineRepo();
    await r.captureText('captured with no signal');
    // Queued, not lost: the outbox is what survives to the reconnect.
    expect(r.debugOutbox, hasLength(1));
    expect(r.debugOutbox.single['op'], 'put');
  });

  // Letting captures happen offline exposed a latent hazard in the capture-only
  // repo: it never calls load(), and every queued mutation ends in
  // _push -> _saveCache, which serializes _envByUid + _outbox WHOLESALE. So a
  // repo that never read the cache persists only its own capture, erasing the
  // cached vault and any ops still waiting to upload. _repoForCapture now
  // awaits primeCache() first.
  group('capture repo cache safety', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('relic_offline_capture_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => tmp.path,
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    File cacheFile() => File('${tmp.path}/relic_cache.json');

    Future<Map<String, dynamic>> envFor(String uid, String content) async {
      final sealed = await RelicCrypto.sealRelicPayload(mk, uid, {
        'kind': 'string',
        'source': 'clipboard',
        'content': content,
        'preview': content,
        'tags': <String>[],
        'user_tags': <String>[],
      });
      return {
        'v': 1,
        'uid': uid,
        'created_at': 1,
        'updated_at': 2,
        'byte_size': content.length,
        'promoted': false,
        'n': sealed['n'],
        'ct': sealed['ct'],
      };
    }

    /// A device that already holds a synced vault plus one upload still queued.
    Future<void> seedCache() async {
      cacheFile().writeAsStringSync(jsonEncode({
        'account': 'test-user',
        'cursor': 500,
        'items': [
          await envFor('kept-1', 'first'),
          await envFor('kept-2', 'second'),
          await envFor('kept-3', 'third'),
        ],
        'outbox': [
          {'op': 'delete', 'uid': 'pending-delete', 'deleted_at': 5},
        ],
      }));
    }

    Map<String, dynamic> readCache() =>
        jsonDecode(cacheFile().readAsStringSync()) as Map<String, dynamic>;

    test('priming preserves the cached vault and the queued ops', () async {
      await seedCache();
      final r = await offlineRepo();
      await r.primeCache();
      await r.captureText('captured offline');

      final cache = readCache();
      final uids =
          (cache['items'] as List).map((e) => (e as Map)['uid']).toSet();
      expect(uids, containsAll(['kept-1', 'kept-2', 'kept-3']),
          reason: 'the already-synced vault must survive a capture');
      expect(uids, hasLength(4), reason: 'plus the new capture');
      expect((cache['outbox'] as List).length, 2,
          reason: 'the pending delete must not be dropped');
      expect((cache['cursor'] as num).toInt(), 500,
          reason: 'resetting the cursor would force a full re-pull');
    });

    test('without priming the same capture would erase it', () async {
      // Pins the failure mode the fix prevents — if this ever starts passing
      // with the vault intact, _saveCache stopped writing wholesale and
      // primeCache may no longer be load-bearing.
      await seedCache();
      final r = await offlineRepo();
      await r.captureText('captured offline');

      final cache = readCache();
      expect((cache['items'] as List), hasLength(1),
          reason: 'an unprimed repo persists only what it knows about');
      expect((cache['cursor'] as num).toInt(), 0);
    });
  });
}
