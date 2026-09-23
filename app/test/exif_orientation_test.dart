// The rotate tag a phone writes into a portrait photo. The one-time re-read of
// photos read on their side keys on it, so it has to be read correctly from the
// first slice of the file and never throw on anything odd.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:relic_app/data/exif_orientation.dart';

Uint8List _jpeg({int? orientation}) {
  final im = img.Image(width: 64, height: 32);
  if (orientation != null) im.exif.imageIfd.orientation = orientation;
  return img.encodeJpg(im);
}

void main() {
  test('reads the rotate tag a phone writes', () {
    expect(jpegExifOrientation(_jpeg(orientation: 6)), 6);
    expect(jpegExifOrientation(_jpeg(orientation: 8)), 8);
    expect(jpegExifOrientation(_jpeg(orientation: 1)), 1);
  });

  test('a photo with no tag has no orientation', () {
    expect(jpegExifOrientation(_jpeg()), isNull);
  });

  test('works on just the head of the file', () {
    final full = _jpeg(orientation: 6);
    final head = Uint8List.sublistView(full, 0, full.length ~/ 2);
    expect(jpegExifOrientation(head), 6);
  });

  test('anything that is not a JPEG is null, never an error', () {
    expect(jpegExifOrientation(Uint8List(0)), isNull);
    expect(jpegExifOrientation(Uint8List.fromList([0x89, 0x50, 0x4e, 0x47])), isNull);
    expect(jpegExifOrientation(Uint8List.fromList([0xff, 0xd8, 0xff, 0xe1, 0x00])), isNull);
  });
}
