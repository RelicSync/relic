import 'dart:io';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../models/relic.dart';
import '../platform/android_save.dart';
import '../util/blob_open.dart';
import 'local_save.dart';
import 'repo.dart';

/// Where mobile's "Save to device" writes.
///
/// Replaces the old hard-coded behaviour, which sent files through
/// `FileSaver.saveFile` — that plugin writes to `getExternalFilesDir(null)`,
/// i.e. app-private storage Android 11+ hides from file managers and deletes on
/// uninstall. Users had no way to change it and no way to find the file.
enum SaveMode {
  /// Public Downloads via MediaStore (Android 10+). The default where possible.
  downloads,

  /// The system save sheet (ACTION_CREATE_DOCUMENT): the user picks the folder
  /// and filename per save. The fallback below Android 10, where there is no
  /// MediaStore.Downloads collection to write to without a storage permission.
  ask,

  /// Images into the photo gallery; non-images fall back to [ask].
  gallery,
}

extension SaveModeLabel on SaveMode {
  String get id => switch (this) {
        SaveMode.downloads => 'downloads',
        SaveMode.ask => 'ask',
        SaveMode.gallery => 'gallery',
      };

  String get label => switch (this) {
        SaveMode.downloads => 'Downloads',
        SaveMode.ask => 'Ask every time',
        SaveMode.gallery => 'Photos gallery',
      };

  String get blurb => switch (this) {
        SaveMode.downloads => 'Your phone’s Downloads folder.',
        SaveMode.ask => 'Pick the folder each time you save.',
        SaveMode.gallery => 'Images go to Photos; other files ask.',
      };
}

SaveMode _modeFromId(String? id) => switch (id) {
      'downloads' => SaveMode.downloads,
      'ask' => SaveMode.ask,
      'gallery' => SaveMode.gallery,
      _ => SaveMode.downloads,
    };

/// Device-local save preference. Kept in the same secure store as the other
/// mobile device prefs (device name, auto-vault, appearance) so there's one
/// place to look, and deliberately outside `_Creds.clear()` so it survives a
/// disconnect/reconnect.
class SavePrefs {
  static const _s = FlutterSecureStorage();
  static const _kMode = 'relic.save.mode';

  /// The stored mode, defaulting to Downloads — and degrading to [SaveMode.ask]
  /// on devices with no public Downloads collection (below Android 10) so the
  /// setting never names a destination the device can't actually write to.
  static Future<SaveMode> mode() async {
    final stored = _modeFromId(await _s.read(key: _kMode));
    if (stored == SaveMode.downloads && !await AndroidSave.available()) {
      return SaveMode.ask;
    }
    return stored;
  }

  static Future<void> setMode(SaveMode m) =>
      _s.write(key: _kMode, value: m.id);

  /// Which modes to offer on this device (Downloads is hidden below Android 10).
  static Future<List<SaveMode>> options() async => [
        if (await AndroidSave.available()) SaveMode.downloads,
        SaveMode.ask,
        SaveMode.gallery,
      ];
}

/// What a save attempt actually did — so the UI can tell "saved" from "the user
/// backed out of the picker" from "it failed", instead of the old code's
/// unconditional green check.
class SaveOutcome {
  final bool saved;
  final bool canceled;

  /// User-facing destination ("Download/report.pdf", "Photos"), when known.
  final String? location;

  const SaveOutcome.ok(this.location)
      : saved = true,
        canceled = false;
  const SaveOutcome.canceled()
      : saved = false,
        canceled = true,
        location = null;
}

