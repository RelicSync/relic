import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'net.dart';

/// Chunked blob upload — client half of docs/cloudflare/15-large-uploads.md.
///
/// The Cloudflare edge rejects request bodies over ~100 MB before the Worker
/// runs, so sealed blobs past [kSingleShotMax] go up as R2 multipart parts via
/// the /blob/mpu routes; smaller ones keep using the plain POST /blob. Parts
/// are views into the sealed wire (no copies), each retried on transient
/// failure; on any fatal error the upload is aborted server-side best-effort
/// (the bucket lifecycle rule is the backstop for anything stranded).

/// Server rejected the blob — permanent, don't retry. 413 = over the tier's
/// per-item cap (the upgrade moment), 402 = storage quota exceeded, 400/404 =
/// the server won't take this key/request no matter how often it's resent.
class BlobRejected implements Exception {
  final int status;
  BlobRejected(this.status);
  @override
  String toString() => 'BlobRejected($status)';
}

/// Mirrors the Worker's PART_SIZE; the server's create response is
/// authoritative (we send `declared_size` and follow the returned part_size).
const int kSingleShotMax = 64 * 1024 * 1024;

/// Upload sealed blob bytes under [blobKey]. [endpoint] maps an API path to a
/// full Uri (each repo's `_u`); [headers] must carry auth. Throws
/// [BlobRejected] on 413/402, [StateError] otherwise.
Future<void> uploadBlobWire({
  required Uri Function(String path) endpoint,
  required Map<String, String> headers,
  required String blobKey,
  required Uint8List wire,
  void Function(double fraction)? onProgress,
}) async {
  if (wire.length <= kSingleShotMax) {
    final resp = await http.post(
      endpoint('/blob').replace(queryParameters: {'id': blobKey}),
      headers: headers,
      body: wire,
    ).timeout(netTimeoutForBytes(wire.length));
    _check(resp.statusCode);
    onProgress?.call(1);
    return;
  }

  // create — the pre-transfer cap/quota check (413 here = show the upgrade
  // pitch before any bytes move)
  final create = await http.post(
    endpoint('/blob/mpu').replace(queryParameters: {'id': blobKey}),
    headers: {...headers, 'Content-Type': 'application/json'},
    body: jsonEncode({'declared_size': wire.length}),
  ).timeout(kNetTimeout);
  _check(create.statusCode);
  final meta = jsonDecode(create.body) as Map<String, dynamic>;
  final uploadId = meta['upload_id'] as String;
  final partSize = (meta['part_size'] as num).toInt();

  final parts = <Map<String, dynamic>>[];
  try {
    var n = 1;
    for (var off = 0; off < wire.length; off += partSize, n++) {
      final end = math.min(off + partSize, wire.length);
      final chunk = Uint8List.sublistView(wire, off, end);
      final resp = await _withRetry(() => http.put(
            endpoint('/blob/mpu/$blobKey')
                .replace(queryParameters: {'upload_id': uploadId, 'part': '$n'}),
            headers: headers,
            body: chunk,
          ).timeout(netTimeoutForBytes(chunk.length)));
      _check(resp.statusCode);
      final p = jsonDecode(resp.body) as Map<String, dynamic>;
      parts.add({'part': p['part'], 'etag': p['etag']});
      onProgress?.call(end / wire.length);
    }
    final done = await http.post(
      endpoint('/blob/mpu/$blobKey/complete'),
      headers: {...headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'upload_id': uploadId, 'parts': parts}),
    ).timeout(kNetTimeout);
    _check(done.statusCode);
  } catch (_) {
    // free the stranded parts now instead of waiting on the lifecycle sweep
    try {
      await http.delete(
        endpoint('/blob/mpu/$blobKey')
            .replace(queryParameters: {'upload_id': uploadId}),
        headers: headers,
      ).timeout(kNetTimeout);
    } catch (_) {}
    rethrow;
  }
}

void _check(int status) {
  if (status == 200) return;
  // Identical resends can't fix these — surface as permanent, or the caller's
  // ordered push queue retries this blob forever and jams behind it.
  if (status == 400 || status == 402 || status == 404 || status == 413) {
    throw BlobRejected(status);
  }
  throw StateError('blob upload failed ($status)');
}

/// 3 attempts, 1s/2s backoff — for per-part transient failures (network blips,
/// 5xx). 4xx are surfaced immediately (retrying can't fix them).
Future<http.Response> _withRetry(Future<http.Response> Function() go) async {
  var delay = const Duration(seconds: 1);
  for (var attempt = 0;; attempt++) {
    try {
      final r = await go();
      if (r.statusCode < 500 || attempt >= 2) return r;
    } catch (_) {
      if (attempt >= 2) rethrow;
    }
    await Future.delayed(delay);
    delay *= 2;
  }
}
