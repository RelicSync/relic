import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/relic.dart';
import 'repo.dart';

/// One-click desktop save, shared by the row download action and the edit
/// screen's save-to-device action: decrypt (and fetch, if needed) the relic's blob and
/// write it into the user's save folder without a picker, never overwriting.
/// Returns the written path; throws with a readable message on failure.
Future<String> saveBlobToDisk(RelicRepo repo, Relic r) async {
  final bytes = await repo.blobBytes(r);
  if (bytes == null) throw StateError('the file’s data isn’t available');
  final dir = await desktopSaveDir(repo);
  final (base, ext) = blobNameAndExt(r);
  final sep = Platform.pathSeparator;
  var path = '$dir$sep$base.$ext';
  for (var n = 1; File(path).existsSync(); n++) {
    path = '$dir$sep$base ($n).$ext';
  }
  File(path).writeAsBytesSync(bytes);
  return path;
}

/// Resolve the desktop save folder: the user's configured folder, else the OS
/// Downloads dir, else ~/Downloads — created if missing.
Future<String> desktopSaveDir(RelicRepo repo) async {
  final configured = repo.saveDir?.trim();
  if (configured != null && configured.isNotEmpty) return configured;
  String? dl;
  try {
    dl = (await getDownloadsDirectory())?.path;
  } catch (_) {}
  if (dl == null || dl.isEmpty) {
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home != null) dl = '$home${Platform.pathSeparator}Downloads';
  }
  if (dl == null || dl.isEmpty) {
    throw StateError('couldn’t find your Downloads folder');
  }
  Directory(dl).createSync(recursive: true);
  return dl;
}

String safeFileName(String s) {
  final cleaned = s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_').trim();
  return cleaned.isEmpty ? 'relic' : cleaned;
}

String blobBaseName(Relic r) {
  final raw = r.filename ?? r.title ?? 'relic-${r.uid}';
  final dot = raw.lastIndexOf('.');
  return safeFileName(dot > 0 ? raw.substring(0, dot) : raw);
}

(String, String) blobNameAndExt(Relic r) {
  final fn = r.filename;
  if (fn != null && fn.contains('.')) {
    final i = fn.lastIndexOf('.');
    return (safeFileName(fn.substring(0, i)), fn.substring(i + 1));
  }
  final ext = r.kind == Kind.photo
      ? switch (r.mime) {
          'image/png' => 'png',
          'image/jpeg' || 'image/jpg' => 'jpg',
          'image/webp' => 'webp',
          'image/gif' => 'gif',
          'image/heic' => 'heic',
          _ => 'png',
        }
      : extForMime(r.mime);
  return (blobBaseName(r), ext);
}

/// MIME <-> extension, the single source of truth for both directions.
///
/// Only the pairs where the mapping is NOT mechanical live here; anything of
/// the shape `type/ext` (image/png, video/webm, audio/flac, application/pdf…)
/// is derived by [_extFromSubtype] / [_mimeFromKnownExt] instead of being
/// enumerated. That keeps a short table honest rather than a long one stale.
const Map<String, String> _mimeToExt = {
  'application/msword': 'doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
      'docx',
  'application/vnd.ms-excel': 'xls',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
  'application/vnd.ms-powerpoint': 'ppt',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation':
      'pptx',
  'application/vnd.oasis.opendocument.text': 'odt',
  'application/vnd.oasis.opendocument.spreadsheet': 'ods',
  'application/vnd.oasis.opendocument.presentation': 'odp',
  'text/plain': 'txt',
  'text/markdown': 'md',
  'text/html': 'html',
  'text/x-python': 'py',
  'application/javascript': 'js',
  'application/x-yaml': 'yaml',
  'application/gzip': 'gz',
  'application/x-tar': 'tar',
  'application/x-7z-compressed': '7z',
  'application/vnd.rar': 'rar',
  'application/x-rar-compressed': 'rar',
  'application/x-bzip2': 'bz2',
  'application/octet-stream': 'bin',
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/svg+xml': 'svg',
  'image/tiff': 'tif',
  'image/x-icon': 'ico',
  'image/vnd.adobe.photoshop': 'psd',
  'video/quicktime': 'mov',
  'video/x-msvideo': 'avi',
  'video/x-matroska': 'mkv',
  'video/mpeg': 'mpg',
  'audio/mpeg': 'mp3',
  'audio/x-wav': 'wav',
  'audio/vnd.wave': 'wav',
  'audio/mp4': 'm4a',
  'audio/x-m4a': 'm4a',
  'application/vnd.android.package-archive': 'apk',
  'application/x-msdownload': 'exe',
};

