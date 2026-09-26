// The one-time store rating request after the tenth capture on a phone.
//
// Two halves. ReviewPrompt is the counter and the decision, tested here with
// an in-memory store and a fake reviewer so no platform plugin is involved.
// WorkerRepo.onUserCapture is what feeds it, and it has to fire only for new
// items the user made on this device: never for items synced in from another
// device, re-captures that only move an item up, or an Undo.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/review_prompt.dart';
import 'package:relic_app/data/supabase_auth.dart';
import 'package:relic_app/data/worker_repo.dart';
import 'package:relic_crypto/relic_crypto.dart';

class _MemStore implements ReviewPromptStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
}

class _FakeReviewer implements StoreReviewer {
  bool available = true;
  int availabilityChecks = 0;
  int requests = 0;
  @override
  Future<bool> isAvailable() async {
    availabilityChecks++;
    return available;
  }

  @override
  Future<void> requestReview() async => requests++;
}

class _ThrowingReviewer implements StoreReviewer {
  int requests = 0;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<void> requestReview() async {
    requests++;
    throw PlatformException(code: 'boom');
  }
}

// flutter_test answers every HttpClient with a 400, which the outbox treats as
// a permanent rejection. Real networking against the discard port is a quiet
// transient failure instead (same harness as reshare_test.dart).
class _RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReviewPrompt', () {
    late _MemStore store;
    late _FakeReviewer reviewer;
    late ReviewPrompt prompt;

    setUp(() {
      store = _MemStore();
      reviewer = _FakeReviewer();
      prompt = ReviewPrompt(store: store, reviewer: reviewer, enabled: true);
    });

    /// One capture followed by the ask, as the mobile shell does it.
    Future<bool> capture({bool calm = true}) async {
      if (!await prompt.recordCapture()) return false;
      return prompt.askIfDue(calm: () => calm);
    }

    test('fires on exactly the tenth capture', () async {
      for (var i = 1; i <= 9; i++) {
        expect(await capture(), isFalse, reason: 'capture $i');
      }
      expect(reviewer.requests, 0);
      expect(reviewer.availabilityChecks, 0);
      expect(await capture(), isTrue);
      expect(reviewer.requests, 1);
      expect(store.data[ReviewPrompt.kPrompted], '1');
    });

    test('never fires twice', () async {
      for (var i = 0; i < 10; i++) {
        await capture();
      }
      expect(reviewer.requests, 1);
      for (var i = 0; i < 25; i++) {
        expect(await capture(), isFalse);
        expect(await prompt.askIfDue(calm: () => true), isFalse);
      }
      expect(reviewer.requests, 1);
    });

    test('the one-time flag survives a new instance (an app restart)',
        () async {
      for (var i = 0; i < 10; i++) {
        await capture();
      }
      final again = ReviewPrompt(store: store, reviewer: reviewer, enabled: true);
      for (var i = 0; i < 12; i++) {
        expect(await again.recordCapture(), isFalse);
      }
      expect(reviewer.requests, 1);
    });

    test('the count carries across restarts', () async {
      for (var i = 0; i < 6; i++) {
        await capture();
      }
      final again = ReviewPrompt(store: store, reviewer: reviewer, enabled: true);
      for (var i = 0; i < 3; i++) {
        expect(await again.recordCapture(), isFalse);
      }
      expect(await again.recordCapture(), isTrue);
      expect(await again.askIfDue(calm: () => true), isTrue);
      expect(reviewer.requests, 1);
    });

    test('a busy moment waits for the next capture instead of dropping it',
        () async {
      for (var i = 0; i < 9; i++) {
        await capture();
      }
      expect(await capture(calm: false), isFalse);
      expect(reviewer.requests, 0);
      expect(store.data[ReviewPrompt.kPrompted], isNull);
      expect(await capture(), isTrue);
      expect(reviewer.requests, 1);
    });

    test('an unavailable store fails silently and never asks', () async {
      reviewer.available = false;
      for (var i = 0; i < 15; i++) {
        expect(await capture(), isFalse);
      }
      expect(reviewer.requests, 0);
      expect(store.data[ReviewPrompt.kPrompted], isNull);
    });

    test('a plugin that throws is swallowed and still counts as asked',
        () async {
      final throwing = _ThrowingReviewer();
      final p =
          ReviewPrompt(store: store, reviewer: throwing, enabled: true);
      for (var i = 0; i < 9; i++) {
        await p.recordCapture();
      }
      expect(await p.recordCapture(), isTrue);
      expect(await p.askIfDue(calm: () => true), isTrue);
      expect(await p.recordCapture(), isFalse);
      expect(await p.askIfDue(calm: () => true), isFalse);
      expect(throwing.requests, 1);
    });

    test('captures landing together are all counted and ask only once',
        () async {
      // A share of several photos: every capture fires at once.
      final due = await Future.wait(
          [for (var i = 0; i < 14; i++) prompt.recordCapture()]);
      expect(store.data[ReviewPrompt.kCount], '14');
      expect(due.where((d) => d), hasLength(5)); // the 10th through 14th
      final asked = await Future.wait(
          [for (var i = 0; i < 5; i++) prompt.askIfDue(calm: () => true)]);
      expect(asked.where((a) => a), hasLength(1));
      expect(reviewer.requests, 1);
    });

    test('never fires on desktop', () async {
      final desk =
          ReviewPrompt(store: store, reviewer: reviewer, enabled: false);
      for (var i = 0; i < 20; i++) {
        expect(await desk.recordCapture(), isFalse);
        expect(await desk.askIfDue(calm: () => true), isFalse);
      }
      expect(reviewer.requests, 0);
      expect(reviewer.availabilityChecks, 0);
      expect(store.data, isEmpty);
    });

    test('the platform gate is off on the test host (a desktop)', () {
      // Tests run on Windows, Linux or macOS, none of which has a store
      // review sheet.
      expect(Platform.isAndroid || Platform.isIOS, isFalse);
      expect(reviewPromptSupported, isFalse);
      debugReviewPromptOverride = true;
      addTearDown(() => debugReviewPromptOverride = null);
      expect(reviewPromptSupported, isTrue);
    });

    test('the default instance follows the platform gate', () async {
      // No store or reviewer injected: on a desktop host it must not touch
      // either (the real plugin and secure storage are never reached).
      final p = ReviewPrompt();
      for (var i = 0; i < 12; i++) {
        expect(await p.recordCapture(), isFalse);
      }
      expect(await p.askIfDue(calm: () => true), isFalse);
    });
  });

  group('WorkerRepo.onUserCapture', () {
    final mk = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xff));
    late Directory tmp;
    HttpOverrides? prevOverrides;

    setUp(() {
      prevOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealNetwork();
      tmp = Directory.systemTemp.createTempSync('relic_review_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => tmp.path,
      );
    });

    tearDown(() {
      HttpOverrides.global = prevOverrides;
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
          baseUrl: 'http://127.0.0.1:9', // discard port: flushes fail fast
          session: const SupabaseSession(
            accessToken: 't',
            refreshToken: 'r',
            expiresAt: 4102444800,
            userId: 'test-user',
          ),
          mk: mk,
        );

    Future<Map<String, dynamic>> syncedEnv(String uid, String content) async {
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

    test('every kind of new capture counts once', () async {
      final r = await repo();
      var n = 0;
      r.onUserCapture = () => n++;

      expect(await r.captureText('a shared sentence'), isTrue);
      expect(n, 1);
      expect(
          await r.captureImage(Uint8List.fromList(List.filled(64, 7)),
              mime: 'image/png', filename: 'shot.png'),
          isNotNull);
      expect(n, 2);
      expect(
          await r.captureFile(Uint8List.fromList(List.filled(64, 3)),
              filename: 'notes.pdf', mime: 'application/pdf'),
          isNotNull);
      expect(n, 3);
      expect(r.createNote(title: 'Typed', body: 'a typed note'), isTrue);
      expect(n, 4);
    });

    test('a re-capture that only moves an item up does not count', () async {
      final r = await repo();
      var n = 0;
      r.onUserCapture = () => n++;
      await r.captureText('same words');
      await r.captureText('same words');
      await r.captureText('  same words  ');
      expect(r.all, hasLength(1));
      expect(n, 1);
    });

    test('items synced in from another device do not count', () async {
      final r = await repo();
      var n = 0;
      r.onUserCapture = () => n++;
      expect(
          await r.debugAbsorbEnvelopes([
            for (var i = 0; i < 12; i++)
              await syncedEnv('synced-$i', 'from the laptop $i'),
          ]),
          isTrue);
      expect(r.all, hasLength(12));
      expect(n, 0);
    });

    test('an Undo restore does not count', () async {
      final r = await repo();
      var n = 0;
      await r.captureText('keep me');
      r.onUserCapture = () => n++;
      final item = r.all.single;
      await r.delete(item);
      await r.restore(item);
      expect(r.all.single.uid, item.uid);
      expect(n, 0);
    });

    test('an empty or refused capture does not count', () async {
      final r = await repo();
      var n = 0;
      r.onUserCapture = () => n++;
      expect(await r.captureText('   '), isFalse);
      expect(await r.captureText('relic://pair#abc'), isFalse);
      expect(r.createNote(body: '  '), isFalse);
      expect(n, 0);
    });
  });
}
