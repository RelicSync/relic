import 'package:flutter/services.dart';

import '../platform/clipboard_bridge.dart';
import '../models/relic.dart';
import '../widgets/chrome.dart';

/// Result ordering for the popup list. `relevance` uses hybrid ranking when a
/// text search is active (falling back to newest otherwise); `newest`/`oldest`
/// force a strict by-date order, ignoring relevance.
enum SortMode { relevance, newest, oldest }

/// Outcome of [RelicRepo.updateAttachments]. [bundleUnavailable] = the
/// current bundle isn't local and can't be fetched right now (offline).
enum AttachmentEditResult { ok, tooLarge, bundleUnavailable, unsupported }

class AccountInfo {
  final String tier; // 'Free' | 'Paid'
  final int usedBytes;
  final int quotaBytes; // 0 == unmetered (paid text)
  final int vaultCount;
  final int? vaultCap;
  const AccountInfo({
    required this.tier,
    required this.usedBytes,
    required this.quotaBytes,
    required this.vaultCount,
    this.vaultCap,
  });

  static String _fmt(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    final mb = bytes / (1024 * 1024);
    return mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(1)} GB'
        : '${mb.toStringAsFixed(1)} MB';
  }

  String get footer {
    final vault = vaultCap == null
        ? 'Vault $vaultCount'
        : 'Vault $vaultCount/$vaultCap';
    if (quotaBytes == 0) return '$tier · ${_fmt(usedBytes)} · $vault';
    final quotaMb = (quotaBytes / (1024 * 1024)).round();
    return '$tier · ${_fmt(usedBytes)}/$quotaMb MB · $vault';
  }
}

/// One purchasable plan, from the Worker `GET /stripe/plans`.
class BillingPlan {
  final String priceId;
  final String tier; // 'pro' | 'max'
  final String? interval; // 'month' | 'year'
  final int? amount; // minor units (e.g. cents); null if unknown
  final String currency;
  const BillingPlan({
    required this.priceId,
    required this.tier,
    this.interval,
    this.amount,
    this.currency = 'usd',
  });

  factory BillingPlan.fromJson(Map<String, dynamic> j) => BillingPlan(
        priceId: j['price_id'] as String,
        tier: j['tier'] as String,
        interval: j['interval'] as String?,
        amount: (j['amount'] as num?)?.toInt(),
        currency: (j['currency'] as String?) ?? 'usd',
      );

  String get tierLabel =>
      tier.isEmpty ? tier : '${tier[0].toUpperCase()}${tier.substring(1)}';

  /// e.g. "Pro · $4/mo" or "Max · $120/yr".
  String get label {
    final per = interval == 'year'
        ? '/yr'
        : interval == 'month'
            ? '/mo'
            : '';
    if (amount == null) return tierLabel;
    final whole = amount! / 100;
    final price = amount! % 100 == 0
        ? whole.toStringAsFixed(0)
        : whole.toStringAsFixed(2);
    return '$tierLabel · \$$price$per';
  }
}

/// Optional billing surface a repo can expose (Upgrade / Manage). The popup
/// checks `repo is BillingRepo` so non-synced repos don't have to implement it.
abstract interface class BillingRepo {
  /// Available purchasable plans (Worker `/stripe/plans`). Empty when offline.
  Future<List<BillingPlan>> billingPlans();

  /// Hosted Stripe Checkout URL for [priceId]. Null only while sync is off;
  /// any other failure throws [BillingException] with a user-facing message.
  Future<String?> checkoutUrl(String priceId);

  /// Hosted Stripe Customer Portal URL. Null only while sync is off; any other
  /// failure (including "no subscription to manage") throws [BillingException].
  Future<String?> portalUrl();
}

/// A billing-action failure with a message fit for the settings pane. Thrown
/// instead of returning null so the UI can say WHY the button did nothing.
class BillingException implements Exception {
  final String message;
  const BillingException(this.message);
  @override
  String toString() => message;
}

/// A created E2EE share link. The URL's fragment carries the decryption key —
/// the server only ever saw ciphertext.
class ShareLink {
  final String url;
  final int expiresAt; // unix seconds
  final bool oneTime;
  const ShareLink(this.url, {required this.expiresAt, required this.oneTime});
}

