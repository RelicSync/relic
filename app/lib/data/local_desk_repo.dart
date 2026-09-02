import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:uuid/uuid.dart';

import '../models/relic.dart';
import '../models/rich_body.dart';
import '../platform/clipboard_bridge.dart';
import '../platform/login_item.dart';
import '../platform/paths.dart';
import '../widgets/chrome.dart';
import 'api.dart';
import 'backup_file.dart';
import 'crash_log.dart';
import 'blob_upload.dart';
import 'bundle.dart';
import 'package:relic_crypto/relic_crypto.dart';
import 'recovery.dart';
import 'file_types.dart';
import 'heuristic_tags.dart';
import 'hotkeys.dart';
import 'relic_db.dart';
import 'repo.dart';
import 'secure_key_store.dart';
import 'sift.dart';
import 'sync_socket.dart';
import 'supabase_auth.dart';

// titleAfterLabel and mergeAiRecord moved to the model when the phone needed
// them too (it applies AI records without ever running the models). Re-exported
// so existing callers and tests keep importing them from here.
export '../models/relic.dart' show mergeAiRecord, titleAfterLabel;

/// Status of the on-device ML (sift) pipeline, for the settings UI.
enum SiftStatus {
  unavailable, // no sift binary bundled
  off, // disabled by the user
  downloading, // models being fetched (~750 MB)
  stageA, // enabled, running deterministic Stage-A while models download
  keywordOnly, // ML ready but the embeddings toggle is off —
  // search runs keyword+typo (+ tag expansion) only, no stored-vector leg
  ready, // full ML available
}

/// User-selectable popup footprint. `mini` shows just the last few items in a
/// tight window; `standard` gives room to browse a big corpus.
enum PopupSize {
  mini('Mini', 380, 420),
  small('Small', 440, 540),
  standard('Standard', 520, 680);

  final String label;
  final double w;
  final double h;
  const PopupSize(this.label, this.w, this.h);

  static PopupSize byName(String? n) => PopupSize.values.firstWhere(
    (e) => e.name == n,
    orElse: () => PopupSize.small,
  );
}

/// How much of the machine the background AI passes may take. Labeling costs
/// roughly 7.5 core-seconds per item, so on a small machine this is the
/// difference between background noise and a desktop that feels stalled.
///
/// [flag] is passed straight to the sift sidecar, which scales its thread count
/// to the host and drops below foreground priority for everything but [full].
/// Defaults to [balanced], which on any 8-core-or-better machine resolves to
/// exactly the thread count used before this setting existed.
enum AnalysisSpeed {
  gentle('Gentle', 'gentle'),
  balanced('Balanced', 'balanced'),
  full('Fast', 'fast');

  final String label;
  final String flag;
  const AnalysisSpeed(this.label, this.flag);

  static AnalysisSpeed byName(String? n) => AnalysisSpeed.values.firstWhere(
    (e) => e.name == n,
    orElse: () => AnalysisSpeed.balanced,
  );
}

/// Theme preference. `system` follows the OS light/dark setting.
///
/// The default is [light], not [system]: Relic's 2026 design is a parchment
/// design, and the ink palette is its parity theme rather than its home. An
/// install that already stored a preference keeps it.
enum Appearance {
  system,
  dark,
  light;

  static Appearance byName(String? n) => Appearance.values.firstWhere(
    (e) => e.name == n,
    orElse: () => Appearance.light,
  );
}

/// The stored appearance, read straight off disk before there is an app.
///
/// The desktop window's opaque background colour has to be handed to the native
/// window in [WindowOptions] before `runApp`, so there is no element tree and no
/// [RelicTheme] to ask. Without this, the window is painted in one palette's
/// base while the user runs the other, and every summon starts with a flash of
/// the wrong colour before Flutter's first frame lands.
///
/// Deliberately does its own minimal parse rather than building a repo: this
/// runs on the boot path, and a full [LocalDeskRepo] would open the vault.
/// Any failure falls back to the default palette, which is what an install with
/// no prefs.json gets anyway.
Appearance bootAppearance() {
  try {
    final f = File(
        '${appDataPath()}${Platform.pathSeparator}prefs.json');
    if (!f.existsSync()) return Appearance.light;
    final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    return Appearance.byName(j['appearance'] as String?);
  } catch (_) {
    return Appearance.light;
  }
}

/// Retention/vault caps for the active tier, mirroring the server `TIERS`
/// (`worker/src/index.ts`). Drives the settings UI's keep-N control and the
/// client-side vault-full pre-check.
class RetentionLimits {
  /// Max promoted (Vault) items; null = unlimited.
  final int? vaultCount;

  /// Max total stored bytes; null = unlimited.
  final int? storageBytes;

  /// Allowed keep-N range and default for the history ring.
  final int ringMin;
  final int ringMax;
  final int ringDefault;

  /// Whether keep-N may be turned off entirely (local tier only).
  final bool allowUnlimited;

  const RetentionLimits({
    required this.vaultCount,
    required this.storageBytes,
    required this.ringMin,
    required this.ringMax,
    required this.ringDefault,
    required this.allowUnlimited,
  });
}

/// Whether a text item should get the generative labeling pass.
///
/// Vault-only by default: a second of generative work is not worth spending on
/// a clipboard line nobody saved, and the stream is where the volume is.
/// `describeEverything` opts the whole history in.
///
/// Photos don't come through here — they're labeled wherever they live, since
/// an image with no text is otherwise unfindable.
@visibleForTesting
bool shouldLabelText({
  required bool describeItems,
  required bool describeEverything,
  required bool promoted,
}) => describeItems && (promoted || describeEverything);

/// Whether saving [r] to the vault should re-queue it for the labeling pass.
///
/// Labeling is vault-only for text, so an item that was enriched while it was
/// still in the stream is already sitting at the ML level with no label — and
/// `needingEnrich` only returns rows *below* that level, so without dropping
/// `enrich_level` the worker would never look at it again. Photos have always
/// done this; text was missed when text labeling was turned on.
///
/// [bulk] is the "Save everything to Vault" sweep, where text is deliberately
/// excluded: re-queuing an entire vault is exactly the backfill we chose not to
/// do, and would be many minutes of generative work nobody asked for. Photos
/// stay included there because that is how the sweep already behaved and there
/// are far fewer of them.
@visibleForTesting
bool shouldRequeueForLabel(
  Relic r, {
  required bool describeItems,
  required bool bulk,
}) {
  if (!r.promoted || !describeItems) return false;
  // An existing title is the thing labeling would write; don't clobber it.
  if (r.title != null && r.title!.trim().isNotEmpty) return false;
  if (r.kind == Kind.photo) return true;
  // Only text goes through the promoted-text label path; `file` relics are
  // labeled by the image branch or not at all.
  return !bulk && r.kind == Kind.string;
}

/// The real desktop store: clipboard captures persisted to a local SQLite
/// database (incremental writes + FTS5 search + windowed reads), fully usable
/// offline. E2E Worker sync layers on top.
class LocalDeskRepo extends ChangeNotifier implements RelicRepo, BillingRepo {
  RelicDb? _db;

  // The currently-loaded window of results for the active query/scope.
  final List<Relic> _window = [];
  String _query = '';
  Scope _scope = Scope.all;
  SortMode _sort = SortMode.relevance;
  int? _createdAfter; // half-open [after, before) date filter, epoch seconds
  int? _createdBefore;
  int _windowSize = kRelicPage;
  int _matchCount = 0;

  // hybrid semantic search
  // uid → document embeddings (index 0 = whole doc, rest = long-doc chunks)
  final Map<String, List<Float32List>> _vec = {};
  List<String>? _hybridUids; // active fused ranking, or null for lexical/browse
  // query-side tag expansion: tag → gloss embedding (same space as the query).
  final Map<String, Float32List> _tagVec = {};
  int _tagDim = 0;
  bool _tagRefreshing = false;
  int _queryGen = 0; // discard stale async refines

  String? _lastCaptured; // text dedupe guard
  // Formatting fingerprint of the same guard. Must be assigned wherever
  // _lastCaptured is, or re-pasting a formatted item captures it again.
  int? _lastCapturedRichFp;
  Timer? _secretClearTimer; // 30 s post-secret-copy clipboard scrub
  int? _lastBlobHash; // blob dedupe guard
  // uid behind _lastBlobHash — lets save & annotate resolve the relic a
  // deduped/echo-suppressed image refers to, without racing mostRecentUid.
  String? _lastBlobUid;
  static final _uuid = Uuid();
  final Set<String> _fetching = {}; // blob ids currently downloading
  final Set<String> _uploaded = {}; // blob ids known present on the Worker

  // --- sync (E2E to the deployed Worker) ---
  String? _syncUrl;
  String? _syncToken;
  String? _deviceId; // this install's stable id, sent as X-Relic-Device
  String? _appVersion; // running version, sent as X-Relic-App-Version
  Uint8List? _mk; // master key, in memory only
  int _cursor = 0;
  int _tombCursor = 0;
  int _aiCursor = 0; // AI records ride their own timeline; see worker/src/ai.ts
  bool _aiConverged = false; // the one-time publish of pre-existing AI titles
  Timer? _syncTimer;
  SyncSocket? _syncSocket; // live-sync doorbell; null until first connect
  bool _online = false;
  bool _flushing = false;
  bool _pulling = false;
  bool _manualSync = false; // a user-triggered syncNow() is in flight
  // Blob upload progress by relic uid (0..1) while a push is uploading its blob.
  // Drives the determinate "Uploading NN%" row/chip state; cleared on completion.
  final Map<String, double> _uploadProgress = {};
  DateTime _lastUploadNotify = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastSyncAt = 0; // epoch s of the last successful pull; 0 = never
  String? _syncScope;
  AccountInfo? _remoteAccount;
  @override
  bool get syncEnabled => _mk != null;

  // Account-switch guard: the identity this database's contents last synced
  // with ('supabase:<sub>' or 'legacy:<scope>'). A property of the DATA, not
  // the session — it deliberately survives disconnectSync so that binding a
  // DIFFERENT account later can be detected and must not auto-upload the
  // previous account's items into it.
  String? _syncedAccount;

  /// Holdback stamp for items whose owning account was never recorded — the
  /// pre-holdback installs that carried a merge-offer COUNT in prefs and
  /// nothing else (see [_migrateLegacyHoldback]). Unlike a real identity it
  /// never auto-releases on a bind: nothing knows which account to match it
  /// against, so only accept or delete can clear it.
  static const kHeldPreviousAccount = 'previous-account';

  /// The user answered "keep them on this device": the holdback stays in place
  /// but the offer stops asking. Cleared whenever a NEW holdback is created.
  bool _mergeOfferDismissed = false;

  /// Only set while a pre-holdback prefs file is being migrated; see
  /// [_migrateLegacyHoldback].
  int _legacyMergeOfferCount = 0;

  /// Cached `held_by IS NOT NULL` count. The popup and settings read
  /// [mergeOfferCount] on every build, and the holdback only changes on a bind
  /// or an explicit decision, so it's counted then rather than per frame.
  int _heldCount = 0;

  void _refreshHeldCount() => _heldCount = _db?.countHeld() ?? 0;

  /// Items on this device that belong to a DIFFERENT account than the one now
  /// connected (0 = nothing pending). They are held back at bind time: hidden
  /// from the list, search, counts and sync until the user decides in Settings
  /// — upload them here ([acceptMergeOffer]), keep them tucked away
  /// ([dismissMergeOffer]), or delete them ([deleteMergeOffer]). Reports 0 once
  /// dismissed even though the items are still held.
  @override
  int get mergeOfferCount => _mergeOfferDismissed ? 0 : _heldCount;

  /// How many items are tucked away, dismissed or not. [mergeOfferCount] is
  /// what ASKS (banner, notification); this is what still EXISTS, so Settings
  /// can keep a quiet way to upload or delete them after a "keep them".
  int get heldCount => _heldCount;

  /// User said "upload this device's items into the connected account": release
  /// the holdback (the items reappear in the vault) and queue a push for every
  /// row (idempotent for rows the account already has).
  Future<void> acceptMergeOffer() async {
    final db = _db;
    if (db == null || _mk == null || db.countHeld() == 0) return;
    db.releaseAllHeld();
    for (final r in db.allRows()) {
      db.queueOp(r.uid, 'push', r.updatedAt);
    }
    _mergeOfferDismissed = false;
    _refreshHeldCount();
    _savePrefs();
    _refreshWindow();
    notifyListeners();
    await _flushPending();
  }

  /// User said "keep them on this device": the rows STAY held (hidden, never
  /// uploaded) and the offer goes quiet. Signing back into the account they
  /// belong to brings them back on its own.
  void dismissMergeOffer() {
    if (_mergeOfferDismissed || (_db?.countHeld() ?? 0) == 0) return;
    _mergeOfferDismissed = true;
    _savePrefs();
    notifyListeners();
  }

  /// User said "delete them from this device": the held rows and their blobs
  /// go for good. Returns how many were removed.
  ///
  /// No delete tombstones are queued. These items were never uploaded to the
  /// account this device is signed into, so a tombstone would be addressed to
  /// an account that has never heard of them — and if the uid happened to
  /// exist there, it would delete a stranger's item.
  Future<int> deleteMergeOffer() async {
    final db = _db;
    if (db == null) return 0;
    final rows = db.heldRows();
    if (rows.isEmpty) return 0;
    final keys = <String>{
      for (final r in rows)
        if (r.blobKey != null) r.blobKey!,
    };
    for (final row in rows) {
      db.deleteAndQueue(row.uid, _now, queueDelete: false); // local-only
      _vec.remove(row.uid); // cached embeddings
      _enrichFails.remove(row.uid); // stale failure counters
    }
    // Blob keys can be shared across rows: only sweep files nothing surviving
    // still points at. One listSync for the lot (see _deleteBlobFilesBulk).
    for (final row in db.allWithBlob()) {
      keys.remove(row.blobKey);
    }
    _deleteBlobFilesBulk(keys);
    _mergeOfferDismissed = false;
    _refreshHeldCount();
    _savePrefs();
    _refreshWindow();
    notifyListeners();
    return rows.length;
  }

  /// Pre-holdback installs (the first version of the merge offer) recorded the
  /// offer as a COUNT in prefs and left every row fully visible — the bug this
  /// replaces. There is no record of which account those items belonged to, so
  /// tag the OLDEST [_legacyMergeOfferCount] rows (the ones that predate the
  /// switch) with the [kHeldPreviousAccount] sentinel and let the count go: it
  /// is derived from the rows from now on.
  void _migrateLegacyHoldback(RelicDb db) {
    final n = _legacyMergeOfferCount;
    _legacyMergeOfferCount = 0;
    if (n <= 0 || db.countHeld() > 0) return;
    db.holdOldest(n, kHeldPreviousAccount);
    _savePrefs(); // rewrites without the legacy merge_offer_count key
  }

  /// Shared bind preamble for BOTH connect paths (Supabase + legacy token).
  /// Returns whether the caller may queue the initial push-all: true on the
  /// first-ever bind (local install joining its own new account) or a re-bind
  /// of the SAME account; false on an account SWITCH, where auto-uploading
  /// would leak the previous account's items into the new one (the 2026-07-14
  /// incident). On a switch, every piece of per-account sync state is reset:
  /// cursors (or the pull misses the new account's items), the uploaded-blob
  /// ledger (or blobs never upload to the new account), and the outbound
  /// queue (ops from the old account must not replay against the new one).
  ///
  /// The previous account's items are also HELD BACK: stamped with the identity
  /// that owned them and hidden from every read path, rather than left sitting
  /// in the history list where they read as this account's items that refuse to
  /// sync. Signing back into that account releases exactly its own rows, so
  /// hopping between two accounts on one machine shows each its own vault.
  bool _prepareBind(String identity) {
    final prev = _syncedAccount;
    final switched = prev != null && prev != identity;
    if (switched) {
      _cursor = 0;
      _tombCursor = 0;
      _aiCursor = 0;
      _lastSyncAt = 0;
      _saveCursors();
      _uploaded.clear();
      _saveUploaded();
      _db?.clearAllPendingSync();
      _db?.holdAll(prev);
      _mergeOfferDismissed = false; // a new holdback asks again
      // Re-copying content that just went into hiding must capture it afresh
      // rather than being swallowed by the dedupe guards.
      _lastCaptured = null;
      _lastCapturedRichFp = null;
      _lastBlobHash = null;
      _lastBlobUid = null;
    }
    // Coming back to an account this device is holding items for: they are its
    // own items again, seamlessly. The sentinel is never matched — nothing
    // knows which account those rows belong to (see [_migrateLegacyHoldback]).
    final released =
        identity == kHeldPreviousAccount ? 0 : (_db?.releaseHeld(identity) ?? 0);
    _syncedAccount = identity;
    _refreshHeldCount();
    _savePrefs();
    if (switched || released > 0) {
      _hybridUids = null;
      _refreshWindow();
      notifyListeners();
    }
    return !switched;
  }

  @visibleForTesting
  bool debugPrepareBind(String identity) => _prepareBind(identity);

  /// Test seam for the account-switch paths that gate on "is this vault bound
  /// to an account" ([acceptMergeOffer] needs a key to push with). Only the
  /// gate is exercised: with no [_syncUrl], flushing is still a no-op, so the
  /// queued ops stay observable instead of going to a network.
  @visibleForTesting
  void debugSetMasterKey(Uint8List? mk) => _mk = mk;

  /// For the QR-pairing + device-registry screens (shared with mobile): the
  /// unlocked master key to deliver, and the current Worker bearer token.
  Uint8List? get masterKey => _mk;
  String? get syncBearer => _syncToken;

  /// The connected server's base URL (Relic Cloud or a self-host address). Used
  /// by the settings pane to show which server a self-host device is bound to.
  String? get syncUrl => _syncUrl;

  /// True when the most recent connect CREATED a fresh vault (so the host must
  /// show the recovery kit once). Cleared after the host consumes it.
  bool vaultJustCreated = false;

  // Supabase auth bridge (in-app sign-in). When _supabaseMode, _syncToken holds
  // a short-lived access token refreshed from _refreshToken; the crypto scope is
  // keyed off the stable user id, not the rotating token.
  bool _supabaseMode = false;
  String? _refreshToken;
  int _accessExpiry = 0; // epoch seconds
  bool _refreshing = false;
  String? _accountEmail;
  String? get accountEmail => _accountEmail;
  /// The signed-in account email, used by the delete-account confirm field.
  /// Lockstep alias with WorkerRepo.supabaseUserEmail so both hosts agree.
  String? get supabaseUserEmail => _accountEmail;
  String? _supabaseUserId;

  /// Set true when a sync write is refused with 403 email_unverified (the
  /// worker's VERIFY_GATE). Both hosts watch this to show the confirm-your-email
  /// banner; capture keeps working locally regardless. Lockstep with
  /// WorkerRepo.emailUnverified.
  final ValueNotifier<bool> emailUnverified = ValueNotifier(false);

  /// True when [body] is the worker's `{"error":"email_unverified",...}` payload.
  /// Static + pure so the flag logic is unit-testable. Lockstep with WorkerRepo.
  static bool isEmailUnverifiedBody(String body) {
    try {
      return (jsonDecode(body) as Map)['error'] == 'email_unverified';
    } catch (_) {
      return false;
    }
  }

  /// The Supabase user id (the crypto-scope `sub`), when connected via an
  /// account session. Used to bind a pairing code/QR to this account. Null on a
  /// legacy device-token connection.
  String? get supabaseUserId => _supabaseUserId;

  /// True when connected via a Supabase account session (not a legacy device
  /// token) — gates the account-wide "sign out everywhere" action.
  bool get isSupabase => _supabaseMode;

  // True when connected to a user's OWN self-hosted server (account-less,
  // passphrase-derived bearer over the device-token path). Drives the settings
  // pane: no Stripe/billing rows, a "Self-hosted" chip, "Switch server" wording.
  bool _selfHost = false;
  bool get isSelfHost => _selfHost;

  PopupSize _popupSize = PopupSize.small;
  PopupSize get popupSize => _popupSize;
  void setPopupSize(PopupSize s) {
    _popupSize = s;
    _savePrefs();
    notifyListeners();
  }

  // --- general / capture preferences (persisted in prefs.json) ---
  Appearance _appearance = Appearance.light;
  bool _launchAtLogin = true;
  bool _showTrayIcon = true;
  bool _pasteOnSelect = true;
  bool _promotionSound = false;
  bool _vaultAnimation = true;
  bool _captureText = true;
  bool _captureImages = true;
  bool _captureFiles = true;
  // Rich text, split into capture and paste so either half can be turned off
  // on its own. Both default ON, but they exist because pasting rich CHANGES
  // existing behaviour: browsers publish HTML for every copy, so a sentence
  // taken from a docs page and pasted into Word now arrives in the website's
  // fonts instead of the document's.
  bool _captureRichText = true;
  bool _pasteRichText = true;
  bool _maskSecrets = true;
  bool _clearSecretClip = true; // scrub clipboard 30 s after a secret copy
  int _maxItemMb = 100;
  bool _autoVault = false; // when on, every capture is auto-saved to the Vault
  int? _retainCount; // local "keep N" history cap; null = unlimited
  int? _retainDays; // local age cap for history (days); null = never
  bool _vaultFullFlag = false; // transient: last vault save was blocked (cap hit)
  String? _saveDir; // desktop "Save" target folder; null → OS Downloads
  String _deviceName = ''; // user override; empty → COMPUTERNAME
  // Scheduled local backup: a weekly sealed .relicvault file, keep the
  // newest 4. The wrap record (BK under the backup passphrase, ciphertext)
  // lives in prefs; the unwrapped BK lives in the OS credential store so
  // runs never prompt. Sealed backups include secrets — that's the point.
  bool _autoBackup = false;
  String? _backupDir;
  Map<String, dynamic>? _backupWrap; // null = passphrase never set up
  int _lastBackupAt = 0; // epoch s; 0 = never
  String _lastBackupSummary = ''; // "412 items, 96 files" for the row
  bool _backingUp = false;
  bool _backupNeedsReauth = false; // BK missing from the credential store
  String? _backupStatus; // last result/error line for the settings row
  Timer? _backupTimer;
  final Set<String> _customTags =
      {}; // reusable tags the user created (Tags pane)
  // Exe stems (lowercase, no .exe) whose copies the watcher ignores. The
  // save & annotate hotkey is NOT gated by this — explicit action wins.
  final Set<String> _captureBlocklist = {};
  /// OS-backed secret storage for the sync master key + auth token: DPAPI
  /// Credential Manager on Windows, Keychain on macOS (secure_key_store.dart).
  final SecureKeyStore _keyStore = SecureKeyStore.forPlatform();
  HotkeyBinding _hkHistory = HotkeyBinding.defaultHistory;
  HotkeyBinding _hkCapture = HotkeyBinding.defaultCapture;
  HotkeyBinding _hkPromote = HotkeyBinding.defaultPromote;
  HotkeyBinding _hkMini = HotkeyBinding.defaultMini;
  // Quick-paste 1-5 (Ctrl+Shift+1..5): paste the Nth most-recent item from any
  // device. On by default (registered like the other hotkeys), each editable.
  List<HotkeyBinding> _hkQuickPaste =
      List<HotkeyBinding>.from(HotkeyBinding.defaultQuickPaste);
  // Paste stack (Ctrl+Shift+D / Ctrl+Shift+B). Registered ONLY while
  // [pasteStackOn], so an opted-out user keeps both chords.
  HotkeyBinding _hkStackPush = HotkeyBinding.defaultStackPush;
  HotkeyBinding _hkStackPop = HotkeyBinding.defaultStackPop;

  /// desktop.dart installs these so a settings change takes effect live (re-
  /// register hotkeys, show/hide the tray, restyle) without the repo having to
  /// depend on the window / tray / hotkey layers.
  VoidCallback? onHotkeysChanged;
  VoidCallback? onTrayVisibilityChanged;
  VoidCallback? onAppearanceChanged;

  /// Fired when a capture is dropped for exceeding the per-item size cap —
  /// the only silent-drop case a user should hear about (privacy-marker and
  /// blocklist skips stay silent by design). desktop.dart throttles + shows
  /// a native notification.
  void Function(int limitMb)? onCaptureTooLarge;

  /// Fired by the reminder sweep when one or more reminders come due. The shell
  /// shows a native toast (coalescing when there are many) whose click summons
  /// the item onto the clipboard. Rows are already marked fired by the sweep.
  void Function(List<Reminder> due)? onRemindersDue;

  /// Hotkey chords that failed to register (another app owns them), keyed
  /// 'history' | 'capture' | 'promote'. Settings shows a warning per row.
  Set<String> _failedHotkeys = const {};
  Set<String> get failedHotkeys => _failedHotkeys;
  void setFailedHotkeys(Set<String> keys) {
    if (setEquals(keys, _failedHotkeys)) return;
    _failedHotkeys = keys;
    notifyListeners();
  }

  /// One-time "Relic lives in the tray" education, shown on the first hide.
  bool _trayHintShown = false;
  bool get trayHintShown => _trayHintShown;
  void markTrayHintShown() {
    _trayHintShown = true;
    _savePrefs();
  }

  Appearance get appearance => _appearance;
  bool get launchAtLogin => _launchAtLogin;
  bool get showTrayIcon => _showTrayIcon;
  bool get pasteOnSelect => _pasteOnSelect;
  @override
  bool get promotionSound => _promotionSound;
  @override
  bool get vaultAnimation => _vaultAnimation;
  bool _coachSeen = false;
  @override
  bool get coachMarksSeen => _coachSeen;

  // One-time "this is sample data" nudge after seeding the demo. Persisted like
  // the mobile promo flag (relic.promo.addDeviceShown) so it never nags twice.
  bool _demoNudgeShown = false;
  bool get demoNudgeDismissed => _demoNudgeShown;
  void dismissDemoNudge() {
    if (_demoNudgeShown) return;
    _demoNudgeShown = true;
    _savePrefs();
    notifyListeners();
  }
  @override
  Future<void> markCoachMarksSeen() async {
    if (_coachSeen) return;
    _coachSeen = true;
    _savePrefs();
  }
  bool get captureTextEnabled => _captureText;
  bool get captureImagesEnabled => _captureImages;
  bool get captureFilesEnabled => _captureFiles;
  bool get captureRichText => _captureRichText;
  bool get pasteRichText => _pasteRichText;
  bool get maskSecrets => _maskSecrets;
  int get maxItemMb => _maxItemMb;
  @override
  int get maxItemBytes => _maxItemMb * 1024 * 1024;
  bool get autoVault => _autoVault;
  int? get retainCount => _retainCount;
  int? get retainDays => _retainDays;
  bool get vaultFull => _vaultFullFlag;
  void clearVaultFull() {
    if (_vaultFullFlag) {
      _vaultFullFlag = false;
      notifyListeners();
    }
  }

  /// Retention/vault limits for the active tier. Local = unlimited vault with an
  /// optional keep-N (10–10,000); Free/Paid mirror the server `TIERS`
  /// (`worker/src/index.ts`) so the UI and pre-checks agree with the backend.
  RetentionLimits get retentionLimits {
    switch (account?.tier) {
      case 'Free':
        return const RetentionLimits(
          vaultCount: 500,
          storageBytes: 250 * 1024 * 1024,
          ringMin: 500,
          ringMax: 500,
          ringDefault: 500,
          allowUnlimited: false,
        );
      case 'Paid':
        return const RetentionLimits(
          vaultCount: null,
          storageBytes: 25 * 1024 * 1024 * 1024,
          ringMin: 100,
          ringMax: 10000,
          ringDefault: 1000,
          allowUnlimited: false,
        );
      default: // 'Local' (no account) — unlimited, opt-in keep-N
        return const RetentionLimits(
          vaultCount: null,
          storageBytes: null,
          ringMin: 10,
          ringMax: 10000,
          ringDefault: 1000,
          allowUnlimited: true,
        );
    }
  }

  @override
  String? get saveDir => _saveDir;
  String get deviceName => _deviceName;

  /// What new captures are stamped with: the user's name, else the hostname.
  String get _deviceLabel => _deviceName.trim().isNotEmpty
      ? _deviceName.trim()
      : (Platform.environment['COMPUTERNAME'] ??
          (Platform.localHostname.isNotEmpty
              ? Platform.localHostname
              : 'This PC'));
  HotkeyBinding get historyHotkey => _hkHistory;
  HotkeyBinding get captureHotkey => _hkCapture;
  HotkeyBinding get promoteHotkey => _hkPromote;
  HotkeyBinding get miniHotkey => _hkMini;
  // The five quick-paste bindings, slot 0 = Ctrl+Shift+1 (newest) … slot 4.
  List<HotkeyBinding> get quickPasteHotkeys => List.unmodifiable(_hkQuickPaste);
  HotkeyBinding get stackPushHotkey => _hkStackPush;
  HotkeyBinding get stackPopHotkey => _hkStackPop;