/// The reverse lookup, first spelling wins (so image/jpeg beats image/jpg).
final Map<String, String> _extToMime = {
  for (final e in _mimeToExt.entries.toList().reversed) e.value: e.key,
};

/// `application/x-foo` / `image/bmp` -> `foo` / `bmp`, when the subtype is
/// already extension-shaped. This is what keeps unlisted-but-ordinary types
/// (image/bmp, video/webm, audio/flac, application/rtf…) from landing as .bin.
String? _extFromSubtype(String mime) {
  final slash = mime.indexOf('/');
  if (slash < 0) return null;
  var sub = mime.substring(slash + 1).trim().toLowerCase();
  // Drop parameters ("text/plain; charset=utf-8") and vendor prefixes.
  final semi = sub.indexOf(';');
  if (semi >= 0) sub = sub.substring(0, semi).trim();
  if (sub.startsWith('x-')) sub = sub.substring(2);
  // A '+' suffix names the underlying syntax, not the format (svg+xml).
  final plus = sub.indexOf('+');
  if (plus > 0) sub = sub.substring(0, plus);
  if (sub.isEmpty || sub.length > 8) return null;
  return RegExp(r'^[a-z0-9]+$').hasMatch(sub) ? sub : null;
}

/// Map a file's MIME type to a sensible extension so the OS picks the right
/// viewer when we hand the decrypted blob off. Falls back to 'bin' only when
/// the MIME is missing or genuinely unparseable.
String extForMime(String? mime) {
  final m = (mime ?? '').trim().toLowerCase();
  if (m.isEmpty) return 'bin';
  final exact = _mimeToExt[m.split(';').first.trim()];
  if (exact != null) return exact;
  return _extFromSubtype(m) ?? 'bin';
}

/// Map an extension back to a MIME type, for the save paths that only know a
/// filename (attachments). MediaStore and the system save sheet both file by
/// MIME, so a wrong type here lands the file in the wrong place.
String mimeForExt(String ext) {
  final e = ext.toLowerCase().replaceAll('.', '').trim();
  if (e.isEmpty) return 'application/octet-stream';
  final exact = _extToMime[e];
  if (exact != null) return exact;
  return _mimeFromKnownExt(e) ?? 'application/octet-stream';
}

/// The mechanical inverse: an extension that IS its own subtype under a
/// guessable top-level type. Deliberately conservative — a wrong top-level
/// type is worse than application/octet-stream, which every OS handles.
String? _mimeFromKnownExt(String ext) {
  const images = {'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif'};
  const videos = {'mp4', 'webm', 'ogg', 'mpeg'};
  const audios = {'flac', 'aac', 'opus', 'midi'};
  const apps = {'pdf', 'zip', 'json', 'xml', 'rtf', 'epub', 'wasm', 'sql'};
  const texts = {'css', 'csv'};
  if (images.contains(ext)) return 'image/$ext';
  if (videos.contains(ext)) return 'video/$ext';
  if (audios.contains(ext)) return 'audio/$ext';
  if (apps.contains(ext)) return 'application/$ext';
  if (texts.contains(ext)) return 'text/$ext';
  return null;
}
