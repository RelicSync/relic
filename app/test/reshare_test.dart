// Sharing something the phone already holds moves it to the top.
//
// Before this, a repeat share of the same photo or file was refused with
// "Already in Relic" and nothing on screen changed, so the share looked lost.
// A repeat share of the same text already bumped the existing item, as a
// desktop re-copy does. Now every kind behaves that way: the item's stamps
// move to now, it goes to the top of the list, and the change is pushed so
// every other device sees it there too. Nothing is stored or uploaded twice.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/supabase_auth.dart';
import 'package:relic_app/data/worker_repo.dart';

// Real networking against the discard port: a transient failure, which keeps
// the outbox queued instead of treating a 400 mock as a permanent rejection.
class _RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealNetwork();

  final mk = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xff));
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('relic_reshare_');
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

  Future<WorkerRepo> repo() => WorkerRepo.bindSupabaseWithMk(
        baseUrl: 'http://127.0.0.1:9',
        session: const SupabaseSession(
          accessToken: '',
          refreshToken: 'stored-refresh',
          expiresAt: 0,
          userId: 'test-user',
          email: 'user@example.com',
        ),
        mk: mk,
      );

  test('a captured photo reports the item it landed on', () async {
    final r = await repo();
    final uid = await r.captureImage(Uint8List.fromList(List.filled(64, 7)),
        mime: 'image/png', filename: 'shot.png');
    expect(uid, isNotNull);
    expect(r.all.single.uid, uid);
  });

  test('resurfacing a photo moves it to the top, dated now, without a copy',
      () async {
    final r = await repo();
    final photo = await r.captureImage(Uint8List.fromList(List.filled(64, 7)),
        mime: 'image/png', filename: 'shot.png');
    // Something newer on top of it, so the move is visible.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await r.captureText('a later note');
    expect(r.all.first.content, 'a later note');
    final before = r.all.firstWhere((e) => e.uid == photo);
    final blobKey = before.blobKey;

    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(await r.resurface(photo!), isTrue);

    expect(r.all, hasLength(2), reason: 'nothing was stored twice');
    final after = r.all.first;
    expect(after.uid, photo);
    expect(after.createdAt, greaterThan(before.createdAt));
    expect(after.updatedAt, greaterThan(before.updatedAt));
    expect(after.blobKey, blobKey, reason: 'the bytes stay where they are');
    // The move is queued for every other device, as one op for this item.
    expect(r.debugOutbox.where((o) => o['uid'] == photo), hasLength(1));
    expect(r.debugBlobOutbox, [blobKey],
        reason: 'the one upload from the capture, not a second');
  });

  test('an item that is no longer here cannot be resurfaced', () async {
    final r = await repo();
    expect(await r.resurface('gone'), isFalse);
    expect(r.all, isEmpty);
  });

  test('sharing the same text again still bumps rather than duplicates',
      () async {
    final r = await repo();
    await r.captureText('the same snippet');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await r.captureText('something else');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(await r.captureText('the same snippet'), isTrue);
    expect(r.all, hasLength(2));
    expect(r.all.first.content, 'the same snippet');
  });
}