  void setAppearance(Appearance a) {
    _appearance = a;
    _savePrefs();
    onAppearanceChanged?.call();
    notifyListeners();
  }

  void setLaunchAtLogin(bool on) {
    _launchAtLogin = on;
    // macOS SMAppService.register() legitimately fails (app outside
    // /Applications, unsigned build, pre-13) — don't leave the toggle claiming
    // a state the OS refused. The Windows Run-key write effectively always
    // succeeds, so this is a no-op there.
    unawaited(setLaunchAtStartup(on).then((ok) {
      if (ok || _launchAtLogin != on) return;
      _launchAtLogin = !on;
      _savePrefs();
      notifyListeners();
    }));
    _savePrefs();
    notifyListeners();
  }

  void setShowTrayIcon(bool on) {
    _showTrayIcon = on;
    _savePrefs();
    onTrayVisibilityChanged?.call();
    notifyListeners();
  }

  void setPasteOnSelect(bool on) {
    _pasteOnSelect = on;
    _savePrefs();
    notifyListeners();
  }

  bool get clearSecretClipboard => _clearSecretClip;
  void setClearSecretClipboard(bool on) {
    _clearSecretClip = on;
    if (!on) _secretClearTimer?.cancel();
    _savePrefs();
    notifyListeners();
  }

  Set<String> get captureBlocklist => Set.unmodifiable(_captureBlocklist);

  /// Normalize user input to the exe stem the watcher gate compares against:
  /// lowercase, trimmed, `.exe` stripped ("Notepad.EXE" → "notepad").
  static String normExe(String s) {
    var t = s.trim().toLowerCase();
    if (t.endsWith('.exe')) t = t.substring(0, t.length - 4);
    return t;
  }

  void addCaptureBlock(String exe) {
    final t = normExe(exe);
    if (t.isEmpty) return;
    if (_captureBlocklist.add(t)) {
      _savePrefs();
      notifyListeners();
    }
  }

  void removeCaptureBlock(String exe) {
    if (_captureBlocklist.remove(normExe(exe))) {
      _savePrefs();
      notifyListeners();
    }
  }

  void setPromotionSound(bool on) {
    _promotionSound = on;
    _savePrefs();
    notifyListeners();
  }

  void setVaultAnimation(bool on) {
    _vaultAnimation = on;
    _savePrefs();
    notifyListeners();
  }

  void setCaptureText(bool on) {
    _captureText = on;
    _savePrefs();
    notifyListeners();
  }

  void setCaptureImages(bool on) {
    _captureImages = on;
    _savePrefs();
    notifyListeners();
  }

  void setCaptureFiles(bool on) {
    _captureFiles = on;
    _savePrefs();
    notifyListeners();
  }

  void setCaptureRichText(bool on) {
    _captureRichText = on;
    _savePrefs();
    notifyListeners();
  }

  void setPasteRichText(bool on) {
    _pasteRichText = on;
    _savePrefs();
    notifyListeners();
  }

  void setMaskSecrets(bool on) {
    _maskSecrets = on;
    _savePrefs();
    notifyListeners();
  }

  void setMaxItemMb(int mb) {
    _maxItemMb = mb.clamp(1, 100);
    _savePrefs();
    notifyListeners();
  }

  /// Set the local "keep N" history cap (null = unlimited). Clamped to the
  /// active tier's range; applies immediately by evicting any excess.
  void setRetainCount(int? n) {
    final lim = retentionLimits;
    _retainCount = n?.clamp(lim.ringMin, lim.ringMax);
    _savePrefs();
    _enforceRetention();
    notifyListeners();
  }

  /// Set the local "remove older than N days" history cap (null = never).
  /// Local-only, like keep-N: the server ring owns synced retention.
  void setRetainDays(int? days) {
    _retainDays = days;
    _savePrefs();
    _enforceRetention();
    notifyListeners();
  }

  /// Local retention eviction: drop unpromoted (history) relics beyond the
  /// keep-N cap and/or older than the age cap. Only acts on local-only
  /// installs — when sync is on, the server ring (`worker/src/index.ts`)
  /// owns account-wide retention and locally evicting would fight the next
  /// pull. Vault items are never touched.
  void _enforceRetention() {
    final db = _db;
    if (db == null || syncEnabled) return;
    var evicted = false;
    final keep = _retainCount;
    if (keep != null && db.countUnpromoted() > keep) {
      for (final row in db.unpromotedBeyond(keep)) {
        _deleteBlobFiles(row.blobKey);
        db.deleteAndQueue(row.uid, _now, queueDelete: false); // local-only
        _vec.remove(row.uid);
        evicted = true;
      }
    }
    final days = _retainDays;
    if (days != null) {
      for (final row in db.unpromotedOlderThan(_now - days * 86400)) {
        _deleteBlobFiles(row.blobKey);
        db.deleteAndQueue(row.uid, _now, queueDelete: false); // local-only
        _vec.remove(row.uid);
        evicted = true;
      }
    }
    if (!evicted) return;
    _refreshWindow();
    notifyListeners();
  }

  /// Would saving [incomingBytes] more to the Vault exceed the tier cap? Used to
  /// block a promotion before it happens (the server 402 is the synced backstop).
  /// Local/Paid vault count is unlimited, so this only bites synced Free.
  bool _vaultFull(int incomingBytes) {
    final db = _db;
    if (db == null) return false;
    final lim = retentionLimits;
    if (lim.vaultCount == null && lim.storageBytes == null) return false;
    final (count, bytes) = db.vaultUsage();
    if (lim.vaultCount != null && count >= lim.vaultCount!) return true;
    if (lim.storageBytes != null && bytes + incomingBytes > lim.storageBytes!) {
      return true;
    }
    return false;
  }

  /// Resolve whether a new capture should land in the Vault: honors the caller's
  /// intent but downgrades to history (and flags `vaultFull`) when the Vault is
  /// at its cap, so the content is still captured rather than lost.
  bool _promoteOnCapture(bool want, int incomingBytes) {
    if (!want) return false;
    if (_vaultFull(incomingBytes)) {
      _vaultFullFlag = true;
      return false;
    }
    return true;
  }

