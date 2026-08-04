// Tests for the July 2026 small-features batch: capture blocklist
// normalization, Relic.toJson, and (sandboxed) pref defaults + vault export
// redaction. The repo-level test runs only under a RELIC_DATA_DIR sandbox:
//
//   RELIC_DATA_DIR=$(mktemp -d) flutter test test/small_features_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/models/relic.dart';

void main() {
  test('normExe strips .exe, lowercases, trims', () {
    expect(LocalDeskRepo.normExe('Notepad.EXE'), 'notepad');
    expect(LocalDeskRepo.normExe('  keepass '), 'keepass');
    expect(LocalDeskRepo.normExe('1Password.exe'), '1password');
    expect(LocalDeskRepo.normExe('pycharm64'), 'pycharm64');
    expect(LocalDeskRepo.normExe(''), '');
  });

  test('Relic.toJson round-trips the export shape', () {
    const r = Relic(
      uid: 'u1',
      createdAt: 100,
      updatedAt: 200,
      kind: Kind.string,
      source: Source.hotkey,
      promoted: true,
      byteSize: 5,
      device: 'desk',
      tags: ['url'],
      userTags: ['work'],
      title: 'T',
      note: 'n',
      content: 'hello',
      preview: 'hello',
    );
    final j = r.toJson();
    expect(j['uid'], 'u1');
    expect(j['created_at'], 100);
    expect(j['updated_at'], 200);
    expect(j['kind'], 'string');
    expect(j['source'], 'hotkey');
    expect(j['promoted'], true);
    expect(j['byte_size'], 5);
    expect(j['tags'], ['url']);
    expect(j['user_tags'], ['work']);
    expect(kindFromStr(j['kind'] as String), Kind.string);
    expect(sourceFromStr(j['source'] as String), Source.hotkey);
    // absent-if-null keys stay absent
    expect(j.containsKey('mime'), isFalse);
    expect(j.containsKey('blob_key'), isFalse);
  });

  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded =
      sandbox == null || sandbox.toLowerCase().contains('roaming');

  test('sandboxed: pref defaults, blocklist, export redaction', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final sb = sandbox;
    final repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false);

    // New effective defaults on a fresh (or never-customized) install.
    expect(repo.pasteOnSelect, isTrue);
    expect(repo.clearSecretClipboard, isTrue);

    // Blocklist normalizes on the way in and removes case-blind.
    repo.addCaptureBlock('Notepad.EXE');
    expect(repo.captureBlocklist, contains('notepad'));
    repo.addCaptureBlock('notepad'); // duplicate collapses
    expect(repo.captureBlocklist.length, 1);
    repo.removeCaptureBlock('NOTEPAD.exe');
    expect(repo.captureBlocklist, isEmpty);

    // Export: a secret is redacted (content AND preview) unless included.
    await repo.captureForAnnotate(text: 'sk_live_0123456789abcdef');
    await repo.captureForAnnotate(text: 'plain shopping list');
    final out = await repo.exportVault(sb, includeSecrets: false);
    expect(out.items, greaterThanOrEqualTo(2));
    final doc = jsonDecode(
            File('${out.path}${Platform.pathSeparator}vault.json')
                .readAsStringSync())
        as Map<String, dynamic>;
    final items = (doc['items'] as List).cast<Map<String, dynamic>>();
    final sec = items.firstWhere(
        (m) => (m['tags'] as List?)?.contains('secret') ?? false);
    expect(sec['redacted'], true);
    expect(sec.containsKey('content'), isFalse);
    expect(sec.containsKey('preview'), isFalse);
    final plain =
        items.firstWhere((m) => m['content'] == 'plain shopping list');
    expect(plain.containsKey('redacted'), isFalse);

    // Include-secrets export keeps the plaintext.
    final out2 = await repo.exportVault(sb, includeSecrets: true);
    final doc2 = jsonDecode(
            File('${out2.path}${Platform.pathSeparator}vault.json')
                .readAsStringSync())
        as Map<String, dynamic>;
    final sec2 = (doc2['items'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((m) => (m['tags'] as List?)?.contains('secret') ?? false);
    expect(sec2['content'], 'sk_live_0123456789abcdef');
    expect(sec2.containsKey('redacted'), isFalse);
  });
}
