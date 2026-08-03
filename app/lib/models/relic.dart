import 'dart:convert';

/// Mirrors relic-core's Relic (SPEC §4 / docs/wire-format.md).
enum Kind { string, photo, file, other }

/// Per-relic sync state for the row indicator. [synced] = acknowledged by the
/// server (no badge). [syncing] = a queued push/delete is in flight (spinner +
/// "Syncing…"). [blocked] = the server rejected it (e.g. quota) and it won't
/// sync without action (warning badge).
enum RelicSync { synced, syncing, blocked }

/// Human copy for a recorded sync rejection (sync_rejections.status). Pure so
/// it's unit-testable; hosts show it in the "Not synced" popover and the sync
/// issues sheet. Status 0 = the blob file was missing locally at push time.
String syncRejectionReason(int status) => switch (status) {
  402 => 'Vault is full on your plan',
  413 => 'Too large for your plan',
  403 => 'Confirm your email to sync',
  409 => 'A newer copy exists elsewhere',
  _ => 'Sync error',
};

/// Optional second line under [syncRejectionReason]: what the user can DO.
String? syncRejectionHint(int status) => switch (status) {
  402 => 'Free up space or upgrade, then retry.',
  413 => 'Upgrade your plan to sync items this large.',
  409 => 'This usually resolves itself on the next sync.',
  _ => null,
};

/// One file attached to a relic. The bytes for every attachment of a relic are
/// concatenated into a single "bundle" blob (the relic's [Relic.blobKey]); this
/// manifest entry — stored inside the encrypted relic payload — gives the name,
/// type, and the byte length used to slice the bundle back apart.
class Attachment {
  final String id; // stable id; also the on-disk cache filename suffix
  final String name; // original filename
  final String? mime;
  final int size; // bytes

