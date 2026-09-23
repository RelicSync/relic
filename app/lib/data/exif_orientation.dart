import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// How many leading bytes of a photo to read for its EXIF block. The APP1
/// segment that carries it sits right after the start marker and is capped at
/// 64 KiB by the format, so this covers it with room for an APP0 in front.
const int exifHeadBytes = 128 * 1024;

/// The EXIF orientation (1-8) in the head of a JPEG, or null when there is
/// none or the bytes are not a JPEG.
///
/// Phones store a portrait photo as sideways pixels plus this tag. Anything
/// other than 1 means the stored pixels are not the way up the user sees them.
/// [head] may be just the first [exifHeadBytes] of the file; a block cut off by
/// that is treated as no tag rather than an error.
int? jpegExifOrientation(Uint8List head) {
  try {
    final o = img.decodeJpgExif(head)?.imageIfd.orientation;
    return (o != null && o >= 1 && o <= 8) ? o : null;
  } catch (_) {
    return null;
  }
}