/// A share-creation failure with a message fit for the dialog.
class ShareException implements Exception {
  final String message;
  const ShareException(this.message);
  @override
  String toString() => message;
}

/// What the popup needs from a backend, independent of how it's implemented.
abstract class RelicRepo {
  Future<void> load();
  List<Relic> get all;
  SyncState get sync;
  AccountInfo? get account;

  bool get promotionSound => false;
  bool get vaultAnimation => true;

  /// First-run coach marks (desktop). Default true = don't show (mobile/others
  /// override or leave as-is); LocalDeskRepo persists it.
  bool get coachMarksSeen => true;
  Future<void> markCoachMarksSeen() async {}

  /// Whether the vault is connected to cross-device sync. Default true so the
  /// desktop "sign in to sync" banner only shows where it's actually meaningful.
  bool get syncEnabled => true;

  /// Items held local after an account switch, awaiting the user's
  /// upload-or-keep decision (see LocalDeskRepo). 0 = no offer pending; the
  /// popup shows a banner while it is, or the offer sits invisible in Settings
  /// and reads as "sync is broken".
  int get mergeOfferCount => 0;

  // --- Power features (opt-in; desktop-only in practice, default off/no-op so
  // the popup can bind to them uniformly). LocalDeskRepo persists + implements.
  bool get multiCombine => false;
  bool get snippets => false;
  bool get reminders => false;

  /// Open-vocabulary machine tags that have been seen only once and so have not
  /// earned a facet chip yet (see relic-sift/src/tag_vocab.rs). They remain on
  /// their relics and stay fully searchable — this only suppresses the chip.
  /// Empty everywhere the local labeler doesn't run.
  Set<String> get provisionalTags => const {};

  /// Uids whose on-device analysis pass (tags, OCR, generated title) is queued
  /// or running, so the UI can show a spinner instead of a bare row. Empty
  /// everywhere the local pipeline doesn't run.
  Set<String> get analyzingUids => const {};

  /// Schedule a reminder (epoch ms); returns the new id or null. No-op default.
  int? addReminder(String uid, int remindAtMs, {String? note}) => null;

  /// Pending (un-fired) reminders for one item. Empty by default.
  List<Reminder> remindersFor(String uid) => const [];

  void clearReminder(int id) {}

  // --- windowed, query-driven result set the popup binds to ---
  /// The currently-loaded page window for the active query/scope (newest first).
  List<Relic> get visible;

  /// Total matches for the active query/scope (for the result counter).
  int get matchCount;

  /// Whether more rows exist beyond the loaded window.
  bool get hasMore;

  /// Set the active search + scope and reset the window to the first page.
  /// [createdAfter]/[createdBefore] bound results to a half-open `[after, before)`
  /// date range (epoch seconds); null means unbounded on that side.
  Future<void> setQuery(
    String search,
    Scope scope, {
    SortMode sort = SortMode.relevance,
    int? createdAfter,
    int? createdBefore,
  });

  /// Grow the window by one page (infinite-scroll).
  Future<void> loadMore();

  Future<void> promote(Relic r, bool promoted);
  Future<void> delete(Relic r);
  /// Update a relic's metadata — and, for non-secret string relics, its BODY
  /// ([content], null = unchanged): the save & annotate flow lets the user
  /// clean up what was captured, not just label it.
  Future<void> updateMeta(
    Relic r, {
    String? title,
    String? note,
    List<String>? userTags,
    List<String>? tags,
    String? content,
  });

  /// Plaintext for copy / view (decrypts a blob when needed). Null if N/A.
  Future<String?> textOf(Relic r);

  /// Local filesystem path to a captured image, if any (row/dialog thumbnails).
  String? localImagePath(Relic r) => null;

  /// Local path to one unpacked attachment (extracted from the bundle blob),
  /// or null if not available. Drives the attachment strip / per-item save.
  String? attachmentPath(Relic r, String attId) => null;

  /// Per-item byte cap (the plan's item limit; drives the composer's running
  /// total / attachment cap). The Worker is the authoritative enforcer.
  int get maxItemBytes => 100 * 1024 * 1024;

  /// Create a relic by hand (the "+" composer): a text body, optional title,
  /// user tags, and file attachments (packed into one bundle blob). Returns
  /// false if nothing to save or the bundle exceeds the per-item cap.
  bool createNote({
    String? title,
    String? body,
    List<String> userTags = const [],
    List<(String name, String? mime, Uint8List bytes)> files = const [],
    bool promote = false,
  }) =>
      false;

