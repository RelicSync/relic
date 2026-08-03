import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:relic_crypto/relic_crypto.dart';

/// Single-file sealed backup container (`.relicvault`).
///
/// Layout (all integers big-endian):
///
///   magic   "RELICVAULT1\n"                      (12 bytes)
///   u32     header length, then header JSON      (PLAINTEXT: v, created_at,
///           device, and the BackupCrypto wrap record — ciphertext itself,
///           safe to expose; it's what makes the file self-contained)
///   u32     manifest length, then sealed manifest (vault items JSON,
///           AAD domain 'manifest')
///   repeat until EOF:
///     u16   blob-key length, then key bytes (utf8; keys are opaque ids)
///     u32   segment length, then sealed blob bytes (AAD `blob:<key>`)
///
/// Every segment is AEAD-authenticated individually, so memory stays bounded
/// by the largest single blob (same ceiling the sync uploader already lives
/// with) and a truncated or tampered file fails loudly instead of restoring
/// garbage. The plaintext blob keys leak nothing: they're the same random ids
/// the sync server sees.
class BackupFile {
  static const magic = 'RELICVAULT1\n';
  static const ext = 'relicvault';
}

/// Streaming writer. Call [writeManifest] once, then [writeBlob] per blob,
/// then [close]. The caller owns deleting a partial file on error.
class BackupFileWriter {
  final IOSink _sink;
  final Uint8List _bk;
  bool _manifestWritten = false;

  BackupFileWriter._(this._sink, this._bk);

  static Future<BackupFileWriter> create(
    File out, {
    required Map<String, dynamic> header,
    required Uint8List bk,
  }) async {
    final sink = out.openWrite();
    sink.add(ascii.encode(BackupFile.magic));
    final h = utf8.encode(jsonEncode(header));
    sink.add(_u32(h.length));
    sink.add(h);
    return BackupFileWriter._(sink, bk);
  }

  Future<void> writeManifest(Map<String, dynamic> manifest) async {
    assert(!_manifestWritten);
    final sealed = await BackupCrypto.seal(
        _bk, 'manifest', utf8.encode(jsonEncode(manifest)));
    _sink.add(_u32(sealed.length));
    _sink.add(sealed);
    _manifestWritten = true;
  }

  Future<void> writeBlob(String key, Uint8List bytes) async {
    assert(_manifestWritten);
    final sealed = await BackupCrypto.seal(_bk, 'blob:$key', bytes);
    final k = utf8.encode(key);
    _sink.add(_u16(k.length));
    _sink.add(k);
    _sink.add(_u32(sealed.length));
    _sink.add(sealed);
  }

  Future<void> close() async {
    await _sink.flush();
    await _sink.close();
  }

  static Uint8List _u16(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v);
  static Uint8List _u32(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v);
}

/// Thrown for anything that isn't a wrong passphrase: bad magic, truncation,
/// a tampered segment, a newer format. [message] is user-facing.
class BackupFormatException implements Exception {
  final String message;
  const BackupFormatException(this.message);
  @override
  String toString() => message;
}

/// Thrown when the wrap record doesn't open under the given passphrase.
class BackupWrongPassphrase implements Exception {
  const BackupWrongPassphrase();
}

/// Random-access reader. [open] parses the header, unwraps the BK (one
/// Argon2 pass), decrypts the manifest, and indexes blob segment offsets
/// without reading their bytes; [blob] then seeks and decrypts on demand.
class BackupFileReader {
  final RandomAccessFile _raf;
  final Uint8List _bk;

  /// Decrypted manifest (the same shape `vault.json` carries).
  final Map<String, dynamic> manifest;

  /// Plaintext header (created_at, device, ...).
  final Map<String, dynamic> header;

  final Map<String, ({int offset, int length})> _blobIndex;

  BackupFileReader._(
      this._raf, this._bk, this.manifest, this.header, this._blobIndex);

  Iterable<String> get blobKeys => _blobIndex.keys;

  static Future<BackupFileReader> open(File file, String passphrase) async {
    const damaged =
        BackupFormatException('This backup file looks damaged or truncated.');
    final raf = await file.open();
    try {
      final magic = await raf.read(BackupFile.magic.length);
      if (magic.length != BackupFile.magic.length ||
          ascii.decode(magic, allowInvalid: true) != BackupFile.magic) {
        throw const BackupFormatException(
            "That doesn't look like a Relic backup file.");
      }
      final total = await raf.length();

      Future<int> u32() async {
        final b = await raf.read(4);
        if (b.length != 4) throw damaged;
        return b.buffer.asByteData().getUint32(0);
      }

      Future<int> u16() async {
        final b = await raf.read(2);
        if (b.length != 2) throw damaged;
        return b.buffer.asByteData().getUint16(0);
      }

      Future<Uint8List> exactly(int n) async {
        final b = await raf.read(n);
        if (b.length != n) throw damaged;
        return b;
      }

      final Map<String, dynamic> header;
      try {
        header = jsonDecode(utf8.decode(await exactly(await u32())))
            as Map<String, dynamic>;
      } on BackupFormatException {
        rethrow;
      } catch (_) {
        throw damaged;
      }
      if (((header['v'] as num?)?.toInt() ?? 0) > 1) {
        throw const BackupFormatException(
            'This backup came from a newer version of Relic.');
      }
      final wrap = header['wrap'];
      if (wrap is! Map) throw damaged;
      final bk = await BackupCrypto.unwrapBk(
          wrap.cast<String, dynamic>(), passphrase);
      if (bk == null) throw const BackupWrongPassphrase();

      final sealedManifest = await exactly(await u32());
      final clear = await BackupCrypto.open(bk, 'manifest', sealedManifest);
      if (clear == null) throw damaged;
      final manifest = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;

      // Index the blob segments by walking lengths; bytes stay on disk.
      final index = <String, ({int offset, int length})>{};
      while (await raf.position() < total) {
        final key = utf8.decode(await exactly(await u16()));
        final len = await u32();
        final at = await raf.position();
        if (at + len > total) throw damaged;
        index[key] = (offset: at, length: len);
        await raf.setPosition(at + len);
      }
      return BackupFileReader._(raf, bk, manifest, header, index);
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  /// Decrypt one blob. Null when the key isn't in the file; throws
  /// [BackupFormatException] on a tampered segment.
  Future<Uint8List?> blob(String key) async {
    final seg = _blobIndex[key];
    if (seg == null) return null;
    await _raf.setPosition(seg.offset);
    final sealed = await _raf.read(seg.length);
    if (sealed.length != seg.length) {
      throw const BackupFormatException(
          'This backup file looks damaged or truncated.');
    }
    final clear = await BackupCrypto.open(_bk, 'blob:$key', sealed);
    if (clear == null) {
      throw const BackupFormatException(
          "A file inside this backup failed verification. It may have been modified.");
    }
    return clear;
  }

  Future<void> close() => _raf.close();
}
