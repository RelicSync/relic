import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hashlib/hashlib.dart' show sha256sum;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../platform/clipboard_bridge.dart';
import '../models/relic.dart';
import '../widgets/chrome.dart';
import 'blob_upload.dart';
import 'boot_trace.dart';
import 'bundle.dart';
import 'package:relic_crypto/relic_crypto.dart';
import 'file_types.dart';
import 'heuristic_tags.dart';
import 'net.dart';
import 'personal_store.dart';
import 'recovery.dart';
import 'relic_db.dart';
import 'repo.dart';
import 'supabase_auth.dart';
import 'sync_socket.dart';

/// RelicRepo backed by the deployed Cloudflare Worker (docs/api.md), with
/// client-side E2E crypto. Wire-compatible with relic-core (verified against
/// the pinned Argon2id vector + AEAD round-trip in test/crypto_test.dart).
///
/// Sync model (mirrors the desktop repo, see local_desk_repo.dart):
///  - A local on-disk cache of the raw (still-encrypted) envelopes + the sync
///    cursors lets the app open **instantly and offline** — decrypt the cache,
///    show the list, then reconcile with the server in the background.
///  - [syncDelta] pulls only `updated_at > cursor` envelopes plus
///    `/tombstones?since=tombCursor`, so steady-state refresh is cheap (no more
///    re-downloading the whole corpus every tick).
///  - Mutations go through an **outbox**: queued, then flushed; if the network
///    is down they persist and retry on the next sync, so a capture made offline
///    is never lost.
class WorkerRepo implements RelicRepo {
  // Sync transparency (rejection reasons / retry / last-synced / Sync now) is
  // desktop-only for now; mobile keeps its pull-to-refresh + chip. Stubs keep
  // the interface satisfied. Upload progress is likewise desktop-only: mobile
  // uploads a blob BEFORE the relic exists, so there is no row to show it on.
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

  final String baseUrl;
  String token;
  final String passphrase;

  /// Label stamped on relics captured from this device (Settings → Device name).
  String deviceLabel;

  /// When true, deliberate captures/notes are born promoted (into the Vault);
  /// when false they land in the stream (All). Settings-controlled.
  bool autoVault;

  /// When true (default), detected secrets get the `secret` tag so they're
  /// masked in the list; when false, new captures skip it. Mirrors the desktop
  /// "detect & mask secrets" preference (LocalDeskRepo.maskSecrets). Set by the
  /// host from device-local prefs, like [autoVault]/[deviceLabel].
  bool maskSecrets;

  /// Stable per-install device id, sent as `X-Relic-Device` so the backend can
  /// list this device and honor a remote remove (docs/cloudflare/13 §7).
  String? deviceId;

  WorkerRepo({
    required this.baseUrl,
    required this.token,
    required this.passphrase,
    this.deviceLabel = 'Phone',
    this.autoVault = true,
    this.maskSecrets = true,
    this.deviceId,
  });

  /// Deterministic subtype tags for captured text, honoring [maskSecrets]: when
  /// off, the `secret` tag (and thus list masking) is dropped for new captures.
  /// Mirrors LocalDeskRepo._tagsFor so both lenses agree.
  List<String> _tagsFor(String t) {
    final tags = detectTags(t);
    if (!maskSecrets) tags.remove('secret');
    return tags;
  }

  // --- Supabase sign-in (mobile in-app auth bridge) ---
  // In supabase mode `token` is a short-lived access token refreshed from
  // _refreshToken; identity = the stable Supabase user id (not the rotating
  // token). The vault passphrase is never sent to Supabase.
  bool _supabaseMode = false;
  String? _refreshToken;
  int _accessExpiry = 0; // epoch seconds
  bool _refreshing = false;
  String? supabaseUserId;
  String? accountEmail;
  String? get refreshToken => _refreshToken;
  bool get isSupabase => _supabaseMode;

  /// The signed-in account email, used by the delete-account confirm field.
  /// Mirrors LocalDeskRepo.supabaseUserEmail so both hosts read the same getter.
  String? get supabaseUserEmail => accountEmail;

  /// Set true when a sync write is refused with 403 email_unverified (the
  /// worker's VERIFY_GATE). Both hosts watch this to show the confirm-your-email
  /// banner; capture keeps working locally regardless. Lockstep with
  /// LocalDeskRepo.emailUnverified.
  final ValueNotifier<bool> emailUnverified = ValueNotifier(false);

  /// True when [body] is the worker's `{"error":"email_unverified",...}` payload.
  /// Static + pure so the flag logic is unit-testable. Lockstep with LocalDeskRepo.
  static bool isEmailUnverifiedBody(String body) {
    try {
      return (jsonDecode(body) as Map)['error'] == 'email_unverified';
    } catch (_) {
      return false;
    }
  }

  /// Called after a successful token refresh so the host can re-persist the
  /// (possibly rotated) refresh token.
  void Function(WorkerRepo repo)? onSupabaseRefresh;

  /// Sign in or sign up with Supabase, then bind sync using the access token as
  /// the Worker bearer. Identity = the stable Supabase user id; the long-lived
  /// refresh token is exposed via [refreshToken] for the host to persist.
  static Future<WorkerRepo> signInSupabase({
    required String baseUrl,
    required String email,
    required String password,
    required String passphrase,
    required bool signUp,
    String deviceLabel = 'Phone',
    bool autoVault = true,
    String? deviceId,
  }) async {
    final session = signUp
        ? await SupabaseAuth.signUp(email, password)
        : await SupabaseAuth.signIn(email, password);
    return _bindSupabase(
      baseUrl: baseUrl,
      session: session,
      passphrase: passphrase,
      allowCreate: signUp,
      deviceLabel: deviceLabel,
      autoVault: autoVault,
      deviceId: deviceId,
    );
  }

  /// Silent relaunch: reconnect from a persisted refresh token.
  static Future<WorkerRepo> reconnectSupabase({
    required String baseUrl,
    required String refreshToken,
    required String passphrase,
    String deviceLabel = 'Phone',
    bool autoVault = true,
  }) async {
    final session = await SupabaseAuth.refresh(refreshToken);
    return _bindSupabase(
      baseUrl: baseUrl,
      session: session,
      passphrase: passphrase,
      allowCreate: false,
      deviceLabel: deviceLabel,
      autoVault: autoVault,
    );
  }

  /// Bind a connected repo from an already-refreshed Supabase session, unlocking
  /// with the passphrase. Used by silent relaunch (which refreshes the rotating
  /// token once, then binds) and the legacy cleartext-passphrase migration.
  static Future<WorkerRepo> fromSession({
    required String baseUrl,
    required SupabaseSession session,
    required String passphrase,
    bool allowCreate = false,
    String deviceLabel = 'Phone',
    bool autoVault = true,
    String? deviceId,
  }) =>
      _bindSupabase(
        baseUrl: baseUrl,
        session: session,
        passphrase: passphrase,
        allowCreate: allowCreate,
        deviceLabel: deviceLabel,
        autoVault: autoVault,
        deviceId: deviceId,
      );

  static Future<WorkerRepo> _bindSupabase({
    required String baseUrl,
    required SupabaseSession session,
    required String passphrase,
    required bool allowCreate,
    required String deviceLabel,
    required bool autoVault,
    String? deviceId,
  }) async {
    if (session.userId.isEmpty) {
      throw StateError('Sign-in did not return a user.');
    }
    final repo = WorkerRepo(
      baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
      token: session.accessToken,
      passphrase: passphrase,
      deviceLabel: deviceLabel,
      autoVault: autoVault,
      deviceId: deviceId,
    );
    repo._supabaseMode = true;
    repo._refreshToken = session.refreshToken;
    repo._accessExpiry = session.expiresAt;
    repo.supabaseUserId = session.userId;
    repo.accountEmail = session.email;
    await repo._initVaultKey(allowCreate);
    return repo;
  }

  /// True when connected to a user's OWN self-hosted server (account-less,
  /// passphrase-derived bearer). Drives the mobile UI + persistence: no billing,
  /// a "Self-hosted" label, and reconnect via the device-token path.
  bool isSelfHost = false;

  /// True when the most recent bind CREATED a fresh vault (keyparams didn't
  /// exist yet), so the onboarding flow shows the recovery kit once. Mirrors
  /// LocalDeskRepo.vaultJustCreated. Consumed + not persisted.
  bool vaultJustCreated = false;

  /// Connect to a user's OWN self-hosted server (the "Obsidian model"). No
  /// account: the bearer is derived from the passphrase alone
  /// ([RelicCrypto.deriveSelfHostToken]) so any device that knows the URL +
  /// passphrase enrolls and pulls the same vault. Enrolls first (trust-on-first-
  /// use claims the instance / is idempotent after; a wrong passphrase is
  /// rejected), then create-or-unwraps the vault keyparams like every other bind.
  static Future<WorkerRepo> connectSelfHost({
    required String baseUrl,
    required String passphrase,
    String? enrollSecret,
    String deviceLabel = 'Phone',
    bool autoVault = true,
    String? deviceId,
  }) async {
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final token = RelicCrypto.deriveSelfHostToken(passphrase);
    await _enrollSelfHost(base, token, enrollSecret, deviceId, deviceLabel);
    final repo = WorkerRepo(
      baseUrl: base,
      token: token,
      passphrase: passphrase,
      deviceLabel: deviceLabel,
      autoVault: autoVault,
      deviceId: deviceId,
    );
    repo.isSelfHost = true;
    await repo._initVaultKey(true); // create on a fresh vault, else unwrap
    return repo;
  }

