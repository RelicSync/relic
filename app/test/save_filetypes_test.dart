import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_save.dart';
import 'package:relic_app/models/relic.dart';

// "Can we download every file that isn't a snippet or text?"
//
// The Save action is gated on blobKey != null, not on a filetype allowlist, and
// ensureBlob/cachedBlobPath are kind-agnostic — so reachability is universal.
// What was NOT universal was the NAME the file landed under: extForMime knew
// about 20 MIME types and mapped everything else to ".bin", so an ordinary
// bitmap or QuickTime video downloaded as "clip.bin" and no app would open it.
//
// These pin the naming for a spread of real formats.

Relic fileRelic({String? filename, String? mime, Kind kind = Kind.file}) =>
    Relic(
      uid: 'u1',
      createdAt: 1,
      updatedAt: 1,
      kind: kind,
      source: Source.share,
      promoted: false,
      byteSize: 10,
      blobKey: 'b1',
      filename: filename,
      mime: mime,
    );

void main() {
  group('a filename with an extension is always trusted verbatim', () {
    // The common case: shares carry a filename, so arbitrary formats survive
    // whether or not any table has heard of them.
    const exotic = [
      'model.blend',
      'art.psd',
      'archive.7z',
      'firmware.hex',
      'sheet.numbers',
      'track.flp',
      'save.sav',
      'notebook.ipynb',
      'cad.dwg',
      'font.woff2',
    ];
    for (final name in exotic) {
      test(name, () {
        final dot = name.lastIndexOf('.');
        final (base, ext) = blobNameAndExt(fileRelic(filename: name));
        expect('$base.$ext', name);
        expect(ext, name.substring(dot + 1));
      });
    }
  });

  group('no filename: the MIME type still yields a real extension', () {
    const cases = {
      // Previously correct.
      'application/pdf': 'pdf',
      'text/plain': 'txt',
      'application/zip': 'zip',
      'video/mp4': 'mp4',
      'audio/mpeg': 'mp3',
      // Previously ".bin", now resolved by the shared table.
      'video/quicktime': 'mov',
      'video/x-msvideo': 'avi',
      'video/x-matroska': 'mkv',
      'audio/x-wav': 'wav',
      'application/x-7z-compressed': '7z',
      'application/vnd.rar': 'rar',
      'application/gzip': 'gz',
      'application/x-tar': 'tar',
      'text/html': 'html',
      'image/vnd.adobe.photoshop': 'psd',
      'application/vnd.android.package-archive': 'apk',
      'application/vnd.oasis.opendocument.text': 'odt',
      // Previously ".bin", now resolved by the subtype heuristic.
      'image/bmp': 'bmp',
      'image/avif': 'avif',
      'video/webm': 'webm',
      'audio/flac': 'flac',
      'application/rtf': 'rtf',
      'application/epub+zip': 'epub',
      'text/css': 'css',
    };
    cases.forEach((mime, want) {
      test('$mime -> .$want', () {
        final (_, ext) = blobNameAndExt(fileRelic(mime: mime));
        expect(ext, want);
      });
    });
  });

  test('a genuinely unknown MIME still degrades to .bin, not to nothing', () {
    final (_, ext) = blobNameAndExt(fileRelic(mime: 'application/x-nonsense-!'));
    expect(ext, 'bin');
    final (_, none) = blobNameAndExt(fileRelic());
    expect(none, 'bin');
  });

  test('photos without a filename keep their image extension', () {
    for (final (mime, want) in const [
      ('image/png', 'png'),
      ('image/jpeg', 'jpg'),
      ('image/webp', 'webp'),
      ('image/heic', 'heic'),
    ]) {
      final (_, ext) =
          blobNameAndExt(fileRelic(mime: mime, kind: Kind.photo));
      expect(ext, want, reason: mime);
    }
  });

  group('extension -> MIME, which is what MediaStore files the download under',
      () {
    const cases = {
      'pdf': 'application/pdf',
      'mov': 'video/quicktime',
      'mkv': 'video/x-matroska',
      '7z': 'application/x-7z-compressed',
      'rar': 'application/vnd.rar',
      'apk': 'application/vnd.android.package-archive',
      'jpg': 'image/jpeg',
      'png': 'image/png',
      'webm': 'video/webm',
      'flac': 'audio/flac',
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    };
    cases.forEach((ext, want) {
      test('.$ext -> $want', () => expect(mimeForExt(ext), want));
    });

    test('an unknown extension falls back to a type every OS accepts', () {
      expect(mimeForExt('blend'), 'application/octet-stream');
      expect(mimeForExt(''), 'application/octet-stream');
    });
  });

  test('round-trips: naming a file then typing it stays self-consistent', () {
    // The save path derives the MIME from the extension it just wrote, so these
    // two must agree or MediaStore appends a second suffix ("clip.mov.qt").
    for (final mime in const [
      'video/quicktime',
      'image/bmp',
      'audio/flac',
      'application/pdf',
      'application/x-7z-compressed',
    ]) {
      final (_, ext) = blobNameAndExt(fileRelic(mime: mime));
      expect(extForMime(mimeForExt(ext)), ext, reason: mime);
    }
  });
}