  /// Remove a relic's blob file and any unpacked attachment cache files.
  void _deleteBlobFiles(String? blobKey) {
    if (blobKey == null) return;
    try {
      final f = File(_blobFilePath(blobKey));
      if (f.existsSync()) f.deleteSync();
      final prefix = '$blobKey.';
      for (final e in _blobsDir.listSync()) {
        if (e is File &&
            e.path.split(Platform.pathSeparator).last.startsWith(prefix)) {
          try {
            e.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Toggle "Save everything to Vault". Turning it on retroactively promotes
  /// every existing relic, then new captures are auto-promoted on the way in.
  void setAutoVault(bool on) {
    _autoVault = on;
    _savePrefs();
    if (on) _promoteAllExisting();
    notifyListeners();
  }

  /// Desktop "Save" destination folder. Empty/null falls back to OS Downloads.
  void setSaveDir(String? dir) {
    final d = dir?.trim();
    _saveDir = (d == null || d.isEmpty) ? null : d;
    _savePrefs();
    notifyListeners();
  }

  void setDeviceName(String name) {
    _deviceName = name.trim();
    _savePrefs();
    notifyListeners();
  }

  void setHistoryHotkey(HotkeyBinding b) {
    _hkHistory = b;
    _savePrefs();
    onHotkeysChanged?.call();
    notifyListeners();
  }

  void setCaptureHotkey(HotkeyBinding b) {
    _hkCapture = b;
    _savePrefs();
    onHotkeysChanged?.call();
    notifyListeners();
  }

  void setPromoteHotkey(HotkeyBinding b) {
    _hkPromote = b;
    _savePrefs();
    onHotkeysChanged?.call();
    notifyListeners();
  }

  void setMiniHotkey(HotkeyBinding b) {
    _hkMini = b;
    _savePrefs();
    onHotkeysChanged?.call();
    notifyListeners();
  }

  /// Rebind quick-paste [slot] (0 = Ctrl+Shift+1 … 4 = Ctrl+Shift+5).
  void setQuickPasteHotkey(int slot, HotkeyBinding b) {
    if (slot < 0 || slot >= _hkQuickPaste.length) return;
    _hkQuickPaste[slot] = b;
    _savePrefs();
    onHotkeysChanged?.call();
    notifyListeners();
  }

  void setStackPushHotkey(HotkeyBinding b) {
    _hkStackPush = b;
    _savePrefs();
    onHotkeysChanged?.call();
    notifyListeners();
  }

  void setStackPopHotkey(HotkeyBinding b) {
    _hkStackPop = b;
    _savePrefs();
    onHotkeysChanged?.call();
    notifyListeners();
  }

  // --- on-device ML (sift) ---
  SiftSidecar? _sift;
  bool _mlEnrich = true;
  // Generated titles + topic tags, for photos AND text. Defaults OFF
  // (docs/ai-labeling-audit-2026-07.md): it is a ~666 MB download and ~0.8 s
  // per item even through the resident classifier. Existing users keep
  // whatever they set — the pref key stays `rich_captions`, which is what this
  // was called when it only did images.
  bool _describeItems = false;
  // Widen labeling from vault-only to the whole stream. Off by default: the
  // stream is where the volume is, so this spends ~0.8 s of generative work on
  // every throwaway copy, and most of them are never looked at again.
  bool _describeEverything = false;
  // How much CPU the background passes may take. See [AnalysisSpeed].
  AnalysisSpeed _analysisSpeed = AnalysisSpeed.balanced;
  // Which generation of retired-model cleanup this install has already run.
  // Bump [_kPruneGen] whenever relic-sift retires more files; that is what makes
  // an upgrade re-run the sweep instead of skipping it forever.
  int _prunedGen = 0;
  // Gen 1: Florence-2 (~246 MB) plus the `dml/` DirectML runtime, both dead
  // once Qwen3.5 took over labeling.
  static const int _kPruneGen = 1;
  // Finer AI knobs under the master `_mlEnrich`. OCR / content tags /
  // embeddings default on (current behavior).
  bool _aiOcr = true;
  bool _aiImageTags = true;
  bool _aiEmbeddings = true;
  // Personalized ranking: learn from picks (usage frecency, query-pick
  // memory, summon-context prior) and apply the learned factors in search.
  // All signals are local-only; one switch governs both learning and use.
  bool _personalRank = true;
  // --- Power features (opt-in, all default OFF; Settings > General) ---
  // These never touch the core copy/paste flow when off. See
  // docs/competitor-parity-features-2026-07.md.
  bool _multiCombine = false; // multi-select in the picker → combine & paste
  bool _snippets = false; // saved reusable text, surfaced as a picker facet
  bool _reminders = false; // per-item reminders with a native toast
  bool _pasteAtCaret = false; // open the picker near the text cursor (desktop)
  bool _pasteStack = false; // queue items, then paste them one at a time
  Timer? _reminderTimer; // sweep runs only while _reminders is on

  /// The paste stack: items queued for sequential pasting, head first.
  ///
  /// Session state, deliberately not persisted — a machine restart must never
  /// come up with a stale queue armed, the same reasoning the pause state uses
  /// (docs/qol-backlog.md). It cannot live in the picker either: the popup
  /// clears its state on every close, and filling the stack then dismissing to
  /// drain it elsewhere is the entire flow.
  ///
  /// Holds Relic snapshots rather than uids for the reason _multiSel does: the
  /// list re-sorts and rows scroll out of the loaded window.
  final List<Relic> _stack = [];
  // Foreground app at the last popup summon (exe stem / bundle id), set by
  // the desktop shell — the "paste destination" for the context prior.
  // Null on mobile and when the summoner is Relic itself.
  String? _summonApp;
  Timer? _enrichTimer;
  bool _enriching = false;
  /// Uids queued or in flight in the current enrich cycle — drives the per-row
  /// "Analyzing…" spinner. Empty whenever the worker is idle.
  Set<String> _analyzing = {};

  @override
  Set<String> get analyzingUids => _analyzing;

  bool _downloadingModels = false;
  bool _removingModels = false;
  String? _modelsDirCache; // resolved `sift models path`, stable per install
  int _enrichBacklog = 0; // relics below the current enrich target
  static const int _levelStageA = 1;
  // v3: bumped from 2 → one-time background re-enrich of the whole corpus, so
  // existing relics pick up title+note embeddings, bare-fact vectors, chunked
  // long-doc vectors, and captions-for-all-photos.
  static const int _levelMl = 3;

  bool get mlAvailable => _sift != null;
  bool get mlEnrich => _mlEnrich;
  bool get describeItems => _describeItems;
  bool get describeEverything => _describeEverything;
  AnalysisSpeed get analysisSpeed => _analysisSpeed;
  bool get aiOcr => _aiOcr;
  bool get aiImageTags => _aiImageTags;
  bool get aiEmbeddings => _aiEmbeddings;
  bool get downloadingModels => _downloadingModels;
  bool get removingModels => _removingModels;
  int get enrichBacklog => _enrichBacklog;

  Future<String?> _modelsDir() async =>
      _modelsDirCache ??= await _sift?.modelsPath();

  /// Total bytes of the downloaded model cache (flat model files, the ONNX
  /// runtime dll(s), and the optional dml/ GPU subdir — a couple dozen files).
  Future<int> modelsBytes() async {
    final path = await _modelsDir();
    if (path == null) return 0;
    final dir = Directory(path);
    if (!dir.existsSync()) return 0;
    var total = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// Files inside the model cache that are USER data, never deleted: custom
  /// classification rules and a taxonomy override both live in the models dir.
  static const _modelsKeep = {'user-rules.json', 'taxonomy.json'};

  /// Delete the downloaded ML models to reclaim disk (settings action).
  /// Only while smart tags is OFF and no download is in flight; they
  /// re-download automatically if smart tags is turned back on. Returns
  /// bytes freed (0 when blocked or nothing to delete).
  Future<int> removeModels() async {
    final sift = _sift;
    if (sift == null || _mlEnrich || _downloadingModels || _removingModels) {
      return 0;
    }
    _removingModels = true;
    notifyListeners();
    try {
      final path = await _modelsDir();
      if (path == null) return 0;
      final dir = Directory(path);
      // Never recursive-delete on unexpected stdout: require an absolute,
      // existing `…/relic-sift/models` path (RELIC_SIFT_HOME may relocate
      // the parent, so only the trailing `models` is required then).
      final segs =
          dir.uri.pathSegments.where((s) => s.isNotEmpty).toList();
      final ok = dir.isAbsolute &&
          dir.existsSync() &&
          segs.isNotEmpty &&
          segs.last == 'models' &&
          (Platform.environment.containsKey('RELIC_SIFT_HOME') ||
              (segs.length >= 2 && segs[segs.length - 2] == 'relic-sift'));
      if (!ok) return 0;
      // Search's embed server may still have the ONNX/dll files mapped even
      // with smart tags off — Windows won't delete a mapped file. Kill it
      // and give the OS a beat; it restarts lazily and fails soft without
      // models (search degrades to lexical).
      sift.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      var freed = 0;
      for (final e in dir.listSync()) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (_modelsKeep.contains(name)) continue;
        try {
          if (e is File) {
            freed += e.lengthSync();
            e.deleteSync();
          } else if (e is Directory) {
            // dml/ GPU runtime
            for (final f in e.listSync(recursive: true)) {
              if (f is File) {
                try {
                  freed += f.lengthSync();
                } catch (_) {}
              }
            }
            e.deleteSync(recursive: true);
          }
        } catch (_) {
          // still locked — skip; the size refresh shows the remainder
        }
      }
      await sift.checkModels(); // -> modelsReady false
      return freed;
    } finally {
      _removingModels = false;
      notifyListeners();
    }
  }

  SiftStatus get siftStatus {
    if (_sift == null) return SiftStatus.unavailable;
    if (!_mlEnrich) return SiftStatus.off;
    if (_downloadingModels) return SiftStatus.downloading;
    if (!_sift!.modelsReady) return SiftStatus.stageA;
    // Models ready but the stored-vector leg is disabled — search runs
    // keyword+typo (+ tag expansion) only. An EMPTY vector table with the
    // toggle on is NOT this state: enrichment is about to fill it.
    if (!_aiEmbeddings) return SiftStatus.keywordOnly;
    return SiftStatus.ready;
  }

  void setMlEnrich(bool on) {
    _mlEnrich = on;
    _savePrefs();
    notifyListeners();
    if (on) {
      _startEnrichWorker();
      _enrichCycle(); // kick immediately
    } else {
      _enrichTimer?.cancel();
    }
  }

  void setDescribeItems(bool on) {
    _describeItems = on;
    // The resident classifier decides at spawn whether to load the labeler at
    // all, so it has to be restarted to pick this up.
    _sift?.labelCapable = on;
    _sift?.stopServer();
    _savePrefs();
    notifyListeners();
  }

  void setDescribeEverything(bool on) {
    _describeEverything = on;
    // Only the per-item label decision changes, and that rides in each request
    // rather than the server's spawn flags — no restart needed.
    _savePrefs();
    notifyListeners();
  }

  void setAnalysisSpeed(AnalysisSpeed s) {
    _analysisSpeed = s;
    // Threads are fixed when a session is built and priority is process-wide,
    // so the resident classifier has to be restarted to adopt this.
    _sift?.speed = s.flag;
    _sift?.stopServer();
    _savePrefs();
    notifyListeners();
  }

  void setAiOcr(bool on) {
    _aiOcr = on;
    _savePrefs();
    notifyListeners();
  }

  void setAiImageTags(bool on) {
    _aiImageTags = on;
    _savePrefs();
    notifyListeners();
  }

  void setAiEmbeddings(bool on) {
    _aiEmbeddings = on;
    _savePrefs();
    notifyListeners();
  }

  bool get personalRank => _personalRank;
  void setPersonalRank(bool on) {
    _personalRank = on;
    _savePrefs();
    notifyListeners();
  }

  // --- Power features (opt-in) ---
  @override
  bool get multiCombine => _multiCombine;
  void setMultiCombine(bool on) {
    _multiCombine = on;
    _savePrefs();
    notifyListeners();
  }

  @override
  bool get pasteStackOn => _pasteStack;

  /// Unlike the other power-feature setters this one calls [onHotkeysChanged]:
  /// turning it on or off has to register or release two global chords, and
  /// the settings rows for those chords are shown only while it is on. Wiring
  /// visibility and liveness together is what keeps a live chord from existing
  /// with nothing in the UI to reveal it.
  void setPasteStack(bool on) {
    _pasteStack = on;
    if (!on) clearStack();
    _savePrefs();
    onHotkeysChanged?.call();
    notifyListeners();
  }

  // --- the stack itself ---
  @override
  List<Relic> get pasteStack => List.unmodifiable(_stack);

  int get pasteStackDepth => _stack.length;

  /// The next item out, without consuming it. The pop handler writes the
  /// clipboard first and only then calls [popStack], so a failed write leaves
  /// the queue untouched.
  Relic? peekStack() => _stack.isEmpty ? null : _stack.first;

  void pushStack(Relic r) {
    _stack.add(r);
    notifyListeners();
  }

  @override
  void pushStackAll(Iterable<Relic> rs) {
    if (rs.isEmpty) return;
    _stack.addAll(rs);
    notifyListeners();
  }

  /// FIFO: [pushStack] appends, this takes the head. Copy 1, 2, 3 then paste
  /// 1, 2, 3. Everyone calls it a stack; it behaves as a queue, which is what
  /// filling a form actually needs.
  Relic? popStack() {
    if (_stack.isEmpty) return null;
    final r = _stack.removeAt(0);
    notifyListeners();
    return r;
  }

  @override
  void removeFromStack(String uid) {
    final before = _stack.length;
    _stack.removeWhere((r) => r.uid == uid);
    if (_stack.length != before) notifyListeners();
  }

  @override
  void reverseStack() {
    if (_stack.length < 2) return;
    final copy = _stack.reversed.toList();
    _stack
      ..clear()
      ..addAll(copy);
    notifyListeners();
  }

  @override
  void clearStack() {
    if (_stack.isEmpty) return;
    _stack.clear();
    notifyListeners();
  }

  @override
  bool get snippets => _snippets;
  void setSnippets(bool on) {
    _snippets = on;
    _savePrefs();
    notifyListeners();
  }

  bool get pasteAtCaret => _pasteAtCaret;
  void setPasteAtCaret(bool on) {
    _pasteAtCaret = on;
    _savePrefs();
    notifyListeners();
  }

  @override
  bool get reminders => _reminders;
  // Reminders own a periodic sweep (mirrors setMlEnrich): start + catch up on
  // enable, cancel on disable. The sweep body no-ops if the toggle is off.
  void setReminders(bool on) {
    _reminders = on;
    _savePrefs();
    notifyListeners();
    if (on) {
      _startReminderSweep();
    } else {
      _reminderTimer?.cancel();
      _reminderTimer = null;
    }
  }

  void setSummonApp(String? app) => _summonApp = app;

  /// The app key the picker was summoned over — i.e. where a paste will land.
  /// Linux needs it to pick the right paste chord (terminals take
  /// Ctrl+Shift+V), which is also why linuxAppKey folds every terminal onto
  /// the one 'terminal' key.
  String? get summonApp => _summonApp;

  // --- Clip reminders plumbing ---
  static int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  /// Look an item up by uid (for the reminder toast's summon + copy).
  Relic? relicByUid(String uid) => _db?.getByUid(uid);

  /// This repo already notifies on every mutation, so it is its own change
  /// signal — see [RelicRepo.changes].
  @override
  Listenable get changes => this;

  @override
  Relic? byUid(String uid) => _db?.getByUid(uid);

  /// Schedule a reminder; returns the row id (or null if the DB is unavailable).
  @override
  int? addReminder(String uid, int remindAtMs, {String? note}) =>
      _db?.addReminder(uid, remindAtMs, note: note);

  @override
  List<Reminder> remindersFor(String uid) =>
      _db?.remindersFor(uid) ?? const [];

  @override
  void clearReminder(int id) => _db?.clearReminder(id);

  void _startReminderSweep() {
    _reminderTimer?.cancel();
    _reminderTimer =
        Timer.periodic(const Duration(seconds: 45), (_) => _sweepReminders());
    _sweepReminders(); // catch up immediately (covers reminders due while off)
  }

  void _sweepReminders() {
    if (!_reminders || _disposed) return;
    final db = _db;
    if (db == null) return;
    // Don't consume reminders until the shell is listening — otherwise a sweep
    // that fires before onRemindersDue is installed would mark them fired and
    // the toast would never show. Next tick retries once the shell is up.
    final cb = onRemindersDue;
    if (cb == null) return;
    final due = db.dueReminders(_nowMs);
    if (due.isEmpty) return;
    // Mark fired before notifying so a re-entrant sweep can't double-fire them.
    for (final r in due) {
      db.markFired(r.id);
    }
    cb(due);
  }

  /// Wipe everything personalized ranking has learned on this device.
  void clearPersonalMemory() {
    _db?.clearPersonalMemory();
    notifyListeners();
  }

  // Data-dir resolution (incl. the RELIC_DATA_DIR sandbox override) lives in
  // platform/paths.dart so the crash log, relic-cli and this repo agree.
  Directory get _dir => appDataDir();

  String _p(String name) => '${_dir.path}${Platform.pathSeparator}$name';

  Directory get _blobsDir {
    final d = Directory(_p('blobs'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  File get _dbFile => File(_p('relics.db'));
  File get _legacyJson => File(_p('flutter-relics.json'));
  File get _configFile => File(_p('config.json'));
  File get _legacyKeyFile => File(_p('key.bin'));
  File get _cursorFile => File(_p('cursor.txt'));
  File get _uploadedFile => File(_p('uploaded.json'));
  File get _prefsFile => File(_p('prefs.json'));

  void _loadPrefs() {
    try {
      if (_prefsFile.existsSync()) {
        final j =
            jsonDecode(_prefsFile.readAsStringSync()) as Map<String, dynamic>;
        _popupSize = PopupSize.byName(j['popup_size'] as String?);
        // ('mini_picker' was retired: which picker opens is decided by what
        // summoned it, not by a preference. Old files keep the key; it is
        // ignored and drops out on the next save.)
        _mlEnrich = j['ml_enrich'] as bool? ?? true;
        _describeItems = j['rich_captions'] as bool? ?? false;
        _describeEverything = j['describe_everything'] as bool? ?? false;
        _analysisSpeed = AnalysisSpeed.byName(j['analysis_speed'] as String?);
        _prunedGen = j['models_pruned_gen'] as int? ?? 0;
        _aiConverged = j['ai_records_converged'] as bool? ?? false;
        _aiOcr = j['ai_ocr'] as bool? ?? true;
        _aiImageTags = j['ai_image_tags'] as bool? ?? true;
        _aiEmbeddings = j['ai_embeddings'] as bool? ?? true;
        _personalRank = j['personal_rank'] as bool? ?? true;
        _multiCombine = j['feature_multi_combine'] as bool? ?? false;
        _snippets = j['feature_snippets'] as bool? ?? false;
        _reminders = j['feature_reminders'] as bool? ?? false;
        _pasteAtCaret = j['feature_paste_at_caret'] as bool? ?? false;
        _pasteStack = j['feature_paste_stack'] as bool? ?? false;
        _appearance = Appearance.byName(j['appearance'] as String?);
        _launchAtLogin = j['launch_at_login'] as bool? ?? true;
        _showTrayIcon = j['show_tray'] as bool? ?? true;
        // Renamed key (July 2026): the old default was OFF, so a stored
        // 'paste_on_select' can't distinguish "never touched" from "opted
        // out" — everyone adopts the new ON default once under the new key,
        // and an explicit off sticks from then on.
        _pasteOnSelect = j['paste_on_select2'] as bool? ?? true;
        _promotionSound =
            j['promotion_sound'] as bool? ??
            j['sound_on_capture'] as bool? ??
            false;
        _vaultAnimation = j['vault_animation'] as bool? ?? true;
        _coachSeen = j['coach_seen'] as bool? ?? false;
        _trayHintShown = j['tray_hint_shown'] as bool? ?? false;
        _demoNudgeShown = j['demo_nudge_dismissed'] as bool? ?? false;
        _captureText = j['capture_text'] as bool? ?? true;
        _captureImages = j['capture_images'] as bool? ?? true;
        _captureFiles = j['capture_files'] as bool? ?? true;
        _captureRichText = j['capture_rich_text'] as bool? ?? true;
        _pasteRichText = j['paste_rich_text'] as bool? ?? true;
        _maskSecrets = j['mask_secrets'] as bool? ?? true;
        _clearSecretClip = j['clear_secret_clip'] as bool? ?? true;
        _maxItemMb = (j['max_item_mb'] as num?)?.toInt().clamp(1, 100) ?? 100;
        _autoVault = j['auto_vault'] as bool? ?? false;
        _retainCount = (j['retain_count'] as num?)?.toInt(); // null = unlimited
        _retainDays = (j['retain_days'] as num?)?.toInt(); // null = never
        final sd = (j['save_dir'] as String?)?.trim();
        _saveDir = (sd == null || sd.isEmpty) ? null : sd;
        _autoBackup = j['auto_backup'] as bool? ?? false;
        final bd = (j['backup_dir'] as String?)?.trim();
        _backupDir = (bd == null || bd.isEmpty) ? null : bd;
        _backupWrap = (j['backup_wrap'] as Map?)?.cast<String, dynamic>();
        _lastBackupAt = (j['last_backup_at'] as num?)?.toInt() ?? 0;
        _lastBackupSummary = j['last_backup_summary'] as String? ?? '';
        _deviceName = j['device_name'] as String? ?? '';
        _syncedAccount = j['synced_account'] as String?;
        _mergeOfferDismissed = j['merge_offer_dismissed'] as bool? ?? false;
        // Legacy key: a count with no marked rows behind it. Consumed once by
        // _migrateLegacyHoldback and never written again.
        _legacyMergeOfferCount =
            (j['merge_offer_count'] as num?)?.toInt() ?? 0;
        _customTags
          ..clear()
          ..addAll((j['custom_tags'] as List?)?.cast<String>() ?? const []);
        _captureBlocklist
          ..clear()
          ..addAll((j['capture_blocklist'] as List?)?.cast<String>() ?? const []);
        // A stored binding equal to the OLD default means the user never
        // customized it — silently adopt the new Ctrl+Shift+Q/W/E defaults.
        HotkeyBinding upgrade(
            Object? raw, HotkeyBinding legacy, HotkeyBinding def) {
          final b = HotkeyBinding.fromJson(raw);
          if (b == null || b.sameChordAs(legacy)) return def;
          return b;
        }

        _hkHistory = upgrade(j['hk_history'], HotkeyBinding.legacyHistory,
            HotkeyBinding.defaultHistory);
        _hkCapture = upgrade(j['hk_capture'], HotkeyBinding.legacyCapture,
            HotkeyBinding.defaultCapture);
        _hkPromote = upgrade(j['hk_promote'], HotkeyBinding.legacyPromote,
            HotkeyBinding.defaultPromote);
        // Quick-paste 1-5 (new in 1.0.22): per-slot, fall back to the default
        // chord for any slot that's missing or unreadable.
        final qp = j['hk_quick_paste'];
        _hkQuickPaste = [
          for (var i = 0; i < HotkeyBinding.defaultQuickPaste.length; i++)
            (qp is List && i < qp.length
                    ? HotkeyBinding.fromJson(qp[i])
                    : null) ??
                HotkeyBinding.defaultQuickPaste[i],
        ];
        _hkStackPush = HotkeyBinding.fromJson(j['hk_stack_push']) ??
            HotkeyBinding.defaultStackPush;
        _hkStackPop = HotkeyBinding.fromJson(j['hk_stack_pop']) ??
            HotkeyBinding.defaultStackPop;
        // Mini picker hotkey (new): no legacy to upgrade, just the default.
        _hkMini =
            HotkeyBinding.fromJson(j['hk_mini']) ?? HotkeyBinding.defaultMini;
      }
    } catch (_) {}
  }

  void _savePrefs() {
    try {
      _prefsFile.writeAsStringSync(
        jsonEncode({
          'popup_size': _popupSize.name,
          'ml_enrich': _mlEnrich,
          'rich_captions': _describeItems,
          'describe_everything': _describeEverything,
          'analysis_speed': _analysisSpeed.name,
          'models_pruned_gen': _prunedGen,
          'ai_records_converged': _aiConverged,
          'ai_ocr': _aiOcr,
          'ai_image_tags': _aiImageTags,
          'ai_embeddings': _aiEmbeddings,
          'personal_rank': _personalRank,
          'feature_multi_combine': _multiCombine,
          'feature_snippets': _snippets,
          'feature_reminders': _reminders,
          'feature_paste_at_caret': _pasteAtCaret,
          'feature_paste_stack': _pasteStack,
          'appearance': _appearance.name,
          'launch_at_login': _launchAtLogin,
          'show_tray': _showTrayIcon,
          'paste_on_select2': _pasteOnSelect,
          'promotion_sound': _promotionSound,
          'vault_animation': _vaultAnimation,
          'coach_seen': _coachSeen,
          'tray_hint_shown': _trayHintShown,
          'demo_nudge_dismissed': _demoNudgeShown,
          'capture_text': _captureText,
          'capture_images': _captureImages,
          'capture_files': _captureFiles,
          'capture_rich_text': _captureRichText,
          'paste_rich_text': _pasteRichText,
          'mask_secrets': _maskSecrets,
          'clear_secret_clip': _clearSecretClip,
          'max_item_mb': _maxItemMb,
          'auto_vault': _autoVault,
          if (_retainCount != null) 'retain_count': _retainCount,
          if (_retainDays != null) 'retain_days': _retainDays,
          if (_saveDir != null) 'save_dir': _saveDir,
          'auto_backup': _autoBackup,
          if (_backupDir != null) 'backup_dir': _backupDir,
          if (_backupWrap != null) 'backup_wrap': _backupWrap,
          if (_lastBackupAt > 0) 'last_backup_at': _lastBackupAt,
          if (_lastBackupSummary.isNotEmpty)
            'last_backup_summary': _lastBackupSummary,
          'device_name': _deviceName,
          if (_syncedAccount != null) 'synced_account': _syncedAccount,
          // The offer's SIZE is derived from the held rows now; only the
          // "don't ask again" answer needs persisting.
          if (_mergeOfferDismissed) 'merge_offer_dismissed': true,
          'custom_tags': _customTags.toList(),
          'capture_blocklist': _captureBlocklist.toList(),
          'hk_history': _hkHistory.toJson(),
          'hk_capture': _hkCapture.toJson(),
          'hk_promote': _hkPromote.toJson(),
          'hk_mini': _hkMini.toJson(),
          'hk_quick_paste': [for (final b in _hkQuickPaste) b.toJson()],
          'hk_stack_push': _hkStackPush.toJson(),
          'hk_stack_pop': _hkStackPop.toJson(),
        }),
      );
    } catch (_) {}
  }

  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // Timers cancel on dispose, but load() also schedules one-shot
  // Future.delayed work (_backlogExtractPass, _maybeAutoBackup) that can fire
  // after the DB is closed — those check this flag instead.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _syncTimer?.cancel();
    _enrichTimer?.cancel();
    _secretClearTimer?.cancel();
    _backupTimer?.cancel();
    _reminderTimer?.cancel();
    _sift?.dispose();
    _db?.dispose();
    super.dispose();
  }

  @override
  Future<void> load() async {
    _loadPrefs();
    // Cache the running version once for the X-Relic-App-Version header (and
    // fail soft in tests, where the platform channel is absent).
    try {
      _appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    // Keep the OS run-at-login entry in sync with the saved preference.
    // Windows needs ownership rules, not just presence: uninstall wipes the
    // Run value, and whichever copy launches next would claim it — a dev
    // build run from the repo once owned every sign-in this way. So the
    // canonical install ALWAYS reclaims the slot, while any other copy only
    // claims one that is empty or points at an exe that no longer exists.
    if (Platform.isWindows && _launchAtLogin) {
      final target = await launchAtStartupTarget();
      final self = Platform.resolvedExecutable;
      bool same(String a, String b) => a.toLowerCase() == b.toLowerCase();
      // Also rewrite when the entry predates the --autostart flag, so existing
      // installs migrate to tray-on-login. The inner ownership gate below still
      // decides whether THIS copy is allowed to claim the slot.
      final hasFlag = await launchAtStartupHasAutostartFlag();
      if (target == null || !same(target, self) || !hasFlag) {
        final local = Platform.environment['LOCALAPPDATA'];
        // relic.iss DefaultDirName={localappdata}\Relic — the one true install.
        final selfIsInstall = local != null &&
            same(self, '$local\\Relic\\relic_app.exe');
        final dangling = target != null && !File(target).existsSync();
        if (target == null || selfIsInstall || dangling) {
          await setLaunchAtStartup(true);
        }
      }
    } else if (Platform.isLinux && _launchAtLogin) {
      // Linux has no slot to contend over: the autostart entry is a file we
      // own by name, so there is no "did another copy claim it" question. It
      // can still go stale — the bundle gets moved or replaced, or it predates
      // the --autostart flag — and a stale Exec means login silently stops
      // launching Relic. Rewrite it to point at the copy that is running.
      if (!await launchAtStartupIsCurrent()) await setLaunchAtStartup(true);
    } else if (_launchAtLogin != await isLaunchAtStartupEnabled()) {
      await setLaunchAtStartup(_launchAtLogin);
    }
    _loadUploaded();
    final db = RelicDb.open(_dbFile.path);
    _db = db;
    _migrateLegacyJson(db);
    _migrateLegacyHoldback(db);
    _refreshHeldCount();
    for (final v in db.allVectors()) {
      (_vec[v.uid] ??= []).add(v.vec); // rows arrive ordered by (uid, chunk)
    }
    _refreshWindow();
    _sift = SiftSidecar.locate();
    // Prefs are read before the sidecar is located, so seed it here.
    _sift?.labelCapable = _describeItems;
    _sift?.speed = _analysisSpeed.flag;
    unawaited(_pruneRetiredModels());
    if (_mlEnrich && _sift != null) {
      _startEnrichWorker();
      unawaited(
        _sift!.warmUp(),
      ); // load the embed model before the first search
      unawaited(_loadTagVectors()); // tag-expansion table (cached on disk)
    }
    // ML-independent: extract text from any backlog documents so they're
    // searchable by content even with smart-tags off. New captures self-extract.
    Future.delayed(const Duration(seconds: 3), _backlogExtractPass);
    // Weekly local backup: check shortly after start, then every 12 h since
    // the tray app can run for weeks without a relaunch.
    Future.delayed(const Duration(seconds: 20), _maybeAutoBackup);
    _backupTimer = Timer.periodic(
      const Duration(hours: 12),
      (_) => _maybeAutoBackup(),
    );
    // Clip reminders: if the toggle survived a restart, start the sweep. The
    // first tick is delayed so the shell has installed onRemindersDue and any
    // reminders that came due while the app was closed fire once (catch-up).
    if (_reminders) {
      Future.delayed(const Duration(seconds: 5), () {
        if (!_disposed && _reminders) _startReminderSweep();
      });
    }
  }

  /// One-time import of the old flat JSON file into SQLite, then retire it.
  void _migrateLegacyJson(RelicDb db) {
    try {
      final f = _legacyJson;
      if (!f.existsSync() || !db.isEmpty) return;
      final list = jsonDecode(f.readAsStringSync()) as List;
      for (final j in list) {
        final r = _fromJson(j as Map<String, dynamic>);
        final hasBytes =
            r.blobKey != null && _blobPathIfExists(r.blobKey) != null;
        db.upsert(r, haveBlob: hasBytes);
      }
      f.renameSync('${f.path}.imported');
    } catch (_) {
      /* leave the JSON in place if anything goes wrong */
    }
  }

  // --- windowed query API ---

  @override
  List<Relic> get all => _db?.allRows() ?? const [];
  @override
  List<Relic> get visible => List.unmodifiable(_window);
  @override
  int get matchCount => _matchCount;
  @override
  bool get hasMore => _window.length < _matchCount;

  @override
  Future<void> setQuery(
    String search,
    Scope scope, {
    SortMode sort = SortMode.relevance,
    int? createdAfter,
    int? createdBefore,
  }) async {
    _query = search;
    _scope = scope;
    _sort = sort;
    _createdAfter = createdAfter;
    _createdBefore = createdBefore;
    _windowSize = kRelicPage;
    _hybridUids = null; // show instant lexical results first
    final gen = ++_queryGen;
    _refreshWindow();
    notifyListeners();

    // Hybrid refine: for real searches (not browse, not tag:-filtered), fuse
    // lexical + trigram (+ semantic when sift is available) via RRF. Async —
    // the lexical results above show immediately; this refines them when the
    // fused ranking lands. Runs even without the ML sidecar: the trigram leg
    // (substring/typo recall) is pure SQLite and needs no models. A forced
    // by-date sort skips ranking entirely, and ANY tag: clause (not just a
    // leading one) skips it — the hybrid legs don't parse tag: filters, so
    // refining would silently drop the filter the lexical view applied.
    final s = search.trim();
    // <3 chars: lexical already covers it; fuzzing adds noise + a round-trip.
    // Broad queries (more lexical matches than the candidate pool) also skip
    // the refine: replacing honest full paging with a pool-truncated fused
    // list would make matches past the pool unreachable and shrink the count.
    // Negated queries ("invoice -stripe") skip it too — the trigram/semantic
    // legs don't understand NOT and would resurrect the excluded items.
    if (sort != SortMode.relevance ||
        s.length < 3 ||
        RegExp(r'tag:\S+|(^|\s)(kind|is|has):\S+')
            .hasMatch(s.toLowerCase()) ||
        RegExp(r'(^|\s)-\S').hasMatch(s) ||
        _matchCount > _pool) {
      return;
    }
    final ranked = await _hybridRanked(s);
    if (gen != _queryGen || ranked == null) return; // superseded or no-op
    _hybridUids = ranked;
    _refreshWindow();
    notifyListeners();
  }

  @override
  Future<void> loadMore() async {
    if (!hasMore) return;
    _windowSize += kRelicPage;
    _refreshWindow();
    notifyListeners();
  }

  /// Re-run the active query into the window — from the fused hybrid ranking
  /// when one is active, else straight from SQLite (lexical / browse).
  void _refreshWindow() {
    final db = _db;
    if (db == null) return;
    if (_hybridUids != null) {
      final page = _hybridUids!.take(_windowSize).toList();
      var rows = db.byUids(page);
      if (rows.length < page.length) {
        // Some ranked uids were deleted after the ranking was computed — prune
        // them so the count stays honest, then re-take the page so the freed
        // slots fill back up in this same pass.
        final alive = rows.map((r) => r.uid).toSet();
        final dead = page.where((u) => !alive.contains(u)).toSet();
        _hybridUids!.removeWhere(dead.contains);
        rows = db.byUids(_hybridUids!.take(_windowSize).toList());
      }
      _window
        ..clear()
        ..addAll(rows);
      _matchCount = _hybridUids!.length;
    } else {
      _window
        ..clear()
        ..addAll(
          db.queryPage(
            _query,
            _scope,
            _windowSize,
            0,
            oldestFirst: _sort == SortMode.oldest,
            // Relevance sort → rank by bm25 so an exact/concise match leads,
            // instead of showing the newest match first.
            byRelevance: _sort == SortMode.relevance,
            createdAfter: _createdAfter,
            createdBefore: _createdBefore,
          ),
        );
      _matchCount = db.countMatching(
        _query,
        _scope,
        createdAfter: _createdAfter,
        createdBefore: _createdBefore,
      );
    }
  }

  // Query-side tag-expansion gate. Fire a tag only when the query is clearly
  // near it — an absolute cosine floor plus a spread from the TOP tag, so two
  // genuinely co-relevant sibling tags ("phone" + "number") can both fire
  // instead of vetoing each other.
  static const double _tagFloor = 0.40; // min cosine to fire a tag
  static const double _tagSpread = 0.06; // max distance below the best tag
  static const int _tagMaxFire = 2; // at most this many tags per query
  static const int _tagCap = 50; // uids per fired tag (recency-ordered)
  static const double _tagWeight = 0.4; // RRF influence of the tag leg
  static const double _ftsWeight = 2.0; // RRF influence of the lexical leg
  static const double _recencyWeight = 0.5; // RRF influence of the recency leg
  // Min cosine for a document to count as a semantic candidate at all —
  // without a floor, top-K returns the "150 least-distant relics" for ANY
  // query, inflating the match count with a garbage tail. Calibrated against
  // the live Gemma embed model (2026-07): relevant query→doc cosines measured
  // 0.40–0.74, irrelevant/garbage ≤ 0.37 — 0.38 separated them cleanly.
  // Recalibrate if the embed model changes (BGE runs a higher, narrower band).
  static const double _semFloor = 0.38;
  static const int _pool = 150; // fts/semantic candidate pool
  static const int _triPool = 50; // trigram pool (recall leg — keep it tight)

  /// Fuse FTS (lexical), trigram (substring/typo), vector (semantic),
  /// tag-expansion (semantic→tag), and tag-intent (query term literally names
  /// a tag) candidate lists with weighted Reciprocal Rank
  /// Fusion — robust to typos, partial words, paraphrase, and conceptual tag
  /// queries. The lexical leg carries double weight, so an exact/concise match
  /// stays on top, but a strong semantic/typo hit can interleave above the long
  /// tail of weak keyword matches — and a uid found by SEVERAL legs sums their
  /// contributions (agreement boost). Works without sift: the semantic legs are
  /// simply empty. Returns the ranked uid list, or null if empty.
  Future<List<String>?> _hybridRanked(String s) async {
    final db = _db;
    if (db == null) return null;
    // Snapshot the query context: a concurrent setQuery mutates these fields
    // mid-await, and the legs must all use ONE consistent view (the gen guard
    // discards the result anyway, but the function shouldn't mix scopes).
    final sift = _sift;
    final scope = _scope;
    final createdAfter = _createdAfter;
    final createdBefore = _createdBefore;
    final fts = db.ftsCandidates(s, scope, _pool,
        createdAfter: createdAfter, createdBefore: createdBefore);
    // When the literal query already hits, the fuzzy trigram tail is mostly
    // noise (typo recall matters when the exact words found nothing) — keep
    // only a short tail so the match count doesn't inflate.
    final tri = db.trigramCandidates(s, scope, fts.isEmpty ? _triPool : 15,
        createdAfter: createdAfter, createdBefore: createdBefore);
    // Items that ARE the type a query term names ("link" → the url tag),
    // filtered by the residual terms — see tagIntentCandidates. Lexical, so
    // it works without sift.
    final tagIntent = db.tagIntentCandidates(s, scope, _tagCap,
        createdAfter: createdAfter, createdBefore: createdBefore);
    // The query embedding powers BOTH the semantic leg and tag expansion, so
    // it needs only sift (tag expansion works before any doc vector exists).
    final qv = sift == null ? null : await sift.embedQuery(s);
    // FTS/trigram are scope- and date-filtered in SQL; the semantic legs are
    // not — restrict them here (vault BEFORE top-K, so a strong vault match
    // isn't truncated away by unpromoted neighbors). The stored-vector leg
    // honors the embeddings toggle so behavior matches the settings status.
    var sem = (qv == null || !_aiEmbeddings)
        ? const <String>[]
        : _cosineTopK(qv, _pool,
            allow: scope == Scope.vault ? db.promotedUids() : null);
    var tagExp = qv == null
        ? const <String>[]
        : _tagExpansion(qv, db, vaultOnly: scope == Scope.vault);
    if (createdAfter != null || createdBefore != null) {
      sem = db.filterByDate(sem, createdAfter, createdBefore);
      tagExp = db.filterByDate(tagExp, createdAfter, createdBefore);
    }
    // Mild recency prior: clipboard queries skew "the recent one" — rank the
    // candidate union newest-first as a low-weight fifth leg, so two
    // similarly-relevant items order recent-first without letting recency
    // outvote actual relevance.
    final union = <String>{...fts, ...tri, ...sem, ...tagExp, ...tagIntent}
        .toList();
    final recency = db.byRecency(union);
    // Kept items win near-ties against clipboard noise via the score factor
    // (All scope only — in Vault scope everything is kept); the personal
    // factors (usage frecency, query-pick memory, summon-context prior)
    // climb in both scopes — a cornerstone is a cornerstone in the vault too.
    final ranked = RelicDb.rrfFuse(
      [fts, tri, sem, tagExp, tagIntent, recency],
      weights: const [
        _ftsWeight,
        1.0,
        1.0,
        _tagWeight,
        RelicDb.kTagIntentWeight,
        _recencyWeight,
      ],
      boostUids: scope == Scope.vault ? null : db.promotedUids(),
      boostFactor: RelicDb.kKeptBoostFactor,
      factors: _personalRank
          ? db.rankFactors(union, query: s, app: _summonApp, now: _now)
          : null,
    );
    // Snippet trigger-boost: a snippet whose trigger label matches what the
    // user typed is pinned to the very top (no keyboard hook — pure ranking).
    // Injected even if no other leg surfaced it, so typing the trigger word is
    // an "overwhelming advantage." Skipped under a date filter (a pin would
    // contradict the active range).
    if (createdAfter == null && createdBefore == null) {
      final pins = _snippetPins(db, s, scope);
      if (pins.isNotEmpty) {
        final seen = pins.toSet();
        return [...pins, for (final u in ranked) if (!seen.contains(u)) u];
      }
    }
    return ranked.isEmpty ? null : ranked;
  }

  /// Uids of snippets whose trigger label matches the query [s]: an exact
  /// (normalized) match, or the trigger begins with the query. Exact beats
  /// prefix; shorter triggers rank ahead among ties. A leading marker like ';'
  /// or '/' on either side is ignored, so ';welcome' fires on 'wel'.
  List<String> _snippetPins(RelicDb db, String s, Scope scope) {
    final q = _triggerNorm(s);
    if (q.isEmpty) return const [];
    final hits = <(String uid, bool exact, int len)>[];
    for (final (uid, trigger) in
        db.snippetTriggers(vaultOnly: scope == Scope.vault)) {
      final t = _triggerNorm(trigger);
      if (t.isEmpty) continue;
      if (t == q) {
        hits.add((uid, true, t.length));
      } else if (t.startsWith(q)) {
        hits.add((uid, false, t.length));
      }
    }
    hits.sort((a, b) {
      if (a.$2 != b.$2) return a.$2 ? -1 : 1; // exact first
      return a.$3.compareTo(b.$3); // then shorter trigger
    });
    return [for (final h in hits) h.$1];
  }

  /// Trim, lowercase, and drop a leading run of non-alphanumerics (the ';' /
  /// '/' snippet marker) so the trigger and query compare on the word itself.
  static String _triggerNorm(String s) =>
      s.trim().toLowerCase().replaceFirst(RegExp(r'^[^a-z0-9]+'), '');

  /// Candidate uids from tags the query *semantically* matches (not just
  /// lexically). Cosine the query against the tag-gloss table; every tag that
  /// clears the absolute floor AND sits within [_tagSpread] of the best tag
  /// fires (capped at [_tagMaxFire]); their recent items are collected
  /// (scope-filtered, capped). Empty unless a tag clearly fires — so normal
  /// content queries are unchanged.
  List<String> _tagExpansion(List<double> qv, RelicDb db,
      {required bool vaultOnly}) {
    if (_tagVec.isEmpty || _tagDim != qv.length) {
      // A nonzero-but-mismatched dim means the embed model changed under a
      // stale cache — rebuild it once (the next search will use it).
      if (_tagDim != 0 && _tagDim != qv.length && !_tagRefreshing) {
        _tagRefreshing = true;
        unawaited(_refreshTagVectors().whenComplete(() => _tagRefreshing = false));
      }
      return const []; // not ready / dim mismatch
    }
    final scored = <MapEntry<String, double>>[];
    for (final e in _tagVec.entries) {
      var dot = 0.0;
      final v = e.value;
      for (var i = 0; i < v.length; i++) {
        dot += qv[i] * v[i];
      }
      scored.add(MapEntry(e.key, dot));
    }
    scored.sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    if (scored.isEmpty || scored.first.value < _tagFloor) return const [];
    final top = scored.first.value;
    final out = <String>[];
    final seen = <String>{};
    for (var i = 0; i < scored.length && i < _tagMaxFire; i++) {
      final c = scored[i].value;
      if (c < _tagFloor || (top - c) > _tagSpread) break; // sorted desc
      for (final uid in db.uidsWithTag(scored[i].key,
          vaultOnly: vaultOnly, limit: _tagCap)) {
        if (seen.add(uid)) out.add(uid);
      }
    }
    return out;
  }

  // --- open-vocabulary tag bounding ----------------------------------------

  /// A tag must be emitted this many times before it becomes a visible chip.
  /// Mirrors `tag_vocab::DEFAULT_MIN_COUNT`; measured at 119 facets / 94% item
  /// coverage on a real vault, down from 327 tags of which 65% appeared once.
  static const int kTagMinCount = 2;

  /// Reconcile once every this many bounded batches. Online absorption assigns
  /// representatives in arrival order, which drifts from the frequency-ordered
  /// grouping; reconcile re-derives it. Not every batch, because it rewrites
  /// every affected relic and reindexes FTS.
  static const int kReconcileEvery = 200;

  int _boundBatches = 0;
  Set<String> _provisionalTags = const {};

  @override
  Set<String> get provisionalTags => _provisionalTags;

  /// Snap one item's open-vocabulary tags onto the corpus vocabulary and record
  /// the emissions. Returns the canonical forms to store on the relic.
  ///
  /// Returns the tags unchanged if the sidecar is unavailable: an unbounded tag
  /// is worse than a bounded one but much better than a dropped one, and the
  /// next reconcile folds it in anyway.
  Future<List<String>> _boundLabelTags(RelicDb db, List<String> emitted) async {
    if (emitted.isEmpty) return const [];
    final sift = _sift;
    if (sift == null) return emitted;
    final res = await sift.boundTags(
      vocabulary: [for (final r in db.tagVocabReps()) r.toJson()],
      emitted: emitted,
    );
    if (res == null) return emitted;
    db.recordTagEmissions(emitted, res.mapping, res.vectors);
    _provisionalTags = db.provisionalTags(kTagMinCount);

    if (++_boundBatches % kReconcileEvery == 0) {
      unawaited(_reconcileTagVocab(db));
    }
    final out = <String>[];
    for (final t in emitted) {
      final canonical = res.mapping[t] ?? t;
      if (!out.contains(canonical)) out.add(canonical);
    }
    return out;
  }

  /// Re-derive the whole tag grouping in frequency order and rewrite the relics
  /// that used a representative which moved.
  ///
  /// Passes **every** row, aliases included — given representatives only this
  /// is a no-op by construction, since a representative exists precisely
  /// because nothing was near it (relic-sift/src/tag_vocab.rs).
  Future<void> _reconcileTagVocab(RelicDb db) async {
    final sift = _sift;
    if (sift == null) return;
    final rows = db.tagVocabAll();
    if (rows.isEmpty) return;
    final res = await sift.boundTags(
      vocabulary: [for (final r in rows) r.toJson()],
      reconcile: true,
    );
    if (res == null) return;
    final touched = db.applyTagReconcile(res.mapping);
    _provisionalTags = db.provisionalTags(kTagMinCount);
    if (touched > 0) notifyListeners();
  }

  /// Delete model files a previous version of Relic downloaded that this one
  /// can never load. Upgrading otherwise leaves ~246 MB of Florence-2 sitting in
  /// the cache forever, since nothing references those files any more.
  ///
  /// Runs once per [_kPruneGen], independent of whether ML is switched on — the
  /// files are dead either way, and someone who turned ML off is exactly the
  /// person who wants the disk back. Only the safe set is swept; the wider
  /// `--deep` pass drops working fallbacks, so that stays a manual choice.
  Future<void> _pruneRetiredModels() async {
    if (_prunedGen >= _kPruneGen) return;
    final sift = _sift;
    if (sift == null) return; // no sidecar yet — try again next launch
    final freed = await sift.pruneModels();
    // Record the generation even when nothing was freed: a clean install has
    // nothing to sweep and should not re-check on every launch forever.
    _prunedGen = _kPruneGen;
    _savePrefs();
    if (freed > 0) {
      debugPrint('pruned ${(freed / 1e6).toStringAsFixed(1)} MB of retired models');
    }
  }

  /// Load the tag-expansion table from the on-disk cache, refreshing it from the
  /// sift binary when the cache is missing or unreadable.
  Future<void> _loadTagVectors() async {
    final f = File(_p('tag_vectors.json'));
    try {
      if (f.existsSync()) {
        _parseTagVectors(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
        if (_tagVec.isNotEmpty) return;
      }
    } catch (_) {/* fall through to refresh */}
    await _refreshTagVectors();
  }

  /// Recompute the tag-expansion table via `sift tags vectors` and cache it.
  Future<void> _refreshTagVectors() async {
    final sift = _sift;
    if (sift == null) return;
    final m = await sift.tagVectors();
    if (m == null) return;
    try {
      File(_p('tag_vectors.json')).writeAsStringSync(jsonEncode(m));
    } catch (_) {/* cache is best-effort */}
    _parseTagVectors(m);
  }

  void _parseTagVectors(Map<String, dynamic> m) {
    _tagVec.clear();
    _tagDim = (m['dim'] as num?)?.toInt() ?? 0;
    for (final t in (m['tags'] as List? ?? const [])) {
      final tag = t['tag'] as String?;
      final vec = (t['vec'] as List?)?.map((x) => (x as num).toDouble()).toList();
      if (tag != null && vec != null) _tagVec[tag] = Float32List.fromList(vec);
    }
  }

  /// Top-k uids by cosine similarity to [q], best-chunk-wins for multi-chunk
  /// documents. Stored vectors and the query are both L2-normalized, so cosine
  /// == dot product. Scores below [_semFloor] are dropped entirely, and
  /// [allow] (when given) restricts candidates before the top-K cut. Ties
  /// break on uid so the ranking is stable across refreshes.
  List<String> _cosineTopK(List<double> q, int k, {Set<String>? allow}) {
    final scored = <MapEntry<String, double>>[];
    for (final e in _vec.entries) {
      if (allow != null && !allow.contains(e.key)) continue;
      var best = -1.0;
      for (final v in e.value) {
        if (v.length != q.length) continue;
        var dot = 0.0;
        for (var i = 0; i < v.length; i++) {
          dot += q[i] * v[i];
        }
        if (dot > best) best = dot;
      }
      if (best >= _semFloor) scored.add(MapEntry(e.key, best));
    }
    scored.sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    return [for (final e in scored.take(k)) e.key];
  }

  @override
  SyncState get sync {
    if (_mk == null) return const SyncState(SyncKind.synced); // local-only
    final pending = _db?.pendingCount() ?? 0;
    if (pending > 0) return SyncState(SyncKind.pending, pending: pending);
    final rejected = _db?.rejectionCount() ?? 0;
    if (rejected > 0) return SyncState(SyncKind.quotaFull, pending: rejected);
    return _online
        ? const SyncState(SyncKind.synced)
        : const SyncState(SyncKind.offline);
  }

  @override
  AccountInfo? get account {
    if (_remoteAccount != null) return _remoteAccount;
    final db = _db;
    if (db == null) return null;
    final (bytes, vault) = db.localAggregate();
    return AccountInfo(
      tier: 'Local',
      usedBytes: bytes,
      quotaBytes: 0,
      vaultCount: vault,
    );
  }

  @override
  bool isNotSynced(Relic r) => _db?.hasPendingOrRejected(r.uid) ?? false;

  @override
  RelicSync relicSync(Relic r) {
    if (_mk == null) return RelicSync.synced; // local-only, nothing to push
    switch (_db?.syncStateFor(r.uid) ?? 0) {
      case 1:
        return RelicSync.syncing;
      case 2:
        return RelicSync.blocked;
      default:
        return RelicSync.synced;
    }
  }

  void _saveUploaded() {
    try {
      _uploadedFile.writeAsStringSync(jsonEncode(_uploaded.toList()));
    } catch (_) {}
  }

  void _loadUploaded() {
    try {
      if (_uploadedFile.existsSync()) {
        _uploaded.addAll(
          (jsonDecode(_uploadedFile.readAsStringSync()) as List).cast<String>(),
        );
      }
    } catch (_) {}
  }

  // Every authed sync request carries the device id so a remote "remove device"
  // (docs/cloudflare/13 §7) actually cuts this desktop off on its next call.
  // The app version rides along so the Devices screen can flag stale installs
  // (the worker touches devices.app_version at most hourly).
  Map<String, String> get _h => {
        'Authorization': 'Bearer $_syncToken',
        if (_deviceId case final d? when d.isNotEmpty) 'X-Relic-Device': d,
        if (_appVersion case final v? when v.isNotEmpty)
          'X-Relic-App-Version': v,
      };
  String _u(String p) => '${_syncUrl!.replaceAll(RegExp(r"/+\$"), "")}$p';

  /// Resolve this install's stable device id once (persisted by [DeviceId]).
  /// Called before sync begins so [_h] can attach `X-Relic-Device`.
  Future<void> _ensureDeviceId() async {
    if (_deviceId != null) return;
    try {
      _deviceId = await DeviceId.get();
    } catch (_) {/* header is best-effort; sync still works without it */}
  }

  // --- demo / first-run ---

  /// True when there are no relics yet (used to gate the first-run welcome).
  bool get isEmpty => _db?.allRows().isEmpty ?? true;

  /// uids of demo samples, so we can drop them if the user later signs in (they
  /// must never sync into a real account). In-memory: covers the demo -> connect
  /// flow within a session.
  final List<String> _demoUids = [];

  /// True while the local vault is the "try without an account" demo (seeded
  /// samples, not yet connected). Drives the popup's sign-in banner.
  bool get isDemo => _demoUids.isNotEmpty && !_supabaseMode;

  /// "Try without an account": seed a few sample relics so the demo isn't empty.
  /// No-op once the vault has any content. Purely local — nothing is synced.
  void seedDemoIfEmpty() {
    if (!isEmpty) return;
    _demoUids.clear();
    // Captured in order; the last one gets the newest timestamp and sits on top,
    // so make it the sign-in nudge (the persistent CTA for demo mode).
    const samples = [
      'Ship list: OAuth sign-in, polished onboarding, demo mode. ✓',
      'AKIAIOSFODNN7EXAMPLE  ·  secrets like API keys are detected and masked.',
      'https://relic.space, your vault, on every device you own.',
      'Try it: copy anything right now and it shows up here instantly.',
      "You're exploring Relic locally. Sign in to save & sync everywhere.",
    ];
    for (final s in samples) {
      captureText(s);
      final uid = _db?.uidByContent(s.trimRight());
      if (uid != null) _demoUids.add(uid);
    }
    _refreshWindow();
    notifyListeners();
  }

  /// Drop the demo samples (raw local delete, no tombstone/push) so "Try the
  /// demo" content never follows the user into a real account. Called on connect.
  void _purgeDemoSeed() {
    if (_demoUids.isEmpty) return;
    for (final uid in _demoUids) {
      _db?.delete(uid);
    }
    _demoUids.clear();
    _refreshWindow();
  }

  // --- capture ---

  /// Capture clipboard text. Re-copying existing content bumps it rather than
  /// duplicating (also makes picking idempotent vs the watcher). [sourceApp]
  /// is the foreground app the copy came from (already tag-normalized) —
  /// stamped as a machine tag so "the thing I copied from chrome" resolves.
  bool captureText(
    String text, {
    Source source = Source.clipboard,
    String? sourceApp,
    String? html,
    Uint8List? rtf,
  }) {
    final t = text.trimRight();
    if (t.trim().isEmpty) return false;
    final rich = RichBody.capture(plain: t, html: html, rtf: rtf);
    // The echo guard is keyed on the text AND its formatting: re-copying the
    // same sentence from a styled source after a plain one is a real change
    // worth recording, not an echo of our own clipboard write.
    if (t == _lastCaptured && rich?.h == _lastCapturedRichFp) return false;
    _lastCaptured = t;
    _lastCapturedRichFp = rich?.h;
    final db = _db;
    if (db == null) return false;
    if (utf8.encode(t).length > maxItemBytes) {
      onCaptureTooLarge?.call(maxItemMb);
      return false; // over the size cap
    }

    final existing = db.uidByContent(t);
    if (existing != null) {
      // Same text, possibly better formatting. Update in place rather than
      // keying the dedupe on `rich`, which would make every styled-then-plain
      // re-copy of the same sentence a duplicate row. setRich first: touch
      // queues the push and the push re-reads the row.
      if (rich != null && rich.h != db.richOf(existing)?.h) {
        final row = db.getByUid(existing);
        if (row != null && !row.isSecret) db.setRich(existing, rich);
      }
      db.touch(existing, _now, queuePush: syncEnabled);
      if (_personalRank) {
        db.recordUse(existing, _now); // a re-copy is a use (frecency)
      }
      final touched = db.getByUid(existing);
      _refreshWindow();
      notifyListeners();
      if (touched != null) _kickSync();
      return false;
    }
    final tags = _tagsFor(t);
    if (sourceApp != null && !tags.contains(sourceApp)) tags.add(sourceApp);
    // A secret never carries formatting. The masked plain text would be
    // scrubbed while the HTML flavor shipped the same value in the clear.
    // Enforced again on the write path and again on export, because a relic
    // can be marked secret AFTER capture and masking can be toggled off.
    final keep = tags.contains('secret') ? null : rich;
    final r = Relic(
      uid: _uuid.v4(),
      createdAt: _now,
      updatedAt: _now,
      kind: Kind.string,
      source: source,
      promoted: _promoteOnCapture(
        _autoVault || source != Source.clipboard,
        utf8.encode(t).length,
      ),
      byteSize: utf8.encode(t).length,
      device: _deviceLabel,
      tags: tags,
      content: t,
      preview: _preview(t),
      rich: keep,
    );
    db.upsert(r, queuePush: syncEnabled);
    _enforceRetention();
    _refreshWindow();
    notifyListeners();
    _kickSync();
    return true;
  }

  /// Create a relic by hand (the "+" composer): a text body, optional title,
  /// user tags, and any number of file attachments packed into ONE bundle blob.
  /// Returns false if there's nothing to save or the bundle exceeds the per-item
  /// cap. The displayed type auto-derives from the result (text length, or the
  /// attachment(s)).
  @override
  bool createNote({
    String? title,
    String? body,
    List<String> userTags = const [],
    List<(String name, String? mime, Uint8List bytes)> files = const [],
    bool promote = false,
  }) {
    final db = _db;
    if (db == null) return false;
    final text = (body ?? '').trimRight();
    if (text.trim().isEmpty && files.isEmpty) return false; // nothing to save

    String? blobKey;
    var byteSize = utf8.encode(text).length;
    var manifest = const <Attachment>[];
    if (files.isNotEmpty) {
      // Each attachment and the whole bundle are bound by the per-item cap.
      final bundle = packBundle([for (final f in files) f.$3]);
      if (bundle.length > maxItemBytes) return false;
      blobKey = _uuid.v4();
      try {
        File(_blobFilePath(blobKey)).writeAsBytesSync(bundle);
      } catch (_) {
        return false;
      }
      byteSize = bundle.length;
      manifest = [
        for (final f in files)
          Attachment(
              id: _uuid.v4(), name: f.$1, mime: f.$2, size: f.$3.length),
      ];
    }

    final t = title?.trim();
    final r = Relic(
      uid: _uuid.v4(),
      createdAt: _now,
      updatedAt: _now,
      kind: Kind.string,
      source: Source.upload,
      promoted: _promoteOnCapture(promote || _autoVault, byteSize),
      byteSize: byteSize,
      device: _deviceLabel,
      blobKey: blobKey,
      title: (t != null && t.isNotEmpty) ? t : null,
      content: text.trim().isEmpty ? null : text,
      preview: text.trim().isNotEmpty
          ? _preview(text)
          : (manifest.isNotEmpty ? manifest.first.name : null),
      tags: text.trim().isEmpty ? const [] : _tagsFor(text),
      userTags: userTags,
      attachments: manifest,
    );
    db.upsert(r, haveBlob: blobKey != null, queuePush: syncEnabled);
    if (blobKey != null) {
      _unpackBundle(r); // pre-extract attachment cache files
      // Index what the attached documents SAY (async; reindexes on finish).
      unawaited(_extractAttachmentText(r));
    }
    _enforceRetention();
    _refreshWindow();
    notifyListeners();
    _kickSync();
    return true;
  }

  @override
  bool get canEditAttachments => true;

  /// Rebuild [r]'s attachment bundle under a FRESH blob key: reusing the old
  /// key would (a) skip the upload entirely (`_uploaded` remembers it) and
  /// (b) corrupt peers that slice a cached old bundle with the new manifest.
  /// The abandoned key orphans server-side and the worker sweep deletes it.
  @override
  Future<AttachmentEditResult> updateAttachments(
    Relic r, {
    List<(String name, String? mime, Uint8List bytes)> added = const [],
    Set<String> removedIds = const {},
  }) async {
    final db = _db;
    if (db == null) return AttachmentEditResult.unsupported;
    if (added.isEmpty && removedIds.isEmpty) return AttachmentEditResult.ok;
    // Re-read the current row (enrichment may have touched it since the
    // dialog opened), same rationale as updateMeta.
    final cur = db.getByUid(r.uid) ?? r;
    // Only string relics carry bundles; a photo/file blob IS the content.
    if (cur.kind != Kind.string) return AttachmentEditResult.unsupported;

    final kept = [
      for (final a in cur.attachments)
        if (!removedIds.contains(a.id)) a,
    ];

    // Slice the kept bytes out of the current bundle (plaintext on disk; the
    // only hard failure is a synced-away bundle we can't fetch right now).
    final keptBytes = <Uint8List>[];
    if (kept.isNotEmpty) {
      if (!await ensureBlob(cur)) {
        return AttachmentEditResult.bundleUnavailable;
      }
      final path = _blobPathIfExists(cur.blobKey);
      if (path == null) return AttachmentEditResult.bundleUnavailable;
      final bundle = await File(path).readAsBytes();
      for (final a in kept) {
        final bytes = sliceAttachment(bundle, cur.attachments, a.id);
        if (bytes == null) return AttachmentEditResult.bundleUnavailable;
        keptBytes.add(bytes);
      }
    }

    final manifest = [
      ...kept,
      for (final f in added)
        Attachment(id: _uuid.v4(), name: f.$1, mime: f.$2, size: f.$3.length),
    ];

    String? newKey;
    int byteSize;
    if (manifest.isEmpty) {
      // Last attachment removed: degrade to a plain text note. The UI blocks
      // the text-less case (that's a delete, not an edit).
      byteSize = utf8.encode(cur.content ?? '').length;
    } else {
      final bundle = packBundle([...keptBytes, for (final f in added) f.$3]);
      if (bundle.length > maxItemBytes) return AttachmentEditResult.tooLarge;
      newKey = _uuid.v4();
      try {
        File(_blobFilePath(newKey)).writeAsBytesSync(bundle);
      } catch (_) {
        return AttachmentEditResult.bundleUnavailable;
      }
      byteSize = bundle.length;
    }

    // Preview follows the first attachment only when there's no text body
    // (mirrors createNote's seeding).
    final hasText = (cur.content ?? '').trim().isNotEmpty;
    final u = cur.copyWith(
      attachments: manifest,
      blobKey: newKey,
      clearBlobKey: newKey == null,
      byteSize: byteSize,
      preview: hasText
          ? cur.preview
          : (manifest.isNotEmpty ? manifest.first.name : null),
      updatedAt: _now,
    );
    db.upsert(u, queuePush: syncEnabled);
    // upsert's ON CONFLICT deliberately leaves have_blob alone — set it
    // explicitly for the new bundle (or clear it when the bundle is gone).
    if (newKey != null) {
      db.markBlobLocal(u.uid);
    } else {
      db.markBlobMissing(u.uid);
    }
    // Old bundle + its unpacked per-attachment cache files are dead weight
    // now; the worker's orphan sweep handles the server copy.
    if (cur.blobKey != null && cur.blobKey != newKey) {
      _deleteBlobFiles(cur.blobKey);
      if (_uploaded.remove(cur.blobKey)) _saveUploaded();
    }
    // Stale extracted text must not stay indexed; re-extract from the new
    // bundle (the backlog pass only retries NULL rows).
    db.clearAttachmentText(u.uid);
    if (newKey != null) {
      _unpackBundle(u);
      unawaited(_extractAttachmentText(u));
    }
    _refreshWindow();
    notifyListeners();
    _kickSync();
    return AttachmentEditResult.ok;
  }

  String _blobFilePath(String key) =>
      '${_blobsDir.path}${Platform.pathSeparator}$key';

  /// Kind-agnostic path to the decrypted blob, unlike [localImagePath], which
  /// only answers for things the engine can render inline.
  @override
  String? cachedBlobPath(Relic r) => _blobPathIfExists(r.blobKey);

  /// Local path to a relic's blob if present (with back-compat for the old
  /// `<key>.png` naming). Null if not downloaded yet.
  String? _blobPathIfExists(String? key) {
    if (key == null) return null;
    final p = _blobFilePath(key);
    if (File(p).existsSync()) return p;
    final legacy = '$p.png';
    return File(legacy).existsSync() ? legacy : null;
  }

  /// Capture a clipboard image (e.g. a screenshot). Saves the PNG to a local
  /// blob and adds a photo relic. Dedupes consecutive identical images.
  /// [sourceApp] is the tag-normalized foreground app the copy came from.
  bool captureImage(Uint8List png, {String? sourceApp}) {
    final h = _hash(png);
    if (h == _lastBlobHash) return false;
    _lastBlobHash = h;
    _lastBlobUid = null; // set again below on a successful insert
    final db = _db;
    if (db == null) return false;
    if (png.length > maxItemBytes) {
      onCaptureTooLarge?.call(maxItemMb);
      return false; // over the size cap
    }
    final dims = _pngDims(png);
    final blobKey = _uuid.v4();
    try {
      File(_blobFilePath(blobKey)).writeAsBytesSync(png);
    } catch (_) {
      return false;
    }
    final r = Relic(
      uid: _uuid.v4(),
      createdAt: _now,
      updatedAt: _now,
      kind: Kind.photo,
      source: Source.clipboard,
      promoted: _promoteOnCapture(_autoVault, png.length),
      byteSize: png.length,
      device: _deviceLabel,
      mime: 'image/png',
      blobKey: blobKey,
      preview: dims == null ? 'Image' : 'Screenshot · ${dims.$1} × ${dims.$2}',
      // Seed concept tags at capture so a photo is findable by "picture"/
      // "image"/"screenshot" (via tag synonyms) before any ML caption runs.
      tags: [
        'photo',
        if (dims != null) 'screenshot',
        ?sourceApp,
      ],
    );
    db.upsert(r, haveBlob: true, queuePush: syncEnabled);
    _lastBlobUid = r.uid;
    _enforceRetention();
    _refreshWindow();
    notifyListeners();
    _kickSync();
    return true;
  }

  /// Capture a copied file's bytes → a file relic with a local blob.
  bool captureFile(String filePath, Uint8List bytes, {String? mime}) {
    final h = _hash(bytes);
    if (h == _lastBlobHash) return false;
    _lastBlobHash = h;
    _lastBlobUid = null; // set again below on a successful insert
    final db = _db;
    if (db == null) return false;
    if (bytes.length > maxItemBytes) {
      onCaptureTooLarge?.call(maxItemMb);
      return false; // over the size cap
    }
    final blobKey = _uuid.v4();
    try {
      File(_blobFilePath(blobKey)).writeAsBytesSync(bytes);
    } catch (_) {
      return false;
    }
    final name = filePath.split(RegExp(r'[\\/]')).last;
    final r = Relic(
      uid: _uuid.v4(),
      createdAt: _now,
      updatedAt: _now,
      kind: Kind.file,
      source: Source.clipboard,
      promoted: _promoteOnCapture(_autoVault, bytes.length),
      byteSize: bytes.length,
      device: _deviceLabel,
      mime: mime,
      filename: name,
      blobKey: blobKey,
      preview: name,
      tags: fileTypeChips(name), // friendly type chips, e.g. ["3D","Blender"]
    );
    db.upsert(r, haveBlob: true, queuePush: syncEnabled);
    _lastBlobUid = r.uid;
    _enforceRetention();
    _refreshWindow();
    notifyListeners();
    _kickSync();
    unawaited(_extractDocText(r)); // make documents searchable by their text
    return true;
  }

  /// Capture the selection/clipboard AND promote it, returning the relic —
  /// the "save & annotate" hotkey's entry point. Dedupes exactly like the
  /// watcher paths (an existing identical relic is touched, not duplicated),
  /// sets the echo guards so the watcher doesn't double-capture the same
  /// event, and reuses [promote]'s tier-cap logic. Returns null when there's
  /// nothing capturable; `promoted` is false when the vault cap refused.
  Future<(Relic, bool)?> captureForAnnotate({
    String? text,
    Uint8List? png,
    String? sourceApp,
    String? html,
    Uint8List? rtf,
  }) async {
    final db = _db;
    final uid = _resolveCapturedUid(
        text: text, png: png, sourceApp: sourceApp, html: html, rtf: rtf);
    if (db == null || uid == null) return null;
    var r = db.getByUid(uid);
    if (r == null) return null;
    if (!r.promoted) {
      await promote(r, true); // tier-cap guarded; no-op on refusal
      r = db.getByUid(uid) ?? r;
    }
    return (r, r.promoted);
  }

  /// Same capture, without the promote: the paste stack queues an item, it does
  /// not put it in the vault. Returns the relic, or null when there was nothing
  /// on the clipboard worth queuing.
  Relic? captureForStack({
    String? text,
    Uint8List? png,
    String? sourceApp,
    String? html,
    Uint8List? rtf,
  }) {
    final db = _db;
    final uid = _resolveCapturedUid(
        text: text, png: png, sourceApp: sourceApp, html: html, rtf: rtf);
    return (db == null || uid == null) ? null : db.getByUid(uid);
  }

  /// Resolve whatever was just read off the clipboard to a relic uid, capturing
  /// it if it is new. Shared by [captureForAnnotate] and [captureForStack] so
  /// the dedupe-by-content, echo guards and image `_lastBlobUid` resolution are
  /// written once.
  String? _resolveCapturedUid({
    String? text,
    Uint8List? png,
    String? sourceApp,
    String? html,
    Uint8List? rtf,
  }) {
    final db = _db;
    if (db == null) return null;
    String? uid;
    if (png != null) {
      final h = _hash(png);
      if (h == _lastBlobHash && _lastBlobUid != null) {
        uid = _lastBlobUid; // the exact image just captured (or echo-marked)
      } else if (captureImage(png, sourceApp: sourceApp)) {
        uid = _lastBlobUid;
      }
      uid ??= db.mostRecentUid(); // last-ditch (e.g. re-copy of an old image)
    } else if (text != null) {
      final t = text.trimRight();
      if (t.trim().isEmpty) return null;
      final rich = RichBody.capture(plain: t, html: html, rtf: rtf);
      final existing = db.uidByContent(t);
      if (existing != null) {
        // Same in-place formatting upgrade captureText does on its dedupe hit.
        if (rich != null && rich.h != db.richOf(existing)?.h) {
          final row = db.getByUid(existing);
          if (row != null && !row.isSecret) db.setRich(existing, rich);
        }
        db.touch(existing, _now, queuePush: syncEnabled);
        if (_personalRank) {
        db.recordUse(existing, _now); // a re-copy is a use (frecency)
      }
        uid = existing;
      } else if (captureText(t,
          source: Source.hotkey, sourceApp: sourceApp, html: html, rtf: rtf)) {
        uid = db.uidByContent(t);
      }
      // Either way the watcher must not re-capture this same clipboard event.
      _lastCaptured = t;
      _lastCapturedRichFp = rich?.h;
    }
    return uid;
  }

  /// Deterministic subtype tags for text, honoring the "detect & mask secrets"
  /// preference (when off, the `secret` tag — and thus list masking — is left
  /// out for new captures).
  List<String> _tagsFor(String t) {
    final tags = _detectTags(t);
    if (!_maskSecrets) tags.remove('secret');
    return tags;
  }

  // --- document text extraction (ML-independent; SPEC §17 "text extraction") ---

  /// sift's coarse file-category tags, suppressed for file relics in favor of
  /// the friendlier extension chips (e.g. "3D"/"Blender" instead of "archive").
  static const _genericFileTags = {'file', 'archive', 'binary'};

  bool _extracting = false;
  static const _plainTextExts = {
    'txt',
    'md',
    'markdown',
    'csv',
    'tsv',
    'log',
    'json',
    'xml',
    'yaml',
    'yml',
    'ini',
    'toml',
  };
  static const _richDocExts = {
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'htm',
    'html',
  };

  /// Document type for a file relic, by extension then MIME. Null = not a
  /// document we extract text from (binaries, archives, media…).
  static String? _docExt(String? filename, String? mime) {
    final name = (filename ?? '').toLowerCase();
    final dot = name.lastIndexOf('.');
    final ext = dot >= 0 ? name.substring(dot + 1) : '';
    if (_plainTextExts.contains(ext) || _richDocExts.contains(ext)) return ext;
    final m = (mime ?? '').toLowerCase();
    if (m.startsWith('text/') || m.contains('json') || m.contains('xml')) {
      return 'txt';
    }
    if (m.contains('pdf')) return 'pdf';
    if (m.contains('wordprocessing') || m.endsWith('msword')) return 'docx';
    if (m.contains('spreadsheet') || m.contains('excel')) return 'xlsx';
    if (m.contains('presentation') || m.contains('powerpoint')) return 'pptx';
    if (m.contains('html')) return 'html';
    return null;
  }

  /// Extract a document file's text into `content` so it's searchable — plain
  /// text decoded directly, richer formats (PDF/Office/HTML) via the sift
  /// sidecar in `--no-ml` mode (pure-Rust, no model download). Idempotent: skips
  /// files that already have text. Runs regardless of the ML-enrich toggle.
  Future<void> _extractDocText(Relic r) async {
    if (r.kind != Kind.file) return;
    final ext = _docExt(r.filename, r.mime);
    if (ext == null) return;
    final path = _blobPathIfExists(r.blobKey);
    if (path == null) return;

    String? text;
    if (_plainTextExts.contains(ext)) {
      try {
        text = utf8.decode(
          await File(path).readAsBytes(),
          allowMalformed: true,
        );
      } catch (_) {}
    } else {
      final sift = _sift;
      if (sift == null) return;
      final res = await sift.classifyPath(path, ml: false, kind: 'file');
      text = res?.extractedText;
    }
    text = text?.trim();
    if (text == null || text.isEmpty) return;
    if (text.length > 100000) text = '${text.substring(0, 100000)}…';

    final db = _db;
    if (db == null) return;
    final cur = db.getByUid(r.uid);
    if (cur == null || (cur.content ?? '').isNotEmpty) {
      return; // gone, or already extracted
    }
    // Content-shape tags (code/json/markdown) describe a clipboard *snippet*'s
    // form; they're noise on a whole document's extracted text (e.g. a setup PDF
    // tagged "code"). Keep only meaningful signals like secrets.
    const docTextTagBlocklist = {'code', 'json', 'markdown'};
    final suppressed = db.suppressedTags(r.uid).toSet();
    // Case-insensitive against existing tags: a .csv file carries the 'CSV'
    // chip, and the detector's lowercase 'csv' must not land beside it.
    final curLower = cur.tags.map((t) => t.toLowerCase()).toSet();
    final tags = <String>[
      ...cur.tags,
      ..._tagsFor(text).where(
        (t) =>
            !curLower.contains(t.toLowerCase()) &&
            !docTextTagBlocklist.contains(t) &&
            !suppressed.contains(t.toLowerCase()),
      ),
    ];
    // Bump updated_at so the extracted text propagates to other devices (the
    // extraction is deterministic, so a peer re-extracting is a no-op).
    final updated = cur.copyWith(
      content: text,
      preview: (cur.preview ?? '').isEmpty ? _preview(text) : cur.preview,
      tags: tags,
      updatedAt: _now,
    );
    db.upsert(updated, queuePush: syncEnabled);
    _refreshWindow();
    notifyListeners();
    _kickSync();
  }

  /// Extract text from a relic's document ATTACHMENTS into the local-only
  /// `attachment_text` column (indexed into the FTS body), so a note is
  /// findable by what its bundled files SAY, not just their filenames. Plain
  /// text decodes directly; PDF/Office/HTML go through the sift sidecar in
  /// --no-ml mode (pure Rust, no models). Leaves the relic unmarked when a
  /// needed input isn't available yet (bundle not local, sift missing) so the
  /// backlog pass retries later.
  Future<void> _extractAttachmentText(Relic r) async {
    final db = _db;
    if (db == null || r.attachments.isEmpty) return;
    final parts = <String>[];
    var blocked = false; // something extractable couldn't be processed yet
    for (final a in r.attachments) {
      final ext = _docExt(a.name, a.mime);
      if (ext == null) continue; // not a document (image etc.)
      final path = attachmentPath(r, a.id); // unpacks the bundle lazily
      if (path == null) {
        blocked = true; // bundle bytes not local yet
        continue;
      }
      String? text;
      if (_plainTextExts.contains(ext)) {
        try {
          text = utf8.decode(
            await File(path).readAsBytes(),
            allowMalformed: true,
          );
        } catch (_) {}
      } else {
        final sift = _sift;
        if (sift == null) {
          blocked = true; // rich doc needs the sidecar → retry when bundled
          continue;
        }
        final res = await sift.classifyPath(path, ml: false, kind: 'file');
        text = res?.extractedText;
      }
      text = text?.trim();
      if (text == null || text.isEmpty) continue;
      if (text.length > 50000) text = '${text.substring(0, 50000)}…';
      parts.add('${a.name}\n$text');
    }
    if (parts.isEmpty && blocked) return; // retry via the backlog pass
    final joined = parts.join('\n\n');
    final cur = db.getByUid(r.uid);
    if (cur == null) return; // deleted while extracting
    // An attachment edit swapped the bundle mid-extraction: this text came
    // from the OLD bytes — drop it and let the backlog pass re-read.
    if (cur.blobKey != r.blobKey) return;
    db.setAttachmentText(r.uid, joined); // '' marks "done, nothing to index"
    _publishAttachmentText(db, r.uid, joined);
    if (joined.isNotEmpty) {
      _refreshWindow();
      notifyListeners();
    }
  }

  /// Share what an attachment said, so the devices that cannot read it still
  /// find the note by it.
  ///
  /// Extraction needs no models, but it does need the attachment bytes, and
  /// blobs download lazily: a desktop that never opened this note has nothing
  /// to extract from, and a phone has no extractor at all. Both of them would
  /// otherwise have a note that is findable only by its filename.
  ///
  /// Amends this device's existing record where there is one, so the caption
  /// and tags the models produced are not replaced by a record carrying only
  /// attachment text. Where there is none, the record is created at the item's
  /// CURRENT enrich level — never at the ML level — because the level is what
  /// tells peers the generative work is finished, and this pass ran no models.
  void _publishAttachmentText(RelicDb db, String uid, String text) {
    if (!syncEnabled || _mk == null) return;
    final existing = db.aiRecord(uid);
    if (existing != null && existing.by != _deviceId) {
      // A peer owns the record. The text stays here, in the column, where this
      // device's own search uses it — but republishing it under our id would
      // mean trading writes with a device that holds more of the answer than
      // we do. It publishes its own attachment text when it reads the bundle.
      return;
    }
    db.putAiRecord(
      existing != null
          ? existing.copyWith(att: text)
          : AiRecord(
              uid: uid,
              at: _now,
              level: db.enrichLevelOf(uid) ?? 0,
              by: _deviceId,
              att: text,
            ),
      needsPush: true,
    );
  }

  /// One-time catch-up: extract text for document files captured before this
  /// existed (or while offline). New captures go through the capture path.
  Future<void> _backlogExtractPass() async {
    if (_extracting || _disposed) return;
    final db = _db;
    if (db == null) return;
    _extracting = true;
    try {
      for (final r in db.filesNeedingText(500)) {
        if (_docExt(r.filename, r.mime) != null) await _extractDocText(r);
      }
      // Attachment contents: notes whose bundled files haven't been read yet
      // (also catches relics synced in from other devices).
      for (final uid in db.attachmentsNeedingText(500)) {
        final r = db.getByUid(uid);
        if (r != null) await _extractAttachmentText(r);
      }
    } finally {
      _extracting = false;
    }
  }

  /// Counts for candidate collection tags in the given scope; only tags that
  /// are actually present (count > 0) are returned. Drives the collections strip.
  @override
  Map<String, int> tagCounts(Iterable<String> tags, {bool vaultOnly = false}) {
    final db = _db;
    if (db == null) return const {};
    final out = <String, int>{};
    for (final t in tags) {
      final n = db.countTag(t, vaultOnly: vaultOnly);
      if (n > 0) out[t] = n;
    }
    return out;
  }

  @override
  ({Map<String, int> user, Map<String, int> machine}) tagFrequencies({
    bool vaultOnly = false,
  }) {
    final f =
        _db?.tagFrequencies(vaultOnly) ??
        (user: <String, int>{}, machine: <String, int>{});
    // Surface created-but-unapplied tags so the user can see/apply them later.
    for (final t in _customTags) {
      f.user.putIfAbsent(t, () => 0);
    }
    return f;
  }

  @override
  Future<void> addCustomTag(String tag) async {
    final t = tag.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
    if (t.isEmpty || !_customTags.add(t)) return;
    _savePrefs();
    notifyListeners();
  }

  /// The `secret` machine tag IS the masking bit (`Relic.isSecret`): deleting
  /// it corpus-wide would unmask every stored key/SSN at once, and renaming an
  /// arbitrary tag TO it would mask random relics. Neither is ever a tag-
  /// management operation — refuse at the repo layer so every UI is covered.
  static bool _guardSecretTagOp(String tag, {required bool userTag}) =>
      !userTag && tag.toLowerCase() == 'secret';

  @override
  Future<int> renameTag(String from, String to, {required bool userTag}) async {
    if (_guardSecretTagOp(from, userTag: userTag) ||
        _guardSecretTagOp(to, userTag: userTag)) {
      return 0;
    }
    final n = _db?.renameTag(from, to, userTag: userTag) ?? 0;
    if (userTag && _customTags.remove(from)) {
      _customTags.add(to);
      _savePrefs();
    }
    _refreshWindow();
    notifyListeners();
    return n;
  }

  @override
  Future<int> deleteTag(String tag, {required bool userTag}) async {
    if (_guardSecretTagOp(tag, userTag: userTag)) return 0;
    final n = _db?.deleteTag(tag, userTag: userTag) ?? 0;
    if (userTag && _customTags.remove(tag)) _savePrefs();
    _refreshWindow();
    notifyListeners();
    return n;
  }

  // --- vault & storage management (settings) ---

  /// The on-disk data directory (config, db, blobs) — for "open data folder".
  String get dataDirPath => _dir.path;

  /// Total bytes of downloaded blob files on this device (the reclaimable cache).
  int get localBlobBytes {
    var total = 0;
    try {
      for (final e in _blobsDir.listSync()) {
        if (e is File) total += e.lengthSync();
      }
    } catch (_) {}
    return total;
  }

  /// On-disk size of the local index: relics.db plus its WAL/SHM sidecars.
  int get dbBytes {
    var total = 0;
    for (final suffix in const ['', '-wal', '-shm']) {
      try {
        final f = File('${_dbFile.path}$suffix');
        if (f.existsSync()) total += f.lengthSync();
      } catch (_) {}
    }
    return total;
  }

  /// Whether this device is linked to a Worker (blobs can be re-downloaded).
  bool get canRedownload => _mk != null && _syncUrl != null;

  /// Delete locally-cached blob files that are safely re-downloadable (already
  /// uploaded to the Worker), reclaiming disk without risking local-only data.
  /// Relics are untouched; their bytes re-download on next view/sync. Returns
  /// bytes freed.
  Future<int> clearLocalBlobCache() async {
    final db = _db;
    if (db == null || !canRedownload) return 0;
    var freed = 0;
    for (final row in db.allWithBlob()) {
      if (!_uploaded.contains(row.blobKey)) continue; // local-only → keep
      final path = _blobPathIfExists(row.blobKey);
      if (path == null) continue;
      try {
        final f = File(path);
        final len = f.lengthSync();
        f.deleteSync();
        freed += len;
        db.markBlobMissing(row.uid);
      } catch (_) {}
    }
    _refreshWindow();
    notifyListeners();
    _prefetchPhotos(); // start pulling thumbnails back in the background
    return freed;
  }

  /// Eagerly re-download every photo blob missing locally (bounded batches).
  Future<int> redownloadBlobs() async {
    final db = _db;
    if (db == null || !canRedownload) return 0;
    var fetched = 0;
    for (final p in db.photosMissingBlob(10000)) {
      final r = db.getByUid(p.uid);
      if (r == null) continue;
      if (await ensureBlob(r)) fetched++;
    }
    return fetched;
  }

  @override
  String? localImagePath(Relic r) {
    // Screenshots/clipboard images, plus image *files* the engine can render.
    if (r.kind == Kind.photo ||
        (r.kind == Kind.file &&
            isDisplayableImageFile(r.filename, r.mime))) {
      return _blobPathIfExists(r.blobKey);
    }
    // A note whose sole attachment is a renderable image → show that image.
    if (r.attachments.length == 1 &&
        isDisplayableImageFile(
            r.attachments.first.name, r.attachments.first.mime)) {
      return attachmentPath(r, r.attachments.first.id);
    }
    return null;
  }

  /// Extract each attachment of a bundle relic to its own cache file
  /// (`<blobKey>.<attId>`) so attachments can be opened, saved, and thumbnailed
  /// individually. No-op when the bundle isn't local yet.
  void _unpackBundle(Relic r) {
    if (r.attachments.isEmpty) return;
    final key = r.blobKey;
    if (key == null) return;
    final bundlePath = _blobPathIfExists(key);
    if (bundlePath == null) return;
    final pending = r.attachments
        .where((a) => !File('${_blobFilePath(key)}.${a.id}').existsSync())
        .toList();
    if (pending.isEmpty) return;
    final Uint8List bundle;
    try {
      bundle = File(bundlePath).readAsBytesSync();
    } catch (_) {
      return;
    }
    for (final a in pending) {
      final bytes = sliceAttachment(bundle, r.attachments, a.id);
      if (bytes == null) continue;
      try {
        File('${_blobFilePath(key)}.${a.id}').writeAsBytesSync(bytes);
      } catch (_) {}
    }
  }

  String? _attachmentCachePath(String? blobKey, String attId) {
    if (blobKey == null) return null;
    final p = '${_blobFilePath(blobKey)}.$attId';
    return File(p).existsSync() ? p : null;
  }

  @override
  String? attachmentPath(Relic r, String attId) {
    final hit = _attachmentCachePath(r.blobKey, attId);
    if (hit != null) return hit;
    _unpackBundle(r); // lazily extract on first access
    return _attachmentCachePath(r.blobKey, attId);
  }

  @override
  Future<Uint8List?> blobBytes(Relic r) async {
    if (!await ensureBlob(r)) return null;
    final p = _blobPathIfExists(r.blobKey);
    return p == null ? null : File(p).readAsBytesSync();
  }

  /// Share links need an authenticated sync connection. Legacy device-token
  /// installs count: the Worker gates /share behind the SAME auth as /relic,
  /// so excluding them just told signed-in users they weren't signed in.
  /// (The offline QR needs nothing.)
  @override
  bool get canShare => _syncToken != null && _syncUrl != null;

  @override
  Future<ShareLink> createShare(Relic r,
      {required Duration ttl, required bool oneTime}) async {
    if (!canShare) throw const ShareException('Sign in to create share links.');
    // Build the plaintext payload (mirrors the recipient page's renderer).
    Map<String, dynamic> payload;
    if (r.kind == Kind.string) {
      final t = r.content;
      if (t == null || t.isEmpty) {
        throw const ShareException('Nothing to share in this item.');
      }
      payload = {'v': 1, 'kind': 'text', 'text': t};
    } else {
      final bytes = await blobBytes(r);
      if (bytes == null) {
        throw const ShareException(
            "This item's content isn't available on this device yet.");
      }
      payload = {
        'v': 1,
        'kind': r.kind == Kind.photo ? 'image' : 'file',
        if (r.mime != null) 'mime': r.mime,
        if (r.filename != null) 'name': r.filename,
        'data': base64.encode(bytes),
      };
    }

    await _maybeRefresh();
    // One 409 retry: the id is client-minted so the AAD can bind it pre-upload;
    // a collision just means mint again.
    for (var attempt = 0; attempt < 2; attempt++) {
      final id = ShareCrypto.mintId();
      final sealed = await ShareCrypto.seal(id, payload);
      final resp = await http.post(
        Uri.parse(_u('/share')).replace(queryParameters: {
          'id': id,
          'ttl': '${ttl.inSeconds}',
          if (oneTime) 'views': '1',
        }),
        headers: _h,
        body: sealed.wire,
      );
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        return ShareLink(
          '${j['url']}#${sealed.keyFragment}',
          expiresAt: (j['expires_at'] as num).toInt(),
          oneTime: oneTime,
        );
      }
      if (resp.statusCode == 409) continue;
      throw ShareException(switch (resp.statusCode) {
        413 => 'Too large to share on your plan.',
        402 => 'Share limit reached. Old links expire on their own.',
        429 => 'Slow down a little. Try again in a minute.',
        401 => 'Sign-in expired. Reconnect sync and try again.',
        _ => "Couldn't create the link. Check your connection and try again.",
      });
    }
    throw const ShareException("Couldn't create the link. Try again.");
  }

  /// Export every relic (plus locally-present blob files) to
  /// `<destDir>/relic-export-<stamp>/` as `vault.json` + `blobs/`. Secrets are
  /// redacted (content AND preview nulled, `redacted: true`, blob skipped)
  /// unless [includeSecrets]. Chunked so the UI thread breathes; blobs that
  /// are synced-away and not cached locally are skipped (the row keeps its
  /// `blob_key` so a future import can re-fetch).
  Future<({int items, int blobs, String path})> exportVault(
    String destDir, {
    required bool includeSecrets,
    void Function(int done, int total)? onProgress,
  }) async {
    const folderPrefix = 'relic-export';
    final now = DateTime.now();
    String p2(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${p2(now.month)}${p2(now.day)}-${p2(now.hour)}${p2(now.minute)}';
    final sep = Platform.pathSeparator;
    final root = Directory('$destDir$sep$folderPrefix-$stamp')
      ..createSync(recursive: true);
    final blobsOut = Directory('${root.path}${sep}blobs')..createSync();
    final rows = all;
    final items = <Map<String, dynamic>>[];
    var blobs = 0;
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final redact = r.isSecret && !includeSecrets;
      final j = r.toJson();
      if (redact) {
        j.remove('content');
        j.remove('preview'); // preview holds plaintext head — scrub it too
        j.remove('rich'); // the HTML/RTF flavors hold the SAME secret, unmasked
        j['redacted'] = true;
      }
      items.add(j);
      if (!redact && r.blobKey != null) {
        final src = _blobPathIfExists(r.blobKey);
        if (src != null) {
          await File(src).copy('${blobsOut.path}$sep${r.blobKey}');
          blobs++;
        }
      }
      if (i % 25 == 24) {
        onProgress?.call(i + 1, rows.length);
        await Future<void>.delayed(Duration.zero);
      }
    }
    await File('${root.path}${sep}vault.json').writeAsString(jsonEncode({
      'version': 1,
      'exported_at': now.toUtc().toIso8601String(),
      'device': _deviceName.isEmpty
          ? (Platform.environment['COMPUTERNAME'] ?? Platform.localHostname)
          : _deviceName,
      'items': items,
    }));
    onProgress?.call(rows.length, rows.length);
    return (items: items.length, blobs: blobs, path: root.path);
  }

  /// Import a folder previously written by [exportVault] (`vault.json` +
  /// `blobs/`). Items whose uid already exists locally are SKIPPED (idempotent
  /// re-runs, never fights LWW with a live account); original timestamps are
  /// preserved; redacted secrets import as metadata-only rows. Blob files are
  /// copied when present; rows keep their `blob_key` either way so a synced
  /// account re-fetches missing bytes on view. Throws with a user-facing
  /// message on a malformed or newer-version export.
  Future<({int imported, int skipped, int blobs, int failed})> importVault(
    String dir, {
    void Function(int done, int total)? onProgress,
  }) async {
    final db = _db;
    if (db == null) throw StateError('Vault not loaded yet.');
    final sep = Platform.pathSeparator;
    final manifest = File('$dir${sep}vault.json');
    if (!manifest.existsSync()) {
      throw StateError('No vault.json in that folder. Pick a Relic export.');
    }
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      throw StateError("Couldn't read vault.json. The export looks damaged.");
    }
    final version = (j['version'] as num?)?.toInt() ?? 0;
    if (version > 1) {
      throw StateError('This export came from a newer version of Relic.');
    }
    if (version != 1 || j['items'] is! List) {
      throw StateError("vault.json doesn't look like a Relic export.");
    }
    final items = (j['items'] as List);
    var imported = 0, skipped = 0, blobs = 0, failed = 0;
    for (var i = 0; i < items.length; i++) {
      try {
        final r = _fromJson((items[i] as Map).cast<String, dynamic>());
        if (db.updatedAtOf(r.uid) != null) {
          skipped++;
        } else {
          var hasBytes = false;
          if (r.blobKey case final key?) {
            if (_blobPathIfExists(key) != null) {
              hasBytes = true; // already on disk from another row/install
            } else {
              final src = File('$dir${sep}blobs$sep$key');
              if (src.existsSync()) {
                await src.copy(_blobFilePath(key));
                hasBytes = true;
                blobs++;
              }
            }
          }
          db.upsert(r, haveBlob: hasBytes, queuePush: syncEnabled);
          if (hasBytes) _unpackBundle(r);
          imported++;
        }
      } catch (_) {
        failed++;
      }
      if (i % 25 == 24) {
        onProgress?.call(i + 1, items.length);
        await Future<void>.delayed(Duration.zero);
      }
    }
    onProgress?.call(items.length, items.length);
    _refreshWindow();
    notifyListeners();
    _kickSync(); // push the imports when connected
    // Freshly-imported documents/bundles become searchable without waiting
    // for the next app start.
    Future.delayed(const Duration(seconds: 2), _backlogExtractPass);
    return (imported: imported, skipped: skipped, blobs: blobs, failed: failed);
  }

  // --- scheduled sealed backup ---

  bool get autoBackup => _autoBackup;
  String? get backupDir => _backupDir;
  bool get backupConfigured => _backupWrap != null;
  bool get backupNeedsReauth => _backupNeedsReauth;
  int get lastBackupAt => _lastBackupAt;
  String get lastBackupSummary => _lastBackupSummary;
  String? get backupStatus => _backupStatus;

  /// Set (or replace) the backup passphrase and arm the weekly backup: mint a
  /// fresh BK, wrap it under [passphrase] (one Argon2 pass), persist the wrap
  /// in prefs and the BK in the OS credential store, then run an immediate
  /// first backup. Replacing the passphrase mints a NEW BK — files already
  /// written stay openable with the passphrase they were sealed under (each
  /// file carries its own wrap record). Returns an error line, or null.
  Future<String?> setupBackup({
    required String dir,
    required String passphrase,
  }) async {
    final (wrap, bk) = await BackupCrypto.createWrap(passphrase);
    await _keyStore.putBackupKey(bk);
    _backupWrap = wrap;
    _backupDir = dir.trim();
    try {
      Directory(_backupDir!).createSync(recursive: true);
    } catch (_) {} // the run below reports a folder that can't exist
    _autoBackup = true;
    _backupNeedsReauth = false;
    _backupStatus = null;
    _savePrefs();
    notifyListeners();
    return _runBackup(force: true);
  }

  /// Re-store the BK when the credential-store entry went missing (cleared
  /// Credential Manager, restored disk image, new user profile). Unwraps from
  /// the prefs wrap record; false on wrong passphrase.
  Future<bool> reauthorizeBackup(String passphrase) async {
    final wrap = _backupWrap;
    if (wrap == null) return false;
    final bk = await BackupCrypto.unwrapBk(wrap, passphrase);
    if (bk == null) return false;
    await _keyStore.putBackupKey(bk);
    _backupNeedsReauth = false;
    _backupStatus = null;
    notifyListeners();
    unawaited(_maybeAutoBackup());
    return true;
  }

  void setAutoBackup(bool on) {
    _autoBackup = on;
    _savePrefs();
    notifyListeners();
    if (on) unawaited(_maybeAutoBackup());
  }

  void setBackupDir(String? dir) {
    final d = dir?.trim();
    _backupDir = (d == null || d.isEmpty) ? null : d;
    _savePrefs();
    notifyListeners();
  }

  static const _backupEvery = 7 * 86400; // weekly
  static const _backupsKept = 4;
  static final _backupFileRe =
      RegExp(r'^relic-backup-\d{8}-\d{4}\.relicvault$');
  static final _legacyBackupDirRe = RegExp(r'^relic-backup-\d{8}-\d{4}$');

  /// Run a backup now regardless of cadence. Returns an error line, or null
  /// on success (result surfaces via [backupStatus] either way).
  Future<String?> runBackupNow() => _runBackup(force: true);

  /// Weekly cadence check; called at startup and every 12 h (the tray app can
  /// run for weeks between launches). Cheap no-op when not due.
  Future<void> _maybeAutoBackup() async {
    if (!_autoBackup || _disposed) return;
    if (_now - _lastBackupAt < _backupEvery) return;
    await _runBackup(force: false);
  }

  Future<String?> _runBackup({required bool force}) async {
    final dir = _backupDir;
    if (_backingUp || dir == null || _backupWrap == null) return null;
    if (!force && !_autoBackup) return null;
    _backingUp = true;
    try {
      if (!Directory(dir).existsSync()) {
        // Unplugged drive / moved folder: report, never crash startup.
        _backupStatus = 'Backup folder is missing. Pick a new one in Settings.';
        notifyListeners();
        return _backupStatus;
      }
      final bk = await _keyStore.getBackupKey();
      if (bk == null) {
        _backupNeedsReauth = true;
        _backupStatus =
            'Backups are paused. Enter your backup passphrase to resume.';
        notifyListeners();
        return _backupStatus;
      }
      final res = await exportSealedBackup(dir, bk: bk);
      _lastBackupAt = _now;
      _lastBackupSummary = [
        '${res.items} items, ${res.blobs} files',
        if (res.skippedBlobs > 0) '${res.skippedBlobs} not on this device',
      ].join(' · ');
      _backupStatus = null;
      _savePrefs();
      _pruneBackups(dir);
      notifyListeners();
      return null;
    } catch (e) {
      _backupStatus = 'Backup failed: $e';
      notifyListeners();
      return _backupStatus;
    } finally {
      _backingUp = false;
    }
  }

  /// Write one sealed `relic-backup-<stamp>.relicvault` into [destDir].
  /// Everything is included — secrets too — because the entire payload is
  /// ciphertext under the backup key; redaction is a plaintext-export concern.
  /// Blobs that are synced away and not cached locally are counted in
  /// `skippedBlobs` (their rows keep `blob_key`, so a restore into a live
  /// account re-fetches the bytes on view).
  Future<({int items, int blobs, int skippedBlobs, String path})>
      exportSealedBackup(
    String destDir, {
    required Uint8List bk,
    void Function(int done, int total)? onProgress,
  }) async {
    final now = DateTime.now();
    String p2(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${p2(now.month)}${p2(now.day)}-${p2(now.hour)}${p2(now.minute)}';
    final sep = Platform.pathSeparator;
    final out = File('$destDir${sep}relic-backup-$stamp.${BackupFile.ext}');
    final rows = all;
    final items = <Map<String, dynamic>>[];
    // key → resolved local path (handles the legacy `<key>.png` naming); a
    // Set-like map so a blob shared by two rows is written once.
    final blobPaths = <String, String>{};
    var skipped = 0;
    for (final r in rows) {
      items.add(r.toJson());
      if (r.blobKey case final key?) {
        final p = _blobPathIfExists(key);
        if (p != null) {
          blobPaths[key] = p;
        } else {
          skipped++;
        }
      }
    }
    final device = _deviceName.isEmpty
        ? (Platform.environment['COMPUTERNAME'] ?? Platform.localHostname)
        : _deviceName;
    final writer = await BackupFileWriter.create(
      out,
      header: {
        'v': 1,
        'created_at': now.toUtc().toIso8601String(),
        'device': device,
        'wrap': _backupWrap,
      },
      bk: bk,
    );
    try {
      await writer.writeManifest({
        'version': 1,
        'exported_at': now.toUtc().toIso8601String(),
        'device': device,
        'items': items,
      });
      var done = 0;
      for (final e in blobPaths.entries) {
        await writer.writeBlob(e.key, await File(e.value).readAsBytes());
        done++;
        if (done % 5 == 0) {
          onProgress?.call(done, blobPaths.length);
          await Future<void>.delayed(Duration.zero);
        }
      }
      await writer.close();
    } catch (e) {
      // Never leave a half-written file looking like a backup.
      try {
        await writer.close();
      } catch (_) {}
      try {
        out.deleteSync();
      } catch (_) {}
      rethrow;
    }
    onProgress?.call(blobPaths.length, blobPaths.length);
    return (
      items: items.length,
      blobs: blobPaths.length,
      skippedBlobs: skipped,
      path: out.path,
    );
  }

  /// Restore from a sealed `.relicvault` file. Same merge semantics as
  /// [importVault]: existing uids are skipped, timestamps preserved, imports
  /// queue for sync when connected. Throws [BackupWrongPassphrase] or
  /// [BackupFormatException] with user-facing messages.
  Future<({int imported, int skipped, int blobs, int failed})>
      importSealedBackup(
    String path,
    String passphrase, {
    void Function(int done, int total)? onProgress,
  }) async {
    final db = _db;
    if (db == null) throw StateError('Vault not loaded yet.');
    final reader = await BackupFileReader.open(File(path), passphrase);
    try {
      final j = reader.manifest;
      final version = (j['version'] as num?)?.toInt() ?? 0;
      if (version != 1 || j['items'] is! List) {
        throw const BackupFormatException(
            "This backup doesn't contain a readable vault.");
      }
      final items = j['items'] as List;
      var imported = 0, skipped = 0, blobs = 0, failed = 0;
      for (var i = 0; i < items.length; i++) {
        try {
          final r = _fromJson((items[i] as Map).cast<String, dynamic>());
          if (db.updatedAtOf(r.uid) != null) {
            skipped++;
          } else {
            var hasBytes = false;
            if (r.blobKey case final key?) {
              if (_blobPathIfExists(key) != null) {
                hasBytes = true; // already on disk from another row/install
              } else {
                final bytes = await reader.blob(key);
                if (bytes != null) {
                  await File(_blobFilePath(key)).writeAsBytes(bytes);
                  hasBytes = true;
                  blobs++;
                }
              }
            }
            db.upsert(r, haveBlob: hasBytes, queuePush: syncEnabled);
            if (hasBytes) _unpackBundle(r);
            imported++;
          }
        } catch (_) {
          failed++; // one bad row/segment must not sink the rest
        }
        if (i % 25 == 24) {
          onProgress?.call(i + 1, items.length);
          await Future<void>.delayed(Duration.zero);
        }
      }
      onProgress?.call(items.length, items.length);
      _refreshWindow();
      notifyListeners();
      _kickSync(); // push the imports when connected
      Future.delayed(const Duration(seconds: 2), _backlogExtractPass);
      return (imported: imported, skipped: skipped, blobs: blobs, failed: failed);
    } finally {
      await reader.close();
    }
  }

  /// Keep the newest [_backupsKept] relic-backup-*.relicvault files; the
  /// stamp is lexicographically ordered so a name sort IS a date sort. Also
  /// removes plaintext relic-backup-* FOLDERS from the pre-sealed format —
  /// those were auto-created artifacts already under this pruner's mandate,
  /// and leaving plaintext copies behind would defeat the sealed upgrade.
  /// Manual relic-export-* folders in the same directory are never touched.
  void _pruneBackups(String dir) {
    try {
      final sep = Platform.pathSeparator;
      final entries = Directory(dir).listSync();
      final old = entries
          .whereType<File>()
          .where((f) => _backupFileRe.hasMatch(f.path.split(sep).last))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path)); // newest first
      for (final f in old.skip(_backupsKept)) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
      for (final d in entries
          .whereType<Directory>()
          .where((d) => _legacyBackupDirRe.hasMatch(d.path.split(sep).last))) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Lazily fetch + decrypt a relic's blob from the Worker (download-on-view).
  /// Returns true when the bytes are available locally.
  @override
  Future<bool> ensureBlob(Relic r) async {
    final key = r.blobKey;
    if (key == null) return false;
    if (_blobPathIfExists(key) != null) return true;
    if (_mk == null || _syncUrl == null || _fetching.contains(key)) {
      return false;
    }
    _fetching.add(key);
    try {
      final resp = await http.get(Uri.parse(_u('/blob/$key')), headers: _h);
      if (resp.statusCode != 200) return false;
      final clear = await RelicCrypto.openBlob(_mk!, key, resp.bodyBytes);
      if (clear == null) return false;
      File(_blobFilePath(key)).writeAsBytesSync(clear);
      _db?.markBlobLocal(r.uid);
      _unpackBundle(r); // extract attachment cache files from a freshly-pulled bundle
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    } finally {
      _fetching.remove(key);
    }
  }

  @override
  Future<void> putOnClipboard(Relic r) async {
    _secretClearTimer?.cancel(); // a newer copy always disarms the scrub
    // Reaching for an item IS the personal-ranking signal (local-only, no
    // sync churn, no list refresh: the effect lands on the next query):
    // frecency counter, plus "picked for these search terms", plus "picked
    // while summoned over this app".
    final db = _db;
    if (db != null && _personalRank) {
      db.recordUse(r.uid, _now);
      if (_query.trim().isNotEmpty) db.recordQueryPick(_query, r.uid, _now);
      final app = _summonApp;
      if (app != null) db.recordContextPick(app, r.uid, r.allTags, _now);
    }
    await _putOnClipboardInner(r);
    if (r.isSecret && _clearSecretClip) await _armSecretScrub();
  }

  @override
  Future<void> putTextOnClipboard(String t, {bool sensitive = false}) async {
    _secretClearTimer?.cancel(); // a newer copy always disarms the scrub
    _lastCaptured = t; // suppress the echo capture
    _lastCapturedRichFp = null;
    if (!await writeSensitiveTextToClipboard(t)) {
      await Clipboard.setData(ClipboardData(text: t));
    }
    if (sensitive && _clearSecretClip) await _armSecretScrub();
  }

  Future<void> _armSecretScrub() async {
    final seq = await clipboardSequence();
    // 0 = API failed / unsupported platform: never arm a blind clear.
    if (seq == 0) return;
    _secretClearTimer = Timer(const Duration(seconds: 30), () async {
      // Only scrub if the clipboard still holds OUR write — anything
      // copied since (by the user or any app) bumps the sequence number.
      if (await clipboardSequence() == seq) await clearClipboard();
    });
  }

  Future<void> _putOnClipboardInner(Relic r) async {
    if (r.kind == Kind.photo) {
      await ensureBlob(r);
      final path = _blobPathIfExists(r.blobKey);
      final clip = SystemClipboard.instance;
      if (path != null && clip != null) {
        final bytes = await File(path).readAsBytes();
        _lastBlobHash = _hash(bytes); // suppress the echo capture
        _lastBlobUid = r.uid; // annotate on this echo resolves to this relic
        final item = DataWriterItem();
        item.add(Formats.png(bytes));
        await clip.write([item]);
        await markClipboardSensitive();
        return;
      }
    } else if (r.kind == Kind.file) {
      await ensureBlob(r);
      final path = _blobPathIfExists(r.blobKey);
      if (path != null) {
        try {
          final bytes = await File(path).readAsBytes();
          final tmp = Directory(
            '${Directory.systemTemp.path}${Platform.pathSeparator}relic',
          );
          if (!tmp.existsSync()) tmp.createSync(recursive: true);
          final dst = File(
            '${tmp.path}${Platform.pathSeparator}${r.filename ?? 'file'}',
          );
          dst.writeAsBytesSync(bytes);
          _lastBlobHash = _hash(bytes); // suppress the echo capture
          _lastBlobUid = r.uid;
          // put a real file on the clipboard (pastes as a file in the file
          // manager); fall back to copying the path text if the native write
          // fails.
          if (await writeFileToClipboard(dst.path)) return;
          _lastCaptured = dst.path;
          _lastCapturedRichFp = null;
          if (!await writeSensitiveTextToClipboard(dst.path)) {
            await Clipboard.setData(ClipboardData(text: dst.path));
          }
          return;
        } catch (_) {}
      }
    }
    final t = await textOf(r);
    if (t != null) {
      // richIfCurrent is the single gate: it returns null for a secret, and
      // null once the text has been edited away from what the formatting
      // described. textOf can also answer with a filename, which no stored
      // formatting will ever fingerprint-match.
      final rich = _pasteRichText ? r.richIfCurrent : null;
      _lastCaptured = t; // suppress the echo capture
      _lastCapturedRichFp = rich?.h;
      final wrote = rich == null
          ? await writeSensitiveTextToClipboard(t)
          : await writeRichToClipboard(t, rich, sensitive: true);
      if (!wrote) {
        await Clipboard.setData(ClipboardData(text: t));
      }
    }
  }

  static int _hash(Uint8List b) {
    // cheap content fingerprint: length + sampled bytes
    var h = b.length;
    final step = (b.length ~/ 64).clamp(1, b.isEmpty ? 1 : b.length);
    for (var i = 0; i < b.length; i += step) {
      h = (h * 31 + b[i]) & 0x7fffffff;
    }
    return h;
  }

  static (int, int)? _pngDims(Uint8List b) {
    if (b.length < 24 || b[0] != 0x89 || b[1] != 0x50) return null;
    int rd(int o) =>
        (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
    return (rd(16), rd(20)); // IHDR width, height
  }

  /// The single most-recently-created item across ALL synced devices — a phone
  /// screenshot pulled seconds ago outranks an older local copy. Backs the
  /// "paste latest" hotkey. Null when the vault is empty.
  Relic? mostRecent() {
    final db = _db;
    if (db == null) return null;
    final uid = db.mostRecentUid();
    if (uid == null) return null;
    return db.getByUid(uid);
  }

  /// The [n]-th most recent item across all devices (1 = newest), for the
  /// quick-paste 1-5 hotkeys. Null if fewer than [n] items exist.
  Relic? nthMostRecent(int n) {
    final db = _db;
    if (db == null) return null;
    final uid = db.nthMostRecentUid(n);
    if (uid == null) return null;
    return db.getByUid(uid);
  }

  /// Promote the most recent capture (promote-last hotkey).
  bool promoteLast() {
    final db = _db;
    if (db == null) return false;
    final uid = db.mostRecentUid();
    if (uid == null) return false;
    final r = db.getByUid(uid);
    if (r == null) return false;
    final u = r.copyWith(promoted: true, updatedAt: _now);
    db.upsert(u, queuePush: syncEnabled);
    _queueCaptionIfNeeded(u);
    _refreshWindow();
    notifyListeners();
    _kickSync();
    return true;
  }

  @override
  Future<void> promote(Relic r, bool promoted) async {
    // Block a vault save that would exceed the tier cap (synced Free); keep the
    // item where it is and surface "Vault full" instead of silently failing.
    if (promoted && !r.promoted && _vaultFull(r.byteSize)) {
      _vaultFullFlag = true;
      notifyListeners();
      return;
    }
    final u = r.copyWith(promoted: promoted, updatedAt: _now);
    _db?.upsert(u, queuePush: syncEnabled);
    _queueCaptionIfNeeded(u);
    _refreshWindow();
    notifyListeners();
    _kickSync();
  }

  /// Labeling is vault-only for text and title-less photos, so saving an
  /// unlabeled one re-queues it — the next worker cycle runs the labeler now
  /// that it's promoted and writes the generated title as its title.
  void _queueCaptionIfNeeded(Relic u, {bool bulk = false}) {
    if (shouldRequeueForLabel(u, describeItems: _describeItems, bulk: bulk)) {
      _db?.setEnrichLevel(u.uid, 0);
    }
  }

  /// Retroactively promote every existing relic into the Vault — the one-time
  /// bulk action when "Save everything to Vault" is switched on.
  void _promoteAllExisting() {
    final db = _db;
    if (db == null) return;
    for (final r in db.allRows()) {
      if (r.promoted) continue;
      final u = r.copyWith(promoted: true, updatedAt: _now);
      db.upsert(u, queuePush: syncEnabled);
      _queueCaptionIfNeeded(u, bulk: true);
    }
    _refreshWindow();
    notifyListeners();
    _kickSync();
  }

  @override
  Future<void> delete(Relic r) async {
    _deleteBlobFiles(r.blobKey);
    final deletedAt = _now;
    _db?.deleteAndQueue(r.uid, deletedAt, queueDelete: syncEnabled);
    _vec.remove(r.uid); // drop the cached embedding too
    _refreshWindow();
    notifyListeners();
    _kickSync();
  }

  /// History item count, for the "Clear all history" confirm.
  int get historyCount => _db?.countUnpromoted() ?? 0;

  /// Delete every history (unpromoted) item. Vault untouched. When synced,
  /// delete tombstones are queued so the items disappear account-wide instead
  /// of pulling back down. One DB transaction + one blob-dir sweep; no undo
  /// (the settings row confirm-gates it). Returns the number removed.
  Future<int> clearHistory() async {
    final db = _db;
    if (db == null) return 0;
    final res = db.clearUnpromoted(_now, queueDeletes: syncEnabled);
    if (res.uids.isEmpty) return 0;
    final gone = res.uids.toSet();
    for (final uid in res.uids) {
      _vec.remove(uid); // cached embeddings
      _enrichFails.remove(uid); // stale failure counters
    }
    _demoUids.removeWhere(gone.contains); // demo banner state stays honest
    _hybridUids?.removeWhere(gone.contains); // active fused ranking
    // Re-copying the same content after a clear should recapture it.
    _lastCaptured = null;
    _lastCapturedRichFp = null;
    _lastBlobHash = null;
    _lastBlobUid = null;
    _deleteBlobFilesBulk(res.orphanBlobKeys);
    _refreshWindow();
    notifyListeners();
    _kickSync();
    return res.uids.length;
  }

  /// Bulk variant of [_deleteBlobFiles]: ONE listSync of blobs/, removing
  /// files named `<key>` or `<key>.<anything>` for keys in [keys] (covers
  /// legacy `<key>.png` and unpacked `<key>.<attachmentId>` files). Blob
  /// keys are dot-free, so the first-dot stem identifies the owner; listSync
  /// is materialized, so deleting while iterating is safe.
  void _deleteBlobFilesBulk(Set<String> keys) {
    if (keys.isEmpty) return;
    List<FileSystemEntity> entries;
    try {
      entries = _blobsDir.listSync();
    } catch (_) {
      return;
    }
    for (final e in entries) {
      if (e is! File) continue;
      final name = e.path.split(Platform.pathSeparator).last;
      final dot = name.indexOf('.');
      final stem = dot < 0 ? name : name.substring(0, dot);
      if (keys.contains(stem)) {
        try {
          e.deleteSync();
        } catch (_) {}
      }
    }
  }

  @override
  bool get canUndoDelete => true;

  /// Read a relic's local blob bytes (if present) so a delete can be undone.
  @override
  Future<Uint8List?> snapshotBlob(Relic r) async {
    final p = r.blobKey == null ? null : _blobPathIfExists(r.blobKey);
    if (p == null) return null;
    try {
      return File(p).readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  /// Re-insert a just-deleted relic (Undo). Rewrites the blob from [blob] when
  /// captured, cancels the queued tombstone, and re-pushes with a fresh
  /// updated_at. Reliable when local-only; best-effort once a delete has already
  /// flushed to the Worker.
  @override
  Future<void> restore(Relic r, {Uint8List? blob}) async {
    final db = _db;
    if (db == null) return;
    final key = r.blobKey;
    final haveBlob = key != null && blob != null;
    if (key != null && blob != null) {
      try {
        File(_blobFilePath(key)).writeAsBytesSync(blob);
      } catch (_) {}
      _uploaded.remove(key); // force a re-upload on the next sync
    }
    db.clearOpsForUid(r.uid); // cancel the queued delete (if any)
    db.upsert(r.copyWith(updatedAt: _now), haveBlob: haveBlob, queuePush: syncEnabled);
    _refreshWindow();
    notifyListeners();
    _kickSync();
  }

  @override
  Future<void> updateMeta(
    Relic r, {
    String? title,
    String? note,
    List<String>? userTags,
    List<String>? tags,
    String? content,
  }) async {
    // Re-read the CURRENT row: [r] is the dialog's snapshot, and enrichment
    // may have added tags (even `secret`) while it was open — building on a
    // stale base would silently drop them without recording suppression.
    final cur = _db?.getByUid(r.uid) ?? r;
    // Body edits: string relics only, never secrets (their plaintext must not
    // flow into preview); empty/unchanged mean "leave the body alone".
    final newContent = (cur.kind != Kind.string ||
            cur.isSecret ||
            content == null ||
            content.trim().isEmpty ||
            content == cur.content)
        ? null
        : content;
    List<String>? newTags;
    if (tags != null) {
      final merged = [...tags];
      // Metadata edits must never unmask: `secret` survives regardless of
      // what the (possibly stale) tag list says.
      if (cur.isSecret && !merged.contains('secret')) merged.add('secret');
      // Tags enrichment added AFTER the dialog snapshot aren't removals the
      // user made — keep them (a real removal of a visible tag still works
      // because those were in the snapshot).
      for (final t in cur.tags) {
        if (!r.tags.contains(t) && !merged.contains(t)) merged.add(t);
      }
      newTags = merged;
    }
    // Snapshot of the USER's tag intent, pre-reconcile: suppression must
    // record only tags the user removed — not detector tags the body edit
    // reconcile strips because the text no longer contains them.
    final userMerged = newTags;
    if (newContent != null) {
      // The body changed — detector tags follow the text they were computed
      // from (same semantics as the v9 reconcile): keep non-detector tags +
      // still-firing ones, `secret`/`jwt` are never REMOVED here, and
      // newly-firing tags land unless the user suppressed them. A secret
      // newly typed into the body masks per the current preference — an edit
      // is new content, so the capture-time rule applies, not migration
      // preservation.
      final base = newTags ?? cur.tags;
      final detected = detectTags(newContent).toSet();
      final suppressed =
          _db?.suppressedTags(r.uid).toSet() ?? const <String>{};
      newTags = [
        for (final t in base)
          if (!kDetectorTags.contains(t) ||
              detected.contains(t) ||
              t == 'secret' ||
              t == 'jwt')
            t,
        for (final t in detected)
          if (!base.contains(t) &&
              !suppressed.contains(t.toLowerCase()) &&
              (_maskSecrets || t != 'secret'))
            t,
      ];
    }
    final u = cur.copyWith(
      title: title,
      note: note,
      userTags: userTags,
      tags: newTags,
      content: newContent,
      preview: newContent == null ? null : _preview(newContent),
      // Blob-less string relics: the body IS the payload, so its size follows.
      byteSize: newContent != null && cur.blobKey == null
          ? utf8.encode(newContent).length
          : null,
      updatedAt: _now,
    );
    _db?.upsert(u, queuePush: syncEnabled);
    // Machine tags the user removed here must stay removed: record them as
    // suppressed so re-enrichment can't resurrect them. Re-adding a tag lifts
    // its suppression. Judged against the user's PRE-reconcile edit, so a
    // body change stripping a detector tag isn't mistaken for a removal.
    if (userMerged != null && _db != null) {
      final keptLower = userMerged.map((t) => t.toLowerCase()).toSet();
      final removed =
          cur.tags.where((t) => !keptLower.contains(t.toLowerCase()));
      final old = _db!.suppressedTags(r.uid); // stored lowercased
      final next = {
        ...old.where((t) => !keptLower.contains(t)),
        ...removed.map((t) => t.toLowerCase()),
      };
      if (next.length != old.length || !old.toSet().containsAll(next)) {
        _db!.setSuppressedTags(r.uid, next.toList());
      }
    }
    // Title/note/body feed the document embedding (string relics only —
    // photos and files embed their OCR/caption text) — reset the enrich level
    // so the background worker re-embeds (FTS is reindexed by upsert).
    final embedChanged = cur.kind == Kind.string &&
        (newContent != null ||
            (title != null && title != cur.title) ||
            (note != null && note != cur.note));
    if (embedChanged) {
      _db?.setEnrichLevel(r.uid, 0);
      if (_mlEnrich && _sift != null) _startEnrichWorker();
    }
    _refreshWindow();
    notifyListeners();
    _kickSync();
  }

  @override
  Future<String?> textOf(Relic r) async => r.content ?? r.filename;

  // --- sync ---

  /// Connect to a deployed Worker, unwrap the master key with the passphrase,
  /// pull existing relics, and push any local-only ones. Persists config + key
  /// so future launches auto-reconnect.
  Future<void> connectSync(String url, String token, String passphrase,
      {String mode = 'cloud'}) async {
    await _ensureDeviceId();
    final base = url.replaceAll(RegExp(r'/+$'), '');
    final auth = {'Authorization': 'Bearer $token'};
    final resp = await http.get(Uri.parse('$base/keyparams'), headers: auth);
    if (resp.statusCode == 401) throw 'Unauthorized. Check the token.';
    Uint8List? mk;
    if (resp.statusCode == 404) {
      // brand-new account → create the vault key on this (first) device
      final (kp, newMk) = await RelicCrypto.createKeyParams(passphrase);
      final put = await http.put(
        Uri.parse('$base/keyparams'),
        headers: {...auth, 'Content-Type': 'application/json'},
        body: jsonEncode(kp),
      );
      if (put.statusCode != 200) {
        throw 'Could not create the vault key (${put.statusCode}).';
      }
      mk = newMk;
      vaultJustCreated = true; // fresh vault → host shows the recovery kit once
    } else if (resp.statusCode == 200) {
      mk = await RelicCrypto.unwrapMasterKey(
        jsonDecode(resp.body) as Map<String, dynamic>,
        passphrase,
      );
      if (mk == null) throw 'Wrong passphrase for this account.';
    } else {
      throw 'Server error ${resp.statusCode}.';
    }
    final key = mk;
    final scope = SecureKeyStore.scopeFor(base, token);
    if (!await _storeSyncSecrets(scope, token, key)) {
      throw 'Could not store sync credentials in the OS credential store.';
    }
    _writeSyncConfig(base, scope, mode: mode);
    _deleteLegacyKeyFile();
    _syncUrl = base;
    _syncToken = token;
    _syncScope = scope;
    _mk = key;
    _selfHost = mode == 'selfhost';
    final pushAll = _prepareBind('legacy:$scope');
    _startTimer();
    notifyListeners();
    unawaited(_initialSync(pushAll));
  }

  /// Connect to a user's OWN self-hosted server (the "Obsidian model"). No
  /// account: the bearer is derived from the passphrase alone
  /// ([RelicCrypto.deriveSelfHostToken]) so any device that knows the URL +
  /// passphrase can enroll and pull the same vault. Enrolls first (claims the
  /// instance on first use / is idempotent after; a wrong passphrase is rejected
  /// by the server's trust-on-first-use check), then reuses the device-token
  /// [connectSync] bootstrap (create-or-unwrap keyparams, persist, start sync).
  Future<void> connectSelfHost(String url, String passphrase,
      {String? enrollSecret}) async {
    await _ensureDeviceId();
    final base = url.replaceAll(RegExp(r'/+$'), '');
    final token = RelicCrypto.deriveSelfHostToken(passphrase);
    await _enrollSelfHost(base, token, enrollSecret);
    await connectSync(base, token, passphrase, mode: 'selfhost');
  }

  /// POST /enroll against a self-host server. Maps the server's TOFU rejections
  /// to friendly errors. Best-effort device metadata for the Devices screen.
  Future<void> _enrollSelfHost(
      String base, String token, String? enrollSecret) async {
    final http.Response resp;
    try {
      resp = await http.post(
        Uri.parse('$base/enroll'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({
          if (_deviceId != null) 'device_id': _deviceId,
          'label': _deviceLabel,
          'platform': Platform.operatingSystem,
          if (_appVersion != null) 'app_version': _appVersion,
          if (enrollSecret != null && enrollSecret.isNotEmpty)
            'enroll_secret': enrollSecret,
        }),
      );
    } catch (_) {
      throw "Couldn't reach that server. Check the address and that it's running.";
    }
    if (resp.statusCode == 200) return;
    if (resp.statusCode == 403) {
      throw isEnrollSecretError(resp.body)
          ? 'Wrong enrollment secret for this server.'
          : 'Wrong passphrase for this server.';
    }
    if (resp.statusCode == 401) throw 'This server rejected the connection.';
    throw 'Server error ${resp.statusCode}.';
  }

  /// True when a self-host /enroll 403 was specifically the enrollment-secret
  /// gate (vs a wrong-passphrase rejection). Mirrors selfhost/src/enroll.ts.
  static bool isEnrollSecretError(String body) {
    try {
      return (jsonDecode(body) as Map)['message'] == 'bad enrollment secret';
    } catch (_) {
      return false;
    }
  }

  /// The first sync after a bind, in the background: the passphrase is already
  /// verified (the MK unwrapped) and the credentials are stored, so connect
  /// returns and the UI moves on while a large vault pulls down and the
  /// catch-up pushes drain. Order matters: pull first (so queued pushes carry
  /// merged rows), then queue, then flush. Failures leave ops queued for the
  /// 8-second cycle to retry — a slow first sync must never look like a
  /// sign-in failure.
  Future<void> _initialSync(bool pushAll) async {
    try {
      await _pullRemote();
      if (pushAll) {
        for (final r in (_db?.allRows() ?? const <Relic>[])) {
          _db?.queueOp(r.uid, 'push', r.updatedAt);
        }
      }
      await _flushPending();
    } catch (e) {
      appendSyncLog('sync cycle error: $e');
      _online = false; // next cycle retries
    }
    notifyListeners();
  }

  /// Sign in (or sign up) with Supabase, then bind sync to the deployed Worker
  /// using the Supabase access token as the bearer. The crypto scope is keyed off
  /// the stable user id (not the rotating JWT); the long-lived refresh token is
  /// stored so future launches reconnect without a password. The passphrase only
  /// unwraps/creates the vault key and never leaves this device.
  Future<void> connectSupabase(
    String workerUrl,
    String email,
    String password,
    String passphrase, {
    bool signUp = false,
  }) async {
    final base = workerUrl.replaceAll(RegExp(r'/+$'), '');
    final session = signUp
        ? await SupabaseAuth.signUp(email, password)
        : await SupabaseAuth.signIn(email, password);
    if (session.userId.isEmpty) throw 'Sign-in did not return a user.';
    final auth = {'Authorization': 'Bearer ${session.accessToken}'};
    final resp = await http.get(Uri.parse('$base/keyparams'), headers: auth);
    if (resp.statusCode == 401) {
      throw 'Signed in, but the server rejected the session.';
    }
    Uint8List? mk;
    if (resp.statusCode == 404) {
      final (kp, newMk) = await RelicCrypto.createKeyParams(passphrase);
      final put = await http.put(
        Uri.parse('$base/keyparams'),
        headers: {...auth, 'Content-Type': 'application/json'},
        body: jsonEncode(kp),
      );
      if (put.statusCode != 200) {
        throw 'Could not create the vault key (${put.statusCode}).';
      }
      mk = newMk;
      vaultJustCreated = true; // host shows the recovery kit once
    } else if (resp.statusCode == 200) {
      mk = await RelicCrypto.unwrapMasterKey(
        jsonDecode(resp.body) as Map<String, dynamic>,
        passphrase,
      );
      if (mk == null) throw 'Wrong passphrase for this account.';
    } else {
      throw 'Server error ${resp.statusCode}.';
    }
    await _bindSupabaseSession(base, session, mk);
  }

  /// Shared bind tail: store secrets + config, set sync state, pull + flush.
  Future<void> _bindSupabaseSession(
      String base, SupabaseSession session, Uint8List key) async {
    await _ensureDeviceId();
    _purgeDemoSeed(); // demo samples must not sync into a real account
    // Stable scope from the user id — survives access-token rotation.
    final scope =
        SecureKeyStore.scopeFor(base, 'supabase:${session.userId}');
    // Store the long-lived REFRESH token (in the device-token slot) + the key.
    if (!await _storeSyncSecrets(scope, session.refreshToken, key)) {
      throw 'Could not store sync credentials in the OS credential store.';
    }
    _writeSyncConfig(
      base,
      scope,
      authMode: 'supabase',
      userId: session.userId,
      email: session.email,
    );
    _deleteLegacyKeyFile();
    _supabaseMode = true;
    _syncUrl = base;
    _syncToken = session.accessToken;
    _refreshToken = session.refreshToken;
    _accessExpiry = session.expiresAt;
    _accountEmail = session.email;
    _supabaseUserId = session.userId;
    _syncScope = scope;
    _mk = key;
    final pushAll = _prepareBind('supabase:${session.userId}');
    _startTimer();
    notifyListeners();
    unawaited(_initialSync(pushAll));
  }

  /// Sign in and unlock with a recovery kit (docs/cloudflare/13 §6): parse the
  /// kit (the raw MK), re-wrap it under a new passphrase (PUT ?replace=1), bind.
  Future<void> connectSupabaseWithKit(String workerUrl, String email,
      String password, String kitText, String newPassphrase) async {
    final base = workerUrl.replaceAll(RegExp(r'/+$'), '');
    final session = await SupabaseAuth.signIn(email, password);
    if (session.userId.isEmpty) throw 'Sign-in did not return a user.';
    final mk = RecoveryKit.parse(kitText).mk; // throws RecoveryKitException
    final kp = await RelicCrypto.rewrapKeyParams(mk, newPassphrase);
    final put = await http.put(
      Uri.parse('$base/keyparams?replace=1'),
      headers: {
        'Authorization': 'Bearer ${session.accessToken}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(kp),
    );
    if (put.statusCode != 200) {
      throw 'Could not re-wrap the vault key (${put.statusCode}).';
    }
    await _bindSupabaseSession(base, session, mk);
  }

  /// OAuth path: bind sync from an already-obtained Supabase [session] (the
  /// browser PKCE flow in oauth_flow.dart), unwrapping/creating the vault with
  /// [passphrase]. Mirrors [connectSupabase] but skips the email/password
  /// sign-in. [allowCreate] gates whether a missing vault (404) is created (first
  /// device) or an error — the caller pre-checks via OnboardingService.hasVault.
  Future<void> connectSupabaseSession(
    String workerUrl,
    SupabaseSession session,
    String passphrase, {
    bool allowCreate = false,
  }) async {
    final base = workerUrl.replaceAll(RegExp(r'/+$'), '');
    if (session.userId.isEmpty) throw 'Sign-in did not return a user.';
    final auth = {'Authorization': 'Bearer ${session.accessToken}'};
    final resp = await http.get(Uri.parse('$base/keyparams'), headers: auth);
    if (resp.statusCode == 401) {
      throw 'Signed in, but the server rejected the session.';
    }
    Uint8List? mk;
    if (resp.statusCode == 404) {
      if (!allowCreate) throw 'No vault found for this account.';
      final (kp, newMk) = await RelicCrypto.createKeyParams(passphrase);
      final put = await http.put(
        Uri.parse('$base/keyparams'),
        headers: {...auth, 'Content-Type': 'application/json'},
        body: jsonEncode(kp),
      );
      if (put.statusCode != 200) {
        throw 'Could not create the vault key (${put.statusCode}).';
      }
      mk = newMk;
      vaultJustCreated = true; // host shows the recovery kit once
    } else if (resp.statusCode == 200) {
      mk = await RelicCrypto.unwrapMasterKey(
        jsonDecode(resp.body) as Map<String, dynamic>,
        passphrase,
      );
      if (mk == null) throw 'Wrong passphrase for this account.';
    } else {
      throw 'Server error ${resp.statusCode}.';
    }
    await _bindSupabaseSession(base, session, mk);
  }

  /// OAuth + recovery-kit door: bind from [session], re-wrapping the kit's master
  /// key under [newPassphrase]. Mirrors [connectSupabaseWithKit] without sign-in.
  Future<void> connectSupabaseSessionWithKit(
    String workerUrl,
    SupabaseSession session,
    String kitText,
    String newPassphrase,
  ) async {
    final base = workerUrl.replaceAll(RegExp(r'/+$'), '');
    if (session.userId.isEmpty) throw 'Sign-in did not return a user.';
    final mk = RecoveryKit.parse(kitText).mk; // throws RecoveryKitException
    final kp = await RelicCrypto.rewrapKeyParams(mk, newPassphrase);
    final put = await http.put(
      Uri.parse('$base/keyparams?replace=1'),
      headers: {
        'Authorization': 'Bearer ${session.accessToken}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(kp),
    );
    if (put.statusCode != 200) {
      throw 'Could not re-wrap the vault key (${put.statusCode}).';
    }
    await _bindSupabaseSession(base, session, mk);
  }

  /// OAuth + pairing door: bind from [session] with a master key already obtained
  /// over the pairing handshake (the desktop "use another device" flow). Mirrors
  /// [connectSupabaseSessionWithKit] but WITHOUT re-wrapping keyparams — the
  /// trusted device's keyparams already validate this MK (the caller ran
  /// OnboardingService.verifyPairedMk first), and a new device must never
  /// overwrite the account's keyparams.
  Future<void> connectSupabaseSessionWithMk(
    String workerUrl,
    SupabaseSession session,
    Uint8List mk,
  ) async {
    final base = workerUrl.replaceAll(RegExp(r'/+$'), '');
    if (session.userId.isEmpty) throw 'Sign-in did not return a user.';
    await _bindSupabaseSession(base, session, mk);
  }

  /// Rotate the vault passphrase (docs/cloudflare/13 §7): re-wrap the in-memory
  /// master key under a new passphrase and PUT ?replace=1. No data is
  /// re-encrypted; the recovery kit stays valid.
  Future<void> changePassphrase(String newPassphrase) async {
    final mk = _mk;
    final base = _syncUrl;
    if (mk == null || base == null) throw 'Connect first.';
    final kp = await RelicCrypto.rewrapKeyParams(mk, newPassphrase);
    final put = await http.put(
      Uri.parse('$base/keyparams?replace=1'),
      headers: {..._h, 'Content-Type': 'application/json'},
      body: jsonEncode(kp),
    );
    if (put.statusCode != 200) {
      throw 'Could not change the passphrase (${put.statusCode}).';
    }
  }

  /// Sign out on ALL devices (docs/cloudflare/13 §7): revoke every refresh token
  /// for this account at the IdP. Other devices drop offline as their access
  /// tokens expire (~1h); this device's refresh token is revoked too. The caller
  /// should follow up with [disconnectSync] to fully sign out here.
  Future<void> signOutEverywhere() async {
    final tok = _syncToken;
    if (!_supabaseMode || tok == null) {
      throw 'Signing out everywhere needs a Relic account session.';
    }
    await SupabaseAuth.signOutGlobal(tok);
    _refreshToken = null;
  }

  /// Change the login (account) email at the IdP. GoTrue emails a confirmation
  /// link to both the current and the new address; the change lands only once
  /// confirmed, so this session keeps working meanwhile. The vault key is
  /// untouched (auth != vault). Mirrors WorkerRepo.changeEmail.
  Future<void> changeEmail(String newEmail) async {
    await _maybeRefresh();
    final tok = _syncToken;
    if (!_supabaseMode || tok == null) {
      throw 'Changing your email needs a Relic account session.';
    }
    await SupabaseAuth.changeEmail(tok, newEmail);
  }

  /// Permanently delete the synced vault + account on the server (DELETE
  /// /account — full teardown). Local history on this computer is untouched; the
  /// caller follows up with [disconnectSync]. Mirrors WorkerRepo.deleteAccount.
  Future<void> deleteAccount() async {
    final base = _syncUrl;
    if (base == null) throw 'Connect first.';
    // Force-refresh: the worker rejects deletion on a token older than ~10
    // minutes (stale_token), so mint a fresh one regardless of expiry.
    await _refreshAccess();
    final r = await http.delete(Uri.parse('$base/account'), headers: _h);
    if (r.statusCode != 200 && r.statusCode != 204) {
      throw 'Could not delete your account (${r.statusCode}).';
    }
  }

  /// Reconnect a persisted Supabase session: exchange the stored refresh token
  /// for a fresh access token, then bind sync. No passphrase needed.
  Future<void> _autoConnectSupabase(
    Map<String, dynamic> cfg,
    String scope,
  ) async {
    final refreshTok = await _keyStore.getRefreshToken(scope);
    final key = await _keyStore.getMasterKey(scope);
    if (refreshTok == null || key == null || key.length != 32) return;
    await _ensureDeviceId();
    SupabaseSession s;
    try {
      s = await SupabaseAuth.refresh(refreshTok);
    } catch (_) {
      return; // refresh expired → user must sign in again
    }
    _supabaseMode = true;
    _refreshToken = s.refreshToken.isEmpty ? refreshTok : s.refreshToken;
    _accessExpiry = s.expiresAt;
    _accountEmail = (cfg['email'] as String?) ?? s.email;
    _supabaseUserId = (cfg['user_id'] as String?) ?? s.userId;
    if (s.refreshToken.isNotEmpty && s.refreshToken != refreshTok) {
      try {
        await _keyStore.putRefreshToken(scope, s.refreshToken);
      } catch (_) {} // rotation persist is best-effort, like the old bool
    }
    _writeSyncConfig(
      _syncUrl!,
      scope,
      authMode: 'supabase',
      userId: cfg['user_id'] as String?,
      email: _accountEmail,
    );
    _syncToken = s.accessToken;
    _syncScope = scope;
    _mk = key;
    // Reconnecting the stored account: teach pre-guard installs which account
    // their data belongs to, so a later switch is detectable.
    final id = 'supabase:$_supabaseUserId';
    if (_syncedAccount != id) {
      _syncedAccount = id;
      _savePrefs();
    }
    _loadCursors();
    await _syncCycle();
    _startTimer();
    notifyListeners();
  }

  /// Refresh the Supabase access token shortly before it expires. No-op outside
  /// Supabase mode or when the token is still fresh. Called every sync cycle.
  Future<void> _maybeRefresh() async {
    if (!_supabaseMode || _refreshing) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (now < _accessExpiry - 120) return;
    await _refreshAccess();
  }

  Future<void> _refreshAccess() async {
    final rt = _refreshToken;
    if (!_supabaseMode || _refreshing || rt == null) return;
    _refreshing = true;
    try {
      final s = await SupabaseAuth.refresh(rt);
      _syncToken = s.accessToken;
      _accessExpiry = s.expiresAt;
      if (s.refreshToken.isNotEmpty && s.refreshToken != rt) {
        _refreshToken = s.refreshToken;
        final scope = _syncScope;
        if (scope != null) {
          try {
            await _keyStore.putRefreshToken(scope, s.refreshToken);
          } catch (_) {} // best-effort, must not flip _online
        }
      }
    } catch (e) {
      appendSyncLog('token refresh failed: $e');
      _online = false; // next cycle retries; persistent failure → re-sign-in
    } finally {
      _refreshing = false;
    }
  }

  /// Silently re-establish sync from persisted config + key (no passphrase).
  Future<void> tryAutoConnect() async {
    try {
      if (!_configFile.existsSync()) return;
      final cfg =
          jsonDecode(_configFile.readAsStringSync()) as Map<String, dynamic>;
      // ignore the legacy egui config shape ({backend:{...}}) — Flutter writes flat.
      if (cfg['url'] is! String) return;
      _syncUrl = (cfg['url'] as String).replaceAll(RegExp(r'/+$'), '');
      final legacyToken = cfg['token'] as String?;
      final scope =
          cfg['credential_scope'] as String? ??
          (legacyToken == null
              ? null
              : SecureKeyStore.scopeFor(_syncUrl!, legacyToken));
      if (scope == null) return;
      if ((cfg['auth_mode'] as String? ?? 'device') == 'supabase') {
        await _autoConnectSupabase(cfg, scope);
        return;
      }
      final token = await _keyStore.getRefreshToken(scope) ?? legacyToken;
      final key = await _keyStore.getMasterKey(scope) ?? _readLegacyKeyBytes();
      if (token == null || key == null || key.length != 32) return;
      await _ensureDeviceId();
      if (!await _storeSyncSecrets(scope, token, key)) return;
      // Self-host reconnects exactly like the cloud device-token path (token +
      // MK already in the keystore, no passphrase needed); only the mode flag
      // and the settings-pane branch differ, so preserve it across the rewrite.
      final mode = cfg['mode'] as String? ?? 'cloud';
      _selfHost = mode == 'selfhost';
      _writeSyncConfig(_syncUrl!, scope, mode: mode);
      _deleteLegacyKeyFile();
      _syncToken = token;
      _syncScope = scope;
      _mk = key;
      // Same pre-guard stamp as _autoConnectSupabase, legacy identity form.
      final id = 'legacy:$scope';
      if (_syncedAccount != id) {
        _syncedAccount = id;
        _savePrefs();
      }
      _loadCursors();
      await _syncCycle();
      _startTimer();
      notifyListeners();
    } catch (_) {}
  }

  void disconnectSync() {
    _syncTimer?.cancel();
    unawaited(_syncSocket?.stop());
    _uploadProgress.clear();
    _mk = null;
    _remoteAccount = null;
    _online = false;
    _supabaseMode = false;
    _selfHost = false;
    _refreshToken = null;
    _accessExpiry = 0;
    _accountEmail = null;
    try {
      final scope = _syncScope ?? _syncScopeFromConfig();
      if (_configFile.existsSync()) _configFile.deleteSync();
      _deleteLegacyKeyFile();
      if (scope != null) {
        unawaited(_keyStore.deleteMasterKey(scope).catchError((_) {}));
        unawaited(_keyStore.deleteRefreshToken(scope).catchError((_) {}));
      }
    } catch (_) {}
    _syncScope = null;
    notifyListeners();
  }

  // With the doorbell live, the poll is only a safety net (missed wake, dropped
  // socket), so it widens; when the socket is down (self-host, offline, or
  // pre-connect) it stays tight so nothing is left waiting.
  Duration get _pollInterval => (_syncSocket?.connected ?? false)
      ? const Duration(seconds: 45)
      : const Duration(seconds: 8);

  /// The live-sync doorbell: a wake nudge means "pull now". Guards inside
  /// [_pullRemote] coalesce this with the periodic cycle.
  void _onWake() {
    if (_mk == null) return;
    unawaited(_pullRemote());
  }

  void _ensureSocket() {
    _syncSocket ??= SyncSocket(
      baseUrl: () => _syncUrl,
      headers: () => _h,
      onWake: _onWake,
      onConnectedChanged: (up) {
        _startTimer(); // re-arm the poll at the new cadence
        if (up) unawaited(_pullRemote()); // catch up on anything missed
      },
    );
    _syncSocket!.start();
  }

  void _startTimer() {
    _ensureSocket();
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
      _pollInterval,
      (_) => _syncCycle(),
    );
  }

  Uint8List? _readLegacyKeyBytes() {
    try {
      if (!_legacyKeyFile.existsSync()) return null;
      return Uint8List.fromList(_legacyKeyFile.readAsBytesSync());
    } catch (_) {
      return null;
    }
  }

  void _deleteLegacyKeyFile() {
    try {
      if (_legacyKeyFile.existsSync()) _legacyKeyFile.deleteSync();
    } catch (_) {}
  }

  String? _syncScopeFromConfig() {
    try {
      if (!_configFile.existsSync()) return null;
      final cfg =
          jsonDecode(_configFile.readAsStringSync()) as Map<String, dynamic>;
      return cfg['credential_scope'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _storeSyncSecrets(
      String scope, String token, Uint8List key) async {
    try {
      await _keyStore.putRefreshToken(scope, token);
      await _keyStore.putMasterKey(scope, key);
      // Read the MK back: the Windows adapter swallows CredWrite's result and
      // Keychain writes can quietly no-op, so verify before promising sync.
      final back = await _keyStore.getMasterKey(scope);
      if (!listEquals(back, key)) throw StateError('key readback mismatch');
      return true;
    } catch (_) {
      try {
        await _keyStore.deleteRefreshToken(scope);
        await _keyStore.deleteMasterKey(scope);
      } catch (_) {}
      return false;
    }
  }

  void _writeSyncConfig(
    String base,
    String scope, {
    String authMode = 'device',
    String mode = 'cloud',
    String? userId,
    String? email,
  }) {
    try {
      _configFile.writeAsStringSync(
        jsonEncode({
          'url': base,
          'credential_scope': scope,
          'token_store': Platform.isWindows
              ? 'credential_manager'
              : Platform.isLinux
                  ? 'secret_service'
                  : 'keychain',
          'auth_mode': authMode,
          // 'cloud' (Relic Cloud / managed) vs 'selfhost' (the user's own
          // server). Absent in pre-self-host configs → treated as 'cloud'.
          'mode': mode,
          'user_id': ?userId,
          'email': ?email,
        }),
      );
    } catch (_) {}
  }

  void _kickSync() {
    if (_mk == null || _db == null) return;
    notifyListeners();
    unawaited(_flushPending());
  }

  Future<void> _syncCycle() async {
    await _maybeRefresh();
    await _flushPending();
    await _pullRemote();
  }

  @override
  DateTime? get lastSyncedAt => _lastSyncAt == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(_lastSyncAt * 1000);

  @override
  bool get syncBusy =>
      // The first pull of a fresh bind is the one long sync a user actually
      // watches (a whole vault coming down), and _online is still false for
      // all of it — without this it wears the "Offline" label start to
      // finish. Gated on "never synced yet" so the periodic 30s pulls (and
      // offline retries) don't flicker the chip for the rest of the app's
      // life.
      _manualSync || (_pulling && _lastSyncAt == 0);

  /// Manual "Sync now": one full push+pull cycle with UI feedback. Safe to
  /// overlap the periodic timer — _maybeRefresh/_flushPending/_pullRemote all
  /// carry their own in-flight guards, so a collision degrades to a no-op.
  @override
  Future<void> syncNow() async {
    if (_mk == null) return;
    _manualSync = true;
    notifyListeners();
    try {
      await _syncCycle();
    } finally {
      _manualSync = false;
      notifyListeners();
    }
  }

  @override
  ({int status, int rejectedAt})? syncRejection(Relic r) {
    final rej = _db?.rejectionFor(r.uid);
    if (rej == null) return null;
    return (status: rej.status, rejectedAt: rej.rejectedAt);
  }

  @override
  void retrySync(Relic r) {
    final db = _db;
    final rej = db?.rejectionFor(r.uid);
    if (db == null || rej == null) return;
    db.queueOp(r.uid, rej.op, _now); // _queueOpInTxn clears the rejection row
    _kickSync();
  }

  @override
  void retryAllBlocked() {
    final db = _db;
    if (db == null) return;
    for (final rej in db.allRejections(limit: 500)) {
      db.queueOp(rej.uid, rej.op, _now);
    }
    _kickSync();
  }

  /// Blocked items for the sync issues sheet, newest rejection first.
  @override
  List<({Relic relic, int status, int rejectedAt})> blockedItems() {
    final db = _db;
    if (db == null) return const [];
    return [
      for (final rej in db.allRejections())
        if (db.getByUid(rej.uid) case final r?)
          (relic: r, status: rej.status, rejectedAt: rej.rejectedAt),
    ];
  }

  /// Record (or clear, when [frac] is null) a relic's blob-upload progress and
  /// notify the UI. Progress ticks are throttled to ~10/s; a clear always fires
  /// so the row leaves the "Uploading" state promptly.
  void _setUploadProgress(String uid, double? frac) {
    if (frac == null) {
      if (_uploadProgress.remove(uid) != null) notifyListeners();
      return;
    }
    _uploadProgress[uid] = frac;
    final now = DateTime.now();
    if (now.difference(_lastUploadNotify).inMilliseconds >= 100) {
      _lastUploadNotify = now;
      notifyListeners();
    }
  }

  @override
  double? uploadFraction(Relic r) => _uploadProgress[r.uid];

  @override
  double? get uploadingFraction => _uploadProgress.isEmpty
      ? null
      // least-done fraction across in-flight uploads = conservative global cue
      : _uploadProgress.values.reduce((a, b) => a < b ? a : b);

  Future<void> _flushPending() async {
    final db = _db;
    if (_flushing || db == null || _mk == null || _syncUrl == null) return;
    _flushing = true;
    var changed = false;
    var skipped = 0;
    try {
      for (final p in db.pendingOps()) {
        final result = p.op == 'push'
            ? await _flushPush(p.uid)
            : await _deleteRemote(p.uid, p.queuedAt);
        if (result.kind == _OutboundKind.retry) {
          _online = false;
          break;
        }
        if (result.kind == _OutboundKind.skip) {
          // The server answered but wouldn't take THIS op right now — leave it
          // queued and keep draining, or one bad item head-of-line blocks the
          // whole queue forever. Capped so a broken server (or expired auth)
          // doesn't burn a request per queued item every cycle.
          if (++skipped >= 10) break;
          continue;
        }
        if (result.kind == _OutboundKind.rejected) {
          db.recordSyncRejection(p.uid, p.op, result.status, _now);
        } else {
          db.clearSyncRejection(p.uid, p.op);
        }
        db.clearOp(p.uid, p.op);
        changed = true;
      }
      // Generated titles and tags this device owes its peers. Drained after the
      // relic queue on purpose: a record whose relic has not reached the server
      // yet is useless to the other devices, since they cannot apply it to a
      // row they do not have.
      await _pushAiRecords();
    } finally {
      _flushing = false;
    }
    if (changed) notifyListeners();
  }

  Future<_Outbound> _flushPush(String uid) async {
    final r = _db?.getByUid(uid);
    if (r == null) return _sent;
    return _pushRelic(r);
  }

  Future<_Outbound> _pushRelic(Relic r) async {
    if (_mk == null) return _retry;
    try {
      // upload the blob once (images/files) — chunked past 64 MiB (the edge
      // body limit; docs/cloudflare/15-large-uploads.md)
      if (r.blobKey != null && !_uploaded.contains(r.blobKey)) {
        final path = _blobPathIfExists(r.blobKey);
        if (path == null) return _rejected(0);
        final bytes = await File(path).readAsBytes();
        final wire = await RelicCrypto.sealBlob(_mk!, r.blobKey!, bytes);
        _setUploadProgress(r.uid, 0);
        try {
          await uploadBlobWire(
            endpoint: (p) => Uri.parse(_u(p)),
            headers: _h,
            blobKey: r.blobKey!,
            wire: wire,
            onProgress: (f) => _setUploadProgress(r.uid, f),
          );
        } on BlobRejected catch (e) {
          return _rejected(e.status);
        } on StateError {
          // The server answered with a transient failure (5xx after the part
          // retries) — reachable, so don't stall the queue behind this blob.
          return _skip;
        } finally {
          _setUploadProgress(r.uid, null); // clear on success, reject, or throw
        }
        // network failures fall through to the enclosing catch (offline -> retry)
        _uploaded.add(r.blobKey!);
        _saveUploaded();
      }
      final payload = {
        'kind': kindToStr(r.kind),
        'source': r.source.name,
        if (r.device != null) 'device': r.device,
        if (r.mime != null) 'mime': r.mime,
        if (r.filename != null) 'filename': r.filename,
        'tags': r.tags,
        'user_tags': r.userTags,
        if (r.title != null) 'title': r.title,
        if (r.note != null) 'note': r.note,
        if (r.content != null) 'content': r.content,
        if (r.preview != null) 'preview': r.preview,
        // Formatting flavors. Optional and additive: a client that does not
        // know the key ignores it (docs/wire-format.md, "clients ignore unknown
        // fields within a version"). Capped at 256 KB so the envelope stays
        // well inside the Worker's caps.item * 1.5 body gate.
        if (r.rich != null) 'rich': r.rich!.toJson(),
        // Attachment manifest rides inside the encrypted payload (filenames
        // never reach the server); the bundle is the single blob_key.
        if (r.attachments.isNotEmpty)
          'attachments': Attachment.listToJson(r.attachments),
      };
      final sealed = await RelicCrypto.sealRelicPayload(_mk!, r.uid, payload);
      final env = {
        'v': 1,
        'uid': r.uid,
        'created_at': r.createdAt,
        'updated_at': r.updatedAt,
        'byte_size': r.byteSize,
        'promoted': r.promoted,
        if (r.blobKey != null) 'blob_key': r.blobKey,
        'n': sealed['n'],
        'ct': sealed['ct'],
      };
      final resp = await http.put(
        Uri.parse(_u('/relic/${r.uid}')),
        headers: {..._h, 'Content-Type': 'application/json'},
        body: jsonEncode(env),
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        _online = true;
        emailUnverified.value = false;
        return _sent;
      }
      if (resp.statusCode == 403 && isEmailUnverifiedBody(resp.body)) {
        // Email not confirmed yet (VERIFY_GATE). Reachable, so keep draining;
        // leave this op queued to flush once they confirm. The banner explains.
        _online = true;
        emailUnverified.value = true;
        return _skip;
      }
      appendSyncLog(
        'push /relic -> ${resp.statusCode} '
        '${resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body}',
      );
      if (_permanentSyncStatus(resp.statusCode)) {
        return _rejected(resp.statusCode);
      }
      // Reachable but refused (401 mid-refresh, 429, 5xx) — per-item, not
      // offline: keep draining the rest of the queue.
      return _skip;
    } catch (e) {
      appendSyncLog('push /relic transport error: $e');
      _online = false;
      return _retry;
    }
  }

  Future<_Outbound> _deleteRemote(String uid, int deletedAt) async {
    if (_mk == null) return _retry;
    try {
      final resp = await http.delete(
        Uri.parse(
          _u('/relic/$uid'),
        ).replace(queryParameters: {'deleted_at': '$deletedAt'}),
        headers: _h,
      );
      if ((resp.statusCode >= 200 && resp.statusCode < 300) ||
          resp.statusCode == 404) {
        _online = true;
        return _sent;
      }
      if (_permanentSyncStatus(resp.statusCode)) {
        return _rejected(resp.statusCode);
      }
      return _skip; // reachable but refused — see _pushRelic
    } catch (_) {
      _online = false;
      return _retry;
    }
  }

  bool _permanentSyncStatus(int status) =>
      status == 400 || status == 402 || status == 409 || status == 413;

  Future<void> _pullRemote() async {
    final db = _db;
    if (_pulling || _mk == null || db == null) return;
    // First-ever pull of this bind: syncBusy is watching, so the chip has to
    // repaint on both edges. Later cycles skip the churn.
    final firstSync = _lastSyncAt == 0;
    _pulling = true;
    if (firstSync) notifyListeners();
    try {
      var changed = false;
      var maxU = _cursor;
      String? cursor;
      do {
        final q = {
          'since': '$_cursor',
          'limit': '500',
          'cursor': ?cursor,
        };
        final resp = await http.get(
          Uri.parse(_u('/relics')).replace(queryParameters: q),
          headers: _h,
        );
        if (resp.statusCode != 200) {
          appendSyncLog(
            'pull /relics -> ${resp.statusCode} '
            '${resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body}',
          );
          _online = false;
          return;
        }
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final items = (body['items'] as List).cast<Map<String, dynamic>>();
        for (final env in items) {
          final u = (env['updated_at'] as num).toInt();
          if (u > maxU) maxU = u;
          final r = await _decryptEnv(env);
          if (r != null && _mergeRemote(r)) changed = true;
        }
        cursor = body['next_cursor'] as String?;
      } while (cursor != null);
      if (maxU - 1 > _cursor) _cursor = maxU - 1;

      final tr = await http.get(
        Uri.parse(
          _u('/tombstones'),
        ).replace(queryParameters: {'since': '$_tombCursor'}),
        headers: _h,
      );
      if (tr.statusCode == 200) {
        final items = (jsonDecode(tr.body)['items'] as List)
            .cast<Map<String, dynamic>>();
        var tmax = _tombCursor;
        for (final t in items) {
          final d = (t['deleted_at'] as num).toInt();
          if (d > tmax) tmax = d;
          final uid = t['uid'] as String;
          db.clearOpsForUid(uid);
          db.clearSyncRejection(uid, 'push');
          db.clearSyncRejection(uid, 'delete');
          changed = true;
          final existing = db.getByUid(uid);
          if (existing != null) {
            final bk = existing.blobKey;
            if (bk != null) {
              try {
                final f = File(_blobFilePath(bk));
                if (f.existsSync()) f.deleteSync();
              } catch (_) {}
            }
            db.delete(uid);
            _vec.remove(uid);
            changed = true;
          }
        }
        if (tmax - 1 > _tombCursor) _tombCursor = tmax - 1;
      }
      // AI records last: they merge INTO relics, so pulling them after the
      // relics in the same cycle means a freshly-arrived item gets its title in
      // the same pass rather than a cycle later.
      if (await _pullAiRecords()) changed = true;
      // And records whose relic only just showed up (either arrival order is
      // normal — they ride independent cursors).
      if (_applyPendingAiRecords(db)) changed = true;
      _online = true;
      _lastSyncAt = _now;
      await _fetchAccount();
      _saveCursors();
      if (changed) _refreshWindow();
      notifyListeners();
      _prefetchPhotos(); // pull image bytes eagerly so thumbnails appear
    } catch (_) {
      _online = false;
    } finally {
      _pulling = false;
      if (firstSync) notifyListeners();
    }
  }

  /// Upsert a pulled relic into SQLite if it's new or strictly newer (LWW).
  bool _mergeRemote(Relic r) {
    final db = _db!;
    // Locally deleted with the tombstone still in flight: a pull snapshot
    // from before the delete must not resurrect the row.
    if (db.hasPendingDelete(r.uid)) return false;
    // A peer's payload carries the tags IT knows — machine tags this user
    // explicitly removed (suppressed locally) must not ride back in via LWW.
    // Suppression is stored lowercased; compare case-blind.
    final suppressed = db.suppressedTags(r.uid).toSet();
    if (suppressed.isNotEmpty &&
        r.tags.any((t) => suppressed.contains(t.toLowerCase()))) {
      r = r.copyWith(
        tags: [
          for (final t in r.tags)
            if (!suppressed.contains(t.toLowerCase())) t,
        ],
      );
    }
    final existing = db.updatedAtOf(r.uid);
    if (existing == null) {
      db.upsert(r);
      db.clearSyncRejection(r.uid, 'push');
      return true;
    }
    if (r.updatedAt > existing) {
      db.upsert(r);
      db.clearSyncRejection(r.uid, 'push');
      return true;
    }
    return false;
  }

  /// Eagerly download blobs for synced *photo* relics whose bytes aren't local
  /// yet, so their thumbnails show in the list without opening each one. Files
  /// stay lazy (download on view/copy). Bounded to a few fetches per cycle.
  void _prefetchPhotos() {
    final db = _db;
    if (db == null || _mk == null) return;
    for (final p in db.photosMissingBlob(8)) {
      if (_fetching.length >= 4) break;
      if (_blobPathIfExists(p.blobKey) != null) {
        db.markBlobLocal(p.uid); // already on disk; clear the flag
        continue;
      }
      if (_fetching.contains(p.blobKey)) continue;
      final r = db.getByUid(p.uid);
      if (r != null) ensureBlob(r); // unawaited
    }
  }

  // --- on-device ML enrichment (sift sidecar) ---

  void _startEnrichWorker() {
    _enrichTimer?.cancel();
    _enrichTimer = Timer.periodic(
      const Duration(seconds: 6),
      (_) => _enrichCycle(),
    );
  }

  /// Classify a batch of saved (promoted) relics through the sift sidecar and
  /// merge the results — extra tags for everything, OCR/caption text + a better
  /// preview for images. Degrades to Stage-A while the models download. Mirrors
  /// relic-app's enricher: scoped to the vault, idempotent via enrich_level,
  /// and it never clobbers the user's title/note/user_tags.
  Future<void> _enrichCycle() async {
    final sift = _sift;
    final db = _db;
    if (_enriching || !_mlEnrich || sift == null || db == null) return;
    _enriching = true;
    // Claimed but not yet done. Held out here rather than inside the try so the
    // finally can hand it back even when a pass throws part-way.
    final unfinished = <String>{};
    try {
      // First cycle (and after each download) we re-check model readiness.
      if (!sift.modelsReady && !_downloadingModels) {
        await sift.checkModels();
        if (!sift.modelsReady) {
          _downloadingModels = true;
          notifyListeners();
          // background fetch; a later cycle upgrades Stage-A → full ML
          unawaited(
            sift.downloadModels(label: _describeItems).then((_) {
              _downloadingModels = false;
              notifyListeners();
            }),
          );
        }
      }
      final target = sift.modelsReady ? _levelMl : _levelStageA;
      // The settings "tagging N items…" progress line, refreshed per cycle.
      // The number jumps when models become ready (target 1 → 3): correct —
      // the full-ML pass really does revisit the corpus.
      final backlog = db.countNeedingEnrich(target);
      var changed = backlog != _enrichBacklog;
      _enrichBacklog = backlog;
      final found = db.needingEnrich(target, 12);
      // Claim before spending anything. Whatever a peer is already working on,
      // or has already finished, this device must not touch: that is what stops
      // two desktops burning the same generative pass and landing on two
      // different titles for one item.
      //
      // Only the ML pass is coordinated. Stage-A is heuristics over text the
      // device already has: cheap, and deterministic enough that every device
      // reaches the same answer, so there is nothing to divide up and a claim
      // round trip would be pure latency.
      final batch = aiCapable
          ? await _claimAiWork(found, target)
              .then((g) => [for (final r in found) if (g.contains(r.uid)) r])
          : found;
      // Drive the per-row "Analyzing…" spinner. The whole batch lights up, not
      // just the item in flight: everything here is queued and will be picked
      // up in this pass, and a row that sat blank for a few seconds before
      // spinning would read as "nothing is happening".
      if (batch.isNotEmpty) {
        _analyzing = batch.map((r) => r.uid).toSet();
        notifyListeners();
      }
      if (aiCapable) unfinished.addAll(batch.map((r) => r.uid));
      for (final r in batch) {
        if (await _enrichOne(sift, r, target)) changed = true;
        unfinished.remove(r.uid);
        // Clear per item so the spinner retreats down the list as it goes.
        if (_analyzing.remove(r.uid)) notifyListeners();
      }
      // Embed anything a peer generated for us. Deliberately after the batch:
      // generating is the scarce work, indexing is the cheap work, and the
      // cheap work must never delay the scarce work.
      if (sift.modelsReady && await _backfillVectors(sift, 8)) changed = true;
      if (changed) {
        _refreshWindow();
        notifyListeners();
      }
    } finally {
      _enriching = false;
      // Anything claimed but not finished (a throw mid-batch, the models
      // unloaded under us) goes back to the pool now, instead of sitting locked
      // until the lease expires and leaving a peer idle in the meantime.
      if (unfinished.isNotEmpty) unawaited(_releaseAiWork(unfinished));
      // A throw mid-batch must not strand spinners on rows forever.
      if (_analyzing.isNotEmpty) {
        _analyzing = {};
        notifyListeners();
      }
    }
  }

  /// Consecutive per-uid enrich failures (in-memory). After [_enrichMaxFails]
  /// the item's level is force-set so one bad item can't stall the newest-first
  /// batch forever; a restart clears the counter and retries.
  final Map<String, int> _enrichFails = {};
  static const int _enrichMaxFails = 5;

  bool _enrichFailed(RelicDb db, String uid, int level) {
    final n = (_enrichFails[uid] ?? 0) + 1;
    _enrichFails[uid] = n;
    if (n >= _enrichMaxFails) db.setEnrichLevel(uid, level);
    return false;
  }

  /// Uids whose embedding attempt produced nothing this session, so a text the
  /// embedder will not take (or a sidecar that keeps failing on it) does not
  /// come back every six seconds. Cleared by a restart, which is the right
  /// cadence for retrying something that may have been a transient fault.
  final Set<String> _embedSkip = {};

  /// The document this device embeds for [r].
  ///
  /// Kept deliberately in step with the composition in [_enrichOne]: a vector
  /// is only worth anything if it means the same thing on every device, and
  /// two machines embedding different documents for one item would rank the
  /// same query differently.
  static String embedDocFor(Relic r) => r.kind == Kind.string
      // Title and note carry the strongest search intent, so they are part of
      // the embedded document rather than metadata beside it.
      ? [r.title, r.note, r.content]
          .whereType<String>()
          .where((x) => x.trim().isNotEmpty)
          .join('\n')
      // Everything else embeds the text that was read out of it. On the device
      // that ran the models that text came from OCR or document extraction;
      // here it arrived in an AI record, which is the whole point.
      : (r.content ?? '').trim();

  /// Give the local semantic index the items whose models ran on another
  /// device. Returns whether anything landed.
  ///
  /// No claim and no publish: an embedding is per-device state, like the FTS
  /// rows next to it. Two devices doing this in parallel is not duplicated work
  /// in the sense the claim exists to prevent, because neither result travels.
  Future<bool> _backfillVectors(SiftSidecar sift, int limit) async {
    final db = _db;
    // With embeddings off the user has opted out of the semantic leg entirely;
    // building an index they asked not to have would be spending their battery
    // to ignore the result.
    if (db == null || !_aiEmbeddings) return false;
    var changed = false;
    for (final r in db.needingVectors(_levelMl, limit)) {
      if (_disposed) break;
      if (_embedSkip.contains(r.uid)) continue;
      final doc = embedDocFor(r);
      if (doc.isEmpty) {
        _embedSkip.add(r.uid);
        continue;
      }
      // label: false is the point of the whole pass. The caption and the tags
      // already exist and travelled here; re-running the labeler would spend
      // minutes to produce a second, different answer to a settled question.
      final res = await sift.classifyText(doc, ml: true, label: false);
      final vec = res?.textVector;
      if (vec == null || vec.isEmpty) {
        _embedSkip.add(r.uid);
        continue;
      }
      final chunks = [vec, ...?res?.textChunkVectors];
      db.upsertVectors(r.uid, chunks);
      _vec[r.uid] = [for (final c in chunks) Float32List.fromList(c)];
      changed = true;
    }
    return changed;
  }

  Future<bool> _enrichOne(SiftSidecar sift, Relic r, int level) async {
    final db = _db!;
    final ml = sift.modelsReady;
    SiftResult? res;
    if (r.kind == Kind.string) {
      // Embed what the user knows the item AS, not just its raw content:
      // title and note carry the strongest search intent ("Stripe webhook
      // retry logic" on a code snippet), so they join the embedded document.
      final t = [r.title, r.note, r.content]
          .whereType<String>()
          .where((x) => x.trim().isNotEmpty)
          .join('\n');
      if (t.trim().isEmpty) {
        db.setEnrichLevel(r.uid, level);
        return false;
      }
      res = await sift.classifyText(
        t,
        ml: ml,
        // Text gets labeled too, not just images: most of a vault IS text, and
        // it is where the taxonomy gap actually lives (74% of items carried no
        // subject tag). Vault-only by default — a second per item is not worth
        // spending on a clipboard line nobody saved — unless the user opts the
        // whole stream in.
        label: shouldLabelText(
          describeItems: _describeItems,
          describeEverything: _describeEverything,
          promoted: r.promoted,
        ),
        embeddings: _aiEmbeddings,
      );
    } else if (r.kind == Kind.photo || r.kind == Kind.file) {
      final ok = await ensureBlob(r);
      final path = _blobPathIfExists(r.blobKey);
      if (!ok || path == null) {
        return _enrichFailed(db, r.uid, level); // blob not here → retry later
      }
      res = await sift.classifyPath(
        path,
        ml: ml,
        kind: r.kind == Kind.photo ? 'image' : 'file',
        // Photos are labeled in stream and vault alike: a text-less image is
        // otherwise unfindable, which is not true of a text clipping.
        label: _describeItems && r.kind == Kind.photo,
        ocr: _aiOcr,
        imageTags: _aiImageTags,
        embeddings: _aiEmbeddings,
      );
    } else {
      db.setEnrichLevel(r.uid, level);
      return false;
    }
    if (res == null) {
      return _enrichFailed(db, r.uid, level); // sidecar failed → retry
    }
    _enrichFails.remove(r.uid);

    // Re-read the latest row BEFORE writing anything: if the relic was deleted
    // while we classified, writing now would resurrect it (orphan vectors +
    // an undead row racing its own tombstone).
    final cur = db.getByUid(r.uid);
    if (cur == null) return false;

    // Persist the document embedding(s) for semantic / hybrid search: the
    // whole-doc vector first, then the extra chunks. Those cover long
    // documents AND the generated title, which sift emits as its own chunk
    // rather than mixing into the doc vector, so chunk 0 keeps meaning the
    // same thing it meant in every previously-indexed vault. Search takes the
    // max across an item's chunks, so this needs nothing on the query side.
    var wroteVector = false;
    if (res.textVector != null && res.textVector!.isNotEmpty) {
      final chunks = [res.textVector!, ...?res.textChunkVectors];
      db.upsertVectors(r.uid, chunks);
      _vec[r.uid] = [for (final c in chunks) Float32List.fromList(c)];
      wroteVector = true;
    }

    // Machine tags the user explicitly removed stay removed.
    final suppressed = db.suppressedTags(r.uid).toSet();
    // Open-vocabulary tags are unbounded, so they never reach a relic raw:
    // near-duplicates snap onto one representative and a representative has to
    // recur before it earns a chip. Canonical forms are what get stored, and
    // provisional ones are stored too — search should find them the first time,
    // it is only the chip that waits.
    final boundLabelTags = await _boundLabelTags(db, res.labelTags);
    // Friendly extension chips (backfills older file relics captured before the
    // type map existed). The sift sidecar's generic "file"/"archive"/"binary"
    // category tags are dropped for files — the ext chips are clearer.
    final extChips = r.kind == Kind.file
        ? fileTypeChips(cur.filename)
        : const <String>[];
    // Deterministic tags from the OCR/extracted text of an image or document, so
    // a screenshot of an invoice is findable by "number"/"currency"/etc. — not
    // just by its pixels. Content-shape tags (code/json/markdown) are noise on a
    // whole image/doc, and `secret` honors the mask preference.
    const ocrTagBlocklist = {'code', 'json', 'markdown'};
    final ocrText =
        r.kind == Kind.string ? '' : (res.extractedText?.trim() ?? '');
    final textTags = ocrText.isEmpty
        ? const <String>[]
        : detectTags(ocrText).where(
            (t) =>
                !ocrTagBlocklist.contains(t) &&
                (_maskSecrets || t != 'secret'),
          );
    // What the MODELS contributed, before this device's own dedupe and
    // suppression is applied. This is the set that travels in the AI record:
    // a peer has its own suppressed tags and its own existing chips, so it has
    // to do that filtering itself rather than inherit ours. Extension chips are
    // deliberately absent — those are derived from the filename, so every
    // device already produces them identically and shipping them would be pure
    // wire weight.
    final aiTags = <String>[];
    final aiSeen = <String>{};
    for (final t in [
      ...boundLabelTags,
      ...res.relicTags.where(
        (t) =>
            (_maskSecrets || t != 'secret') &&
            // sift's content-shape tags are noise on a whole image/document
            // (the v2 migration scrubbed exactly this class once already).
            !(r.kind != Kind.string && ocrTagBlocklist.contains(t)) &&
            !(r.kind == Kind.file && _genericFileTags.contains(t)),
      ),
      ...textTags.where((t) => !(r.kind == Kind.file && _genericFileTags.contains(t))),
    ]) {
      // Cross-source dedupe: the labeler and the classifier can land on the
      // same word, and only the per-source checks below caught that before.
      if (aiSeen.add(t.toLowerCase())) aiTags.add(t);
    }

    // Case-insensitive views for dedupe: extension chips are Capitalized
    // ("Markdown") while sift/detector tags are lowercase ("markdown") — an
    // exact-case check let both land on one relic as duplicate-looking chips.
    final curLower = cur.tags.map((t) => t.toLowerCase()).toSet();
    final extLower = extChips.map((t) => t.toLowerCase()).toSet();
    final tags = <String>[
      ...cur.tags,
      ...extChips.where((t) =>
          !curLower.contains(t.toLowerCase()) &&
          !suppressed.contains(t.toLowerCase())),
      ...aiTags.where(
        (t) =>
            !curLower.contains(t.toLowerCase()) &&
            !extLower.contains(t.toLowerCase()) &&
            !suppressed.contains(t.toLowerCase()),
      ),
    ];
    var content = cur.content;
    var preview = cur.preview;
    var title = cur.title;
    if (r.kind != Kind.string) {
      final tx = res.extractedText?.trim();
      if (tx != null && tx.isNotEmpty) content = tx; // OCR/caption → searchable
      // A file keeps its filename as the headline — never rename it to the first
      // line of its extracted text. Only photos (which have no filename) adopt
      // sift's text/caption preview.
      if (r.kind != Kind.file && res.preview.trim().isNotEmpty) {
        preview = res.preview.trim();
      }
    }
    // Deliberately outside the block above: that one is for extracted text, and
    // its `kind != string` guard would make this unreachable for the text the
    // labeler now handles.
    title = titleAfterLabel(kind: r.kind, current: cur.title, caption: res.caption);

    // Record what the models produced as a document of its own, so it can reach
    // the user's other devices. Without this the whole pass is a local side
    // effect: the title shows up on the machine that happened to run the models
    // and nowhere else, and every other device re-runs them to get its own
    // (different) answer. Note this stores what the AI SAID, not what landed on
    // the row — if the user had already titled the item, `title` above keeps
    // their name while the record still carries the generated one, so a peer
    // that has no title yet can still use it.
    final aiCaption = res.caption?.trim();
    final rec = AiRecord(
      uid: r.uid,
      at: _now,
      level: level,
      by: _deviceId,
      title: (aiCaption != null && aiCaption.isNotEmpty) ? aiCaption : null,
      tags: aiTags,
      // What the models READ, not just what they said about it. Without this a
      // screenshot of an invoice is findable by its text on this desk and
      // nowhere else, because OCR output lands in the relic's content column
      // and that column only travels on a user edit.
      text: ocrText.isEmpty ? null : ocrText,
    );
    // An empty record would still claim its uid under earliest-wins and then
    // lock every other device out of producing a real one.
    //
    // Only the ML pass publishes. Stage-A output is heuristics over text the
    // peer already has, so it would derive the same tags itself: sending them
    // is wire traffic that buys nothing, and it would put a placeholder record
    // in front of the real one.
    if (!rec.isEmpty) {
      db.putAiRecord(rec, needsPush: syncEnabled && ml);
    }

    final changed =
        tags.length != cur.tags.length ||
        content != cur.content ||
        preview != cur.preview ||
        title != cur.title;
    if (changed) {
      // copyWith so every untouched field (attachments, note, …) survives —
      // enrichment must never drop data it doesn't rewrite. updatedAt is
      // deliberately left alone (local-only enrichment: don't disturb LWW).
      db.upsert(
        cur.copyWith(
          tags: tags,
          title: title,
          content: content,
          preview: preview,
        ),
      );
    }
    db.setEnrichLevel(r.uid, level);
    // A vector-only write also counts as a change: the caller's notify is what
    // flips the settings status off "keyword-only" when the first vector lands.
    return changed || wroteVector;
  }

  // --- AI records: sharing the models' output across devices ---
  //
  // The models run on whichever device can run them, and the result reaches all
  // of them. Two things have to be true for that to work:
  //
  //   * only one device does the work for a given item, or you pay for the same
  //     generative pass N times and get N different titles (the labeler is not
  //     deterministic across machines), and
  //   * the result travels without touching the relic's updated_at, or every
  //     background tagging pass looks like a user edit.
  //
  // The first is the claim lease, the second is the separate record. See
  // worker/src/ai.ts.

  /// Whether this device should be doing AI work at all.
  ///
  /// Phones never are, and low-powered laptops may never be: the models are
  /// gigabytes of weights and minutes of compute. A big desktop does the work
  /// and everyone else consumes the result. This is a capability, deliberately
  /// not a preference — the user should not have to nominate a machine, and
  /// nominating one that is asleep would stall the whole account.
  bool get aiCapable {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return false;
    }
    return _mlEnrich && (_sift?.modelsReady ?? false);
  }

  /// Ask the server which of [batch] this device should work on.
  ///
  /// Returns the uids we won. Anything a peer is already working on, or has
  /// already finished at this level or better, is excluded — those we either
  /// leave alone or mark done locally so they stop coming back every cycle.
  ///
  /// Offline (or on a self-host build with no account) there is no coordinator,
  /// so the whole batch is granted: a single-device vault must keep working
  /// exactly as it does today, and duplicate work is impossible with one device.
  Future<Set<String>> _claimAiWork(List<Relic> batch, int level) async {
    final db = _db;
    if (db == null) return batch.map((r) => r.uid).toSet();
    if (!syncEnabled || _mk == null || (_deviceId?.isEmpty ?? true)) {
      return batch.map((r) => r.uid).toSet();
    }
    try {
      final resp = await http
          .post(
            Uri.parse(_u('/ai/claim')),
            headers: {..._h, 'Content-Type': 'application/json'},
            body: jsonEncode({
              'items': [
                for (final r in batch) {'uid': r.uid, 'level': level},
              ],
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        // The coordinator is unreachable or unhappy. Working anyway is the
        // right failure mode: a duplicate title is a far smaller problem than
        // a vault that silently stops tagging whenever the server hiccups.
        return batch.map((r) => r.uid).toSet();
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final granted = (body['granted'] as List?)?.cast<String>().toSet() ?? {};
      // A peer already finished these. Adopt its level so this device stops
      // asking; the content itself arrives on the next AI pull.
      for (final d in (body['done'] as List?) ?? const []) {
        final m = (d as Map).cast<String, dynamic>();
        final uid = m['uid'] as String?;
        final lv = (m['level'] as num?)?.toInt();
        if (uid != null && lv != null) db.raiseEnrichLevel(uid, lv);
      }
      return granted;
    } catch (_) {
      return batch.map((r) => r.uid).toSet(); // offline — see above
    }
  }

  /// Hand back leases we won but did not use, so a peer can pick them up in
  /// seconds rather than waiting out the lease. Best-effort by design: every
  /// lease expires on its own, so a failure here costs latency, never work.
  Future<void> _releaseAiWork(Iterable<String> uids) async {
    final list = uids.toList();
    if (list.isEmpty || !syncEnabled || _mk == null) return;
    try {
      await http
          .post(
            Uri.parse(_u('/ai/release')),
            headers: {..._h, 'Content-Type': 'application/json'},
            body: jsonEncode({'uids': list}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// One-time reconciliation of AI titles that predate AI records.
  ///
  /// Two machines that both enriched this vault each hold their own titles,
  /// generated independently and never shared. This publishes what is already
  /// here so they converge on one answer. It runs no models and generates
  /// nothing new: the deliberate backfill of never-titled items is a separate
  /// decision, not this.
  void _convergeAiRecords() {
    final db = _db;
    if (db == null || _aiConverged || !syncEnabled || _mk == null) return;
    // Mark it done first. A crash mid-seed leaves whatever landed already
    // queued and correct, whereas retrying forever on a vault that trips the
    // insert would re-scan the corpus on every launch.
    _aiConverged = true;
    _savePrefs();
    try {
      db.seedAiRecordsFromRelics(minLevel: _levelMl, by: _deviceId);
    } catch (_) {}
  }

  /// Publish the AI records this device generated and still owes the server.
  Future<void> _pushAiRecords() async {
    final db = _db;
    if (db == null || !syncEnabled || _mk == null) return;
    _convergeAiRecords();
    for (final rec in db.aiRecordsNeedingPush(limit: 25)) {
      try {
        final sealed =
            await RelicCrypto.sealAiPayload(_mk!, rec.uid, rec.toPayload());
        final resp = await http.put(
          Uri.parse(_u('/ai/${rec.uid}')),
          headers: {..._h, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'v': 1,
            'uid': rec.uid,
            'ai_at': rec.at,
            'level': rec.level,
            'n': sealed['n'],
            'ct': sealed['ct'],
          }),
        );
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          // Settled either way: `stale: true` means a peer's result won, which
          // is an answer, not a failure. Retrying would loop forever.
          db.markAiPushed(rec.uid);
          _online = true;
        } else if (_permanentSyncStatus(resp.statusCode)) {
          // Malformed or over cap: it will never be accepted, so stop owing it
          // rather than retrying every cycle for the life of the vault.
          db.markAiPushed(rec.uid);
        } else {
          return; // reachable but refused (401 mid-refresh, 429, 5xx) — retry
        }
      } catch (_) {
        _online = false;
        return; // offline: keep the rest queued
      }
    }
  }

  /// Pull AI records produced by this account's other devices.
  Future<bool> _pullAiRecords() async {
    final db = _db;
    if (db == null || !syncEnabled || _mk == null) return false;
    var changed = false;
    try {
      var maxAt = _aiCursor;
      String? cursor;
      do {
        final resp = await http.get(
          Uri.parse(_u('/ai')).replace(queryParameters: {
            'since': '$_aiCursor',
            'limit': '500',
            'cursor': ?cursor,
          }),
          headers: _h,
        );
        if (resp.statusCode != 200) return changed;
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final items = (body['items'] as List).cast<Map<String, dynamic>>();
        for (final env in items) {
          final at = (env['ai_at'] as num).toInt();
          if (at > maxAt) maxAt = at;
          final uid = env['uid'] as String;
          final p = await RelicCrypto.openAiPayload(
              _mk!, uid, env['n'] as String, env['ct'] as String);
          if (p == null) continue; // not ours to read, or tampered with
          final rec = AiRecord.fromWire(env, p);
          // Already published by definition — never echo it back.
          if (!db.putAiRecord(rec, needsPush: false)) continue;
          if (_applyAiRecord(db, rec)) changed = true;
        }
        cursor = body['next_cursor'] as String?;
      } while (cursor != null);
      // Same off-by-one guard the relic cursor uses: rewind a second so a
      // record written in the same second as the cursor is not skipped.
      if (maxAt - 1 > _aiCursor) _aiCursor = maxAt - 1;
    } catch (_) {
      _online = false;
    }
    return changed;
  }

  /// Merge an AI record into its relic. Returns whether the row changed.
  ///
  /// Returns false when the relic is not here yet: records and relics ride
  /// independent cursors, so either arrival order is normal. The record stays
  /// stored and [_applyPendingAiRecords] picks it up once the relic lands.
  bool _applyAiRecord(RelicDb db, AiRecord rec) {
    final cur = db.getByUid(rec.uid);
    if (cur == null) return false;
    final merged = mergeAiRecord(
      cur: cur,
      rec: rec,
      suppressed: db.suppressedTags(rec.uid).toSet(),
    );
    // Attachment text sits in a column of its own rather than on the relic, so
    // it is applied separately and reindexes itself.
    final attChanged =
        rec.att != null && db.applyAttachmentText(rec.uid, rec.att!);
    final changed = merged.tags.length != cur.tags.length ||
        merged.title != cur.title ||
        merged.content != cur.content;
    if (changed) {
      // No queuePush and no updatedAt bump: AI output travels as its own
      // record, so writing it here must not look like a user edit.
      //
      // The content write is what puts a peer's OCR into this device's search
      // index — upsert re-derives the FTS rows, so the text is findable here
      // the moment it lands, without this machine ever opening the image.
      db.upsert(cur.copyWith(
        tags: merged.tags,
        title: merged.title,
        content: merged.content,
      ));
    }
    // The point of the whole exercise: this device now considers the item done
    // and will not run the models on it.
    db.raiseEnrichLevel(rec.uid, rec.level);
    return changed || attChanged;
  }

  /// Apply records whose relic has since arrived (or which predate a level bump
  /// on this device). Cheap indexed lookup; runs once per sync cycle.
  bool _applyPendingAiRecords(RelicDb db) {
    var changed = false;
    for (final uid in db.aiRecordsUnapplied()) {
      final rec = db.aiRecord(uid);
      if (rec != null && _applyAiRecord(db, rec)) changed = true;
    }
    return changed;
  }

  Future<Relic?> _decryptEnv(Map<String, dynamic> env) async {
    final p = await RelicCrypto.openRelicPayload(_mk!, env);
    if (p == null) return null;
    final blobKey = env['blob_key'] as String?;
    if (blobKey != null) _uploaded.add(blobKey); // already on the Worker
    return Relic(
      uid: env['uid'] as String,
      createdAt: (env['created_at'] as num).toInt(),
      updatedAt: (env['updated_at'] as num).toInt(),
      kind: kindFromStr(p['kind'] as String? ?? 'string'),
      source: sourceFromStr(p['source'] as String? ?? 'api'),
      promoted: env['promoted'] as bool? ?? false,
      byteSize: (env['byte_size'] as num?)?.toInt() ?? 0,
      device: p['device'] as String?,
      mime: p['mime'] as String?,
      filename: p['filename'] as String?,
      blobKey: blobKey,
      tags: (p['tags'] as List?)?.cast<String>() ?? const [],
      userTags: (p['user_tags'] as List?)?.cast<String>() ?? const [],
      title: p['title'] as String?,
      note: p['note'] as String?,
      content: p['content'] as String?,
      preview: p['preview'] as String?,
      attachments: Attachment.listFrom(p['attachments']),
      rich: RichBody.fromJson(p['rich']),
    );
  }

  Future<void> _fetchAccount() async {
    try {
      final a = await http.get(Uri.parse(_u('/account')), headers: _h);
      if (a.statusCode == 200) {
        final j = jsonDecode(a.body) as Map<String, dynamic>;
        _remoteAccount = AccountInfo(
          tier: const {'pro': 'Pro', 'max': 'Max'}[j['tier']] ?? 'Free',
          usedBytes: (j['storage_used'] as num).toInt(),
          quotaBytes: (j['storage_quota'] as num).toInt(),
          vaultCount: (j['vault_count'] as num).toInt(),
          vaultCap: (j['vault_cap'] as num?)?.toInt(),
        );
      }
    } catch (_) {}
  }

  // --- billing (Upgrade / Manage), backed by the Worker /stripe/* routes ---
  @override
  Future<List<BillingPlan>> billingPlans() async {
    if (_syncUrl == null) return const [];
    try {
      final r = await http.get(Uri.parse(_u('/stripe/plans')), headers: _h);
      if (r.statusCode != 200) return const [];
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return [
        for (final p in (j['plans'] as List? ?? const []))
          BillingPlan.fromJson(p as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<String?> checkoutUrl(String priceId) async {
    if (_syncUrl == null) return null;
    await _maybeRefresh();
    final r = await _billingPost(
      '/stripe/checkout',
      headers: {..._h, 'Content-Type': 'application/json'},
      body: jsonEncode({'price_id': priceId}),
    );
    final url = (jsonDecode(r.body) as Map<String, dynamic>)['url'] as String?;
    if (url == null) {
      throw const BillingException('Billing returned no checkout link.');
    }
    return url;
  }

  @override
  Future<String?> portalUrl() async {
    if (_syncUrl == null) return null;
    await _maybeRefresh();
    final r = await _billingPost('/stripe/portal', headers: _h);
    final url = (jsonDecode(r.body) as Map<String, dynamic>)['url'] as String?;
    if (url == null) {
      throw const BillingException('Billing returned no portal link.');
    }
    return url;
  }

  /// POST a billing route; anything but a 200 becomes a [BillingException]
  /// whose message the settings pane can show verbatim.
  Future<http.Response> _billingPost(
    String path, {
    required Map<String, String> headers,
    String? body,
  }) async {
    final http.Response r;
    try {
      r = await http.post(Uri.parse(_u(path)), headers: headers, body: body);
    } catch (_) {
      throw const BillingException(
          'Could not reach the billing service. Check your connection.');
    }
    if (r.statusCode == 200) return r;
    String? code, message;
    try {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      code = j['error'] as String?;
      message = j['message'] as String?;
    } catch (_) {}
    throw BillingException(switch (code) {
      'no_subscription' =>
        'No subscription to manage yet. Upgrade first, then manage your plan here.',
      'billing_unconfigured' => 'Billing is not available right now.',
      'rate_limited' => 'Too many attempts. Try again in a minute.',
      'unauthorized' =>
        'Your session has expired. Reconnect sync, then try again.',
      _ => message ?? 'Billing request failed (HTTP ${r.statusCode}).',
    });
  }

  void _saveCursors() {
    try {
      // Third field: last successful pull time, so "Last synced" survives a
      // restart. Written exactly once per successful pull, same cadence as
      // the cursors themselves.
      // Fourth field: the AI-record cursor. Appended rather than folded in, so
      // a file written by an older build still parses (its AI cursor reads 0,
      // which just re-pulls records that are idempotent to apply anyway).
      _cursorFile
          .writeAsStringSync('$_cursor,$_tombCursor,$_lastSyncAt,$_aiCursor');
    } catch (_) {}
  }

  void _loadCursors() {
    try {
      if (_cursorFile.existsSync()) {
        final parts = _cursorFile.readAsStringSync().split(',');
        _cursor = int.tryParse(parts[0]) ?? 0;
        if (parts.length > 1) _tombCursor = int.tryParse(parts[1]) ?? 0;
        if (parts.length > 2) _lastSyncAt = int.tryParse(parts[2]) ?? 0;
        if (parts.length > 3) _aiCursor = int.tryParse(parts[3]) ?? 0;
      }
    } catch (_) {}
  }

  // --- helpers ---
  static String _preview(String t) {
    final line = t
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return line.length > 200 ? '${line.substring(0, 200)}…' : line;
  }

  /// Deterministic subtype tags (SPEC §5), client-side and instant — the same
  /// vocabulary the core's Stage-A emits, so the whole stream (not just the
  /// enriched vault) is richly faceted at capture time. The heuristics live in
  /// the shared [detectTags] (heuristic_tags.dart) so the mobile lens stays in
  /// lockstep.
  static List<String> _detectTags(String t) => detectTags(t);

  static Relic _fromJson(Map<String, dynamic> j) => Relic(
    uid: j['uid'] as String,
    createdAt: (j['created_at'] as num).toInt(),
    updatedAt:
        (j['updated_at'] as num?)?.toInt() ?? (j['created_at'] as num).toInt(),
    kind: kindFromStr(j['kind'] as String? ?? 'string'),
    source: sourceFromStr(j['source'] as String? ?? 'clipboard'),
    promoted: j['promoted'] as bool? ?? false,
    byteSize: (j['byte_size'] as num?)?.toInt() ?? 0,
    device: j['device'] as String?,
    mime: j['mime'] as String?,
    filename: j['filename'] as String?,
    blobKey: j['blob_key'] as String?,
    tags: (j['tags'] as List?)?.cast<String>() ?? const [],
    userTags: (j['user_tags'] as List?)?.cast<String>() ?? const [],
    title: j['title'] as String?,
    note: j['note'] as String?,
    content: j['content'] as String?,
    preview: j['preview'] as String?,
    attachments: Attachment.listFrom(j['attachments']),
    rich: RichBody.fromJson(j['rich']),
  );
}

/// sent: on the server, clear the op. rejected: server permanently refused,
/// clear the op and record it — [status] carries the HTTP code that refused
/// (0 = the blob file was missing locally), which feeds the "Not synced"
/// reason UI. skip: server reachable but this op failed non-permanently —
/// leave it queued, keep draining. retry: offline — stop the whole flush and
/// try again next cycle.
enum _OutboundKind { sent, retry, skip, rejected }

typedef _Outbound = ({_OutboundKind kind, int status});

const _Outbound _sent = (kind: _OutboundKind.sent, status: 0);
const _Outbound _retry = (kind: _OutboundKind.retry, status: 0);
const _Outbound _skip = (kind: _OutboundKind.skip, status: 0);
_Outbound _rejected(int status) => (kind: _OutboundKind.rejected, status: status);