  /// POST /enroll against a self-host server; map its TOFU rejections to
  /// friendly errors. Device metadata is best-effort (for the Devices screen).
  static Future<void> _enrollSelfHost(String base, String token, String? secret,
      String? deviceId, String label) async {
    final http.Response resp;
    try {
      resp = await http.post(
        Uri.parse('$base/enroll'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
          'label': label,
          'platform': Platform.operatingSystem,
          if (secret != null && secret.isNotEmpty) 'enroll_secret': secret,
        }),
      ).timeout(kNetTimeout);
    } catch (_) {
      throw StateError(
          "Couldn't reach that server. Check the address and that it's running.");
    }
    if (resp.statusCode == 200) return;
    if (resp.statusCode == 403) {
      throw StateError(isEnrollSecretError(resp.body)
          ? 'Wrong enrollment secret for this server.'
          : 'Wrong passphrase for this server.');
    }
    if (resp.statusCode == 401) {
      throw StateError('This server rejected the connection.');
    }
    throw StateError('Server error ${resp.statusCode}.');
  }

  /// True when a self-host /enroll 403 was the enrollment-secret gate (vs a
  /// wrong-passphrase rejection). Mirrors selfhost/src/enroll.ts messages.
  static bool isEnrollSecretError(String body) {
    try {
      return (jsonDecode(body) as Map)['message'] == 'bad enrollment secret';
    } catch (_) {
      return false;
    }
  }

  /// Bind a Supabase session with an already-known master key (the QR-pairing and
  /// recovery-kit paths, where the MK comes from another device or the kit rather
  /// than from unwrapping keyparams with a passphrase). The passphrase is left
  /// empty; the vault is already unlocked.
  static Future<WorkerRepo> bindSupabaseWithMk({
    required String baseUrl,
    required SupabaseSession session,
    required Uint8List mk,
    String deviceLabel = 'Phone',
    bool autoVault = true,
    String? deviceId,
  }) async {
    if (session.userId.isEmpty) {
      throw StateError('Sign-in did not return a user.');
    }
    final repo = WorkerRepo(
      baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
      token: session.accessToken,
      passphrase: '',
      deviceLabel: deviceLabel,
      autoVault: autoVault,
      deviceId: deviceId,
    );
    repo._supabaseMode = true;
    repo._refreshToken = session.refreshToken;
    repo._accessExpiry = session.expiresAt;
    repo.supabaseUserId = session.userId;
    repo.accountEmail = session.email;
    repo._mk = mk; // already unlocked; skip keyparams/passphrase
    return repo;
  }

  Uint8List? _mk;

  /// The unwrapped master key, once the vault is unlocked. Used by the trusted
  /// device's "show QR" pairing flow to deliver the key to a new device.
  Uint8List? get masterKey => _mk;

  final List<Relic> _items = [];

  /// Raw envelopes keyed by uid — what we persist to the local cache so a
  /// relaunch can rebuild [_items] without hitting the network.
  final Map<String, Map<String, dynamic>> _envByUid = {};

  /// Pending outbound mutations (puts/deletes) not yet acknowledged by the
  /// server. Flushed on every sync; survives restarts via the cache.
  final List<Map<String, dynamic>> _outbox = [];

  /// Blob keys whose cleartext is cached locally but whose upload hasn't landed
  /// yet. Captures used to upload synchronously and *throw* when it failed, so
  /// photographing or sharing a file with no signal silently lost the item. Now
  /// the bytes are written to the blob cache first, the relic is created
  /// regardless, and the upload is retried here on every sync. Flushed BEFORE
  /// [_outbox] so a relic never reaches another device pointing at a blob the
  /// server doesn't have. Survives restarts via the cache.
  final List<String> _blobOutbox = [];

  final Set<String> _custom = {}; // user-created reusable tags (not yet applied)

  // In-memory FTS/trigram search index, mirroring [_items]. The mobile lens now
  // searches through the SAME engine as desktop (RelicDb) — bm25 relevance,
  // synonym expansion, embedded-link matching, trigram typo recall, tag facets —
  // instead of the old in-memory substring matcher. It's a rebuildable mirror,
  // not the source of truth ([_items] + [_envByUid] remain canonical), so a
  // failure to open it degrades gracefully to [filterRelics].
  RelicDb? _index;
  // Fallback windowing when the index isn't up yet (first frame / open failure).
  late final QueryWindow _qw = QueryWindow(() => _items);
  // Active query state (mirrors LocalDeskRepo). The window + count are recomputed
  // by [_refreshWindow] from either the fused hybrid ranking or a lexical page.
  String _query = '';
  Scope _scope = Scope.all;
  SortMode _sort = SortMode.relevance;
  int? _createdAfter, _createdBefore;
  int _windowSize = kRelicPage;
  List<String>? _hybridUids; // fused ranking for the active query, else null
  final List<Relic> _window = [];
  int _matchCount = 0;
  static const int _searchPool = 150; // skip the hybrid refine above this

  SyncState _sync = const SyncState(SyncKind.offline);
  AccountInfo? _account;
  SyncSocket? _syncSocket; // live-sync doorbell (foreground); null until first pull

  /// True while the doorbell socket is connected. The mobile poll widens when
  /// this is set (the socket delivers changes) and tightens when it drops.
  bool get socketConnected => _syncSocket?.connected ?? false;

  int _cursor = 0; // max relic updated_at pulled
  int _tombCursor = 0; // max tombstone deleted_at pulled
  int _aiCursor = 0; // max AI-record ai_at pulled

  // AI records (generated titles + tags) from the account's desktops. This
  // device is a pure consumer: phones never run the models, so it only ever
  // pulls these, never claims work and never publishes. Kept as raw envelopes
  // like `_envByUid` so the account-switch cache guard covers them for free —
  // another account's records simply fail to decrypt.
  final Map<String, Map<String, dynamic>> _aiEnvByUid = {};
  final Map<String, AiRecord> _aiByUid = {};
  Map<String, dynamic>? _keyparams; // cached so the key can be unwrapped offline
  bool _cacheLoaded = false;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        if (deviceId case final d? when d.isNotEmpty) 'X-Relic-Device': d,
      };
  String _u(String path) => '${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path';

  @override
  List<Relic> get all => List.unmodifiable(_items);
  /// Whether the index can answer a query right now.
  ///
  /// NOT just `_index != null`: during the deferred launch build the field is
  /// still null (or, on a re-decrypt, still the previous corpus) while
  /// [_indexPending] is set. Every read below routes to [_qw] until this is
  /// true, which is what keeps a search typed in the first seconds of a launch
  /// from blocking on the build.
  bool get _indexReady => _index != null && !_indexPending;

  @override
  List<Relic> get visible => !_indexReady ? _qw.visible : _window;
  @override
  int get matchCount => !_indexReady ? _qw.matchCount : _matchCount;
  @override
  bool get hasMore =>
      !_indexReady ? _qw.hasMore : _matchCount > _windowSize;
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
    _hybridUids = null;
    if (!_indexReady) {
      // The launch build is still in flight. This USED to force it to finish
      // synchronously, on this isolate, which meant searching in the first few
      // seconds after launch locked the UI for the entire build — the very
      // freeze the deferral existed to remove, moved onto the keystroke that
      // triggers it.
      //
      // Answer from the in-memory matcher instead. It reads [_items] directly
      // so it is never stale, only less clever (no bm25 ranking, no trigram
      // fuzz). [_runQuery] re-answers properly the moment the index lands.
      _qw.setQuery(search, scope,
          sort: sort, createdAfter: createdAfter, createdBefore: createdBefore);
      return;
    }
    _runQuery();
  }

  /// Answer the active query from the index. Split out of [setQuery] so the
  /// completed launch build can re-run it without disturbing query state or
  /// resetting how far the user has paged.
  void _runQuery() {
    final db = _index;
    if (db == null) return;
    final search = _query;
    final scope = _scope;
    final sort = _sort;
    final createdAfter = _createdAfter;
    final createdBefore = _createdBefore;
    // Hybrid refine — for real relevance searches only. A forced by-date sort,
    // any `tag:` clause (the hybrid legs don't parse it), a negation ("a -b",
    // which the recall legs don't understand), a <3-char query, or a very broad
    // query (more lexical hits than the pool) all skip it and use plain lexical
    // paging — mirrors the desktop gates so results/counts stay honest. The
    // ranking is pure SQLite here (no ML), so it runs synchronously.
    final s = search.trim();
    final skipHybrid = sort != SortMode.relevance ||
        s.length < 3 ||
        RegExp(r'tag:\S+|(^|\s)(kind|is|has):\S+')
            .hasMatch(s.toLowerCase()) ||
        RegExp(r'(^|\s)-\S').hasMatch(s);
    if (!skipHybrid) {
      final lexCount = db.countMatching(s, scope,
          createdAfter: createdAfter, createdBefore: createdBefore);
      if (lexCount <= _searchPool) {
        _hybridUids = db.lexicalHybridUids(s, scope,
            createdAfter: createdAfter,
            createdBefore: createdBefore,
            // Personal factors come from the on-disk store, not this
            // ephemeral index (see the personalized-ranking section).
            factorsFor: personalRank && _personal != null
                ? (union) {
                    try {
                      return _personal!.factors(union, s, _now);
                    } catch (_) {
                      return const <String, double>{};
                    }
                  }
                : null);
      }
    }
    _refreshWindow();
  }

  @override
  Future<void> loadMore() async {
    if (_index == null) {
      _qw.loadMore();
      return;
    }
    if (!hasMore) return;
    _windowSize += kRelicPage;
    _refreshWindow();
  }

  /// Recompute the visible window + match count for the active query — from the
  /// fused hybrid ranking when one is active, else a straight lexical page.
  void _refreshWindow() {
    final db = _index;
    if (db == null) return;
    if (_hybridUids != null) {
      final page = _hybridUids!.take(_windowSize).toList();
      var rows = db.byUids(page);
      if (rows.length < page.length) {
        // Some ranked uids were deleted after ranking — prune and re-take so the
        // count stays honest and freed slots fill back up in this pass.
        final alive = rows.map((r) => r.uid).toSet();
        _hybridUids!.removeWhere((u) => !alive.contains(u) && page.contains(u));
        rows = db.byUids(_hybridUids!.take(_windowSize).toList());
      }
      _window
        ..clear()
        ..addAll(rows);
      _matchCount = _hybridUids!.length;
    } else {
      _window
        ..clear()
        ..addAll(db.queryPage(
          _query,
          _scope,
          _windowSize,
          0,
          oldestFirst: _sort == SortMode.oldest,
          byRelevance: _sort == SortMode.relevance,
          createdAfter: _createdAfter,
          createdBefore: _createdBefore,
        ));
      _matchCount = db.countMatching(
        _query,
        _scope,
        createdAfter: _createdAfter,
        createdBefore: _createdBefore,
      );
    }
  }

  // --- search index (mirror of [_items]) -----------------------------------

  /// (Re)build the whole search index from [_items]. Called after a full cache
  /// decrypt / corpus rebuild; incremental changes use [_indexUpsert]/[_indexDelete].
  void _rebuildIndex() {
    _indexPending = false; // whether it succeeds or degrades, the debt is paid
    try {
      final db = RelicDb.memory();
      // bulkLoad, not a loop of upsert: upsert opens a transaction and
      // re-prepares ~8 statements per relic, which measured 6.1s building this
      // index on a real vault at launch.
      db.bulkLoad(_items, haveBlob: (r) => localImagePath(r) != null);
      // bulkLoad rebuilds every index row from the relics alone, so the
      // attachment text a desktop sent us has to be written back on top or a
      // full rebuild would quietly drop it from search.
      for (final e in _aiByUid.entries) {
        final att = e.value.att;
        if (att != null && att.isNotEmpty) db.setAttachmentText(e.key, att);
      }
      _index?.dispose();
      _index = db;
      _refreshWindow();
    } catch (_) {
      _index = null; // degrade to the in-memory matcher
    }
  }

  void _indexUpsert(Relic r) {
    if (_indexBuilding) _indexDirty.add(r.uid); // replayed onto the new db
    try {
      _index?.upsert(r, haveBlob: localImagePath(r) != null);
      // Attachment text is a column on the index row, not a field on the Relic,
      // so an upsert leaves it behind and it has to be written back. A phone
      // has no extractor of its own, so this copy from a desktop is the only
      // one it will ever have.
      final att = _aiByUid[r.uid]?.att;
      if (att != null && att.isNotEmpty) _index?.setAttachmentText(r.uid, att);
    } catch (_) {}
  }

  void _indexDelete(String uid) {
    if (_indexBuilding) _indexDirty.add(uid);
    try {
      _index?.delete(uid);
    } catch (_) {}
  }

  // --- personalized ranking (usage frecency + query-pick memory) -----------
  // Desktop keeps these decaying counters in the vault DB; here the index is
  // an ephemeral mirror, so they live in a tiny on-disk sqlite of their own
  // (PersonalStore), one file per account, terms hashed at rest.

  /// Gates learning AND applying the personal factors. Set by the host from
  /// device-local prefs (like [autoVault]); mirrors LocalDeskRepo's
  /// `personal_rank` pref, default on.
  bool personalRank = true;

  PersonalStore? _personal;

  /// Stable per-account id for the personal store file + salt slot: the
  /// Supabase user id, else (legacy device-token mode, where the token never
  /// rotates) the same scope hash the secure stores use.
  String get _personalAcct =>
      supabaseUserId ?? sha256sum('$baseUrl\n$token', utf8).substring(0, 32);

  String _personalSaltSlot(String acct) => 'relic.personal.salt.$acct';

  /// Open (or create) this account's personal store. Idempotent; the host
  /// calls it once connected. The HMAC salt for terms-at-rest is minted once
  /// per account and kept in secure storage — losing it just resets the
  /// learned query memory, never user content. Failure degrades silently:
  /// search still works, just not personalized.
  Future<void> initPersonalStore() async {
    if (_personal != null) return;
    try {
      final acct = _personalAcct;
      const store = FlutterSecureStorage();
      final slot = _personalSaltSlot(acct);
      var saltB64 = await store.read(key: slot);
      if (saltB64 == null) {
        final rnd = Random.secure();
        saltB64 =
            base64Encode([for (var i = 0; i < 32; i++) rnd.nextInt(256)]);
        await store.write(key: slot, value: saltB64);
      }
      final dir = await _supportDir();
      _personal =
          PersonalStore('${dir.path}/personal-$acct.db', base64Decode(saltB64));
    } catch (_) {
      _personal = null;
    }
  }

  /// Wipe everything personalized ranking has learned on this device
  /// (Settings → Clear learned ranking). Lockstep with
  /// LocalDeskRepo.clearPersonalMemory.
  void clearPersonalMemory() {
    try {
      _personal?.clear();
    } catch (_) {}
  }

  /// Tear down the personal store and delete its file + salt. Sign-out /
  /// switch-account / account-deletion path: the learned rows reference this
  /// account's uids and are useless without them.
  Future<void> destroyPersonalData() async {
    try {
      final acct = _personalAcct;
      _personal?.dispose();
      _personal = null;
      final f = File('${(await _supportDir()).path}/personal-$acct.db');
      if (f.existsSync()) f.deleteSync();
      await const FlutterSecureStorage().delete(key: _personalSaltSlot(acct));
    } catch (_) {}
  }
  @override
  bool get promotionSound => false;
  @override
  bool get vaultAnimation => true;
  @override
  bool get coachMarksSeen => true; // coach marks are desktop-only
  @override
  Future<void> markCoachMarksSeen() async {}
  @override
  bool get multiCombine => false; // power features are desktop-only
  @override
  bool get snippets => false;
  @override
  bool get reminders => false;

  @override
  // The local labeler is desktop-only, so nothing here is ever provisional.
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
  bool get syncEnabled => true; // mobile: a live repo means connected
  @override
  SyncState get sync => _sync;
  @override
  AccountInfo? get account => _account;

  // --- key -----------------------------------------------------------------

  /// Fetch keyparams and unwrap the master key (cached). Falls back to the
  /// locally-cached keyparams when offline so the app can still decrypt the
  /// cache and open. A capture only needs this — it's separate from a full sync.
  Future<void> _ensureKey() async {
    if (_mk != null) return;
    Map<String, dynamic>? kp;
    try {
      final r = await http
          .get(Uri.parse(_u('/keyparams')), headers: _headers)
          .timeout(kNetTimeout);
      if (r.statusCode == 404) {
        throw StateError(
          'No account yet for this token. Create a key on desktop first.',
        );
      }
      if (r.statusCode == 200) {
        kp = jsonDecode(r.body) as Map<String, dynamic>;
        _keyparams = kp;
      }
    } catch (e) {
      if (e is StateError) rethrow;
      // Network error — fall through to the cached keyparams (offline launch).
    }
    kp ??= _keyparams;
    if (kp == null) {
      throw StateError('Offline. Connect once with a signal to set up.');
    }
    final mk = await RelicCrypto.unwrapMasterKey(kp, passphrase);
    if (mk == null) throw StateError('Wrong passphrase for this account.');
    _mk = mk;
  }

  /// Fetch (or, when [allowCreate], create on 404) the vault keyparams and
  /// unwrap the master key with the passphrase. Mode-agnostic: used by the
  /// Supabase bind and by [connectSelfHost].
  Future<void> _initVaultKey(bool allowCreate) async {
    final r = await http
        .get(Uri.parse(_u('/keyparams')), headers: _headers)
        .timeout(kNetTimeout);
    if (r.statusCode == 401) {
      throw StateError('Signed in, but the server rejected the session.');
    }
    if (r.statusCode == 404) {
      if (!allowCreate) {
        throw StateError('No vault for this account yet. Create one first.');
      }
      final (kp, mk) = await RelicCrypto.createKeyParams(passphrase);
      final put = await http.put(
        Uri.parse(_u('/keyparams')),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode(kp),
      ).timeout(kNetTimeout);
      if (put.statusCode != 200) {
        throw StateError('Could not create the vault key (${put.statusCode}).');
      }
      _keyparams = kp;
      _mk = mk;
      vaultJustCreated = true; // fresh vault → onboarding shows the recovery kit
    } else if (r.statusCode == 200) {
      final kp = jsonDecode(r.body) as Map<String, dynamic>;
      final mk = await RelicCrypto.unwrapMasterKey(kp, passphrase);
      if (mk == null) throw StateError('Wrong passphrase for this account.');
      _keyparams = kp;
      _mk = mk;
    } else {
      throw StateError('Server error ${r.statusCode}.');
    }
  }

  /// Rotate the vault passphrase (docs/cloudflare/13 §7): re-wrap the in-memory
  /// master key under a new passphrase and PUT ?replace=1. No data is
  /// re-encrypted; the cached MK and the recovery kit both stay valid.
  Future<void> changePassphrase(String newPassphrase) async {
    final mk = _mk;
    if (mk == null) throw StateError('Unlock the vault first.');
    final kp = await RelicCrypto.rewrapKeyParams(mk, newPassphrase);
    final r = await http.put(
      Uri.parse(_u('/keyparams?replace=1')),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(kp),
    ).timeout(kNetTimeout);
    if (r.statusCode != 200) {
      throw StateError('Could not change the passphrase (${r.statusCode}).');
    }
    _keyparams = kp;
  }

  /// Sign out on ALL devices (docs/cloudflare/13 §7): revoke every refresh token
  /// for this account at the IdP. Other devices drop offline as their access
  /// tokens expire (~1h). This device's refresh token is revoked too, so the
  /// host should treat a successful call as a full sign-out.
  Future<void> signOutEverywhere() async {
    if (!_supabaseMode) {
      throw StateError('Signing out everywhere needs a Relic account session.');
    }
    await SupabaseAuth.signOutGlobal(token);
    _refreshToken = null;
    unawaited(_syncSocket?.stop());
  }

  /// Change the login (account) email at the IdP. GoTrue emails a confirmation
  /// link to both the current and the new address; the change lands only once
  /// confirmed, so the current session keeps working meanwhile. The vault key is
  /// untouched (auth != vault). Mirrors LocalDeskRepo.changeEmail.
  Future<void> changeEmail(String newEmail) async {
    if (!_supabaseMode) {
      throw StateError('Changing your email needs a Relic account session.');
    }
    await _maybeRefresh();
    await SupabaseAuth.changeEmail(token, newEmail);
  }

  /// Permanently delete the synced vault + account on the server (DELETE
  /// /account — full teardown). Local history on this device is untouched; the
  /// host runs its disconnect path afterward. Mirrors LocalDeskRepo.deleteAccount.
  Future<void> deleteAccount() async {
    // Force-refresh: the worker rejects deletion on a token older than ~10
    // minutes (stale_token), so mint a fresh one regardless of expiry.
    await _maybeRefresh(force: true);
    final r = await http
        .delete(Uri.parse(_u('/account')), headers: _headers)
        .timeout(kNetTimeout);
    if (r.statusCode != 200 && r.statusCode != 204) {
      throw StateError('Could not delete your account (${r.statusCode}).');
    }
  }

  /// Refresh the Supabase access token shortly before expiry. No-op outside
  /// supabase mode or while still fresh (unless [force]). Called at the top of
  /// [syncDelta]; forced by [deleteAccount] to satisfy the worker's fresh-token
  /// requirement on destructive routes.
  Future<void> _maybeRefresh({bool force = false}) async {
    if (!_supabaseMode || _refreshing) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (!force && now < _accessExpiry - 120) return;
    final rt = _refreshToken;
    if (rt == null) return;
    _refreshing = true;
    try {
      final s = await SupabaseAuth.refresh(rt);
      token = s.accessToken;
      _accessExpiry = s.expiresAt;
      if (s.refreshToken.isNotEmpty && s.refreshToken != rt) {
        _refreshToken = s.refreshToken;
        onSupabaseRefresh?.call(this);
      }
    } catch (_) {
      _sync = const SyncState(SyncKind.offline);
    } finally {
      _refreshing = false;
    }
  }

  // --- load / sync ---------------------------------------------------------

  @override
  Future<void> load() async {
    await loadLocal();
    await syncDelta(); // reconcile with the server
  }

  /// Everything needed to *show* the vault, with no network on the path.
  ///
  /// This is what a launch should await. [load] additionally blocks on
  /// [syncDelta] — a token refresh, an outbox flush, `/account`, a paginated
  /// `/relics` pull — which is how the mobile splash screen came to sit there
  /// for ten seconds with a fully decryptable vault already on disk. The host
  /// awaits this, paints, and lets the sync land behind the UI.
  ///
  /// [_ensureKey] can still touch the network (legacy device-token mode has no
  /// cached master key), but it falls back to the cached keyparams and now runs
  /// under a deadline, so offline it costs at most [kNetTimeout] once.
  Future<void> loadLocal() async {
    await _loadCache();
    BootTrace.mark('cache read');
    await _ensureKey();
    BootTrace.mark('key ready');
    await _decryptCache(); // instant list from the local cache (offline-safe)
    BootTrace.mark('cache decrypted');
  }

  /// Read the on-disk cache into memory WITHOUT decrypting it or syncing.
  ///
  /// For the capture-only repo (share sheet / QS tile), which never calls
  /// [load]: every queued mutation ends in `_push` -> `_saveCache`, and
  /// `_saveCache` serializes `_envByUid` + `_outbox` wholesale. Priming first is
  /// what stops a one-item capture from overwriting the whole cached vault (and
  /// discarding mutations still queued in the outbox).
  Future<void> primeCache() => _loadCache();

  /// Incremental reconcile: flush the outbox, pull `updated_at > cursor`
  /// envelopes and `deleted_at > tombCursor` tombstones, then persist. Cheap
  /// enough to run on a gentle timer. Sets [sync] to synced/offline.
  /// The live-sync doorbell for mobile foreground: a wake nudge pulls now, so a
  /// change from another device lands sub-second instead of on the next tick.
  /// Idempotent; started on the first [syncDelta] once the repo is live.
  void _ensureSocket() {
    // No onConnectedChanged: the mobile poll re-arms its own cadence by checking
    // socketConnected on each tick (see mobile.dart _scheduleNextPoll), and this
    // repo is not a ChangeNotifier.
    _syncSocket ??= SyncSocket(
      baseUrl: () => baseUrl,
      headers: () => _headers,
      onWake: () => unawaited(syncDelta()),
    );
    _syncSocket!.start();
  }

  Future<void> syncDelta() async {
    // Refresh BEFORE opening the socket. The launch now binds with an
    // already-expired access token (that's what keeps the network off the cold
    // path), so starting the socket first would hand it an empty bearer,
    // guarantee an auth failure, and make the live-sync doorbell wait out a
    // backoff on every single launch.
    await _maybeRefresh();
    _ensureSocket();
    if (_mk == null) {
      try {
        await _ensureKey();
      } catch (_) {
        _sync = const SyncState(SyncKind.offline);
        return;
      }
    }
    // Blobs first: a relic put that lands before its blob would show up on
    // another device as an item whose bytes 404.
    await _flushBlobOutbox();
    await _flushOutbox();
    try {
      // account (best-effort)
      try {
        final a = await http
            .get(Uri.parse(_u('/account')), headers: _headers)
            .timeout(kNetTimeout);
        if (a.statusCode == 200) {
          final j = jsonDecode(a.body) as Map<String, dynamic>;
          _account = AccountInfo(
            tier: const {'pro': 'Pro', 'max': 'Max'}[j['tier'] as String] ?? 'Free',
            usedBytes: (j['storage_used'] as num).toInt(),
            quotaBytes: (j['storage_quota'] as num).toInt(),
            vaultCount: (j['vault_count'] as num).toInt(),
            vaultCap: (j['vault_cap'] as num?)?.toInt(),
          );
        }
      } catch (_) {}

      // relics changed since the cursor
      var changed = false;
      var maxU = _cursor;
      String? cursor;
      do {
        final q = {
          'since': '$_cursor',
          'limit': '500',
          'cursor': ?cursor,
        };
        final r = await http.get(
          Uri.parse(_u('/relics')).replace(queryParameters: q),
          headers: _headers,
        ).timeout(kNetTimeout);
        if (r.statusCode != 200) {
          _sync = const SyncState(SyncKind.offline);
          return;
        }
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        final items = (body['items'] as List).cast<Map<String, dynamic>>();
        for (final env in items) {
          final u = (env['updated_at'] as num).toInt();
          if (u > maxU) maxU = u;
          if (await _upsertEnv(env)) changed = true;
        }
        cursor = body['next_cursor'] as String?;
      } while (cursor != null);
      if (maxU - 1 > _cursor) _cursor = maxU - 1;

      // tombstones (deletions from other devices)
      final tr = await http.get(
        Uri.parse(_u('/tombstones')).replace(
          queryParameters: {'since': '$_tombCursor'},
        ),
        headers: _headers,
      ).timeout(kNetTimeout);
      if (tr.statusCode == 200) {
        final items = (jsonDecode(tr.body)['items'] as List)
            .cast<Map<String, dynamic>>();
        var tmax = _tombCursor;
        for (final t in items) {
          final d = (t['deleted_at'] as num).toInt();
          if (d > tmax) tmax = d;
          final uid = t['uid'] as String;
          // The AI record dies with its relic, as it does on the server.
          _aiEnvByUid.remove(uid);
          _aiByUid.remove(uid);
          if (_envByUid.remove(uid) != null) {
            _items.removeWhere((x) => x.uid == uid);
            _indexDelete(uid);
            _outbox.removeWhere((o) => o['uid'] == uid && o['op'] == 'put');
            changed = true;
          }
        }
        if (tmax - 1 > _tombCursor) _tombCursor = tmax - 1;
      }

      // AI records last, so an item that arrived in this same pass gets its
      // generated title now rather than a cycle later.
      if (await _pullAiRecords()) changed = true;

      if (changed) {
        _items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        _refreshWindow(); // reflect pulled items in the active view
      }
      _sync = SyncState(
        // A queued blob with no queued relic op still means "not fully synced".
        // The count stays the relic-op count: an offline capture queues both,
        // and showing it as two pending things would just read as a bug.
        _outbox.isEmpty && _blobOutbox.isEmpty
            ? SyncKind.synced
            : SyncKind.pending,
        pending: _outbox.length,
      );
      await _saveCache();
    } catch (_) {
      _sync = const SyncState(SyncKind.offline);
    }
  }

  /// Decrypt an envelope and upsert it into [_items] / [_envByUid]. Returns
  /// whether anything changed (skips re-inserting an identical updated_at).
  Future<bool> _upsertEnv(Map<String, dynamic> env) async {
    final uid = env['uid'] as String;
    // Locally deleted with the tombstone still in flight: a pull snapshot
    // from before the delete must not resurrect the row.
    if (_outbox.any((o) => o['uid'] == uid && o['op'] == 'delete')) {
      return false;
    }
    final existing = _envByUid[uid];
    if (existing != null &&
        (existing['updated_at'] as num).toInt() >=
            (env['updated_at'] as num).toInt()) {
      return false;
    }
    final relic = await _decrypt(env);
    if (relic == null) return false;
    _envByUid[uid] = env;
    final i = _items.indexWhere((x) => x.uid == uid);
    if (i >= 0) {
      _items[i] = relic;
    } else {
      _items.add(relic);
    }
    _indexUpsert(relic);
    // A relic update replaces the decrypted row wholesale, and the generated
    // title lives only in that row (never in the envelope), so it has to be
    // folded back in or an unrelated edit on another device would silently
    // strip the title off this one.
    _applyAiRecord(uid);
    return true;
  }

  /// Fold this uid's AI record into the in-memory relic, if both are here.
  ///
  /// Returns whether anything changed. Safe to call at any time: records and
  /// relics arrive on independent cursors, so either order is normal and this
  /// simply does nothing until both halves exist.
  bool _applyAiRecord(String uid) {
    final rec = _aiByUid[uid];
    if (rec == null) return false;
    final i = _items.indexWhere((x) => x.uid == uid);
    if (i < 0) return false;
    final cur = _items[i];
    // Suppression is desktop-only local state, so there is nothing to filter
    // out here; the user's own title still outranks the generated one.
    final merged = mergeAiRecord(cur: cur, rec: rec, suppressed: const {});
    if (merged.tags.length == cur.tags.length &&
        merged.title == cur.title &&
        merged.content == cur.content) {
      // Nothing on the relic itself changed, but the record may still carry
      // attachment text, which lives on the index row rather than the relic.
      // Routed through _indexUpsert so it gets the same treatment as any other
      // index write, including being replayed if a rebuild is in flight.
      final att = rec.att;
      if (att != null && att.isNotEmpty) {
        _indexUpsert(cur);
        return true;
      }
      return false;
    }
    // Content carries the extracted text a desktop read out of the item. A
    // phone will never produce it, so this is the only way a screenshot ends up
    // searchable by the words inside it here.
    _items[i] = cur.copyWith(
      tags: merged.tags,
      title: merged.title,
      content: merged.content,
    );
    _indexUpsert(_items[i]);
    return true;
  }

  /// Pull the generated titles and tags the account's desktops produced.
  ///
  /// This is the half of the feature that matters on a phone. The models will
  /// never run here, so without this pull a vaulted screenshot shows up
  /// untitled forever even though a desktop already named it.
  Future<bool> _pullAiRecords() async {
    if (_mk == null) return false;
    var changed = false;
    try {
      var maxAt = _aiCursor;
      String? cursor;
      do {
        final r = await http.get(
          Uri.parse(_u('/ai')).replace(queryParameters: {
            'since': '$_aiCursor',
            'limit': '500',
            'cursor': ?cursor,
          }),
          headers: _headers,
        ).timeout(kNetTimeout);
        if (r.statusCode != 200) return changed;
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        for (final env in (body['items'] as List).cast<Map<String, dynamic>>()) {
          final at = (env['ai_at'] as num).toInt();
          if (at > maxAt) maxAt = at;
          if (await _absorbAiEnv(env)) changed = true;
        }
        cursor = body['next_cursor'] as String?;
      } while (cursor != null);
      // Same off-by-one guard the relic cursor uses, so a record written in the
      // same second as the cursor is not skipped.
      if (maxAt - 1 > _aiCursor) _aiCursor = maxAt - 1;
    } catch (_) {
      return changed;
    }
    return changed;
  }

  Future<bool> _absorbAiEnv(Map<String, dynamic> env) async {
    final uid = env['uid'] as String;
    final p = await RelicCrypto.openAiPayload(
        _mk!, uid, env['n'] as String, env['ct'] as String);
    if (p == null) return false; // not ours to read, or tampered with
    _aiEnvByUid[uid] = env;
    _aiByUid[uid] = AiRecord.fromWire(env, p);
    return _applyAiRecord(uid);
  }

  // --- test hooks (the pull/outbox plumbing is private; there is no offline
  // network seam, so tests drive these directly) ----------------------------

  @visibleForTesting
  Future<bool> debugUpsertEnv(Map<String, dynamic> env) => _upsertEnv(env);

  /// Feed one AI record in, as a pull would. There is no offline network seam,
  /// so the consumer path is driven directly.
  @visibleForTesting
  Future<bool> debugAbsorbAiEnv(Map<String, dynamic> env) => _absorbAiEnv(env);

  /// Rebuild the search index from scratch, as a relaunch does.
  @visibleForTesting
  void debugRebuildIndex() => _rebuildIndex();

  @visibleForTesting
  List<Map<String, dynamic>> get debugOutbox => List.unmodifiable(_outbox);

  @visibleForTesting
  List<String> get debugBlobOutbox => List.unmodifiable(_blobOutbox);

  @visibleForTesting
  void debugSetPersonalStore(PersonalStore? s) => _personal = s;

  Future<Relic?> _decrypt(Map<String, dynamic> env) async {
    final p = await RelicCrypto.openRelicPayload(_mk!, env);
    if (p == null) return null;
    return Relic(
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
    );
  }

  // --- local cache (instant + offline launch) ------------------------------

  Directory? _supportDirCache;
  Future<Directory> _supportDir() async =>
      _supportDirCache ??= await getApplicationSupportDirectory();

  Future<File> _cacheFile() async => File('${(await _supportDir()).path}/relic_cache.json');

  Future<void> _loadCache() async {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    try {
      final f = await _cacheFile();
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      // Account-switch guard: a cache written under a different account must
      // not leak into this session — its envelopes wouldn't decrypt with this
      // account's key, its outbox would replay old-account ops against the new
      // one, and its cursors would blind the pull. Discard it wholesale. A
      // cache with no stamp (pre-guard build) is trusted as this account's.
      final cachedAcct = j['account'] as String?;
      if (cachedAcct != null && cachedAcct != _personalAcct) {
        try {
          f.deleteSync();
        } catch (_) {}
        return;
      }
      _cursor = (j['cursor'] as num?)?.toInt() ?? 0;
      _tombCursor = (j['tombCursor'] as num?)?.toInt() ?? 0;
      _aiCursor = (j['aiCursor'] as num?)?.toInt() ?? 0;
      _keyparams = (j['keyparams'] as Map?)?.cast<String, dynamic>();
      for (final e in (j['items'] as List? ?? const [])) {
        final env = (e as Map).cast<String, dynamic>();
        _envByUid[env['uid'] as String] = env;
      }
      // Cached alongside the relics because the AI cursor is cached too: on a
      // relaunch the pull starts past these records, so if they were not kept
      // every generated title would vanish until something happened to
      // re-publish it.
      for (final e in (j['aiItems'] as List? ?? const [])) {
        final env = (e as Map).cast<String, dynamic>();
        _aiEnvByUid[env['uid'] as String] = env;
      }
      for (final o in (j['outbox'] as List? ?? const [])) {
        _outbox.add((o as Map).cast<String, dynamic>());
      }
      for (final k in (j['blobOutbox'] as List? ?? const [])) {
        if (k is String) _blobOutbox.add(k);
      }
      // Last-known plan + storage. Only /account can refresh this, so without a
      // cached copy the whole account section of Settings simply vanished when
      // offline. Stale numbers beat no numbers; the next sync corrects them.
      final a = (j['accountInfo'] as Map?)?.cast<String, dynamic>();
      if (a != null) {
        _account = AccountInfo(
          tier: a['tier'] as String? ?? 'Free',
          usedBytes: (a['usedBytes'] as num?)?.toInt() ?? 0,
          quotaBytes: (a['quotaBytes'] as num?)?.toInt() ?? 0,
          vaultCount: (a['vaultCount'] as num?)?.toInt() ?? 0,
          vaultCap: (a['vaultCap'] as num?)?.toInt(),
        );
      }
    } catch (_) {
      // Corrupt cache — ignore and re-sync from scratch.
    }
  }

  Future<void> _decryptCache() async {
    _items.clear();
    for (final env in _envByUid.values) {
      final r = await _decrypt(env);
      if (r != null) _items.add(r);
    }
    // Generated titles, folded in before the first paint. The relic envelope
    // never carries them, so without this pass a relaunch would show every
    // desktop-titled item untitled until the next successful pull.
    _aiByUid.clear();
    for (final env in _aiEnvByUid.values) {
      final uid = env['uid'] as String;
      final p = await RelicCrypto.openAiPayload(
          _mk!, uid, env['n'] as String, env['ct'] as String);
      if (p != null) _aiByUid[uid] = AiRecord.fromWire(env, p);
    }
    for (final uid in _aiByUid.keys) {
      _applyAiRecord(uid);
    }
    _items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    BootTrace.mark('relics decrypted');
    // The list can paint from _items alone; only SEARCH needs the index, and
    // building it means an in-memory SQLite plus an FTS5 and a trigram row per
    // relic. Scheduled just after the current frame instead of blocking the
    // launch on it: by the time a human has focused the search box it is long
    // since built, and [_ensureIndex] covers the pathological case where they
    // are faster than the scheduler.
    _scheduleIndexBuild();
  }

  /// Whether the deferred index build from [_decryptCache] is still owed.
  bool _indexPending = false;

  /// Whether [_buildIndexChunked] is mid-pass, so index mutations know to
  /// record themselves for replay onto the database being built.
  bool _indexBuilding = false;

  /// Uids mutated while a chunked build was in flight. Those writes went to the
  /// OLD index (or nowhere), so they are replayed onto the new one before the
  /// swap — otherwise a relic pulled by the first sync would be missing from
  /// search until something else forced a rebuild.
  final Set<String> _indexDirty = {};

  /// Kick the post-launch index build.
  ///
  /// NOT scheduleMicrotask, which was the first attempt: the microtask queue
  /// drains before the next frame renders, so "deferring" that way still
  /// blocked the launch on the entire build. The on-device trace was
  /// unambiguous — vault ready at 509ms, then `index built +6154ms`. A timer is
  /// an event-loop task, so the list is actually on screen first.
  void _scheduleIndexBuild() {
    _indexPending = true;
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (_indexPending) unawaited(_buildIndexChunked());
    });
  }

  /// Build the index off the UI isolate, then insert it a slice at a time.
  ///
  /// Deferring this past first paint fixed the ten-second splash, but the work
  /// itself still ran on the UI isolate, so the list arrived and then froze for
  /// about three seconds. Slicing alone could not fix that: the cost is real
  /// CPU, and yielding only chops the freeze into pieces.
  ///
  /// A benchmark located it precisely — of 2900ms to index 1000 relics, 2658ms
  /// is [RelicDb.deriveIndexText] (the in-prose scanners in `_auxText`) and
  /// only ~70ms is SQLite. Derivation is pure string work over plain data, so
  /// it runs in a background isolate; the database, which cannot move, gets
  /// only the cheap half, still sliced so even that never blocks a frame.
  Future<void> _buildIndexChunked() async {
    if (_indexBuilding || !_indexPending) return;
    _indexBuilding = true;
    _indexDirty.clear();
    RelicDb? db;
    try {
      const slice = 150;
      final snapshot = List<Relic>.from(_items);

      // The expensive half, on another isolate. If spawning fails (memory
      // pressure, an embedder that forbids it) fall through with an empty map —
      // bulkLoad then derives inline, which is slow but correct.
      Map<String, IndexText> derived = const {};
      try {
        final rows = await Isolate.run(() => RelicDb.deriveIndexText(snapshot));
        derived = {for (final r in rows) r.uid: r};
        BootTrace.mark('index text derived');
      } catch (_) {
        BootTrace.mark('index derive fell back to main isolate');
      }
      if (!_indexPending) return;

      db = RelicDb.memory();
      for (var i = 0; i < snapshot.length; i += slice) {
        // A search arriving mid-build calls _ensureIndex, which builds
        // synchronously and clears the flag; this pass is then redundant.
        if (!_indexPending) return;
        db.bulkLoad(
          snapshot.skip(i).take(slice),
          haveBlob: (r) => localImagePath(r) != null,
          derived: derived,
        );
        await Future<void>.delayed(Duration.zero);
      }
      if (!_indexPending) return;
      // Replay anything that changed while we were building.
      for (final uid in _indexDirty) {
        final r = _items.where((x) => x.uid == uid).firstOrNull;
        if (r == null) {
          db.delete(uid);
        } else {
          db.upsert(r, haveBlob: localImagePath(r) != null);
        }
      }
      _indexPending = false;
      _index?.dispose();
      _index = db;
      db = null; // handed over — don't dispose it in the finally
      // Anything the user searched or scrolled while the build ran was answered
      // by [_qw]. Carry its paging over so the list doesn't snap back to the
      // first page, then re-answer the query for real.
      final degradedRows = _qw.visible.length;
      if (degradedRows > _windowSize) _windowSize = degradedRows;
      _runQuery();
      BootTrace.mark('index built');
      onIndexReady?.call();
    } catch (_) {
      _indexPending = false;
      _index = null; // degrade to the in-memory matcher
    } finally {
      _indexBuilding = false;
      _indexDirty.clear();
      db?.dispose(); // abandoned pass
    }
  }

  /// Fired when the deferred launch index lands and the active query has been
  /// re-answered from it. The UI has no listener on this repo, so without this
  /// a search typed during the build would keep showing the degraded matcher's
  /// answer until the next unrelated rebuild.
  void Function()? onIndexReady;

  Future<void> _saveCache() async {
    try {
      final f = await _cacheFile();
      f.writeAsStringSync(jsonEncode({
        'account': _personalAcct, // owner stamp — see _loadCache's guard
        'cursor': _cursor,
        'tombCursor': _tombCursor,
        'aiCursor': _aiCursor,
        'keyparams': _keyparams,
        'items': _envByUid.values.toList(),
        'aiItems': _aiEnvByUid.values.toList(),
        'outbox': _outbox,
        'blobOutbox': _blobOutbox,
        if (_account != null)
          'accountInfo': {
            'tier': _account!.tier,
            'usedBytes': _account!.usedBytes,
            'quotaBytes': _account!.quotaBytes,
            'vaultCount': _account!.vaultCount,
            'vaultCap': _account!.vaultCap,
          },
      }));
    } catch (_) {}
  }

  /// Delete the on-disk cache and forget its in-memory mirror. Sign-out /
  /// switch-account path, alongside [destroyPersonalData]: the cache holds the
  /// account's envelopes, outbox, and keyparams, none of which may survive
  /// into a session bound to a different account.
  Future<void> destroyLocalCache() async {
    _items.clear();
    _envByUid.clear();
    _aiEnvByUid.clear();
    _aiByUid.clear();
    _outbox.clear();
    _blobOutbox.clear();
    _account = null; // cached plan/storage belongs to the account being dropped
    _cursor = 0;
    _tombCursor = 0;
    _aiCursor = 0;
    _keyparams = null;
    try {
      final f = await _cacheFile();
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // --- outbound queue ------------------------------------------------------

  bool _permanent(int status) =>
      status == 400 || status == 402 || status == 409 || status == 413;

  Map<String, dynamic> _seal(Relic r, Map<String, dynamic> sealed) => {
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

  Future<void> _push(Relic r) async {
    // Keep the search index + visible window in step with every local mutation
    // that gets queued (captures, notes, promote). Cheap and idempotent.
    _indexUpsert(r);
    _refreshWindow();
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
      if (r.attachments.isNotEmpty)
        'attachments': Attachment.listToJson(r.attachments),
    };
    final sealed = await RelicCrypto.sealRelicPayload(_mk!, r.uid, payload);
    final env = _seal(r, sealed);
    _envByUid[r.uid] = env;
    _outbox.removeWhere((o) => o['uid'] == r.uid); // supersede older pending op
    _outbox.add({'op': 'put', 'uid': r.uid, 'env': env});
    await _saveCache();
    await _flushOutbox();
  }

  /// Try to send every queued mutation. Stops at the first transient failure
  /// (keeps the rest queued); drops permanently-rejected ops.
  Future<void> _flushOutbox() async {
    if (_outbox.isEmpty || _mk == null) return;
    final pending = List<Map<String, dynamic>>.from(_outbox);
    var sent = false;
    for (final op in pending) {
      try {
        final http.Response resp;
        if (op['op'] == 'delete') {
          resp = await http.delete(
            Uri.parse(_u('/relic/${op['uid']}')).replace(
              queryParameters: {'deleted_at': '${op['deleted_at']}'},
            ),
            headers: _headers,
          ).timeout(kNetTimeout);
        } else {
          resp = await http.put(
            Uri.parse(_u('/relic/${op['uid']}')),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode(op['env']),
          ).timeout(kNetTimeout);
        }
        if (resp.statusCode == 200 || _permanent(resp.statusCode)) {
          if (resp.statusCode == 200) emailUnverified.value = false;
          _outbox.remove(op);
          sent = true;
        } else if (resp.statusCode == 403 &&
            isEmailUnverifiedBody(resp.body)) {
          // Email not confirmed yet (VERIFY_GATE). Leave the op queued and stop;
          // it flushes once they confirm. The banner tells them what to do.
          emailUnverified.value = true;
          break;
        } else {
          break; // transient (5xx/timeout) — retry next sync
        }
      } catch (_) {
        break; // offline — keep the queue
      }
    }
    if (sent) {
      _sync = SyncState(
        // A queued blob with no queued relic op still means "not fully synced".
        // The count stays the relic-op count: an offline capture queues both,
        // and showing it as two pending things would just read as a bug.
        _outbox.isEmpty && _blobOutbox.isEmpty
            ? SyncKind.synced
            : SyncKind.pending,
        pending: _outbox.length,
      );
      await _saveCache();
    }
  }

  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // --- manual capture (the + button / share sheet / QS tile). Deliberate
  // captures are born promoted (SPEC §1). Encrypt + queue immediately; insert
  // locally so it shows before the next sync. ---
  static const _uuid = Uuid();

  String _previewLine(String s) {
    final line = s.trim().split('\n').firstWhere((_) => true, orElse: () => '');
    return line.length > 100 ? '${line.substring(0, 100)}…' : line;
  }

  /// Relic's own control/secret strings that must never be stored as content:
  /// internal deep links (`relic://auth-callback`, `relic://capture`,
  /// `relic://pair`, ...) and the recovery kit. Onboarding puts these on the
  /// clipboard, so a capture trigger firing afterward would otherwise grab one
  /// and (with auto-vault) plant it at the top of the Vault.
  static bool isUncapturable(String text) {
    final t = text.trim();
    if (t.isEmpty) return true;
    final lower = t.toLowerCase();
    return lower.startsWith('relic://') ||
        lower.contains(RecoveryKit.formatTag); // relic-mk-v1
  }

  Future<void> captureText(String text) async {
    final t = text.trim();
    if (t.isEmpty || isUncapturable(t)) return;
    try {
      await _ensureKey();
    } catch (_) {
      return;
    }
    if (_mk == null) return;
    final now = _now;
    // Re-copy dedupe (parity with the desktop watcher): identical text
    // resurfaces as the newest capture instead of duplicating. Both stamps
    // move — every list surface orders by created_at, so a bumped item that
    // kept its old created_at would look like a dropped capture.
    final i = _items.indexWhere((e) => e.kind == Kind.string && e.content == t);
    if (i >= 0) {
      final bumped = _items[i].copyWith(createdAt: now, updatedAt: now);
      _items.removeAt(i);
      _items.insert(0, bumped);
      await _push(bumped);
      return;
    }
    final r = Relic(
      uid: _uuid.v4(),
      createdAt: now,
      updatedAt: now,
      kind: Kind.string,
      source: Source.share,
      promoted: autoVault,
      byteSize: utf8.encode(t).length,
      device: deviceLabel,
      tags: _tagsFor(t), // same deterministic facets as desktop (mask-aware)
      content: t,
      preview: _previewLine(t),
    );
    _items.insert(0, r);
    await _push(r);
  }

  /// Seal + upload a blob to the Worker (chunked past 64 MiB — the edge body
  /// limit; docs/cloudflare/15-large-uploads.md). Throws on a failed upload.
  Future<void> _uploadBlob(String blobKey, Uint8List bytes) async {
    final wire = await RelicCrypto.sealBlob(_mk!, blobKey, bytes);
    await uploadBlobWire(
      endpoint: (p) => Uri.parse(_u(p)),
      headers: _headers,
      blobKey: blobKey,
      wire: wire,
    );
  }

  /// Cache the cleartext locally, then upload — and never let a failed upload
  /// take the capture down with it.
  ///
  /// The local write comes first on purpose: with it done, the relic is fully
  /// usable on this device (thumbnail, viewer, save-to-device) whether or not
  /// the bytes ever reach the server. A transient failure queues the key in
  /// [_blobOutbox] for the next sync. A [BlobRejected] is permanent (over the
  /// tier's item cap or the storage quota), so it is not queued — retrying
  /// would just fail forever; the relic stays local-only and the sync state
  /// already surfaces the rejection.
  Future<void> _putBlob(String blobKey, Uint8List bytes) async {
    await _ensureBlobDir();
    File(_blobFile(blobKey)).writeAsBytesSync(bytes);
    try {
      await _uploadBlob(blobKey, bytes);
    } on BlobRejected {
      rethrow; // permanent — the caller reports the cap/quota to the user
    } catch (_) {
      _queueBlob(blobKey);
    }
  }

  void _queueBlob(String blobKey) {
    if (!_blobOutbox.contains(blobKey)) _blobOutbox.add(blobKey);
  }

  /// Retry queued blob uploads, reading the cleartext back from the blob cache.
  /// Stops at the first transient failure (still offline) so the rest stay
  /// queued; drops keys that are permanently rejected or whose local file has
  /// gone (cache eviction — nothing left to send).
  Future<void> _flushBlobOutbox() async {
    if (_blobOutbox.isEmpty || _mk == null) return;
    await _ensureBlobDir();
    var changed = false;
    for (final key in List<String>.from(_blobOutbox)) {
      final f = File(_blobFile(key));
      if (!f.existsSync()) {
        _blobOutbox.remove(key);
        changed = true;
        continue;
      }
      try {
        await _uploadBlob(key, f.readAsBytesSync());
        _blobOutbox.remove(key);
        changed = true;
      } on BlobRejected {
        _blobOutbox.remove(key); // permanent — stop trying
        changed = true;
      } catch (_) {
        break; // still offline — keep the queue for the next sync
      }
    }
    if (changed) await _saveCache();
  }

  Future<void> captureImage(Uint8List bytes, {String? mime, String? filename}) async {
    try {
      await _ensureKey();
    } catch (_) {
      return;
    }
    if (_mk == null) return;
    final now = _now;
    final blobKey = _uuid.v4(); // 36 chars, matches the worker's blob-id regex
    await _putBlob(blobKey, bytes);
    final r = Relic(
      uid: _uuid.v4(),
      createdAt: now,
      updatedAt: now,
      kind: Kind.photo,
      source: Source.share,
      promoted: autoVault,
      byteSize: bytes.length,
      device: deviceLabel,
      mime: mime ?? 'image/jpeg',
      filename: filename,
      blobKey: blobKey,
      tags: fileTypeChips(filename),
      title: filename ?? 'Shared image',
      preview: filename ?? 'Shared image',
    );
    _items.insert(0, r);
    await _push(r);
  }

  /// Capture an arbitrary file (share sheet / picker) as a `Kind.file` relic —
  /// uploads the blob, stamps friendly file-type chips, and pushes.
  Future<void> captureFile(Uint8List bytes, {String? filename, String? mime}) async {
    try {
      await _ensureKey();
    } catch (_) {
      return;
    }
    if (_mk == null) return;
    final now = _now;
    final blobKey = _uuid.v4();
    await _putBlob(blobKey, bytes);
    final r = Relic(
      uid: _uuid.v4(),
      createdAt: now,
      updatedAt: now,
      kind: Kind.file,
      source: Source.upload,
      promoted: autoVault,
      byteSize: bytes.length,
      device: deviceLabel,
      mime: mime,
      filename: filename,
      blobKey: blobKey,
      tags: fileTypeChips(filename),
      title: filename,
      preview: filename,
    );
    _items.insert(0, r);
    await _push(r);
  }

  @override
  Future<void> promote(Relic r, bool promoted) async {
    final updated = r.copyWith(promoted: promoted, updatedAt: _now);
    _replace(updated);
    await _push(updated);
  }

  /// The per-uid bookkeeping of a delete, without the save/flush tail so
  /// [clearHistory] can batch it: drop the item + envelope + index rows +
  /// learned-ranking rows, supersede any pending put, queue the tombstone.
  void _deleteLocal(Relic r) {
    _items.removeWhere((x) => x.uid == r.uid);
    _envByUid.remove(r.uid);
    _indexDelete(r.uid);
    try {
      _personal?.deleteUid(r.uid); // forget its learned-ranking rows too
    } catch (_) {}
    _outbox.removeWhere((o) => o['uid'] == r.uid); // drop any pending put
    _outbox.add({'op': 'delete', 'uid': r.uid, 'deleted_at': _now});
  }

  @override
  Future<void> delete(Relic r) async {
    _deleteLocal(r);
    _refreshWindow();
    await _saveCache();
    await _flushOutbox();
  }

  /// Every unpromoted item in the account (the "history" scope).
  int get historyCount => _items.where((r) => !r.promoted).length;

  /// Delete every unpromoted item (Vault untouched). Local removal is
  /// immediate and batched (one save, one flush kick); the account-wide
  /// effect drains through the outbox as per-uid tombstones — there is no
  /// bulk endpoint, and the outbox persists in the cache so a queued clear
  /// survives an app kill. Returns the number removed. The caller owns the
  /// rebuild (mobile refreshes via setState, same as every other mutation).
  Future<int> clearHistory() async {
    final doomed = _items.where((r) => !r.promoted).toList();
    for (final r in doomed) {
      _deleteLocal(r);
    }
    if (doomed.isNotEmpty) {
      _refreshWindow();
      await _saveCache();
      await _flushOutbox();
    }
    return doomed.length;
  }

  // Undo-on-delete: the shared delete flow snapshots the blob, deletes, then
  // offers a 5s Undo (toast / Ctrl-Z) that genuinely restores the relic. A
  // custom save folder stays a desktop feature (mobile saves via the OS sheet).
  @override
  bool get canUndoDelete => true;

  /// Read a relic's local blob bytes (photo, or the attachment bundle) before a
  /// delete, so [restore] can rewrite them. Null when there's no cached blob.
  @override
  Future<Uint8List?> snapshotBlob(Relic r) async {
    final key = r.blobKey;
    if (key == null || _blobDir == null) return null;
    try {
      final f = File(_blobFile(key));
      return f.existsSync() ? f.readAsBytesSync() : null;
    } catch (_) {
      return null;
    }
  }

  /// Re-insert a just-deleted relic (Undo). Cancels the queued tombstone and
  /// re-pushes with a fresh updated_at so the put supersedes the delete (even if
  /// it already flushed). Rewrites — and, best-effort, re-uploads — the blob from
  /// [blob] so it survives a tombstone that GC'd it server-side.
  @override
  Future<void> restore(Relic r, {Uint8List? blob}) async {
    if (_mk == null) return; // vault locked — can't re-seal
    if (_items.any((x) => x.uid == r.uid)) return; // already back
    _outbox.removeWhere((o) => o['uid'] == r.uid && o['op'] == 'delete');
    final restored = r.copyWith(updatedAt: _now);
    final key = restored.blobKey;
    if (key != null && blob != null) {
      try {
        await _ensureBlobDir();
        File(_blobFile(key)).writeAsBytesSync(blob);
        if (restored.attachments.isNotEmpty) _unpackBundle(restored);
        await _uploadBlob(key, blob); // re-upload in case the delete GC'd it
      } on BlobRejected {
        // Permanent — the restored relic stays local-only.
      } catch (_) {
        // Offline: the local copy shows fine, and the queued re-upload makes
        // the restore reach the other devices once a sync gets through.
        _queueBlob(key);
      }
    }
    _items.insert(0, restored);
    _items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await _push(restored); // re-seal, re-queue the put, reindex + save + flush
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
    // Body edits: non-secret string relics only (a secret's plaintext must
    // never flow into preview), and empty means "unchanged".
    final newContent =
        (r.isSecret || content == null || content.trim().isEmpty)
            ? null
            : content;
    final updated = r.copyWith(
      title: title,
      note: note,
      userTags: userTags,
      tags: tags,
      content: newContent,
      preview: newContent == null ? null : _previewLine(newContent),
      byteSize: newContent != null && r.blobKey == null
          ? utf8.encode(newContent).length
          : null,
      updatedAt: _now,
    );
    _replace(updated);
    await _push(updated);
  }

  @override
  Future<String?> textOf(Relic r) async => r.content ?? r.filename;

  // --- blobs (photo/file payloads): downloaded from R2 via the Worker and
  // decrypted locally, then cached on disk so the list can show real thumbs ---
  Directory? _blobDir;
  final Set<String> _fetching = {};

  Future<Directory> _ensureBlobDir() async {
    if (_blobDir != null) return _blobDir!;
    final base = await _supportDir();
    final d = Directory('${base.path}/relic_blobs');
    if (!d.existsSync()) d.createSync(recursive: true);
    return _blobDir = d;
  }

  String _blobFile(String key) => '${_blobDir!.path}/$key';

  @override
  String? localImagePath(Relic r) {
    if (r.kind != Kind.photo) return null;
    final key = r.blobKey;
    if (key == null || _blobDir == null) return null;
    final f = File(_blobFile(key));
    return f.existsSync() ? f.path : null;
  }

  @override
  String? cachedBlobPath(Relic r) {
    final key = r.blobKey;
    if (key == null || _blobDir == null) return null;
    final f = File(_blobFile(key));
    return f.existsSync() ? f.path : null;
  }

  // --- attachments (bundle blob → per-file cache slices) -------------------

  String _attFile(String blobKey, String attId) =>
      '${_blobDir!.path}/att_${blobKey}_$attId';

  /// Slice every attachment out of a relic's already-cached bundle blob and
  /// write each to its own cache file, so [attachmentPath] can hand a real path
  /// to the viewer / open-with.
  void _unpackBundle(Relic r) {
    final key = r.blobKey;
    if (key == null || r.attachments.isEmpty || _blobDir == null) return;
    final bundleFile = File(_blobFile(key));
    if (!bundleFile.existsSync()) return;
    final bundle = bundleFile.readAsBytesSync();
    for (final a in r.attachments) {
      final out = File(_attFile(key, a.id));
      if (out.existsSync()) continue;
      final bytes = sliceAttachment(bundle, r.attachments, a.id);
      if (bytes != null) out.writeAsBytesSync(bytes);
    }
  }

  @override
  String? attachmentPath(Relic r, String attId) {
    final key = r.blobKey;
    if (key == null || _blobDir == null) return null;
    final f = File(_attFile(key, attId));
    return f.existsSync() ? f.path : null;
  }

  @override
  int get maxItemBytes => 100 * 1024 * 1024;

  @override
  bool createNote({
    String? title,
    String? body,
    List<String> userTags = const [],
    List<(String name, String? mime, Uint8List bytes)> files = const [],
    bool promote = false,
  }) {
    if (_mk == null) return false;
    final text = (body ?? '').trimRight();
    if (text.trim().isEmpty && files.isEmpty) return false; // nothing to save

    String? blobKey;
    Uint8List? bundle;
    var byteSize = utf8.encode(text).length;
    var manifest = const <Attachment>[];
    final typeTags = <String>{};
    if (files.isNotEmpty) {
      bundle = packBundle([for (final f in files) f.$3]);
      if (bundle.length > maxItemBytes) return false;
      blobKey = _uuid.v4();
      byteSize = bundle.length;
      manifest = [
        for (final f in files)
          Attachment(id: _uuid.v4(), name: f.$1, mime: f.$2, size: f.$3.length),
      ];
      for (final f in files) {
        typeTags.addAll(fileTypeChips(f.$1));
      }
    }

    final t = title?.trim();
    final r = Relic(
      uid: _uuid.v4(),
      createdAt: _now,
      updatedAt: _now,
      kind: Kind.string,
      source: Source.upload,
      promoted: promote || autoVault,
      byteSize: byteSize,
      device: deviceLabel,
      blobKey: blobKey,
      title: (t != null && t.isNotEmpty) ? t : null,
      content: text.trim().isEmpty ? null : text,
      preview: text.trim().isNotEmpty
          ? _previewLine(text)
          : (manifest.isNotEmpty ? manifest.first.name : null),
      tags: {
        ...typeTags,
        if (text.trim().isNotEmpty) ..._tagsFor(text),
      }.toList(),
      userTags: userTags,
      attachments: manifest,
    );
    _items.insert(0, r);
    _indexUpsert(r); // show it in search immediately (blob upload continues async)
    _refreshWindow();
    unawaited(_finishNote(r, blobKey, bundle));
    return true;
  }

  /// Cache + unpack the bundle locally (instant viewing), upload the blob, then
  /// queue the relic push. Runs in the background after [createNote] returns.
  Future<void> _finishNote(Relic r, String? blobKey, Uint8List? bundle) async {
    if (blobKey != null && bundle != null) {
      try {
        await _ensureBlobDir();
        File(_blobFile(blobKey)).writeAsBytesSync(bundle); // local view now
        _unpackBundle(r);
        await _uploadBlob(blobKey, bundle); // then to the server
      } on BlobRejected {
        // Permanent (over the item cap / storage quota) — don't queue a retry
        // that can only fail. The note stays fully usable on this device.
      } catch (_) {
        // Offline or a transient failure: the bundle is already cached locally,
        // so queue the upload for the next sync rather than leaving the server
        // pointing at a blob that never arrives.
        _queueBlob(blobKey);
      }
    }
    await _push(r);
  }

  @override
  Future<bool> ensureBlob(Relic r) async {
    final key = r.blobKey;
    if (key == null || _mk == null) return false;
    await _ensureBlobDir();
    if (File(_blobFile(key)).existsSync()) {
      if (r.attachments.isNotEmpty) _unpackBundle(r);
      return true;
    }
    if (!_fetching.add(key)) return false; // already in flight
    try {
      // kBlobTimeout, not kNetTimeout: this covers the whole body and a relic
      // can be 100 MB. Still bounded so a stalled transfer can't pin a spinner.
      final resp = await http
          .get(Uri.parse(_u('/blob/$key')), headers: _headers)
          .timeout(kBlobTimeout);
      if (resp.statusCode != 200) return false;
      final clear = await RelicCrypto.openBlob(_mk!, key, resp.bodyBytes);
      if (clear == null) return false;
      File(_blobFile(key)).writeAsBytesSync(clear);
      if (r.attachments.isNotEmpty) _unpackBundle(r);
      return true;
    } catch (_) {
      return false;
    } finally {
      _fetching.remove(key);
    }
  }

  @override
  Future<Uint8List?> blobBytes(Relic r) async {
    final key = r.blobKey;
    if (key == null) return null;
    if (!await ensureBlob(r)) return null;
    final f = File(_blobFile(key));
    return f.existsSync() ? f.readAsBytesSync() : null;
  }

  /// Download every not-yet-cached photo blob (call after [load]); returns how
  /// many new blobs landed so the caller can rebuild to show the thumbnails.
  Future<int> prefetchPhotos() async {
    await _ensureBlobDir();
    var fetched = 0;
    for (final r in _items) {
      if (r.kind != Kind.photo || r.blobKey == null) continue;
      if (localImagePath(r) != null) continue;
      if (await ensureBlob(r)) fetched++;
    }
    return fetched;
  }

  @override
  Future<void> putOnClipboard(Relic r) async {
    // Reaching for an item IS the personal-ranking signal (local-only, the
    // effect lands on the next query): frecency counter, plus "picked for
    // these search terms". Mirrors LocalDeskRepo.putOnClipboard minus the
    // summon context (the popup IS the app here). Bookkeeping must never
    // break the copy itself.
    if (personalRank) {
      try {
        _personal?.recordUse(r.uid, _now);
        if (_query.trim().isNotEmpty) {
          _personal?.recordQueryPick(_query, r.uid, _now);
        }
      } catch (_) {}
    }
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

  // --- E2EE share links (mirrors LocalDeskRepo.createShare) ----------------
  // The Worker gates /share behind the same auth as /relic, so a connected
  // mobile repo (always signed in) can always create links. The share payload
  // is sealed under a fresh per-share key (ShareCrypto) whose fragment rides in
  // the URL — the server only ever sees ciphertext, and the vault MK is never
  // involved (text is already in memory; blobs are decrypted via blobBytes).
  @override
  bool get canShare => token.isNotEmpty;

  @override
  Future<ShareLink> createShare(Relic r,
      {required Duration ttl, required bool oneTime}) async {
    if (!canShare) throw const ShareException('Sign in to create share links.');
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
        headers: _headers,
        body: sealed.wire,
      ).timeout(netTimeoutForBytes(sealed.wire.length));
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

  @override
  Map<String, int> tagCounts(Iterable<String> tags, {bool vaultOnly = false}) {
    final db = _index;
    final counts = <String, int>{};
    for (final t in tags) {
      final n = db != null
          ? db.countTag(t, vaultOnly: vaultOnly)
          : _items
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
  }) async {
    final n = retagInPlace(_items, from, to, userTag);
    _rebuildIndex(); // tags changed in place — reindex the affected rows
    return n;
  }
  @override
  Future<int> deleteTag(String tag, {required bool userTag}) async {
    _custom.remove(tag);
    final n = retagInPlace(_items, tag, null, userTag);
    _rebuildIndex();
    return n;
  }

  @override
  Future<void> addCustomTag(String tag) async {
    if (tag.isNotEmpty) _custom.add(tag);
  }

  @override
  bool isNotSynced(Relic r) => _outbox.any((o) => o['uid'] == r.uid);

  @override
  RelicSync relicSync(Relic r) => _outbox.any((o) => o['uid'] == r.uid)
      ? RelicSync.syncing
      : RelicSync.synced;

  void _replace(Relic r) {
    final i = _items.indexWhere((x) => x.uid == r.uid);
    if (i >= 0) _items[i] = r;
    _indexUpsert(r);
    _refreshWindow();
  }
}
