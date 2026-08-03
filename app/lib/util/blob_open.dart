import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../data/local_save.dart';
import '../data/repo.dart';
import '../models/relic.dart';

/// Open a relic's file/image blob in the OS default app for its type — the
/// shared "open in default app" hand-off used by both the detail dialog and the
/// row-level action. Decrypts (and downloads on first view) the blob, writes it
/// to a temp file with a real name + extension, then launches it.

/// A filesystem-safe `(base, ext)` for [r]'s blob, so the OS resolves the right
/// default app when we hand off the decrypted file.
///
/// Was a second, drifting copy of the naming + MIME→extension logic; it now
/// defers to [blobNameAndExt] in data/local_save.dart so open-with and
/// save-to-device can never disagree about a file's name or type.
(String, String) relicNameAndExt(Relic r) => blobNameAndExt(r);

/// True when [r] has bytes behind it that have never reached this device.
///
/// Everything else in the app works offline from the local cache, but a blob
/// that was never downloaded genuinely isn't here to open, save or share. The
/// UI used to fold that into the same vague "couldn't open file" as a real
/// error; this lets it say the one thing the user can act on.
bool blobNotOnDevice(RelicRepo repo, Relic r) =>
    r.blobKey != null && repo.cachedBlobPath(r) == null;

/// What to tell the user when a blob can't be produced. [verb] is the action
/// they asked for ("open", "save", "share").
String blobUnavailableMessage(RelicRepo repo, Relic r, String verb) =>
    blobNotOnDevice(repo, r)
        ? "Not downloaded to this device yet — connect once to $verb it"
        : "Couldn't $verb this file";

/// The temp directory decrypted blobs are written to for "open in default app".
Future<Directory> _viewDir() async {
  final dir = await getTemporaryDirectory();
  final v = Directory('${dir.path}/relic_view');
  if (!v.existsSync()) v.createSync(recursive: true);
  return v;
}

/// Ensure [r]'s blob exists as a real named file in the relic_view temp dir;
/// returns its path (null when the blob can't be fetched). Shared by "open in
/// default app" and drag-out: desktop blobs are plaintext on disk, so for a
/// local blob this is a file copy; only sync-evicted blobs hit the network.
/// Cleanup is the age-based [pruneRelicViewCache] — never delete on drop
/// (targets may read the file after the drag returns).
Future<String?> materializeRelicFile(RelicRepo repo, Relic r) async {
  final bytes = await repo.blobBytes(r);
  if (bytes == null) return null;
  final (base, ext) = relicNameAndExt(r);
  final path = '${(await _viewDir()).path}/$base.$ext';
  File(path).writeAsBytesSync(bytes);
  return path;
}

/// Decrypt (and download, if needed) [r]'s blob to a temp file, then hand it to
/// the OS default app for its type. Returns true on a successful hand-off.
Future<bool> openRelicExternally(RelicRepo repo, Relic r) async {
  final path = await materializeRelicFile(repo, r);
  if (path == null) return false;
  // Pass the MIME so apps that ignore the extension still open it.
  final res = await OpenFilex.open(path, type: r.mime);
  return res.type == ResultType.done;
}

/// Delete files left in the "open in default app" temp dir older than [maxAge].
/// Cheap best-effort housekeeping — call once on startup. Same-named files
/// overwrite on re-open, so this only clears one-off leftovers.
Future<void> pruneRelicViewCache({
  Duration maxAge = const Duration(days: 3),
}) async {
  try {
    final dir = await _viewDir();
    final cutoff = DateTime.now().subtract(maxAge);
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      try {
        if (e.statSync().modified.isBefore(cutoff)) e.deleteSync();
      } catch (_) {}
    }
  } catch (_) {}
}