  /// Whether [updateAttachments] works here (desktop's local-DB repo only) —
  /// gates the Edit dialog's attachment section.
  bool get canEditAttachments => false;

  /// Rebuild a note's attachment bundle: drop [removedIds], append [added].
  /// Removing everything (with a text body remaining) degrades the relic to a
  /// plain text note. Default: unsupported.
  Future<AttachmentEditResult> updateAttachments(
    Relic r, {
    List<(String name, String? mime, Uint8List bytes)> added = const [],
    Set<String> removedIds = const {},
  }) async =>
      AttachmentEditResult.unsupported;

  /// Ensure a relic's blob bytes are available locally (download if synced).
  /// Returns true when present. Default: only true if already local.
  Future<bool> ensureBlob(Relic r) async => localImagePath(r) != null;

  /// Decrypted bytes of a relic's blob (photo/file), downloading + caching if
  /// needed. Null when there's no blob or it can't be fetched.
  Future<Uint8List?> blobBytes(Relic r) async => null;

  /// Filesystem path of the already-decrypted blob, for any kind — unlike
  /// [localImagePath], which is photos-only. Null when it isn't cached; call
  /// [ensureBlob] first.
  ///
  /// The mobile save path streams from this instead of going through
  /// [blobBytes]: items run to maxItemBytes (100 MB), and materialising that as
  /// a Dart list and then copying it across a platform channel is a real
  /// out-of-memory risk on mid-range phones.
  String? cachedBlobPath(Relic r) => null;

  /// Whether [restore] can bring back a just-deleted relic — gates the "Undo"
  /// affordance on the delete toast. Default: false.
  bool get canUndoDelete => false;

  /// Capture a relic's local blob bytes (if any) before a delete, so [restore]
  /// can put them back. Null when there's no blob. Default: none.
  Future<Uint8List?> snapshotBlob(Relic r) async => null;

  /// Re-insert a relic deleted via [delete] (the Undo path), rewriting its blob
  /// from [blob] when supplied. Default: no-op.
  Future<void> restore(Relic r, {Uint8List? blob}) async {}

  /// The folder desktop "Save" writes blobs to. Null → the OS Downloads folder.
  String? get saveDir => null;

  /// Whether this repo can create E2EE share links (signed in + sync
  /// configured). The ShareDialog's offline QR works regardless.
  bool get canShare => false;

  /// Encrypt [r] client-side and create a share link on the Worker. The
  /// returned URL carries the decryption key in its fragment. Throws a
  /// [ShareException] with a user-facing message on failure.
  Future<ShareLink> createShare(Relic r,
          {required Duration ttl, required bool oneTime}) async =>
      throw UnsupportedError('sharing not available on this repo');

  /// Place the relic on the system clipboard. Text by default; repos with
  /// image blobs override to put the actual image back.
  Future<void> putOnClipboard(Relic r) async {
    final t = await textOf(r);
    if (t != null && !await writeSensitiveTextToClipboard(t)) {
      await Clipboard.setData(ClipboardData(text: t));
    }
  }

  /// Place raw text on the system clipboard (bulk merge-copy, "Copy as"
  /// transforms). Watcher-backed repos override to suppress their own echo
  /// capture; [sensitive] additionally arms the same post-copy scrub as
  /// copying a secret relic.
  Future<void> putTextOnClipboard(String t, {bool sensitive = false}) async {
    if (!await writeSensitiveTextToClipboard(t)) {
      await Clipboard.setData(ClipboardData(text: t));
    }
  }

  /// Counts for candidate collection tags (only those present, count > 0), for
  /// the browse "collections" strip. Default: none (overridden by the DB repo).
  Map<String, int> tagCounts(Iterable<String> tags, {bool vaultOnly = false}) =>
      const {};

  /// Every present tag with counts, split into the user's tags and auto tags —
  /// for the "All tags" browse sheet. Default: empty.
  ({Map<String, int> user, Map<String, int> machine}) tagFrequencies({
    bool vaultOnly = false,
  }) => (user: const {}, machine: const {});

