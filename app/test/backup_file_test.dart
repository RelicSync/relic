import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/data/backup_file.dart';
import 'package:relic_crypto/relic_crypto.dart';

/// Sealed-backup crypto + container tests. Argon2id runs at the pinned 64 MiB
/// params (~1s per derive), so the wrap is created once in setUpAll and
/// reader-open tests are kept to one derive each.
void main() {
  const passphrase = 'correct horse battery relic';
  late Map<String, dynamic> wrap;
  late Uint8List bk;
  late Directory tmp;

  const secretLine = 'kubernetes-prod-token bright-zebra-71';
  final manifest = {
    'version': 1,
    'exported_at': '2026-07-14T00:00:00Z',
    'device': 'TESTBOX',
    'items': [
      {'uid': 'u1', 'content': secretLine, 'kind': 'text'},
      {'uid': 'u2', 'content': 'plain note', 'kind': 'photo', 'blob_key': 'bk1'},
    ],
  };
  final blob1 = Uint8List.fromList(
      utf8.encode('BLOBPAYLOAD-alpha ${'x' * 500}'));
  final blob2 = Uint8List.fromList(List.generate(1 << 12, (i) => i % 251));

  setUpAll(() async {
    (wrap, bk) = await BackupCrypto.createWrap(passphrase);
    tmp = Directory.systemTemp.createTempSync('relic_backup_test');
  });

  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<File> writeBackup(String name) async {
    final f = File('${tmp.path}${Platform.pathSeparator}$name');
    final w = await BackupFileWriter.create(f,
        header: {'v': 1, 'created_at': '2026-07-14T00:00:00Z', 'wrap': wrap},
        bk: bk);
    await w.writeManifest(manifest);
    await w.writeBlob('bk1', blob1);
    await w.writeBlob('bk2', blob2);
    await w.close();
    return f;
  }

  group('BackupCrypto', () {
    test('unwrap round-trips under the right passphrase, null under wrong',
        () async {
      expect(await BackupCrypto.unwrapBk(wrap, passphrase), bk);
      expect(await BackupCrypto.unwrapBk(wrap, 'wrong passphrase'), isNull);
    });

    test('segment seal/open round-trips; tamper and domain mismatch fail',
        () async {
      final wire = await BackupCrypto.seal(bk, 'blob:k', blob1);
      expect(await BackupCrypto.open(bk, 'blob:k', wire), blob1);
      // wrong AAD domain
      expect(await BackupCrypto.open(bk, 'blob:other', wire), isNull);
      // flipped ciphertext byte
      final bad = Uint8List.fromList(wire);
      bad[bad.length - 1] ^= 0xFF;
      expect(await BackupCrypto.open(bk, 'blob:k', bad), isNull);
      // wrong key
      final otherKey = Uint8List(32);
      expect(await BackupCrypto.open(otherKey, 'blob:k', wire), isNull);
    });
  });

  group('BackupFile container', () {
    test('write → read round-trips manifest and blobs', () async {
      final f = await writeBackup('roundtrip.relicvault');
      final r = await BackupFileReader.open(f, passphrase);
      try {
        expect(r.manifest, manifest);
        expect(r.header['created_at'], '2026-07-14T00:00:00Z');
        expect(r.blobKeys.toSet(), {'bk1', 'bk2'});
        expect(await r.blob('bk1'), blob1);
        expect(await r.blob('bk2'), blob2);
        // random access works out of write order too
        expect(await r.blob('bk1'), blob1);
        expect(await r.blob('nope'), isNull);
      } finally {
        await r.close();
      }
    });

    test('file bytes never contain plaintext content or blob bytes', () async {
      final f = await writeBackup('opaque.relicvault');
      final bytes = await f.readAsBytes();
      final hay = latin1.decode(bytes, allowInvalid: true);
      expect(hay.contains(secretLine), isFalse);
      expect(hay.contains('plain note'), isFalse);
      expect(hay.contains('BLOBPAYLOAD-alpha'), isFalse);
      expect(hay.contains('TESTBOX'), isFalse); // manifest is sealed whole
      // sanity: the magic IS there (the file is recognizable, not hidden)
      expect(hay.startsWith(BackupFile.magic), isTrue);
    });

    test('wrong passphrase throws BackupWrongPassphrase', () async {
      final f = await writeBackup('wrongpass.relicvault');
      expect(() => BackupFileReader.open(f, 'not it'),
          throwsA(isA<BackupWrongPassphrase>()));
    });

    test('garbage and truncated files throw BackupFormatException', () async {
      final junk = File('${tmp.path}${Platform.pathSeparator}junk.relicvault')
        ..writeAsBytesSync(utf8.encode('this is not a backup at all'));
      expect(() => BackupFileReader.open(junk, passphrase),
          throwsA(isA<BackupFormatException>()));

      final f = await writeBackup('trunc.relicvault');
      final whole = await f.readAsBytes();
      final cut = File('${tmp.path}${Platform.pathSeparator}cut.relicvault')
        ..writeAsBytesSync(whole.sublist(0, whole.length - 10));
      expect(() => BackupFileReader.open(cut, passphrase),
          throwsA(isA<BackupFormatException>()));
    });

    test('a tampered blob segment fails verification on read', () async {
      final f = await writeBackup('tamper.relicvault');
      final bytes = await f.readAsBytes();
      bytes[bytes.length - 1] ^= 0xFF; // inside the last segment's tag
      final bad = File('${tmp.path}${Platform.pathSeparator}bad.relicvault')
        ..writeAsBytesSync(bytes);
      final r = await BackupFileReader.open(bad, passphrase);
      try {
        // the untouched segment still opens; the tampered one refuses
        expect(await r.blob('bk1'), blob1);
        await expectLater(
            r.blob('bk2'), throwsA(isA<BackupFormatException>()));
      } finally {
        await r.close();
      }
    });
  });
}
