import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:relic_crypto/relic_crypto.dart';

import '../models/relic.dart';
import '../models/rich_body.dart';
import 'bundle.dart';
import 'relic_db.dart';

/// The pure work the phone's sync hands to a background isolate.
///
/// Every job here takes plain data and returns plain data. That is a hard
/// constraint, not a style: `Isolate.run` copies the closure it is given
/// together with everything the closure's scope captured, and a closure made
/// inside the repo would drag along the repo itself, with its SQLite handle,
/// HTTP client and socket, none of which can leave the UI isolate. So the
/// hop happens HERE, in top-level functions whose closures can capture
/// nothing but their own arguments. The repo pulls out what a job needs
/// (the master key, a list of envelopes, a file path), calls the job, and
/// puts the answer back itself.
///
/// Why this file exists: the crypto is pure Dart XChaCha20, and it used to run
/// on the UI isolate, one envelope at a time, for every item a sync pulled and
/// every photo it fetched, followed by a synchronous JSON write of the entire
/// cache after every pass. On a big vault that froze the list for seconds on a
/// timer. None of that work needs the UI isolate; only the SQLite index and
/// the widget tree do, and those stay where they are.
///
/// Nothing here throws for a bad item. A record that will not open belongs to
/// somebody else (a stale cache from another account, a tampered row), and the
/// answer for it is "skip", never "abort the sync".

/// Run [job] on a background isolate, inline if one cannot be spawned.
///
/// Falling back inline is slow but correct, which is the right way round for
/// a sync. Only the top-level jobs below should call this, for the capture
/// reason given above.
Future<T> offThread<T>(Future<T> Function() job) async {
  try {
    return await Isolate.run(job);
  } catch (_) {
    return await job();
  }
}

/// Build the in-memory relic from its envelope and opened payload.
Relic relicFromEnvelope(Map<String, dynamic> env, Map<String, dynamic> p) =>
    Relic(
      uid: env['uid'] as String,
      createdAt: (env['created_at'] as num).toInt(),
      updatedAt: (env['updated_at'] as num).toInt(),
      kind: kindFromStr(p['kind'] as String? ?? 'other'),
      source: sourceFromStr(p['source'] as String? ?? 'api'),
      promoted: env['promoted'] as bool? ?? false,
      byteSize: (env['byte_size'] as num?)?.toInt() ?? 0,
      device: p['device'] as String?,
      mime: p['mime'] as String?,
      filename: p['filename'] as String?,
      blobKey: env['blob_key'] as String?,
      tags: (p['tags'] as List?)?.cast<String>() ?? const [],
      userTags: (p['user_tags'] as List?)?.cast<String>() ?? const [],
      title: p['title'] as String?,
      note: p['note'] as String?,
      content: p['content'] as String?,
      preview: p['preview'] as String?,
      attachments: Attachment.listFrom(p['attachments']),
      rich: RichBody.fromJson(p['rich']),
      voice: Relic.voiceFrom(p['voice']),
    );

/// Open every relic envelope under [mk], off the UI isolate.
///
/// The result lines up with [envs] by index; a null means that envelope would
/// not open under this key (or was malformed), and the caller leaves it out.
Future<List<Relic?>> openRelicEnvelopes(
        Uint8List mk, List<Map<String, dynamic>> envs) =>
    offThread(() => _openRelicEnvelopes(mk, envs));

Future<List<Relic?>> _openRelicEnvelopes(
    Uint8List mk, List<Map<String, dynamic>> envs) async {
  final out = <Relic?>[];
  for (final env in envs) {
    Map<String, dynamic>? p;
    try {
      p = await RelicCrypto.openRelicPayload(mk, env);
    } catch (_) {
      p = null;
    }
    Relic? r;
    if (p != null) {
      try {
        r = relicFromEnvelope(env, p);
      } catch (_) {
        r = null;
      }
    }
    out.add(r);
  }
  return out;
}

/// Open every AI record envelope under [mk], keyed by uid, off the UI
/// isolate. Records that will not open are simply absent from the map.
Future<Map<String, Map<String, dynamic>>> openAiEnvelopes(
        Uint8List mk, List<Map<String, dynamic>> envs) =>
    offThread(() => _openAiEnvelopes(mk, envs));

Future<Map<String, Map<String, dynamic>>> _openAiEnvelopes(
    Uint8List mk, List<Map<String, dynamic>> envs) async {
  final out = <String, Map<String, dynamic>>{};
  for (final env in envs) {
    try {
      final uid = env['uid'] as String;
      final p = await RelicCrypto.openAiPayload(
          mk, uid, env['n'] as String, env['ct'] as String);
      if (p != null) out[uid] = p;
    } catch (_) {
      // Not ours to read, or not a record at all.
    }
  }
  return out;
}

/// The search index text for [relics], derived off the UI isolate. See
/// [RelicDb.deriveIndexText] for why this is the expensive half of indexing.
Future<List<IndexText>> deriveIndexTextOffThread(List<Relic> relics) =>
    offThread(() async => RelicDb.deriveIndexText(relics));

/// Decrypt a downloaded blob straight into its cache file, then slice its
/// attachments out beside it, all off the UI isolate.
///
/// Written under a temporary name and renamed into place, so a reader that
/// checks the path while this runs sees no file rather than half a photo.
/// [attachmentPaths] maps attachment id to the file each slice should land
/// in; slices that already exist are left alone.
Future<bool> openBlobToFile(
  Uint8List mk,
  String key,
  Uint8List wire,
  String path, {
  List<Attachment> attachments = const [],
  Map<String, String> attachmentPaths = const {},
}) =>
    offThread(() => _openBlobToFile(
        mk, key, wire, path, attachments, attachmentPaths));

Future<bool> _openBlobToFile(
  Uint8List mk,
  String key,
  Uint8List wire,
  String path,
  List<Attachment> attachments,
  Map<String, String> attachmentPaths,
) async {
  try {
    final clear = await RelicCrypto.openBlob(mk, key, wire);
    if (clear == null) return false;
    await _writeAtomically(path, clear);
    for (final a in attachments) {
      final out = attachmentPaths[a.id];
      if (out == null || File(out).existsSync()) continue;
      final bytes = sliceAttachment(clear, attachments, a.id);
      if (bytes != null) await _writeAtomically(out, bytes);
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Serialise the cache document and write it, off the UI isolate.
///
/// The encode is the expensive half: every envelope's ciphertext, base64, in
/// one string. Written under a temporary name and renamed, so a crash
/// mid-write leaves the old cache whole rather than a truncated new one.
Future<void> writeCacheFile(String path, Map<String, dynamic> doc) =>
    offThread(() => _writeCacheFile(path, doc));

Future<void> _writeCacheFile(String path, Map<String, dynamic> doc) async {
  final tmp = File('$path.tmp');
  await tmp.writeAsString(jsonEncode(doc), flush: true);
  await tmp.rename(path);
}

/// Read and parse the cache document, off the UI isolate. Null when it is
/// missing or unreadable; the caller treats both as "start from empty".
Future<Map<String, dynamic>?> readCacheFile(String path) =>
    offThread(() => _readCacheFile(path));

Future<Map<String, dynamic>?> _readCacheFile(String path) async {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    final v = jsonDecode(await f.readAsString());
    return v is Map<String, dynamic> ? v : null;
  } catch (_) {
    return null;
  }
}

Future<void> _writeAtomically(String path, Uint8List bytes) async {
  final tmp = File('$path.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(path);
}