  /// Rename a tag across the corpus (in the machine `tags` or `user_tags`
  /// column). Returns relics changed. Default: no-op.
  Future<int> renameTag(
    String from,
    String to, {
    required bool userTag,
  }) async => 0;

  /// Remove a tag from the corpus. Returns relics changed. Default: no-op.
  Future<int> deleteTag(String tag, {required bool userTag}) async => 0;

  /// Register a reusable tag the user created in the Tags pane so it persists
  /// (and shows under "Your tags") even before it's applied to anything. The
  /// user then applies it to relics from the Edit dialog. Default: no-op.
  Future<void> addCustomTag(String tag) async {}

  /// True when this relic has a queued or rejected outbound sync operation.
  bool isNotSynced(Relic r) => false;

  /// Finer-grained per-relic sync state for the row badge: actively syncing vs.
  /// blocked (rejected) vs. clean. Default: clean (local-only / preview repos).
  RelicSync relicSync(Relic r) => RelicSync.synced;

  /// Blob upload progress (0..1) while this relic's attachment is uploading, or
  /// null when it isn't. Drives the determinate "Uploading NN%" row/chip state.
  double? uploadFraction(Relic r) => null;

  /// Aggregate upload progress (0..1) across all in-flight blob uploads, or null
  /// when nothing is uploading. Drives the global chip's "Uploading NN%".
  double? get uploadingFraction => null;

  /// Why a blocked relic won't sync (HTTP status + when it was refused), for
  /// the "Not synced" popover. Null when it isn't blocked. Feed the status to
  /// [syncRejectionReason]/[syncRejectionHint] for copy.
  ({int status, int rejectedAt})? syncRejection(Relic r) => null;

  /// Re-queue one blocked relic's outbound op and kick a flush. No-op default.
  void retrySync(Relic r) {}

  /// Re-queue every blocked op ("Retry all" in the sync issues sheet).
  void retryAllBlocked() {}

  /// Every blocked relic with its rejection, newest first — the sync issues
  /// sheet's list. Default: none.
  List<({Relic relic, int status, int rejectedAt})> blockedItems() => const [];

  /// When the last successful pull completed; null = never synced (or a repo
  /// without a sync engine).
  DateTime? get lastSyncedAt => null;

  /// True while a user-triggered [syncNow] runs (drives the chip spinner).
  bool get syncBusy => false;

  /// Manual full sync cycle (push + pull). No-op on repos without sync.
  Future<void> syncNow() async {}
}

/// In-memory rename ([to] set) / delete ([to] null) of a tag across [items],
/// for the gallery/preview repos. Returns relics changed.
///
/// The machine `secret` tag is refused as source or target here — it IS the
/// masking bit (`Relic.isSecret`), so guarding the shared helper covers every
/// repo implementation that delegates to it.
int retagInPlace(List<Relic> items, String from, String? to, bool userTag) {
  if (!userTag &&
      (from.toLowerCase() == 'secret' || to?.toLowerCase() == 'secret')) {
    return 0;
  }
  var n = 0;
  for (var i = 0; i < items.length; i++) {
    final r = items[i];
    final list = userTag ? r.userTags : r.tags;
    if (!list.contains(from)) continue;
    final out = <String>[];
    for (final t in list) {
      if (t == from) {
        if (to != null && to.isNotEmpty && !out.contains(to)) out.add(to);
      } else if (!out.contains(t)) {
        out.add(t);
      }
    }
    items[i] = userTag ? r.copyWith(userTags: out) : r.copyWith(tags: out);
    n++;
  }
  return n;
}

/// Shared in-memory tag-frequency computation for the gallery/preview repos.
({Map<String, int> user, Map<String, int> machine}) tagFreqOf(
  Iterable<Relic> items,
  bool vaultOnly,
) {
  final machine = <String, int>{};
  final user = <String, int>{};
  for (final r in items) {
    if (vaultOnly && !r.promoted) continue;
    for (final t in r.tags) {
      machine[t] = (machine[t] ?? 0) + 1;
    }
    for (final t in r.userTags) {
      user[t] = (user[t] ?? 0) + 1;
    }
  }
  return (user: user, machine: machine);
}

/// Page size for windowed reads (infinite-scroll increment, and the "Load more"
/// footer threshold). Lists longer than this page in 50s rather than dumping
/// the whole corpus into one scroll view.
const int kRelicPage = 50;

