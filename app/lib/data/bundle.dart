import 'dart:typed_data';

import '../models/relic.dart';

/// A relic with file attachments stores them as a single "bundle" blob — the
/// attachment bytes concatenated in manifest order. The manifest (each
/// [Attachment.size]) gives the offsets to slice them back apart. Keeping it to
/// one blob means the sync layer and the Worker treat it exactly like any other
/// single-blob relic (no schema/quota/cleanup changes).

/// Concatenate attachment payloads into one bundle, in order.
Uint8List packBundle(List<Uint8List> parts) {
  final total = parts.fold<int>(0, (n, p) => n + p.length);
  final out = Uint8List(total);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}

/// Slice a single attachment's bytes out of [bundle] using the manifest order.
/// Returns null if the manifest doesn't line up with the bundle length.
Uint8List? sliceAttachment(
    Uint8List bundle, List<Attachment> manifest, String attId) {
  var off = 0;
  for (final a in manifest) {
    if (a.id == attId) {
      if (off + a.size > bundle.length) return null;
      return Uint8List.sublistView(bundle, off, off + a.size);
    }
    off += a.size;
  }
  return null;
}