/// Save a relic's blob to the device, honouring the user's [SaveMode].
///
/// Works for every relic that HAS a blob — the caller gates on
/// `blobKey != null`, not on a filetype allowlist, so photos, files and
/// anything else with bytes behind it are all saveable. Text and snippets
/// (Kind.string) have no blob and no Save action.
///
/// Throws [SaveFailure] (or the underlying plugin error) when the save fails.
Future<SaveOutcome> saveBlobOnMobile(RelicRepo repo, Relic r) async {
  // Fetches on first save if the blob was never pulled down; kind-agnostic.
  // Offline, that fetch just fails, so say which of the two it was rather than
  // reporting "data isn't available" for a file that's merely not downloaded.
  if (!await repo.ensureBlob(r) || repo.cachedBlobPath(r) == null) {
    throw SaveFailure(blobNotOnDevice(repo, r)
        ? 'it isn’t downloaded to this device yet'
        : 'the file’s data isn’t available');
  }
  final path = repo.cachedBlobPath(r)!;
  final (base, ext) = blobNameAndExt(r);
  return saveFileOnMobile(
    sourcePath: path,
    base: base,
    ext: ext,
    mime: r.mime,
    isImage: r.kind == Kind.photo,
  );
}

/// The shared implementation, also used for a relic's individual attachments
/// and for the recovery kit.
///
/// Supply exactly one of [sourcePath] or [bytes]. Prefer the path: relics run
/// to 100 MB (maxItemBytes) and buffering one in the Dart heap and again across
/// the platform channel is an out-of-memory risk on mid-range devices. [bytes]
/// exists for small payloads generated in memory that were never on disk.
Future<SaveOutcome> saveFileOnMobile({
  String? sourcePath,
  Uint8List? bytes,
  required String base,
  required String ext,
  String? mime,
  bool isImage = false,
}) async {
  assert((sourcePath == null) != (bytes == null),
      'pass exactly one of sourcePath / bytes');
  final mode = await SavePrefs.mode();
  final name = ext.isEmpty ? base : '$base.$ext';
  // Prefer the extension's type: it is what the saved filename actually claims,
  // and MediaStore will append its own suffix if the name and MIME disagree.
  final type = ext.isEmpty ? (mime ?? mimeForExt(ext)) : mimeForExt(ext);

  if (mode == SaveMode.gallery && isImage) {
    // Gal needs WRITE_EXTERNAL_STORAGE below Android 10 and throws
    // accessDenied without it; the old code never asked, so gallery saves just
    // failed there.
    if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
      throw const SaveFailure('Relic needs permission to write to Photos');
    }
    if (sourcePath != null) {
      await Gal.putImage(sourcePath);
    } else {
      await Gal.putImageBytes(bytes!, name: base);
    }
    return const SaveOutcome.ok('Photos');
  }

  if (mode == SaveMode.downloads && await AndroidSave.available()) {
    // MediaStore streams from a file, so an in-memory payload gets spooled to
    // the cache dir first. Only ever small ones take this branch.
    final path = sourcePath ?? await _spool(bytes!, name);
    try {
      return SaveOutcome.ok(
        await AndroidSave.saveToDownloads(
            name: name, sourcePath: path, mime: type),
      );
    } catch (_) {
      // MediaStore refused (an OEM-restricted Downloads collection, a storage
      // policy, a name it won't accept). Fall through to the system save sheet
      // rather than failing outright: the user still gets their file, just via
      // a picker. Never let the preferred destination being unavailable mean
      // "you can't save this".
    } finally {
      if (sourcePath == null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  }

  // Ask every time (and the fallback for gallery-mode non-images, and for
  // Downloads on pre-Android-10). saveAs returns null when the user dismisses
  // the sheet — that is a cancel, not a failure.
  // MimeType.custom is required for customMimeType to be honoured — with any
  // other enum value file_saver uses the enum's own type and ignores it.
  // filePath (not bytes) makes file_saver stream from disk natively.
  final where = await FileSaver.instance.saveAs(
    name: base,
    filePath: sourcePath,
    bytes: sourcePath == null ? bytes : null,
    fileExtension: ext,
    mimeType: MimeType.custom,
    customMimeType: type,
  );
  if (where == null || where.isEmpty) return const SaveOutcome.canceled();
  return const SaveOutcome.ok(null);
}

/// Write an in-memory payload to a private temp file so the streaming save
/// paths can take it. Caller deletes it.
Future<String> _spool(Uint8List bytes, String name) async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/relic_save_$name');
  await f.writeAsBytes(bytes);
  return f.path;
}