/// In-memory windowing over a `List<Relic>` source — used by the gallery /
/// preview repos. The DB-backed repo implements the same contract against SQLite.
class QueryWindow {
  final List<Relic> Function() source;
  String search = '';
  Scope scope = Scope.all;
  SortMode sort = SortMode.relevance;
  int? createdAfter;
  int? createdBefore;
  int _win = kRelicPage;
  QueryWindow(this.source);

  List<Relic> _matches() => filterRelics(
        source(),
        search,
        scope,
        sort: sort,
        createdAfter: createdAfter,
        createdBefore: createdBefore,
      );
  List<Relic> get visible => _matches().take(_win).toList();
  int get matchCount => _matches().length;
  bool get hasMore => matchCount > _win;
  void setQuery(
    String s,
    Scope sc, {
    SortMode sort = SortMode.relevance,
    int? createdAfter,
    int? createdBefore,
  }) {
    search = s;
    scope = sc;
    this.sort = sort;
    this.createdAfter = createdAfter;
    this.createdBefore = createdBefore;
    _win = kRelicPage;
  }

  void loadMore() => _win += kRelicPage;
}

/// In-memory repo seeded with the design's example data — lets the UI run
/// standalone. Swapped for the Worker-backed repo once crypto/sync land.
class MemoryRepo implements RelicRepo {
  final List<Relic> _items = [];
  final Set<String> _custom =
      {}; // user-created reusable tags (not yet applied)
  late final QueryWindow _qw = QueryWindow(() => _items);
  @override
  double? uploadFraction(Relic r) => null;
  @override
  double? get uploadingFraction => null;
  @override
  ({int status, int rejectedAt})? syncRejection(Relic r) => null;
  @override
  void retrySync(Relic r) {}
  @override
  void retryAllBlocked() {}
  @override
  List<({Relic relic, int status, int rejectedAt})> blockedItems() => const [];
  @override
  DateTime? get lastSyncedAt => null;
  @override
  bool get syncBusy => false;
  @override
  Future<void> syncNow() async {}
  @override
  bool get canEditAttachments => false;
  @override
  Future<AttachmentEditResult> updateAttachments(
    Relic r, {
    List<(String name, String? mime, Uint8List bytes)> added = const [],
    Set<String> removedIds = const {},
  }) async =>
      AttachmentEditResult.unsupported;
  @override
  bool get canShare => false;
  @override
  Future<ShareLink> createShare(Relic r,
          {required Duration ttl, required bool oneTime}) async =>
      throw UnsupportedError('sharing not available on this repo');
  @override
  List<Relic> get all => List.unmodifiable(_items);
  @override
  List<Relic> get visible => _qw.visible;
  @override
  int get matchCount => _qw.matchCount;
  @override
  bool get hasMore => _qw.hasMore;
  @override
  Future<void> setQuery(
    String search,
    Scope scope, {
    SortMode sort = SortMode.relevance,
    int? createdAfter,
    int? createdBefore,
  }) async => _qw.setQuery(
        search,
        scope,
        sort: sort,
        createdAfter: createdAfter,
        createdBefore: createdBefore,
      );
  @override
  Future<void> loadMore() async => _qw.loadMore();
  @override
  SyncState get sync => const SyncState(SyncKind.synced);
  @override
  bool get promotionSound => false;
  @override
  bool get vaultAnimation => true;
  @override
  bool get coachMarksSeen => true;
  @override
  Future<void> markCoachMarksSeen() async {}
  @override
  bool get multiCombine => false;
  @override
  bool get snippets => false;
  @override
  bool get reminders => false;

  @override
  Set<String> get provisionalTags => const {};

