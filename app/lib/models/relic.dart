import 'dart:convert';

import 'rich_body.dart';

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
///
/// [storeSafe] drops the upgrade suggestion (App Store 3.1.1 — iOS builds
/// may state plan facts but not steer toward a purchase); kept as a
/// parameter, not a Platform check, so this file stays pure.
String? syncRejectionHint(int status, {bool storeSafe = false}) =>
    switch (status) {
      402 => storeSafe
          ? 'Free up space, then retry.'
          : 'Free up space or upgrade, then retry.',
      413 => storeSafe
          ? 'This item is larger than your plan allows.'
          : 'Upgrade your plan to sync items this large.',
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

  /// Formatting flavors (HTML / RTF) captured alongside [content], or null.
  /// Always read through [richIfCurrent], never directly: the body carries a
  /// fingerprint of the text it came from, and formatting that no longer
  /// matches must be ignored rather than pasted. See models/rich_body.dart.
  final RichBody? rich;

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
    this.rich,
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
        if (rich != null) 'rich': rich!.toJson(),
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

  /// The formatting flavors, but only when they still describe [content].
  ///
  /// Every paste and export path goes through this rather than [rich]. A writer
  /// that changes the text without knowing the field exists (relic-cli's
  /// upsert, an import) leaves formatting behind that no longer matches; the
  /// fingerprint check makes that leftover inert instead of wrong. Secrets get
  /// nothing regardless of what is stored.
  RichBody? get richIfCurrent => isSecret ? null : rich?.forPlain(content);

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
    RichBody? rich,
    bool clearRich = false,
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
        rich: clearRich ? null : (rich ?? this.rich),
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

/// What the on-device models generated for one relic: a title and some tags.
///
/// This is a document in its own right, not a field of [Relic], because it
/// syncs on a separate cursor. A relic push is only accepted if it advances
/// `updated_at`, so if AI output rode the relic envelope then every background
/// tagging pass would count as a user edit, reshuffle "recently updated", and
/// let a model run race a rename. Keeping it separate means a generated title
/// can propagate to every device without touching the relic's own timeline.
///
/// [level] is the enrich level it was produced at, so a newer model generation
/// can supersede an older one while two devices on the SAME generation leave
/// each other's work alone.
class AiRecord {
  final String uid;

  /// When the producing device generated it (epoch seconds).
  final int at;

  /// The enrich level of the models that produced it.
  final int level;

  /// Which device produced it. Null only for records from before the field
  /// existed; used to break exact ties deterministically.
  final String? by;

  final String? title;
  final List<String> tags;

  /// The text the models read out of the item: OCR from a screenshot, the
  /// extracted body of a document. Never set for [Kind.string], whose text is
  /// the relic itself and already travels in the relic envelope.
  ///
  /// This is the difference between a screenshot being findable everywhere and
  /// being findable only on the machine that happened to run the OCR. It is
  /// also the largest thing an AI record carries, hence [aiTextForWire].
  final String? text;

  /// Text read out of the item's ATTACHMENTS, so a note is findable by what its
  /// bundled files say and not just their filenames.
  ///
  /// Extraction itself needs no models, but it does need the attachment bytes,
  /// and blobs download lazily. So a device that never opened the note has no
  /// way to index it, and a phone has no extractor at all. Both get it here.
  ///
  /// An empty string is a value, not an absence: it means extraction ran and
  /// found nothing, which is worth saying so nobody retries it.
  final String? att;

  const AiRecord({
    required this.uid,
    required this.at,
    required this.level,
    this.by,
    this.title,
    this.tags = const [],
    this.text,
    this.att,
  });

  AiRecord copyWith({
    String? title,
    List<String>? tags,
    String? text,
    String? att,
    int? at,
    int? level,
    String? by,
  }) =>
      AiRecord(
        uid: uid,
        at: at ?? this.at,
        level: level ?? this.level,
        by: by ?? this.by,
        title: title ?? this.title,
        tags: tags ?? this.tags,
        text: text ?? this.text,
        att: att ?? this.att,
      );

  /// True when there is nothing worth publishing. An empty record would still
  /// win its uid under the earliest-wins rule and then lock every other device
  /// out of producing a real one, so these are dropped rather than stored.
  bool get isEmpty =>
      (title == null || title!.trim().isEmpty) &&
      tags.isEmpty &&
      (text == null || text!.trim().isEmpty) &&
      (att == null || att!.trim().isEmpty);

  /// The sealed half of the wire record (the half the server never reads).
  ///
  /// The byte budget is applied HERE rather than at each producer, so no path
  /// can build a record the server will refuse. A rejected record is not
  /// retried (there is no version of it that would fit), so an untrimmed one
  /// would mean silently losing the text instead of shipping most of it.
  Map<String, dynamic> toPayload() {
    // ONE budget for extracted text, spent in order rather than one budget
    // each. In practice the two barely compete: an item with OCR of its own is
    // a photo or a document, an item with attachment text is a note, and a note
    // has nothing to OCR. Giving each a full budget would double the ceiling
    // for a case that hardly occurs.
    final t = aiTextForWire(text);
    final a = aiTextForWire(att,
        budget: kAiTextBytes - (t == null ? 0 : utf8.encode(t).length));
    final p = {
      if (title != null) 'title': title,
      'tags': tags,
      'text': ?t,
      // Empty is meaningful here ("ran, found nothing"), so it is sent as ''
      // rather than dropped — but only when there was something to say.
      if (a != null || (att != null && att!.isEmpty)) 'att': a ?? '',
    };
    // The byte budget is on the text; JSON escaping is on top of it and has no
    // fixed ratio (a stray control character costs six bytes to encode one).
    // In the rare case that pushes a record over, the text goes and the title
    // and tags still travel — losing the whole record because a document
    // contained something strange would be the worse outcome by far.
    if (utf8.encode(jsonEncode(p)).length > kAiPayloadBytes) p.remove('att');
    if (utf8.encode(jsonEncode(p)).length > kAiPayloadBytes) p.remove('text');
    return p;
  }

  /// Rebuild from a decrypted payload plus the envelope's plaintext fields.
  static AiRecord fromWire(Map<String, dynamic> env, Map<String, dynamic> p) =>
      AiRecord(
        uid: env['uid'] as String,
        at: (env['ai_at'] as num).toInt(),
        level: (env['level'] as num?)?.toInt() ?? 0,
        by: env['device'] as String?,
        title: p['title'] as String?,
        tags: (p['tags'] as List?)?.whereType<String>().toList() ?? const [],
        text: p['text'] as String?,
        att: p['att'] as String?,
      );
}

/// How much extracted text one AI record may carry, in UTF-8 bytes.
///
/// Measured against a real vault: every screenshot's OCR fits several times
/// over (the largest was under 3 KB), and so does the text of all but the
/// longest documents. Past that the record is truncated rather than dropped,
/// because the front of a document is where its title, headings and names
/// live, and finding it at all is the point.
///
/// The ceiling is not free storage: AI records live in D1 next to the sync
/// metadata, not in blob storage, and the actual file already syncs as a blob.
/// Kept in step with MAX_CT in worker/src/ai.ts, which has to allow for
/// encryption and base64 on top of this.
const int kAiTextBytes = 24 * 1024;

/// The ceiling on a whole sealed payload, in UTF-8 bytes.
///
/// Chosen backwards from the server's MAX_CT of 48 KiB: base64 costs 4/3 and
/// the seal adds a nonce and a tag, so a payload at this size lands around
/// 45 KiB on the wire. Anything under it is guaranteed to be accepted, which
/// matters because a rejected record is not retried.
const int kAiPayloadBytes = 33 * 1024;

/// [text], trimmed and cut to [budget] UTF-8 bytes, or null if there is nothing
/// left to send.
///
/// The cut is on whole characters and counted in UTF-8 bytes, which is what the
/// wire actually costs: a budget counted in characters would let a document in
/// a non-Latin script produce a record three times over the server's cap.
String? aiTextForWire(String? text, {int budget = kAiTextBytes}) {
  final t = text?.trim();
  if (t == null || t.isEmpty) return null;
  // Too little left to be worth anything: a truncation marker and two words is
  // not a searchable document, just wire weight.
  if (budget < 64) return null;
  var bytes = 0;
  for (var i = 0; i < t.length; i++) {
    final c = t.codeUnitAt(i);
    // Surrogate pairs are two code units of one 4-byte character; counting the
    // lead as 4 and the trail as 0 keeps the total right and, because a cut can
    // only happen on a lead, never splits one.
    bytes += c < 0x80
        ? 1
        : c < 0x800
        ? 2
        : (c & 0xFC00) == 0xD800
        ? 4
        : (c & 0xFC00) == 0xDC00
        ? 0
        : 3;
    if (bytes > budget) {
      // The ellipsis is the honest signal that there is more of this document
      // on the device that read it.
      return '${t.substring(0, i).trimRight()}…';
    }
  }
  return t;
}

/// The headline to store after a labeling pass: the generated title, for a
/// photo or a text item the user hasn't titled themselves.
///
/// A photo then shows "a rocky beach…" rather than its first OCR line, and a
/// vault note shows what it is rather than its first 60 characters. A title the
/// user (or an earlier pass) already set always wins — labeling never overwrites
/// one. Files keep their filename as the headline.
///
/// Text only reaches a labeling pass once promoted; that gate lives at the call
/// site, not here.
String? titleAfterLabel({
  required Kind kind,
  required String? current,
  required String? caption,
}) {
  if (current != null && current.trim().isNotEmpty) return current;
  if (kind != Kind.photo && kind != Kind.string) return current;
  final cap = caption?.trim();
  return (cap != null && cap.isNotEmpty) ? cap : current;
}

/// Fold an [AiRecord] into the relic a device already holds.
///
/// The invariant that matters: **the user always outranks the models**. A title
/// they typed is never replaced by a generated one, and a machine tag they
/// deleted is never re-added. [suppressed] is the RECEIVING device's own record
/// of those deletions, which is exactly why this filtering happens here rather
/// than at the device that generated the record: the producer knows what its
/// models said, but only this device knows what its user has thrown away.
///
/// Lives on the model rather than in either repo because both need it — the
/// desktop applies records it pulls from peers, and the phone, which will never
/// run the models at all, applies every record it receives.
({List<String> tags, String? title, String? content}) mergeAiRecord({
  required Relic cur,
  required AiRecord rec,
  required Set<String> suppressed,
}) {
  final curLower = cur.tags.map((t) => t.toLowerCase()).toSet();
  return (
    tags: <String>[
      ...cur.tags,
      ...rec.tags.where((t) =>
          !curLower.contains(t.toLowerCase()) &&
          !suppressed.contains(t.toLowerCase())),
    ],
    // titleAfterLabel returns `current` whenever it is non-empty, so a
    // generated title only ever fills a gap.
    title: titleAfterLabel(kind: cur.kind, current: cur.title, caption: rec.title),
    content: contentAfterExtract(
      kind: cur.kind,
      current: cur.content,
      text: rec.text,
    ),
  );
}

/// The searchable body to store for an item whose text was read by the models
/// on another device.
///
/// Extracted text fills a gap and never overwrites one. Whatever is already in
/// [current] is either this device's own extraction or something the user typed
/// into the item, and both outrank a peer's copy — the peer cannot tell which
/// of the two it is looking at, so the only safe rule is to leave it alone.
///
/// [Kind.string] is excluded outright: a text relic's content IS the relic, it
/// already syncs in the envelope, and letting an AI record write it would put
/// a second, stale copy of the body on a path with no last-write-wins.
String? contentAfterExtract({
  required Kind kind,
  required String? current,
  required String? text,
}) {
  if (kind == Kind.string) return current;
  if (current != null && current.trim().isNotEmpty) return current;
  final t = text?.trim();
  return (t != null && t.isNotEmpty) ? t : current;
}