  const Attachment({
    required this.id,
    required this.name,
    this.mime,
    required this.size,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (mime != null) 'mime': mime,
        'size': size,
      };

  static Attachment fromJson(Map<String, dynamic> j) => Attachment(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'file',
        mime: j['mime'] as String?,
        size: (j['size'] as num?)?.toInt() ?? 0,
      );

  /// Decode a JSON list (or a JSON-encoded string) into a manifest.
  static List<Attachment> listFrom(Object? v) {
    if (v == null) return const [];
    final raw = v is String ? (v.isEmpty ? null : jsonDecode(v)) : v;
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => Attachment.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  static List<Map<String, dynamic>> listToJson(List<Attachment> a) =>
      a.map((e) => e.toJson()).toList();
}

enum Source { clipboard, upload, hotkey, share, api }

/// Tags that describe a clip's PROVENANCE (kind seeds, the app it was copied
/// from) rather than its content — displayed after content tags. Covers the
/// capture seeds plus the mapped source-app vocabulary (foreground_app.dart);
/// unmapped exe stems still show, just in their stored position.
const Set<String> _provenanceTags = {
  'photo', 'screenshot',
  'chrome', 'edge', 'firefox', 'brave', 'opera', 'vivaldi', 'arc', 'safari',
  'vscode', 'visualstudio', 'intellij', 'pycharm', 'webstorm', 'rider',
  'clion', 'goland', 'androidstudio', 'terminal', 'slack', 'discord', 'teams',
  'telegram', 'whatsapp', 'word', 'excel', 'powerpoint', 'outlook', 'notion',
  'obsidian', 'acrobat', 'notepad',
};

Kind kindFromStr(String s) => switch (s) {
      'string' => Kind.string,
      'photo' => Kind.photo,
      'file' => Kind.file,
      _ => Kind.other,
    };

String kindToStr(Kind k) => k.name;

Source sourceFromStr(String s) => switch (s) {
      'clipboard' => Source.clipboard,
      'upload' => Source.upload,
      'hotkey' => Source.hotkey,
      'share' => Source.share,
      _ => Source.api,
    };

/// A pending clip reminder (local-only, never synced). `remindAt` is epoch
/// milliseconds (DateTime.millisecondsSinceEpoch), independent of the
/// seconds-based relic timestamps.
class Reminder {
  const Reminder(this.id, this.relicUid, this.remindAt, this.note);
  final int id;
  final String relicUid;
  final int remindAt;
  final String? note;
}

class Relic {
  final String uid;
  final int createdAt; // unix seconds
  final int updatedAt;
  final Kind kind;
  final Source source;
  final bool promoted;
  final int byteSize;
  final String? device;
  final String? mime;
  final String? filename;
  final String? blobKey;
  final List<String> tags; // deterministic subtype tags
  final List<String> userTags;
  final String? title;
  final String? note;
  final String? content; // decrypted text (string relics)
  final String? preview;
  final List<Attachment> attachments; // files packed into the bundle blob

  const Relic({
    required this.uid,
    required this.createdAt,
    required this.updatedAt,
    required this.kind,
    required this.source,
    required this.promoted,
    required this.byteSize,
    this.device,
    this.mime,
    this.filename,
    this.blobKey,
    this.tags = const [],
    this.userTags = const [],
    this.title,
    this.note,
    this.content,
    this.preview,
    this.attachments = const [],
  });

  bool get isSecret => tags.contains('secret');

  /// Snake-case wire shape, key-compatible with LocalDeskRepo._fromJson (the
  /// vault-export format is the same shape the sync payloads use).
  Map<String, dynamic> toJson() => {
        'uid': uid,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'kind': kindToStr(kind),
        'source': source.name,
        'promoted': promoted,
        'byte_size': byteSize,
        if (device != null) 'device': device,
        if (mime != null) 'mime': mime,
        if (filename != null) 'filename': filename,
        if (blobKey != null) 'blob_key': blobKey,
        'tags': tags,
        'user_tags': userTags,
        if (title != null) 'title': title,
        if (note != null) 'note': note,
        if (content != null) 'content': content,
        if (preview != null) 'preview': preview,
        if (attachments.isNotEmpty)
          'attachments': Attachment.listToJson(attachments),
      };

  bool get hasAttachments => attachments.isNotEmpty;

  /// The primary line shown in a row / dialog title. An explicit [title] and a
  /// [filename] pass through verbatim; derived text (preview/content) is run
  /// through [cleanDisplayText] first so leading bullets, quote marks, and
  /// stray one-letter fragments don't headline the row. Display-only — the
  /// stored fields are never mutated.
  String get displayTitle {
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    for (final derived in [preview, content]) {
      if (derived == null) continue;
      final cleaned = cleanDisplayText(derived);
      if (cleaned.isNotEmpty) return cleaned;
    }
    final f = filename;
    if (f != null && f.isNotEmpty) return f;
    return '(untitled)';
  }

  /// All user-facing tags (deterministic + user), for the meta line. Content
  /// tags lead; provenance tags (photo/screenshot seeds, source apps) sort
  /// last so the row's few visible chip slots say what the clip IS, not where
  /// it came from. De-duplicated (a user tag that shadows a machine tag shows
  /// once).
  List<String> get allTags {
    final seen = <String>{};
    final out = <String>[];
    void take(Iterable<String> src) {
      for (final t in src) {
        if (seen.add(t.toLowerCase())) out.add(t);
      }
    }

    final machine = tags.where((t) => t != 'secret');
    take(userTags);
    take(machine.where((t) => !_provenanceTags.contains(t)));
    take(machine.where(_provenanceTags.contains));
    return out;
  }

  /// Whether [t] is one of this relic's user-applied tags (case-insensitive).
  /// Pure — used by the row to render user tags as chips and machine tags as
  /// quiet "#tag" text.
  bool isUserTag(String t) {
    final lower = t.toLowerCase();
    for (final u in userTags) {
      if (u.toLowerCase() == lower) return true;
    }
    return false;
  }

  /// The first http(s) link contained in this relic's text, if any. Powers the
  /// "open in browser" action on link items. Null for secrets or when there's
  /// no openable URL. Handles both full URLs and url-tagged bare domains.
  String? get firstUrl {
    if (isSecret) return null;
    final text = content ?? preview ?? title ?? '';
    final m = RegExp(r'''https?://[^\s<>"')\]}]+''', caseSensitive: false)
        .firstMatch(text);
    if (m != null) {
      // Drop trailing sentence punctuation that isn't part of the link.
      return m.group(0)!.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
    }
    // A url-tagged relic saved without a scheme (e.g. "example.com/path").
    if (tags.contains('url')) {
      final t = text.trim();
      if (RegExp(r'^(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/\S*)?$',
              caseSensitive: false)
          .hasMatch(t)) {
        return 'https://$t';
      }
    }
    return null;
  }

  /// True when [firstUrl] would return a link — for showing the open action.
  bool get hasLink => firstUrl != null;

  /// True when this is a blob-backed file/image that can be handed to the OS
  /// default app (excludes secrets and text-only relics).
  bool get hasFile =>
      (kind == Kind.photo || kind == Kind.file) &&
      blobKey != null &&
      !isSecret;

  /// [blobKey]/[clearBlobKey]: attachment edits rebuild the bundle under a
  /// fresh key (or drop it entirely when the last attachment goes) — the only
  /// mutation that ever changes a relic's blob identity.
  Relic copyWith({
    bool? promoted,
    String? title,
    String? note,
    int? createdAt,
    int? updatedAt,
    List<String>? userTags,
    List<String>? tags,
    String? content,
    String? preview,
    List<Attachment>? attachments,
    int? byteSize,
    String? blobKey,
    bool clearBlobKey = false,
  }) =>
      Relic(
        uid: uid,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        kind: kind,
        source: source,
        promoted: promoted ?? this.promoted,
        byteSize: byteSize ?? this.byteSize,
        device: device,
        mime: mime,
        filename: filename,
        blobKey: clearBlobKey ? null : (blobKey ?? this.blobKey),
        tags: tags ?? this.tags,
        userTags: userTags ?? this.userTags,
        title: title ?? this.title,
        note: note ?? this.note,
        content: content ?? this.content,
        preview: preview ?? this.preview,
        attachments: attachments ?? this.attachments,
      );
}

/// Display-only cleanup for a derived title line (preview/content). Strips
/// leading list bullets, quote marks, and heading punctuation, drops a stray
/// one-letter fragment left by a mangled bullet (e.g. "o 1.0.16+19 by"), and
/// collapses internal whitespace to single spaces. Never mutates the stored
/// data — callers pass a copy of the raw text.
String cleanDisplayText(String raw) {
  var s = raw.trimLeft();
  // Leading bullet / punctuation / quote runs, stripped to a stable point.
  final lead = RegExp(r'''^[-–—*•·>#|:;,.)\]}»"'`\s]+''');
  while (true) {
    final next = s.replaceFirst(lead, '');
    if (next == s) break;
    s = next;
  }
  // A single stray alphabetic char (not the words "a"/"I") left by a mangled
  // bullet like "o 1.0.16+19 by" → drop it, keeping the real text.
  final firstSpace = s.indexOf(RegExp(r'\s'));
  if (firstSpace > 0) {
    final head = s.substring(0, firstSpace);
    if (head.length == 1 &&
        RegExp(r'[A-Za-z]').hasMatch(head) &&
        head != 'a' &&
        head != 'A' &&
        head != 'I') {
      s = s.substring(firstSpace).trimLeft();
    }
  }
  // Collapse internal whitespace/newline/tab runs to single spaces.
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return raw.trim();
  return s;
}

/// Compact meta-line age: "just now", "14m", "1h", "2d" for the first three
/// days, then the absolute capture date, e.g. "June 20th, 2026".
String relativeAge(int createdAtSecs, int nowSecs) {
  final age = nowSecs - createdAtSecs;
  if (age < 8) return 'just now';
  if (age < 60) return '${age}s';
  if (age < 3600) return '${age ~/ 60}m';
  if (age < 86400) return '${age ~/ 3600}h';
  if (age < 3 * 86400) return '${age ~/ 86400}d';
  return formatCaptureDate(createdAtSecs);
}

const List<String> _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December',
];

String _ordinalDay(int d) {
  if (d >= 11 && d <= 13) return '${d}th';
  switch (d % 10) {
    case 1:
      return '${d}st';
    case 2:
      return '${d}nd';
    case 3:
      return '${d}rd';
    default:
      return '${d}th';
  }
}

/// Absolute capture date in the long form "June 20th, 2026" (local time).
String formatCaptureDate(int createdAtSecs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(createdAtSecs * 1000);
  return '${_monthNames[dt.month - 1]} ${_ordinalDay(dt.day)}, ${dt.year}';
}

/// A half-open `[after, before)` capture-date filter in epoch seconds. Either
/// bound may be null (open-ended on that side); `null`/`null` means no filter.
/// Used by search to constrain results by `Relic.createdAt`.
class DateRange {
  final int? after; // inclusive lower bound, epoch seconds
  final int? before; // exclusive upper bound, epoch seconds

  const DateRange({this.after, this.before});

  bool get isEmpty => after == null && before == null;

  /// "older than X" — no lower bound, just an upper one (e.g. vague "months ago").
  bool get isOpenEndedOlder => after == null && before != null;

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.after == after && other.before == before;

  @override
  int get hashCode => Object.hash(after, before);
}

/// Short human label for a date range, e.g. "June 20th, 2026", "since June 1st,
/// 2026", "before Jan 1st, 2025", or "June 1st, 2026 – June 30th, 2026". The
/// upper bound is exclusive, so the last *included* day is `before - 1s`.
String formatDateRangeLabel(DateRange r) {
  final a = r.after;
  final b = r.before;
  if (a == null && b == null) return 'Any date';
  if (a == null) return 'before ${formatCaptureDate(b! - 1)}';
  if (b == null) return 'since ${formatCaptureDate(a)}';
  if (b - a <= 86400) return formatCaptureDate(a); // single day
  return '${formatCaptureDate(a)} – ${formatCaptureDate(b - 1)}';
}

/// Human byte size: "84 KB", "1.1 MB".
String humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