  /// Uids whose on-device analysis pass (tags, OCR, generated title) is queued
  /// or running, so the UI can show a spinner instead of a bare row. Empty
  /// everywhere the local pipeline doesn't run.
  @override
  Set<String> get analyzingUids => const {};
  @override
  int? addReminder(String uid, int remindAtMs, {String? note}) => null;
  @override
  List<Reminder> remindersFor(String uid) => const [];
  @override
  void clearReminder(int id) {}
  @override
  bool get syncEnabled => false;
  @override
  int get mergeOfferCount => 0;
  @override
  AccountInfo? get account => const AccountInfo(
    tier: 'Free',
    usedBytes: 12897484,
    quotaBytes: 262144000,
    vaultCount: 8,
    vaultCap: 25,
  );

  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  @override
  Future<void> load() async {
    final now = _now;
    Relic mk(
      String uid,
      Kind kind,
      int agoSecs, {
      String? content,
      String? title,
      String? preview,
      String? filename,
      String? device = 'MacBook Pro',
      bool promoted = false,
      List<String> tags = const [],
      List<String> userTags = const [],
      int bytes = 0,
      String? blobKey,
    }) => Relic(
      uid: uid,
      createdAt: now - agoSecs,
      updatedAt: now - agoSecs,
      kind: kind,
      source: Source.clipboard,
      promoted: promoted,
      byteSize: bytes,
      device: device,
      filename: filename,
      blobKey: blobKey,
      tags: tags,
      userTags: userTags,
      title: title,
      content: content,
      preview: preview ?? content,
    );

    _items
      ..clear()
      ..addAll([
        mk(
          '1',
          Kind.string,
          120,
          content:
              'aws s3 sync ./dist s3://relic-prod-assets --delete --cache-control max-age=31536000 --exclude "*.map"',
        ),
        mk(
          '2',
          Kind.string,
          480,
          content:
              'git rebase -i HEAD~3 --autosquash --rebase-merges origin/main',
        ),
        mk(
          '3',
          Kind.photo,
          840,
          title: 'Screenshot · 2560 × 1440',
          bytes: 1468006,
          blobKey: 'demo',
        ),
        mk(
          '4',
          Kind.string,
          900,
          title: 'Staging deploy command',
          content:
              'kubectl apply -f staging/ && kubectl rollout status deploy/api',
          device: 'iMac',
          promoted: true,
          userTags: ['ops', 'deploy'],
        ),
        mk(
          '5',
          Kind.string,
          1200,
          content: 'sk_live_51HbQ2eF8kLmZ9xRtY7nP4wV0aB6cD3eG', // scan-ok: fake demo seed
          title: 'Stripe secret key',
          tags: ['secret'],
          device: 'iMac',
        ),
        mk(
          '6',
          Kind.file,
          3600,
          filename: 'q3-forecast-regional-breakdown-FINAL-v4.xlsx',
          preview: 'q3-forecast-regional-breakdown-FINAL-v4.xlsx',
          device: 'iMac',
          bytes: 86016,
          blobKey: 'demo',
        ),
        mk(
          '7',
          Kind.string,
          7200,
          content: 'docker compose up -d --build --remove-orphans',
          device: 'iMac',
        ),
        mk(
          '8',
          Kind.string,
          10800,
          content: 'ssh deploy@10.0.0.4 -p 2202 -i ~/.ssh/relic_ed25519',
        ),
        mk(
          '9',
          Kind.string,
          86400,
          title: 'VPN config notes',
          content: 'WireGuard endpoint 51820, persistent keepalive 25',
          promoted: true,
          device: 'iMac',
        ),
        mk(
          '10',
          Kind.other,
          9000,
          content: 'application/octet-stream',
          preview: 'application/octet-stream',
          device: 'iMac',
        ),
      ]);
  }

  @override
  Future<void> promote(Relic r, bool promoted) async {
    _replace(r.copyWith(promoted: promoted, updatedAt: _now));
  }

  @override
  Future<void> delete(Relic r) async =>
      _items.removeWhere((x) => x.uid == r.uid);

  @override
  bool get canUndoDelete => true;

  @override
  Future<Uint8List?> snapshotBlob(Relic r) async => null;

  @override
  Future<void> restore(Relic r, {Uint8List? blob}) async {
    if (_items.any((x) => x.uid == r.uid)) return;
    _items.add(r);
  }

  @override
  String? get saveDir => null;

  @override
  Future<void> updateMeta(
    Relic r, {
    String? title,
    String? note,
    List<String>? userTags,
    List<String>? tags,
    String? content,
  }) async {
    _replace(
      r.copyWith(
        title: title,
        note: note,
        userTags: userTags,
        tags: tags,
        content: r.isSecret ? null : content,
        updatedAt: _now,
      ),
    );
  }

  @override
  Future<String?> textOf(Relic r) async => r.content ?? r.filename;

  @override
  String? localImagePath(Relic r) => null;

