// Rich text at the repo level: what capture stores, what the dedupe path does
// with better formatting arriving later, and the two places a secret's HTML
// flavor could otherwise leak.
//
// The pure half (CF_HTML, the cap, the fingerprint) is in rich_body_test.dart;
// the storage half is in relic_db_test.dart. These need a real repo, so they
// run only under a sandbox:
//
//   RELIC_DATA_DIR=$(mktemp -d) flutter test test/rich_capture_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/models/relic.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded =
      sandbox == null || sandbox.toLowerCase().contains('roaming');

  Future<LocalDeskRepo> repo() async {
    final r = LocalDeskRepo();
    await r.load();
    r.setMlEnrich(false);
    return r;
  }

  Relic only(LocalDeskRepo r, String content) =>
      r.all.firstWhere((x) => x.content == content);

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 10));

  // The sandbox directory is reused between runs unless the caller mints a
  // fresh one, and capture dedupes on content — so every case makes its own
  // text. Keeps these independent of run order and of leftover rows.
  final salt = DateTime.now().microsecondsSinceEpoch;
  var seq = 0;
  String uniq(String base) => '$base $salt-${seq++}';

  test('capture keeps the formatting flavors', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    final text = uniq('quarterly figures');
    final rtf = Uint8List.fromList(utf8.encode(r'{\rtf1\ansi q}'));
    r.captureText(text, html: '<b>$text</b>', rtf: rtf);
    await settle();

    final rel = only(r, text);
    expect(rel.rich, isNotNull);
    expect(rel.richIfCurrent!.html, '<b>$text</b>');
    expect(rel.richIfCurrent!.rtf, orderedEquals(rtf));
  });

  test('a plain capture stores nothing extra', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    final text = uniq('just text');
    r.captureText(text);
    await settle();
    expect(only(r, text).rich, isNull);
  });

  test('a secret never stores formatting', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    // The salt goes on its own line so the key shape stays intact for
    // heuristicTags, which is what decides `secret`.
    final text = '${uniq('ref')}\nsk_live_0123456789abcdef';
    r.captureText(text, html: '<span>$text</span>');
    await settle();

    final rel = only(r, text);
    expect(rel.isSecret, isTrue, reason: 'precondition');
    expect(rel.rich, isNull,
        reason: 'the masked text would be scrubbed while the HTML shipped it');
  });

  test('re-copying the same text with formatting upgrades the row', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    // Plain first: the first copy of a sentence must not permanently poison
    // every later formatted copy of it.
    final text = uniq('shared sentence');
    r.captureText(text);
    await settle();
    expect(only(r, text).rich, isNull);

    r.captureText(text, html: '<i>$text</i>');
    await settle();

    final rows = r.all.where((x) => x.content == text);
    expect(rows.length, 1, reason: 'dedupe still collapses onto one row');
    expect(rows.first.richIfCurrent!.html, '<i>$text</i>');
  });

  // byte_size is what the quota is charged against AND what the Worker
  // measures its plausibility floor against, so formatting has to be inside
  // it. A four-byte sentence declaring four bytes while carrying 47 KB of
  // HTML came back `400 invalid_envelope` and never synced.
  test('byte_size counts the formatting that travels with the text', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    final text = uniq('sized');
    final html = '<p style="color:#fff">${'padding ' * 500}</p>';
    r.captureText(text, html: html);
    await settle();

    final rel = only(r, text);
    expect(rel.rich, isNotNull, reason: 'precondition');
    expect(rel.byteSize, utf8.encode(text).length + rel.rich!.encodedLength);
    // The Worker's floor: body <= byte_size * 4 + 16 KiB. The declared size
    // now scales with the payload instead of staying at the plain length.
    expect(rel.byteSize, greaterThan(4000));
  });

  test('the dedupe upgrade moves byte_size with the formatting', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    final text = uniq('grew later');
    r.captureText(text);
    await settle();
    expect(only(r, text).byteSize, utf8.encode(text).length);

    r.captureText(text, html: '<i>${'wide ' * 400}</i>');
    await settle();

    final rel = only(r, text);
    expect(rel.byteSize, utf8.encode(text).length + rel.rich!.encodedLength);
  });

  test('editing the body drops the formatting it no longer matches', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    final text = uniq('before');
    r.captureText(text, html: '<b>${'long ' * 400}</b>');
    await settle();
    final captured = only(r, text);
    expect(captured.rich, isNotNull, reason: 'precondition');

    final edited = uniq('after');
    await r.updateMeta(captured, content: edited);
    await settle();

    final rel = only(r, edited);
    expect(rel.rich, isNull,
        reason: 'the fingerprint no longer matches, so it was dead weight');
    expect(rel.byteSize, utf8.encode(edited).length);
  });

  test('the echo guard still suppresses an identical re-capture', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    final text = uniq('echo me');
    expect(r.captureText(text, html: '<b>$text</b>'), isTrue);
    expect(r.captureText(text, html: '<b>$text</b>'), isFalse,
        reason: 'same text and same formatting is our own clipboard write');
  });

  test('export redaction strips the rich flavors too', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    // Build the case capture-time enforcement alone cannot produce: a relic
    // captured plain, given formatting, and only THEN marked secret. Without
    // the export-side strip this writes a file that scrubs the plaintext body
    // and ships the same value inside the HTML.
    const card = '9021 6644 1288 3355';
    final text = '${uniq('ref')}\n$card';
    r.captureText(text, html: '<b>$text</b>');
    await settle();

    var rel = only(r, text);
    expect(rel.rich, isNotNull, reason: 'precondition: formatting was stored');
    await r.updateMeta(rel, tags: [...rel.tags, 'secret']);
    await settle();

    rel = only(r, text);
    expect(rel.isSecret, isTrue, reason: 'precondition: now secret');
    expect(rel.rich, isNotNull,
        reason: 'updateMeta does not clear it — that is the leak');

    final out = await r.exportVault(sandbox, includeSecrets: false);
    final doc = jsonDecode(
      File('${out.path}${Platform.pathSeparator}vault.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final item = (doc['items'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((m) => m['uid'] == rel.uid);

    expect(item['redacted'], true);
    expect(item.containsKey('content'), isFalse);
    expect(item.containsKey('preview'), isFalse);
    expect(item.containsKey('rich'), isFalse,
        reason: 'the HTML holds the same secret, unmasked');
    expect(jsonEncode(item), isNot(contains(card)));
  });
}