  @override
  String? cachedBlobPath(Relic r) => null;

  @override
  String? attachmentPath(Relic r, String attId) => null;

  @override
  int get maxItemBytes => 100 * 1024 * 1024;

  @override
  bool createNote({
    String? title,
    String? body,
    List<String> userTags = const [],
    List<(String name, String? mime, Uint8List bytes)> files = const [],
    bool promote = false,
  }) =>
      false;

  @override
  Future<bool> ensureBlob(Relic r) async => false;

  @override
  Future<Uint8List?> blobBytes(Relic r) async => null;

  @override
  Future<void> putOnClipboard(Relic r) async {
    final t = await textOf(r);
    if (t != null && !await writeSensitiveTextToClipboard(t)) {
      await Clipboard.setData(ClipboardData(text: t));
    }
  }

  @override
  Future<void> putTextOnClipboard(String t, {bool sensitive = false}) async {
    if (!await writeSensitiveTextToClipboard(t)) {
      await Clipboard.setData(ClipboardData(text: t));
    }
  }

  @override
  Map<String, int> tagCounts(Iterable<String> tags, {bool vaultOnly = false}) {
    final counts = <String, int>{};
    for (final t in tags) {
      final n = _items
          .where((r) => (!vaultOnly || r.promoted) && r.allTags.contains(t))
          .length;
      if (n > 0) counts[t] = n;
    }
    return counts;
  }

  @override
  ({Map<String, int> user, Map<String, int> machine}) tagFrequencies({
    bool vaultOnly = false,
  }) {
    final f = tagFreqOf(_items, vaultOnly);
    for (final t in _custom) {
      f.user.putIfAbsent(t, () => 0);
    }
    return f;
  }

  @override
  Future<int> renameTag(
    String from,
    String to, {
    required bool userTag,
  }) async => retagInPlace(_items, from, to, userTag);
  @override
  Future<int> deleteTag(String tag, {required bool userTag}) async {
    _custom.remove(tag);
    return retagInPlace(_items, tag, null, userTag);
  }

  @override
  Future<void> addCustomTag(String tag) async {
    if (tag.isNotEmpty) _custom.add(tag);
  }

  @override
  bool isNotSynced(Relic r) => false;

  @override
  RelicSync relicSync(Relic r) => RelicSync.synced;

  void _replace(Relic r) {
    final i = _items.indexWhere((x) => x.uid == r.uid);
    if (i >= 0) _items[i] = r;
  }
}

/// Search + scope filtering shared by all repos. Bare words → prefix/substring
/// match across content/title/preview/filename/tags; supports `tag:x`.
List<Relic> filterRelics(
  List<Relic> items,
  String query,
  Scope scope, {
  SortMode sort = SortMode.relevance,
  int? createdAfter,
  int? createdBefore,
}) {
  Iterable<Relic> out = items;
  if (scope == Scope.vault) out = out.where((r) => r.promoted);

  // Half-open [after, before) date filter — mirrors the DB-backed predicate.
  if (createdAfter != null) {
    out = out.where((r) => r.createdAt >= createdAfter);
  }
  if (createdBefore != null) {
    out = out.where((r) => r.createdAt < createdBefore);
  }

  final q = query.trim().toLowerCase();
  if (q.isNotEmpty) {
    // Pull out every `tag:` clause (AND-ed); the remainder is free text.
    final tagRe = RegExp(r'tag:(\S+)');
    final tags = tagRe.allMatches(q).map((m) => m.group(1)!).toList();
    final text = q.replaceAll(tagRe, ' ').trim();
    for (final tag in tags) {
      out = out.where(
        (r) => r.allTags.any((t) => t.toLowerCase().contains(tag)),
      );
    }
    if (text.isNotEmpty) {
      final terms = text.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
      out = out.where((r) {
        final hay = [
          r.content ?? '',
          r.title ?? '',
          r.preview ?? '',
          r.filename ?? '',
          r.note ?? '',
          ...r.allTags,
        ].join(' ').toLowerCase();
        return terms.every(hay.contains);
      });
    }
  }
  final asc = sort == SortMode.oldest;
  final list = out.toList()
    ..sort(
      (a, b) => asc
          ? a.createdAt.compareTo(b.createdAt)
          : b.createdAt.compareTo(a.createdAt),
    );
  return list;
}
