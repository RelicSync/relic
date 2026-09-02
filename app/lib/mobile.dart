import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data/api.dart';
import 'data/boot_trace.dart';
import 'data/oauth_flow.dart';
import 'data/repo.dart';
import 'data/save_prefs.dart';
import 'data/secure_key_store.dart';
import 'data/share_dedup.dart';
import 'data/supabase_auth.dart';
import 'data/worker_repo.dart';
import 'onboarding/add_device.dart';
import 'onboarding/onboarding.dart';
import 'platform/store_safe.dart';
import 'theme/relic_theme.dart';
import 'theme/tokens.dart';
import 'ui/dialogs.dart';
import 'ui/popup.dart';
import 'ui/quick_capture_tutorial.dart';
import 'widgets/chrome.dart' show SyncKind;
import 'widgets/relic_mark.dart';

/// Mobile entry point — the "lens" (SPEC §8): connect to your deployed Worker,
/// pull + decrypt your real relics, browse/search them on the phone. No
/// background clipboard capture and no on-device ML (both desktop-only).

Future<void> runMobileApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  BootTrace.mark('binding ready');
  // Resolve the saved appearance BEFORE the first frame: the boot screen then
  // paints the user's theme immediately instead of defaulting to the system
  // theme and visibly flipping once prefs load. The OS splash (which matches
  // colors.base via @color/launch_bg) covers this Keystore read.
  String ap;
  try {
    ap = await _Creds.appearance();
  } catch (_) {
    ap = 'system';
  }
  // The first secure-storage call also pays for Android Keystore init, so this
  // mark isolates a cost that lands before a single pixel is drawn.
  BootTrace.mark('appearance read');
  runApp(MobileApp(initialAppearance: ap));
  BootTrace.mark('runApp');
}

/// Connection credentials kept in the Android Keystore (encrypted), so the
/// lens silently reconnects on launch. The passphrase never leaves the device.
class _Creds {
  static const _s = FlutterSecureStorage();
  static const _kUrl = 'relic.worker.url';
  static const _kToken = 'relic.worker.token';
  static const _kPass = 'relic.worker.pass';
  static const _kTut = 'relic.quickcapture.tutorialShown';
  // Supabase sign-in (auth bridge): the persisted secret is a long-lived refresh
  // token, not a static device token. _kPass (the vault passphrase) is shared.
  static const _kAuthMode =
      'relic.auth.mode'; // 'token' | 'supabase' | 'selfhost'
  static const _kRefresh = 'relic.supabase.refresh';
  static const _kUserId = 'relic.supabase.userId';
  static const _kEmail = 'relic.supabase.email';

  /// One-time flag so the quick-capture walkthrough auto-opens only once. Kept
  /// out of [clear] so it survives a disconnect/reconnect.
  static Future<bool> tutorialShown() async => (await _s.read(key: _kTut)) == '1';
  static Future<void> markTutorialShown() => _s.write(key: _kTut, value: '1');

  static const _kPromo = 'relic.promo.addDeviceShown';
  static Future<bool> promoShown() async => (await _s.read(key: _kPromo)) == '1';
  static Future<void> markPromoShown() => _s.write(key: _kPromo, value: '1');

  // Fingerprints of recently captured shares, so a share intent Android
  // re-delivers on a later launch-from-recents isn't captured twice. See
  // [ShareDedup]. Kept out of [clear] so it survives disconnect/reconnect.
  static const _kShareSeen = 'relic.share.seen';
  static Future<Map<String, int>> shareSeen() async =>
      ShareDedup.decode(await _s.read(key: _kShareSeen));
  static Future<void> setShareSeen(Map<String, int> seen) async {
    try {
      await _s.write(key: _kShareSeen, value: ShareDedup.encode(seen));
    } catch (_) {}
  }

  static Future<({String url, String token, String pass})?> read() async {
    final url = await _s.read(key: _kUrl);
    final token = await _s.read(key: _kToken);
    final pass = await _s.read(key: _kPass);
    if (url == null || token == null || pass == null) return null;
    return (url: url, token: token, pass: pass);
  }

  static Future<void> clear() => Future.wait([
        _s.delete(key: _kUrl),
        _s.delete(key: _kToken),
        _s.delete(key: _kPass),
        _s.delete(key: _kAuthMode),
        _s.delete(key: _kRefresh),
        _s.delete(key: _kUserId),
        _s.delete(key: _kEmail),
      ]);

  // --- Supabase sign-in persistence ---
  static Future<String> authMode() async =>
      (await _s.read(key: _kAuthMode)) ?? 'token';

  /// Persist a Supabase session WITHOUT the cleartext passphrase. The unwrapped
  /// master key is cached in the OS key store instead (see SecureKeyStore), so we
  /// reconnect silently without re-deriving from the passphrase.
  static Future<void> saveSupabaseNoPass(
    String url,
    String refresh,
    String? userId,
    String? email,
  ) =>
      Future.wait([
        _s.write(key: _kAuthMode, value: 'supabase'),
        _s.write(key: _kUrl, value: url),
        _s.write(key: _kRefresh, value: refresh),
        _s.write(key: _kUserId, value: userId ?? ''),
        _s.write(key: _kEmail, value: email ?? ''),
      ]);

  /// Drop the legacy cleartext passphrase once its master key is cached.
  static Future<void> dropLegacyPass() => _s.delete(key: _kPass);

  /// Persist a self-host connection. Reuses the device-token storage (url +
  /// passphrase-derived bearer + passphrase) since self-host reconnects via the
  /// same path; `authMode='selfhost'` only flips the UI/branching. The bearer is
  /// derived once at connect and stored, so relaunch skips the Argon2 pass.
  static Future<void> saveSelfHost(String url, String token, String pass) =>
      Future.wait([
        _s.write(key: _kAuthMode, value: 'selfhost'),
        _s.write(key: _kUrl, value: url),
        _s.write(key: _kToken, value: token),
        _s.write(key: _kPass, value: pass),
      ]);

  /// Read the persisted session (no passphrase required). `legacyPass` is the old
  /// cleartext passphrase if a pre-migration install still has one.
  static Future<
      ({String url, String refresh, String? userId, String? email, String? legacyPass})?> readSupabaseSession() async {
    // Concurrent, not sequential: every read is a platform-channel round trip
    // into the Android Keystore, and five of them in series was pure latency in
    // front of the launch screen.
    final v = await Future.wait([
      _s.read(key: _kUrl),
      _s.read(key: _kRefresh),
      _s.read(key: _kUserId),
      _s.read(key: _kEmail),
      _s.read(key: _kPass),
    ]);
    final url = v[0];
    final refresh = v[1];
    if (url == null || refresh == null) return null;
    return (
      url: url,
      refresh: refresh,
      userId: v[2],
      email: v[3],
      legacyPass: v[4],
    );
  }

  static Future<void> updateRefresh(String refresh) =>
      _s.write(key: _kRefresh, value: refresh);

  // --- device-local preferences (kept out of [clear] so they survive a
  // disconnect/reconnect) ---
  static const _kDevice = 'relic.device.name';
  static const _kAutoVault = 'relic.capture.autoVault';
  static const _kAppearance = 'relic.appearance'; // 'system' | 'dark' | 'light'

  static Future<String> deviceName() async {
    // One read, not two: the old form called _s.read twice (once to null-check,
    // once for the value), doubling a Keystore platform round trip on a boot
    // path that already had far too many.
    final v = (await _s.read(key: _kDevice))?.trim();
    return (v == null || v.isEmpty) ? 'Phone' : v;
  }
  static Future<void> setDeviceName(String v) => _s.write(key: _kDevice, value: v);

  static Future<bool> autoVault() async => (await _s.read(key: _kAutoVault)) != '0';
  static Future<void> setAutoVault(bool v) =>
      _s.write(key: _kAutoVault, value: v ? '1' : '0');

  static const _kMaskSecrets = 'relic.capture.maskSecrets';
  static Future<bool> maskSecrets() async =>
      (await _s.read(key: _kMaskSecrets)) != '0'; // default on
  static Future<void> setMaskSecrets(bool v) =>
      _s.write(key: _kMaskSecrets, value: v ? '1' : '0');

  static Future<String> appearance() async =>
      (await _s.read(key: _kAppearance)) ?? 'light';
  static Future<void> setAppearance(String v) => _s.write(key: _kAppearance, value: v);

  static const _kPersonalRank = 'relic.ranking.personalRank';
  static Future<bool> personalRank() async =>
      (await _s.read(key: _kPersonalRank)) != '0'; // default on
  static Future<void> setPersonalRank(bool v) =>
      _s.write(key: _kPersonalRank, value: v ? '1' : '0');
}

/// How the app picks light vs dark.
enum Appearance { system, dark, light }

class MobileApp extends StatefulWidget {
  /// The persisted appearance ('system' | 'dark' | 'light'), resolved by
  /// [runMobileApp] before the first frame so boot paints the right theme.
  final String initialAppearance;
  const MobileApp({super.key, this.initialAppearance = 'light'});
  @override
  State<MobileApp> createState() => _MobileAppState();
}

/// Parse the persisted appearance string. Shared by the pre-frame boot path
/// and the prefs reload so both agree. Unrecognised (and unset) resolves to
/// light, which is the design's home palette; 'system' is still honoured when
/// it was explicitly chosen.
Appearance parseAppearance(String v) => switch (v) {
      'dark' => Appearance.dark,
      'system' => Appearance.system,
      _ => Appearance.light,
    };

class _MobileAppState extends State<MobileApp> with WidgetsBindingObserver {
  late Appearance _appearance = parseAppearance(widget.initialAppearance);
  String _deviceName = 'Phone';
  bool _autoVault = true;
  bool _maskSecrets = true;
  bool _personalRank = true;

  /// Where "Save to device" writes, and which choices this device supports
  /// (Downloads needs Android 10+ — see [SavePrefs.options]).
  SaveMode _saveMode = SaveMode.downloads;
  List<SaveMode> _saveOptions = const [SaveMode.ask, SaveMode.gallery];
  PackageInfo? _pkg; // version/build for the ABOUT rows (null until loaded)

  /// Resolve the effective dark/light, honouring the OS when on System. Reads
  /// the platform brightness directly so it works outside a build context.
  bool get _dark => switch (_appearance) {
        Appearance.dark => true,
        Appearance.light => false,
        Appearance.system =>
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark,
      };

  bool _booting = true; // resolving saved creds on launch

  /// Whether to draw the boot logo at all.
  ///
  /// Android 12+ already shows a splash with the launcher icon, drawn large by
  /// the system. Flutter then drew a DIFFERENT asset at 116px, so every launch
  /// popped from one logo to a smaller, differently-cropped one. Now the boot
  /// frame is just the matching background colour, and the logo only fades in
  /// if boot is slow enough that a bare colour would look broken. A normal
  /// launch never reaches it.
  bool _showBootLogo = false;

  WorkerRepo? __repo;

  /// The bound repo. Assigning moves the change subscription with it, so
  /// whatever a pull brings in repaints even when no poll tick is due — the
  /// doorbell can land a desktop's OCR or generated title while the poll is on
  /// its wide 20s cadence, and the item is very likely open on screen at that
  /// moment because opening it is what makes the wait noticeable.
  WorkerRepo? get _repo => __repo;

  set _repo(WorkerRepo? r) {
    if (identical(__repo, r)) return;
    __repo?.changes.removeListener(_onRepoChanged);
    __repo?.sessionRevoked.removeListener(_onRepoChanged);
    __repo = r;
    r?.changes.addListener(_onRepoChanged);
    // Watched separately from `changes`: a revoked session is discovered by a
    // pull that, by definition, brought nothing back, so `changes` never fires
    // and the banner would not appear until something else repainted.
    r?.sessionRevoked.addListener(_onRepoChanged);
  }

  void _onRepoChanged() {
    if (mounted) setState(() {});
  }

  bool _popupModal = false; // a popup dialog is up (hides the compose FAB)

  // Onboarding escape / reconnect state (no repo). _browseOnly shows the
  // read-only empty state; _reconnectMode marks it as a failed-reconnect (button
  // says "Reconnect" and re-opens onboarding on sign-in); _onboardAtSignIn is
  // OnboardingFlow.startAtSignIn for the switch-account + reconnect paths.
  bool _browseOnly = false;
  bool _reconnectMode = false;
  bool _onboardAtSignIn = false;
  bool _emailBannerDismissed = false; // verify-to-sync banner, session-only
  final SecureKeyStore _keyStore = SecureKeyStore.forPlatform();
  // The bottom sheet must open from a context *below* MaterialApp's Navigator;
  // this key gives us one (the State's own context is above it).
  final _navKey = GlobalKey<NavigatorState>();

  Timer? _poll; // live refresh while the app is foregrounded
  bool _refreshing = false; // guard against overlapping loads
  bool _caughtUp = false; // the foreground catch-up pass has finished

  /// Only show the syncing spinner during the catch-up sync right after the app
  /// is opened/resumed — not on every silent poll tick afterwards.
  ///
  /// Bounded by that pass finishing, never by the clock. The old version hid
  /// the spinner two seconds after foregrounding, so a cold launch with a real
  /// backlog spent the rest of its first pull showing the [SyncKind.offline]
  /// the repo is *initialised* to: the chip read "Offline" for several seconds
  /// with the network plainly working, then flipped to "Synced" the moment the
  /// items landed. Nothing was wrong with the sync; the chip was describing a
  /// state the app had never actually been in.
  bool get _showSyncSpinner => _refreshing && !_caughtUp;
  StreamSubscription<List<SharedMediaFile>>? _shareSub;
  final List<SharedMediaFile> _pendingShares = []; // shared before connect
  // Whether everything queued in [_pendingShares] arrived while Relic was
  // already on screen. A launch share drags the whole batch down to false: the
  // batch is toasted as one, so the quieter rule has to win.
  bool _pendingSharesLive = true;
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  final List<String> _pendingText = []; // captured via link before connect

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Marks the moment the user actually sees something (the boot logo), which
    // separates "the app took ages to start" from "the app started fine and
    // then sat on the splash".
    WidgetsBinding.instance.addPostFrameCallback((_) {
      BootTrace.markFirstFrame();
      unawaited(BootTrace.loadNativeStartup());
    });
    // Only reveal the boot logo if we're still booting well past the point a
    // healthy launch would have finished (measured: ~500ms to a ready vault).
    Timer(const Duration(milliseconds: 700), () {
      if (mounted && _booting) setState(() => _showBootLogo = true);
    });
    _loadPrefs();
    _autoConnect();
    _initShare();
    _initLinks();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    try {
      final p = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _pkg = p);
    } catch (_) {} // unavailable (tests) — the version row just hides
  }

  /// Load device-local prefs (device name, auto-vault, appearance) and apply
  /// them to the repo if it's already up.
  Future<void> _loadPrefs() async {
    // All independent, so read them concurrently — in series this was seven
    // more Keystore round trips racing the launch screen.
    final (dev, av, ms, ap, pr, sm, so) = await (
      _Creds.deviceName(),
      _Creds.autoVault(),
      _Creds.maskSecrets(),
      _Creds.appearance(),
      _Creds.personalRank(),
      SavePrefs.mode(),
      SavePrefs.options(),
    ).wait;
    BootTrace.mark('prefs read');
    if (!mounted) return;
    setState(() {
      _deviceName = dev;
      _autoVault = av;
      _maskSecrets = ms;
      _appearance = parseAppearance(ap);
      _personalRank = pr;
      _saveMode = sm;
      _saveOptions = so;
    });
    final repo = _repo;
    if (repo != null) {
      repo.deviceLabel = _deviceName;
      repo.autoVault = _autoVault;
      repo.maskSecrets = _maskSecrets;
      repo.personalRank = _personalRank;
    }
  }

  @override
  void didChangePlatformBrightness() {
    // Re-theme live when following the OS and it flips light/dark.
    if (_appearance == Appearance.system && mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _shareSub?.cancel();
    _linkSub?.cancel();
    __repo?.changes.removeListener(_onRepoChanged);
    __repo?.sessionRevoked.removeListener(_onRepoChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only poll while actually on screen.
    if (state == AppLifecycleState.resumed) {
      _startPolling();
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  /// Completes when [_autoConnect] has settled, however it settled: repo bound,
  /// browse-only, onboarding. A capture arriving mid-boot waits on this rather
  /// than standing up a second repo over the same cache file — see
  /// [_repoForCapture].
  final Completer<void> _bootSettled = Completer<void>();

  Future<void> _autoConnect() async {
    try {
      await _autoConnectInner();
    } finally {
      if (!_bootSettled.isCompleted) _bootSettled.complete();
    }
  }

  Future<void> _autoConnectInner() async {
    // Supabase mode: bind silently (cached master key, or a one-time legacy
    // passphrase migration). See [_silentSupabaseRepo].
    final mode = await _Creds.authMode();
    BootTrace.mark('auth mode');
    if (mode == 'supabase') {
      final repo = await _silentSupabaseRepo();
      BootTrace.mark('repo bound');
      if (repo == null) {
        // A returning user whose silent reconnect failed (expired refresh /
        // offline / can't unlock): land on the browse-only state with a
        // "Reconnect" button rather than the full onboarding wall.
        if (mounted) {
          setState(() {
            _booting = false;
            _browseOnly = true;
            _reconnectMode = true;
          });
        }
        return;
      }
      // loadLocal, NOT load: `load` also awaits syncDelta (token refresh,
      // outbox flush, /account, the paginated /relics pull), so the splash used
      // to sit there until the server answered — with the whole vault already
      // decryptable on disk. The sync still runs, it just runs behind the UI:
      // _onConnected -> _startPolling fires _silentRefresh immediately.
      try {
        await repo.loadLocal();
      } catch (_) {/* corrupt/absent cache: open empty, the sync fills it */}
      BootTrace.mark('vault ready');
      if (!mounted) return;
      setState(() {
        _repo = repo;
        _booting = false;
      });
      BootTrace.mark('list shown');
      _onConnected(repo);
      return;
    }

    final saved = await _Creds.read();
    if (saved == null) {
      if (mounted) setState(() => _booting = false);
      return;
    }
    // Self-host reconnects exactly like the legacy device-token path (the
    // persisted token is the passphrase-derived bearer); only the flag differs.
    final selfHost = await _Creds.authMode() == 'selfhost';
    final repo = WorkerRepo(
      baseUrl: saved.url,
      token: saved.token,
      passphrase: saved.pass,
    );
    repo.isSelfHost = selfHost;
    try {
      // Local-only, same as the Supabase branch above. This path still has to
      // unwrap the master key from the passphrase (there's no cached MK in
      // device-token / self-host mode), but _ensureKey falls back to the cached
      // keyparams, so it works offline too.
      await repo.loadLocal();
      if (!mounted) return;
      setState(() {
        _repo = repo;
        _booting = false;
      });
      _onConnected(repo);
    } catch (e) {
      // Never unlocked on this device (no cached keyparams) or a bad
      // passphrase — nothing decryptable to show. Fall back to the connect
      // screen (prefilled).
      if (mounted) setState(() => _booting = false);
    }
  }

  /// Bind a connected repo from the persisted session, using the cached master
  /// key (no passphrase). If only a legacy cleartext passphrase is stored,
  /// derive the key once, cache it, and drop the passphrase. Returns null when
  /// it can't unlock silently (re-onboard).
  ///
  /// The common case does NO network at all. Everything needed to open and
  /// decrypt the vault — the user id, the master key, the relic cache — is
  /// already on the device, so a cold launch has no reason to wait on Supabase.
  Future<WorkerRepo?> _silentSupabaseRepo() async {
    // Concurrent: both are platform-channel reads and neither needs the other.
    final (s, deviceId) = await (
      _Creds.readSupabaseSession(),
      DeviceId.get(),
    ).wait;
    BootTrace.mark('session read');
    if (s == null) return null;

    final storedId = s.userId;
    if (storedId != null && storedId.isNotEmpty) {
      final scope = SecureKeyStore.scopeFor(s.url, storedId);
      final mk = await _keyStore.getMasterKey(scope);
      BootTrace.mark('master key');
      if (mk != null) {
        // Bind against the cached key with an already-expired access token plus
        // the stored refresh token. _maybeRefresh runs at the top of every
        // syncDelta, so the first sync mints a fresh access token behind the
        // UI — online or off, the launch itself never blocks on it. Offline,
        // the app simply keeps working from cache until a sync gets through.
        final repo = await WorkerRepo.bindSupabaseWithMk(
          baseUrl: s.url,
          session: SupabaseSession(
            accessToken: '',
            refreshToken: s.refresh,
            expiresAt: 0, // already expired → _maybeRefresh mints on first sync
            userId: storedId,
            email: s.email,
          ),
          mk: mk,
          deviceLabel: _deviceName,
          autoVault: _autoVault,
          deviceId: deviceId,
        );
        repo.onSupabaseRefresh = (r) => _Creds.updateRefresh(r.refreshToken ?? '');
        return repo;
      }
    }

    // Slow path, and the only one that needs a network round trip to launch:
    // either this install predates the stored user id, or it still has a
    // cleartext passphrase and no cached master key (pre-migration). Both are
    // one-time; once the key is cached, every later launch takes the fast path
    // above. Offline here really does mean "can't open", because there is no
    // key on the device to decrypt with.
    final SupabaseSession session;
    try {
      session = await SupabaseAuth.refresh(s.refresh);
      await _Creds.updateRefresh(session.refreshToken);
    } catch (_) {
      return null;
    }
    final userId = session.userId;
    if (userId.isEmpty) return null;
    final scope = SecureKeyStore.scopeFor(s.url, userId);
    final mk = await _keyStore.getMasterKey(scope);

    try {
      WorkerRepo repo;
      if (mk != null) {
        repo = await WorkerRepo.bindSupabaseWithMk(
          baseUrl: s.url,
          session: session,
          mk: mk,
          deviceLabel: _deviceName,
          autoVault: _autoVault,
          deviceId: deviceId,
        );
      } else if (s.legacyPass != null && s.legacyPass!.isNotEmpty) {
        repo = await WorkerRepo.fromSession(
          baseUrl: s.url,
          session: session,
          passphrase: s.legacyPass!,
          deviceLabel: _deviceName,
          autoVault: _autoVault,
          deviceId: deviceId,
        );
        if (repo.masterKey != null) {
          await _keyStore.putMasterKey(scope, repo.masterKey!);
          await _Creds.dropLegacyPass();
        }
      } else {
        return null;
      }
      repo.onSupabaseRefresh = (r) => _Creds.updateRefresh(r.refreshToken ?? '');
      // Backfill what sent us down this path, so it's a one-time cost. Without
      // this, an install that predates the stored user id would need the
      // network on EVERY launch — exactly the thing being fixed.
      await _Creds.saveSupabaseNoPass(
        s.url,
        repo.refreshToken ?? s.refresh,
        userId,
        session.email ?? s.email,
      );
      return repo;
    } catch (_) {
      return null;
    }
  }

  /// Onboarding completed: persist the session (no cleartext passphrase) and
  /// cache the master key so future launches reconnect silently, then connect.
  Future<void> _persistAndConnect(WorkerRepo repo) async {
    // Self-host: no account/refresh token — persist the device-token trio (url +
    // passphrase-derived bearer + passphrase) so relaunch reconnects silently.
    if (repo.isSelfHost) {
      await _Creds.saveSelfHost(repo.baseUrl, repo.token, repo.passphrase);
      if (mounted) setState(() => _repo = repo);
      _onConnected(repo);
      return;
    }
    await _Creds.saveSupabaseNoPass(
      repo.baseUrl,
      repo.refreshToken ?? '',
      repo.supabaseUserId,
      repo.accountEmail,
    );
    final uid = repo.supabaseUserId;
    final mk = repo.masterKey;
    if (uid != null && mk != null) {
      await _keyStore.putMasterKey(
          SecureKeyStore.scopeFor(repo.baseUrl, uid), mk);
    }
    await _Creds.dropLegacyPass();
    repo.onSupabaseRefresh = (r) => _Creds.updateRefresh(r.refreshToken ?? '');
    if (mounted) setState(() => _repo = repo);
    _onConnected(repo);
  }

  /// Shared post-connect setup: prefetch thumbs, flush queued shares, start the
  /// live refresh loop.
  void _onConnected(WorkerRepo repo) {
    // Clear any onboarding-escape / reconnect state now that we're connected.
    _browseOnly = false;
    _reconnectMode = false;
    _onboardAtSignIn = false;
    repo.deviceLabel = _deviceName; // apply device-local prefs to captures
    repo.autoVault = _autoVault;
    repo.maskSecrets = _maskSecrets;
    repo.personalRank = _personalRank;
    // Searching during the first seconds of a launch is answered by the
    // degraded matcher while the real index builds; this repaints with the
    // proper ranking the moment it lands.
    repo.onIndexReady = () {
      if (mounted) setState(() {});
    };
    unawaited(repo.initPersonalStore()); // learned-ranking counters (on-disk)
    // No _prefetch here any more. The launch binds with a deliberately expired
    // access token, so prefetching before the first sync would fire one doomed
    // 401 per uncached photo. _startPolling -> _silentRefresh already prefetches
    // straight after syncDelta, which is the first moment the token is valid.
    _startPolling();
    _flushPending();
    _maybeShowTutorialOnce();
    _maybePromo();
  }

  /// One-time, dismissible nudge to add another device (the "promotion journey").
  bool _promo = false;
  Future<void> _maybePromo() async {
    if (await _Creds.promoShown()) return;
    if (mounted) setState(() => _promo = true);
  }

  Widget _addDeviceBanner(RelicColors c) => Material(
        color: c.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
          child: Row(
            children: [
              Icon(LucideIcons.qrCode, color: c.accent, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Use Relic on your computer too. Add a device.',
                    style: RelicTheme.sans(size: 12.5, color: c.text)),
              ),
              TextButton(
                onPressed: () => _dismissPromo(open: true),
                child: Text('Add',
                    style: RelicTheme.sans(
                        size: 13,
                        color: c.accentMuted,
                        weight: FontWeight.w600)),
              ),
              IconButton(
                icon: Icon(LucideIcons.x, size: 16, color: c.textMuted),
                onPressed: () => _dismissPromo(),
              ),
            ],
          ),
        ),
      );

  void _dismissPromo({bool open = false}) {
    _Creds.markPromoShown();
    setState(() => _promo = false);
    final r = _repo;
    final mk = r?.masterKey;
    final c = _navKey.currentContext;
    if (open && r != null && mk != null && c != null) {
      Navigator.of(c).push(MaterialPageRoute(
          builder: (_) => AddDeviceScreen(
              masterKey: mk,
              bearer: () async => r.token,
              accountId: r.supabaseUserId)));
    }
  }

  /// Read-only empty state (no repo): the "Not now" escape from onboarding and
  /// the failed-silent-reconnect landing. A single button re-opens onboarding —
  /// on the sign-in step for a reconnect, on welcome for a fresh browse-only.
  Widget _browseOnlyView(RelicColors colors) => Container(
        color: colors.base,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.eye, color: colors.textMuted, size: 40),
            const SizedBox(height: 16),
            Text('Browse-only mode. Sign in to sync your vault to this phone.',
                textAlign: TextAlign.center,
                style: RelicTheme.sans(
                    size: 14.5, color: colors.textSecondary, height: 1.5)),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => setState(() {
                _browseOnly = false;
                _onboardAtSignIn = _reconnectMode; // reconnect → sign-in step
                _reconnectMode = false;
              }),
              style: FilledButton.styleFrom(
                  backgroundColor: colors.accent,
                  foregroundColor: colors.onAccent),
              child: Text(_reconnectMode ? 'Reconnect' : 'Connect'),
            ),
          ],
        ),
      );

  /// Verify-to-sync banner (worker VERIFY_GATE 403 email_unverified). Local use
  /// is unaffected; offer a resend and a session-only dismiss.
  /// Shown when the account's session was revoked, which is what removing a
  /// device now does (it signs the account out at the IdP). Without it the sync
  /// chip reads "offline" for ever: the refresh token is gone, so no retry can
  /// ever succeed. Not dismissible, because sync stays broken until it is acted
  /// on.
  Widget _signedOutBanner(RelicColors c) => Material(
        color: c.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
          child: Row(
            children: [
              Icon(LucideIcons.logOut, color: c.accent, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    'You were signed out. Sign in again to resume syncing. '
                    'Your vault is safe on this device.',
                    style: RelicTheme.sans(
                        size: 12.5, color: c.text, height: 1.35)),
              ),
            ],
          ),
        ),
      );

  Widget _verifyBanner(RelicColors c) => Material(
        color: c.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
          child: Row(
            children: [
              Icon(LucideIcons.mailWarning, color: c.accent, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    'Confirm your email to start syncing. Local use is unaffected.',
                    style: RelicTheme.sans(
                        size: 12.5, color: c.text, height: 1.35)),
              ),
              TextButton(
                onPressed: () async {
                  final email = _repo?.accountEmail;
                  if (email == null || email.isEmpty) return;
                  try {
                    await SupabaseAuth.resendSignupConfirmation(email);
                    _toast('Confirmation email sent');
                  } catch (_) {
                    _toast('Could not resend the email.');
                  }
                },
                child: Text('Resend',
                    style: RelicTheme.sans(
                        size: 13,
                        color: c.accentMuted,
                        weight: FontWeight.w600)),
              ),
              IconButton(
                icon: Icon(LucideIcons.x, size: 16, color: c.textMuted),
                onPressed: () => setState(() => _emailBannerDismissed = true),
              ),
            ],
          ),
        ),
      );

  /// Auto-open the quick-capture walkthrough the first time the user connects,
  /// and never again (it stays available from Settings → Set up quick capture).
  Future<void> _maybeShowTutorialOnce() async {
    if (await _Creds.tutorialShown()) return;
    await _Creds.markTutorialShown();
    await Future.delayed(const Duration(milliseconds: 700)); // let the list settle
    final ctx = _navKey.currentContext;
    if (!mounted || ctx == null || !ctx.mounted) return;
    showQuickCaptureTutorial(
      ctx,
      colors: _dark ? RelicColors.dark : RelicColors.light,
    );
  }

  void _startPolling() {
    if (_repo == null) return;
    _caughtUp = false; // spinner only shows for this catch-up sync
    _poll?.cancel();
    // Incremental re-sync while foregrounded — pulls only what changed since the
    // cursor (and flushes any queued captures). Stops entirely when backgrounded
    // (see didChangeAppLifecycleState). Runs once immediately, then on a cadence
    // that adapts to the doorbell: tight (2s) until the live-sync socket is up,
    // then wide (20s) as a mere safety net once wakes deliver changes instantly.
    _silentRefresh();
    _scheduleNextPoll();
  }

  void _scheduleNextPoll() {
    _poll?.cancel();
    final live = _repo?.socketConnected ?? false;
    // Offline, a 2s cadence is just a battery drain: every tick runs a sync
    // that can only time out. Back off until something gets through — the
    // socket coming up (or a successful sync) re-arms the tight cadence.
    final offline = _repo?.sync.kind == SyncKind.offline;
    final every = live
        ? const Duration(seconds: 20)
        : (offline ? const Duration(seconds: 15) : const Duration(seconds: 2));
    _poll = Timer.periodic(every, (_) {
      // Re-arm at the other cadence if connectivity flipped either way.
      if ((_repo?.socketConnected ?? false) != live ||
          (_repo?.sync.kind == SyncKind.offline) != offline) {
        _scheduleNextPoll();
      }
      _silentRefresh();
    });
  }

  Future<void> _silentRefresh() async {
    final repo = _repo;
    if (repo == null || _refreshing) return;
    _refreshing = true;
    if (mounted) setState(() {}); // show the syncing spinner
    try {
      await repo.syncDelta();
      _prefetch(repo);
    } catch (_) {
      // transient network hiccup — next tick retries
    } finally {
      _refreshing = false;
      // However this pass ended, the catch-up is over: a failure now shows the
      // real (offline) chip rather than spinning forever.
      _caughtUp = true;
      if (mounted) setState(() {}); // hide spinner + reflect any new data
    }
  }

  Future<void> _refresh() async {
    final repo = _repo;
    if (repo == null) return;
    await repo.syncDelta();
    if (mounted) setState(() {});
    _prefetch(repo);
  }

  /// Pull photo blobs in the background; rebuild once they're cached so the
  /// real thumbnails replace the placeholders.
  void _prefetch(WorkerRepo repo) {
    repo.prefetchPhotos().then((n) {
      if (n > 0 && mounted) setState(() {});
    });
  }

  /// Ask before disconnecting — it clears the saved credentials, so the user
  /// has to sign in and re-enter their vault passphrase (or recovery kit) to get
  /// back in.
  Future<void> _confirmDisconnect() async {
    final ctx = _navKey.currentContext;
    if (ctx == null) return;
    final colors = _dark ? RelicColors.dark : RelicColors.light;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => RelicTheme(
        colors: colors,
        isMobile: true,
        child: AlertDialog(
          backgroundColor: colors.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.card),
            side: BorderSide(color: colors.borderStrong),
          ),
          title: Text('Disconnect?',
              style: RelicTheme.headline(size: 17, color: colors.text)),
          content: Text(
            'This clears your saved connection. You will need to sign in and enter your vault passphrase (or recovery kit) to reconnect. Your relics stay safe on the server.',
            style: RelicTheme.sans(size: 13.5, color: colors.textSecondary, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text('Cancel',
                  style: RelicTheme.sans(size: 13.5, color: colors.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text('Disconnect',
                  style: RelicTheme.sans(
                      size: 13.5, weight: FontWeight.w600, color: colors.danger)),
            ),
          ],
        ),
      ),
    );
    if (ok == true) await _disconnect();
  }

  Future<void> _disconnect() async {
    _poll?.cancel();
    _poll = null;
    // Learned-ranking data references this account's uids; useless without
    // them, so it goes with the connection (file + salt).
    await _repo?.destroyPersonalData();
    // The envelope cache + outbox belong to this account too — left behind
    // they would leak into (and push into) whatever account signs in next.
    await _repo?.destroyLocalCache();
    await _Creds.clear();
    if (mounted) {
      setState(() {
        _repo = null;
        _captureRepo = null;
      });
    }
  }

  /// Guided "switch account": same warning as disconnect, but after clearing the
  /// saved connection it re-opens onboarding on the sign-in step.
  Future<void> _confirmSwitchAccount() async {
    final ctx = _navKey.currentContext;
    if (ctx == null) return;
    final colors = _dark ? RelicColors.dark : RelicColors.light;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => RelicTheme(
        colors: colors,
        isMobile: true,
        child: AlertDialog(
          backgroundColor: colors.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.card),
            side: BorderSide(color: colors.borderStrong),
          ),
          title: Text('Switch account?',
              style: RelicTheme.headline(size: 17, color: colors.text)),
          content: Text(
            'This clears your saved connection, then you sign in to another account. To reconnect this one you will need its vault passphrase (or recovery kit). Your relics stay safe on the server.',
            style: RelicTheme.sans(
                size: 13.5, color: colors.textSecondary, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text('Cancel',
                  style: RelicTheme.sans(size: 13.5, color: colors.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text('Switch account',
                  style: RelicTheme.sans(
                      size: 13.5,
                      weight: FontWeight.w600,
                      color: colors.accentMuted)),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    _poll?.cancel();
    _poll = null;
    await _repo?.destroyPersonalData(); // per-account learned ranking
    await _repo?.destroyLocalCache(); // envelopes/outbox: see _disconnect
    await _Creds.clear();
    if (mounted) {
      setState(() {
        _repo = null;
        _captureRepo = null;
        _browseOnly = false;
        _reconnectMode = false;
        _onboardAtSignIn = true; // land on sign-in for the new account
      });
    }
  }

  /// Rename this device's local label to match a rename made from the devices
  /// list, so new captures pick up the new name.
  Future<void> _renameThisDevice(String label) async {
    if (mounted) setState(() => _deviceName = label);
    _repo?.deviceLabel = label;
    await _Creds.setDeviceName(label);
  }

  static const _upgradeUrl = 'https://relic.space/upgrade';

  /// Upgrade guidance (device-cap dialog): open relic.space/upgrade in the
  /// browser, falling back to copying the link. The app sells nothing in-app;
  /// upgrades happen on desktop or the web. Fine on Play; on iOS this exact
  /// shape is the Guideline 3.1.1 violation, so [storeSafeBuild] builds never
  /// reach it (call sites pass null) and it refuses defensively if one does.
  Future<void> _openUpgradeGuidance() async {
    if (storeSafeBuild) return;
    final ctx = _navKey.currentContext;
    final messenger = ctx == null ? null : ScaffoldMessenger.of(ctx);
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(_upgradeUrl),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (ok) return;
    await Clipboard.setData(const ClipboardData(text: _upgradeUrl));
    if (!mounted) return;
    messenger?.showSnackBar(const SnackBar(
        content: Text('Upgrade link copied. Open it on your computer.')));
  }

  // --- manual + share capture ---

  void _initShare() {
    // Content shared while the app was already running.
    _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      _handleShared,
      onError: (_) {},
    );
    // Content that launched the app via the share sheet.
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      if (files.isNotEmpty) {
        _handleShared(files, live: false);
        ReceiveSharingIntent.instance.reset();
      }
    });
  }

  /// [live] distinguishes a share that arrived while Relic was already on
  /// screen from one that launched it, which decides whether an
  /// already-captured share is worth saying anything about. See
  /// [_captureShared].
  void _handleShared(List<SharedMediaFile> files, {bool live = true}) {
    final repo = _repo;
    if (repo == null) {
      _pendingShares.addAll(files); // capture once connected
      if (!live) _pendingSharesLive = false;
      return;
    }
    _captureShared(repo, files, live: live);
  }

  void _flushPending() {
    final repo = _repo;
    if (repo == null) return;
    if (_pendingShares.isNotEmpty) {
      final batch = List<SharedMediaFile>.from(_pendingShares);
      final live = _pendingSharesLive;
      _pendingShares.clear();
      _pendingSharesLive = true;
      _captureShared(repo, batch, live: live);
    }
    if (_pendingText.isNotEmpty) {
      final batch = List<String>.from(_pendingText);
      _pendingText.clear();
      unawaited(_flushPendingText(repo, batch));
    }
  }

  /// Drain queued tile captures, counting the ones that actually landed. The
  /// old version fired them off unawaited and toasted `batch.length` regardless.
  Future<void> _flushPendingText(WorkerRepo repo, List<String> batch) async {
    var added = 0;
    for (final t in batch) {
      if (await repo.captureText(t)) added++;
    }
    if (!mounted) return;
    setState(() {});
    _toast(added > 0
        ? '$added captured to Relic'
        : "Couldn't capture — open Relic and retry");
  }

  // --- relic://capture deep link (Android QS tile / iOS Shortcut) ---

  String? _lastLink; // dedup the cold-start double-delivery (stream + initial)
  DateTime? _lastLinkAt;

  void _initLinks() {
    _linkSub = _appLinks.uriLinkStream.listen(_handleUri, onError: (_) {});
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) _handleUri(uri);
    });
  }

  void _handleUri(Uri uri) {
    if (uri.scheme != 'relic') return;
    // app_links delivers the launch URI via BOTH getInitialLink and the stream;
    // ignore an identical URI seen within a couple of seconds (still allows a
    // genuine repeat capture later).
    final s = uri.toString();
    final now = DateTime.now();
    if (s == _lastLink &&
        _lastLinkAt != null &&
        now.difference(_lastLinkAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastLink = s;
    _lastLinkAt = now;
    if (uri.host == 'auth-callback') {
      OAuthFlow.deliverMobileCallback(uri); // browser OAuth code -> onboarding
    } else if (uri.host == 'capture' || uri.path.contains('capture')) {
      _captureFromTrigger(uri);
    }
  }

  /// A repo good enough to capture with: the live one if loaded, else a
  /// lightweight repo built from the saved creds. captureText() unlocks the key
  /// on demand, so this never waits for the full corpus to sync.
  WorkerRepo? _captureRepo;
  Future<WorkerRepo?> _repoForCapture() async {
    if (_repo != null) return _repo;
    // A tile tap launches the app, so _autoConnect is usually still running
    // right here. Building a second repo now would give one cache file two
    // owners: each loads it, each later writes the WHOLE file back, and the
    // loser's items and outbox are erased — the capture is toasted, then
    // vanishes from the list and never uploads. Whether the clipboard read
    // needed a retry decided which repo saved last, which is why it only
    // happened sometimes. Wait for boot to settle instead.
    if (!_bootSettled.isCompleted) {
      await _bootSettled.future
          .timeout(const Duration(seconds: 10), onTimeout: () {});
      if (_repo != null) return _repo;
      // Boot is wedged, not finished. Still no safe moment to open a second
      // writer, so let the caller queue this for _flushPending.
      if (!_bootSettled.isCompleted) return null;
    }
    // Boot finished without a repo (offline, browse-only, expired session):
    // nothing else owns the cache now, so a standalone capture repo is safe.
    if (_captureRepo != null) return _captureRepo;
    if (await _Creds.authMode() == 'supabase') {
      final repo = await _silentSupabaseRepo();
      if (repo != null) {
        repo.maskSecrets = _maskSecrets;
        // Must precede any capture: _push saves the whole cache, so an unprimed
        // repo would write a one-item vault over the real one. See primeCache.
        await repo.primeCache();
        return _captureRepo = repo;
      }
    }
    final saved = await _Creds.read();
    if (saved == null) return null;
    final repo = WorkerRepo(
      baseUrl: saved.url,
      token: saved.token,
      passphrase: saved.pass,
      deviceLabel: _deviceName,
      autoVault: _autoVault,
      maskSecrets: _maskSecrets,
    );
    await repo.primeCache();
    return _captureRepo = repo;
  }

  /// Read the system clipboard, retrying briefly: a QS-tile launch invokes this
  /// during init, before the window has focus — and Android only lets the
  /// FOREGROUND, FOCUSED app read the clipboard, so the first read often returns
  /// null. Poll until the app is focused and a value appears (or give up).
  Future<String?> _readClipboard() async {
    for (var i = 0; i < 12; i++) {
      final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (t != null && t.trim().isNotEmpty) return t;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  /// Capture from a trigger: use the link's ?text= if present, else read the
  /// system clipboard once the window is focused.
  Future<void> _captureFromTrigger(Uri uri) async {
    var text = uri.queryParameters['text'];
    if (text == null || text.trim().isEmpty) {
      text = await _readClipboard();
    }
    text = text?.trim();
    if (text == null || text.isEmpty) {
      _toast('Clipboard was empty');
      return;
    }
    // Never capture Relic's own control/secret strings (internal relic:// links,
    // the recovery kit) that transit the clipboard during onboarding.
    if (WorkerRepo.isUncapturable(text)) {
      _toast('Nothing to capture');
      return;
    }
    final repo = await _repoForCapture();
    if (repo == null) {
      _pendingText.add(text); // not set up yet — capture once connected
      return;
    }
    // Never claim success we didn't have: captureText returns false when the
    // master key can't be unlocked, and the old unconditional toast made that
    // silent no-op look like a capture.
    final ok = await repo.captureText(text);
    if (_repo != null && mounted) setState(() {}); // refresh the live list
    _toast(ok ? 'Captured to Relic' : "Couldn't capture — open Relic and retry");
  }

  /// Capture shared content, reporting what landed.
  ///
  /// [live] is whether the share arrived while Relic was already on screen, and
  /// it decides one thing only: whether "everything here was already captured"
  /// is worth a toast. Sharing into a running Relic changes nothing on screen,
  /// so a skip has to be spoken or the share looks lost. A share that LAUNCHED
  /// Relic is a different situation — the vault is now in front of the user,
  /// which is answer enough, and the launch path is also where Android's
  /// replayed intents arrive (see MainActivity.stripStaleShare). Between a
  /// re-delivery, which is common, and a deliberate immediate re-share of
  /// identical bytes, which is not, the toast cannot tell; staying quiet is
  /// wrong only in the rare case, and it is never a lie.
  Future<void> _captureShared(WorkerRepo repo, List<SharedMediaFile> files,
      {bool live = true}) async {
    final seen = await _Creds.shareSeen();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var added = 0, skipped = 0, failed = 0, tooBig = 0;
    var dirty = false;
    for (final f in files) {
      try {
        // Fingerprint the content and capture it, unless we've already captured
        // this exact share recently — Android re-delivers a share's launch
        // intent when the app is reopened from recents, which would otherwise
        // resurface a days-old screenshot as a new (and desync'd) item.
        final String fp;
        final Future<bool> Function() capture;
        if (f.type == SharedMediaType.text || f.type == SharedMediaType.url) {
          fp = ShareDedup.fingerprint('txt', utf8.encode(f.path));
          capture = () => repo.captureText(f.path);
        } else {
          // An image or any other file (PDF, zip, video, …) → an image/file
          // relic. Both are read whole into memory, so check the per-item cap
          // against the file's length BEFORE the read: the server would
          // reject an oversized item anyway, and a giant readAsBytes can take
          // the whole app down long before it gets that answer.
          if (await File(f.path).length() > repo.maxItemBytes) {
            tooBig++;
            continue;
          }
          final bytes = await File(f.path).readAsBytes();
          if (f.type == SharedMediaType.image) {
            fp = ShareDedup.fingerprint('img', bytes);
            capture = () => repo.captureImage(bytes,
                mime: mimeType(f), filename: _basename(f.path));
          } else {
            fp = ShareDedup.fingerprint('file', bytes);
            capture = () => repo.captureFile(bytes,
                mime: mimeType(f), filename: _basename(f.path));
          }
        }
        if (ShareDedup.alreadySeen(seen, fp)) {
          skipped++;
          continue;
        }
        // Only remember the fingerprint for a capture that actually landed. A
        // failed capture that recorded one would be skipped as "Already in
        // Relic" on every retry for the whole 90-day window, so the content
        // could never be shared in again.
        if (await capture()) {
          seen[fp] = now;
          dirty = true;
          added++;
        } else {
          failed++;
        }
      } catch (_) {
        failed++;
      }
    }
    if (dirty) await _Creds.setShareSeen(ShareDedup.prune(seen, now));
    if (added > 0 && mounted) {
      setState(() {});
      _toast('$added added to Relic');
    } else if (skipped > 0 && live && mounted) {
      // The share was already captured — reassure rather than silently no-op.
      _toast(skipped == 1 ? 'Already in Relic' : 'Already in Relic ($skipped)');
    } else if (tooBig > 0 && mounted) {
      // Say WHY nothing landed, or the refusal reads as a bug.
      final mb = repo.maxItemBytes ~/ (1024 * 1024);
      _toast(tooBig == 1
          ? 'Too big to keep — Relic items are capped at $mb MB'
          : '$tooBig items too big to keep — the cap is $mb MB');
    } else if (failed > 0 && mounted) {
      _toast("Couldn't capture — open Relic and retry");
    }
  }

  String? mimeType(SharedMediaFile f) => f.mimeType;
  String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

  void _toast(String msg) {
    final ctx = _navKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  void _openMenu() {
    final ctx = _navKey.currentContext;
    if (ctx == null) return;
    showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      // A scroll-controlled sheet may grow to full height; without this it
      // slides under the iOS status bar and the close button lands in the
      // unreachable clock/battery strip.
      useSafeArea: true,
      // Transparent: the panel color lives inside the StatefulBuilder (below) so
      // it repaints live when appearance flips. A backgroundColor set here is
      // captured once at open time and would stay stale until the sheet reopens.
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          final colors = _dark ? RelicColors.dark : RelicColors.light;
          final acct = _repo?.account;
          return RelicTheme(
            colors: colors,
            isMobile: true,
            child: Container(
              decoration: BoxDecoration(
                color: colors.panel,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(Radii.card)),
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 2),
                        child: Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: colors.borderStrong,
                              borderRadius: BorderRadius.circular(Radii.pill),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 8, 4),
                      child: Row(
                        children: [
                          Text('Settings',
                              style: RelicTheme.headline(
                                  size: 17, color: colors.text)),
                          const Spacer(),
                          IconButton(
                            icon: Icon(LucideIcons.x, size: 20, color: colors.textMuted),
                            tooltip: 'Close',
                            onPressed: () => Navigator.pop(sheetCtx),
                          ),
                        ],
                      ),
                    ),
                    if ((_repo?.accountEmail ?? '').isNotEmpty)
                      _accountEmailRow(colors, _repo!.accountEmail!),
                    if (acct != null) _accountHeader(colors, acct),
                    // Store-safe builds state plan facts (the header above)
                    // and stop there: no upgrade copy, no pointer to where
                    // plans are sold.
                    if (acct != null && !storeSafeBuild) ...[
                      _settingLabel(colors, 'PLAN'),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                        child: Text(
                          acct.tier == 'Free'
                              ? 'Upgrade to Pro or Max in the Relic app on your '
                                  'computer, or at relic.space. Sign in there with '
                                  'this account.'
                              : 'Manage your plan in the Relic app on your computer, '
                                  'or at relic.space.',
                          style: RelicTheme.sans(
                            size: 12.5,
                            color: colors.textMuted,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                    _settingLabel(colors, 'CAPTURE'),
                    _deviceNameTile(colors, setSheet),
                    _autoVaultTile(colors, setSheet),
                    _maskSecretsTile(colors, setSheet),
                    _settingLabel(colors, 'SEARCH'),
                    _personalRankTile(colors, setSheet),
                    if (_personalRank)
                      _sheetItem(colors, LucideIcons.eraser,
                          'Clear learned ranking', () {
                        _repo?.clearPersonalMemory();
                        Navigator.pop(sheetCtx);
                        final cx = _navKey.currentContext;
                        if (cx != null) {
                          ScaffoldMessenger.of(cx).showSnackBar(
                            const SnackBar(
                              content: Text('Learned ranking cleared.'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        }
                      }),
                    _settingLabel(colors, 'FILES'),
                    _saveLocationTile(colors, setSheet),
                    _settingLabel(colors, 'APPEARANCE'),
                    _appearanceTile(colors, setSheet),
                    Divider(color: colors.border, height: 18),
                    _sheetItem(colors, LucideIcons.refreshCw, 'Refresh now', () {
                      Navigator.pop(sheetCtx);
                      _refresh();
                    }),
                    if ((_repo?.historyCount ?? 0) > 0)
                      _sheetItem(colors, LucideIcons.trash2, 'Clear all history',
                          () {
                        Navigator.pop(sheetCtx);
                        _confirmClearHistory();
                      }, color: colors.danger),
                    if ((_repo?.accountEmail ?? '').isNotEmpty)
                      _sheetItem(colors, LucideIcons.copy, 'Copy account email', () {
                        Clipboard.setData(
                          ClipboardData(text: _repo!.accountEmail!),
                        );
                        Navigator.pop(sheetCtx);
                        final cx = _navKey.currentContext;
                        if (cx != null) {
                          ScaffoldMessenger.of(cx).showSnackBar(
                            SnackBar(
                              content: Text(storeSafeBuild
                                  ? 'Account email copied.'
                                  : 'Account email copied. Sign in on desktop '
                                      'to upgrade.'),
                              duration: const Duration(seconds: 3),
                            ),
                          );
                        }
                      }),
                    // Option A: relic.space/account links to upgrade/billing,
                    // so store-safe builds must not offer a path to it
                    // (Guideline 3.1.1/3.1.3(a) — the plan's top rejection
                    // risk).
                    if (!storeSafeBuild)
                      _sheetItem(colors, LucideIcons.externalLink,
                          'Manage account', () {
                        Navigator.pop(sheetCtx);
                        _openManageAccount();
                      }),
                    _sheetItem(colors, LucideIcons.qrCode, 'Add a device', () {
                      Navigator.pop(sheetCtx);
                      final r = _repo;
                      final mk = r?.masterKey;
                      final c = _navKey.currentContext;
                      if (r != null && mk != null && c != null) {
                        Navigator.of(c).push(MaterialPageRoute(
                            builder: (_) => AddDeviceScreen(
                                masterKey: mk,
                                bearer: () async => r.token,
                                accountId: r.supabaseUserId)));
                      }
                    }),
                    _sheetItem(colors, LucideIcons.smartphone, 'Your devices', () {
                      Navigator.pop(sheetCtx);
                      final r = _repo;
                      final c = _navKey.currentContext;
                      if (r != null && c != null) {
                        Navigator.of(c).push(MaterialPageRoute(
                            builder: (_) => DevicesScreen(
                                  bearer: () async => r.token,
                                  onRenameThisDevice: _renameThisDevice,
                                  onUpgrade: storeSafeBuild
                                      ? null
                                      : _openUpgradeGuidance,
                                  upgradeLabel: storeSafeBuild
                                      ? ''
                                      : 'Upgrade on your computer or at '
                                          'relic.space/upgrade',
                                )));
                      }
                    }),
                    _sheetItem(colors, LucideIcons.shieldCheck, 'Security', () {
                      Navigator.pop(sheetCtx);
                      final r = _repo;
                      final mk = r?.masterKey;
                      final c = _navKey.currentContext;
                      if (r != null && mk != null && c != null) {
                        Navigator.of(c).push(MaterialPageRoute(
                            builder: (_) => SecurityScreen(
                                  masterKey: mk,
                                  accountEmail: r.accountEmail ?? '',
                                  onChangePassphrase: r.changePassphrase,
                                  onChangeEmail:
                                      r.isSupabase ? r.changeEmail : null,
                                  onSignOutEverywhere: r.isSupabase
                                      ? r.signOutEverywhere
                                      : null,
                                  // Raw disconnect for the sign-out-everywhere
                                  // follow-through (already confirmed there).
                                  onDisconnect: _disconnect,
                                  onDeleteAccount:
                                      r.isSupabase ? r.deleteAccount : null,
                                )));
                      }
                    }),
                    _sheetItem(colors, LucideIcons.zap, 'Set up quick capture', () {
                      Navigator.pop(sheetCtx);
                      final c = _navKey.currentContext;
                      if (c != null) showQuickCaptureTutorial(c, colors: colors);
                    }),
                    _sheetItem(colors, LucideIcons.repeat, 'Switch account', () {
                      Navigator.pop(sheetCtx);
                      _confirmSwitchAccount();
                    }),
                    _sheetItem(colors, LucideIcons.logOut, 'Disconnect', () {
                      Navigator.pop(sheetCtx);
                      _confirmDisconnect();
                    }),
                    _settingLabel(colors, 'ABOUT'),
                    if (_pkg != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                        child: Text(
                          'Relic ${_pkg!.version}+${_pkg!.buildNumber}',
                          style: RelicTheme.mono(
                              size: 12.5, color: colors.textMuted),
                        ),
                      ),
                    _sheetItem(colors, LucideIcons.globe, 'Website',
                        () => _openLink(sheetCtx, 'https://relic.space')),
                    _sheetItem(colors, LucideIcons.mail, 'Contact support',
                        () => _openLink(sheetCtx, 'mailto:support@relic.space')),
                    _sheetItem(colors, LucideIcons.shield, 'Privacy policy',
                        () => _openLink(
                            sheetCtx, 'https://relic.space/legal/privacy')),
                    _sheetItem(colors, LucideIcons.scrollText, 'Terms of service',
                        () => _openLink(
                            sheetCtx, 'https://relic.space/legal/terms')),
                    _sheetItem(colors, LucideIcons.fileCode, 'Open-source licenses',
                        () {
                      Navigator.pop(sheetCtx);
                      _showLicenses(colors);
                    }),
                    _sheetItem(colors, LucideIcons.gauge, 'Startup', () {
                      Navigator.pop(sheetCtx);
                      _showStartupTrace(colors);
                    }),
                    _sheetItem(colors, LucideIcons.clipboardCopy,
                        'Copy diagnostics', () {
                      Navigator.pop(sheetCtx);
                      _copyDiagnostics();
                    }),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Open the web account page in an external browser. Deliberately lands on a
  /// neutral, sign-in-gated account/status page (not a pricing or checkout page)
  /// so the app never steers to an out-of-store purchase flow. The app itself
  /// sells nothing; upgrades happen on desktop or relic.space.
  Future<void> _openManageAccount() async {
    final uri = Uri.parse('https://relic.space/account');
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      final cx = _navKey.currentContext;
      if (cx != null && cx.mounted) {
        ScaffoldMessenger.of(cx).showSnackBar(
          const SnackBar(
            content: Text('Could not open the browser. Visit relic.space/account.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _snack(String text, {int seconds = 2}) {
    final cx = _navKey.currentContext;
    if (cx == null) return;
    ScaffoldMessenger.of(cx).showSnackBar(SnackBar(
      content: Text(text),
      duration: Duration(seconds: seconds),
    ));
  }

  /// Open an external link (About rows). Same fallback idiom as
  /// [_openManageAccount]: if no handler takes it, surface the address.
  Future<void> _openLink(BuildContext sheetCtx, String url) async {
    Navigator.pop(sheetCtx);
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok) _snack('Could not open $url', seconds: 3);
  }

  /// Confirm, then delete every unpromoted item. Mobile is always synced, so
  /// the deletes propagate account-wide as the outbox drains.
  Future<void> _confirmClearHistory() async {
    final repo = _repo;
    final ctx = _navKey.currentContext;
    if (repo == null || ctx == null) return;
    final n = repo.historyCount;
    if (n == 0) return;
    final colors = _dark ? RelicColors.dark : RelicColors.light;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => RelicTheme(
        colors: colors,
        isMobile: true,
        child: AlertDialog(
          backgroundColor: colors.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.card),
            side: BorderSide(color: colors.borderStrong),
          ),
          title: Text('Delete $n history item${n == 1 ? '' : 's'}?',
              style: RelicTheme.headline(size: 17, color: colors.text)),
          content: Text(
            "Everything not saved to your Vault is deleted from your account and all devices. This can't be undone.",
            style: RelicTheme.sans(
                size: 13.5, color: colors.textSecondary, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text('Cancel',
                  style: RelicTheme.sans(
                      size: 13.5, color: colors.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text('Delete',
                  style: RelicTheme.sans(
                      size: 13.5,
                      weight: FontWeight.w600,
                      color: colors.danger)),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final cleared = await repo.clearHistory();
    if (mounted) setState(() {}); // the list rebuilds from repo.visible
    _snack('Cleared $cleared item${cleared == 1 ? '' : 's'}');
  }

  void _showLicenses(RelicColors colors) {
    final c = _navKey.currentContext;
    if (c == null) return;
    Navigator.of(c).push(MaterialPageRoute(
      builder: (_) => Theme(
        data: materialThemeFor(colors),
        child: LicensePage(
          applicationName: 'Relic',
          applicationVersion: _pkg?.version,
        ),
      ),
    ));
  }

  void _copyDiagnostics() {
    final v = _pkg == null ? '' : ' ${_pkg!.version}+${_pkg!.buildNumber}';
    Clipboard.setData(ClipboardData(
      text: 'Relic$v · Android ${Platform.operatingSystemVersion} · '
          'device $_deviceName · ${_repo?.all.length ?? 0} relics\n'
          '${BootTrace.report().join('\n')}',
    ));
    _snack('Diagnostics copied');
  }

  /// Show where the launch actually spent its time.
  ///
  /// Reading the code produced a confident but wrong answer about why the
  /// launch is slow, and the device can't be attached for a logcat, so the
  /// numbers come back through the UI instead. Durations only — no vault
  /// content — so the whole thing is safe to paste into a report.
  void _showStartupTrace(RelicColors colors) {
    final ctx = _navKey.currentContext;
    if (ctx == null) return;
    final lines = BootTrace.report();
    showDialog<void>(
      context: ctx,
      builder: (dctx) => RelicTheme(
        colors: colors,
        isMobile: true,
        child: AlertDialog(
          backgroundColor: colors.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.card),
            side: BorderSide(color: colors.borderStrong),
          ),
          title: Text('Startup',
              style: RelicTheme.headline(size: 17, color: colors.text)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${_repo?.all.length ?? 0} relics',
                    style: RelicTheme.mono(
                        size: 11, color: colors.textFaintest)),
                const SizedBox(height: 8),
                for (final l in lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(l,
                        style: RelicTheme.mono(
                            size: 11, color: colors.textMuted)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: lines.join('\n')));
                Navigator.pop(dctx);
                _snack('Startup timings copied');
              },
              child: Text('Copy',
                  style: RelicTheme.sans(size: 13, color: colors.accentMuted)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: Text('Close',
                  style: RelicTheme.sans(size: 13, color: colors.textMuted)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetItem(RelicColors c, IconData icon, String label, VoidCallback onTap,
          {Color? color}) =>
      ListTile(
        leading: Icon(icon, color: color ?? c.accent, size: 20),
        title: Text(label,
            style: RelicTheme.sans(size: 15, color: color ?? c.text)),
        onTap: onTap,
      );

  Widget _settingLabel(RelicColors c, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        // kicker, not label: this is a settings GROUP HEADING, which is the
        // same role desktop settings.dart gives kicker to. label() is for a
        // field's own caption. Keeping them aligned is the point of the system.
        child: Text(t, style: RelicTheme.kicker(c.textMuted)),
      );

  /// Account identity line: the signed-in email. Sits above the storage line so
  /// the account is identifiable at a glance; the copy action lives lower down.
  Widget _accountEmailRow(RelicColors c, String email) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
        child: Row(
          children: [
            Icon(LucideIcons.mail, size: 18, color: c.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Text(email,
                  style: RelicTheme.sans(size: 13.5, color: c.text)),
            ),
          ],
        ),
      );

  /// Read-only account + storage line (tier · usage · vault), from the synced
  /// [AccountInfo].
  Widget _accountHeader(RelicColors c, AccountInfo a) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Row(
          children: [
            Icon(LucideIcons.database, size: 18, color: c.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Text(a.footer,
                  style: RelicTheme.sans(size: 13, color: c.textSecondary)),
            ),
          ],
        ),
      );

  Widget _deviceNameTile(RelicColors c, StateSetter setSheet) => ListTile(
        leading: Icon(LucideIcons.smartphone, color: c.accent, size: 20),
        title: Text('Device name', style: RelicTheme.sans(size: 15, color: c.text)),
        subtitle: Text(_deviceName, style: RelicTheme.mono(size: 12, color: c.textMuted)),
        trailing: Icon(LucideIcons.pencil, size: 16, color: c.textFaint),
        onTap: () => _editDeviceName(setSheet),
      );

  Widget _autoVaultTile(RelicColors c, StateSetter setSheet) => SwitchListTile(
        value: _autoVault,
        activeThumbColor: c.accent,
        secondary: Icon(LucideIcons.star, color: c.accent, size: 20),
        title: Text('Auto-save to Vault', style: RelicTheme.sans(size: 15, color: c.text)),
        subtitle: Text('New captures go straight to your Vault',
            style: RelicTheme.sans(size: 11.5, color: c.textMuted)),
        onChanged: (v) {
          setState(() => _autoVault = v);
          setSheet(() {});
          _repo?.autoVault = v;
          _captureRepo?.autoVault = v;
          _Creds.setAutoVault(v);
        },
      );

  Widget _maskSecretsTile(RelicColors c, StateSetter setSheet) => SwitchListTile(
        value: _maskSecrets,
        activeThumbColor: c.accent,
        secondary: Icon(LucideIcons.eyeOff, color: c.accent, size: 20),
        title: Text('Mask secrets', style: RelicTheme.sans(size: 15, color: c.text)),
        subtitle: Text('Hide detected API keys and tokens in the list',
            style: RelicTheme.sans(size: 11.5, color: c.textMuted)),
        onChanged: (v) {
          setState(() => _maskSecrets = v);
          setSheet(() {});
          _repo?.maskSecrets = v;
          _captureRepo?.maskSecrets = v;
          _Creds.setMaskSecrets(v);
        },
      );

  Widget _personalRankTile(RelicColors c, StateSetter setSheet) => SwitchListTile(
        value: _personalRank,
        activeThumbColor: c.accent,
        secondary: Icon(LucideIcons.sparkles, color: c.accent, size: 20),
        title: Text('Personalized ranking',
            style: RelicTheme.sans(size: 15, color: c.text)),
        subtitle: Text(
            'Items you pick often rank higher over time. Learned and stored on this device only.',
            style: RelicTheme.sans(size: 11.5, color: c.textMuted)),
        onChanged: (v) {
          setState(() => _personalRank = v);
          setSheet(() {});
          _repo?.personalRank = v;
          _captureRepo?.personalRank = v;
          _Creds.setPersonalRank(v);
        },
      );

  /// Where "Save to device" writes. Vertical rows rather than the appearance
  /// chip strip: the labels are too long to sit side by side on a phone, and
  /// each mode needs a line of explanation.
  Widget _saveLocationTile(RelicColors c, StateSetter setSheet) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final m in _saveOptions) _saveLocationRow(c, m, setSheet),
          ],
        ),
      );

  Widget _saveLocationRow(RelicColors c, SaveMode m, StateSetter setSheet) {
    final on = _saveMode == m;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() => _saveMode = m);
        setSheet(() {});
        SavePrefs.setMode(m);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Icon(on ? LucideIcons.circleCheck : LucideIcons.circle,
                size: 18, color: on ? c.accent : c.textFaint),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.label,
                      style: RelicTheme.sans(
                          size: 14.5,
                          weight: on ? FontWeight.w600 : FontWeight.w400,
                          color: c.text)),
                  const SizedBox(height: 1),
                  Text(m.blurb,
                      style:
                          RelicTheme.sans(size: 11.5, color: c.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _appearanceTile(RelicColors c, StateSetter setSheet) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Row(
          children: [
            for (final a in Appearance.values) ...[
              Expanded(child: _appearanceChip(c, a, setSheet)),
              if (a != Appearance.values.last) const SizedBox(width: 8),
            ],
          ],
        ),
      );

  Widget _appearanceChip(RelicColors c, Appearance a, StateSetter setSheet) {
    final on = _appearance == a;
    final label = switch (a) {
      Appearance.system => 'System',
      Appearance.dark => 'Dark',
      Appearance.light => 'Light',
    };
    return GestureDetector(
      onTap: () {
        setState(() => _appearance = a);
        setSheet(() {});
        _Creds.setAppearance(a.name);
      },
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? c.selected : c.surface,
          borderRadius: BorderRadius.circular(Radii.input),
          border: on ? null : Border.all(color: c.border),
        ),
        child: Text(label,
            style: RelicTheme.sans(
                size: 13,
                weight: FontWeight.w600,
                color: on ? c.textOnSelected : c.textSecondary)),
      ),
    );
  }

  Future<void> _editDeviceName(StateSetter setSheet) async {
    final ctx = _navKey.currentContext;
    if (ctx == null) return;
    final colors = _dark ? RelicColors.dark : RelicColors.light;
    final ctl = TextEditingController(text: _deviceName);
    final name = await showDialog<String>(
      context: ctx,
      builder: (dctx) => RelicTheme(
        colors: colors,
        isMobile: true,
        child: AlertDialog(
          backgroundColor: colors.panel,
          title: Text('Device name',
              style: RelicTheme.headline(size: 17, color: colors.text)),
          content: TextField(
            controller: ctl,
            autofocus: true,
            style: RelicTheme.sans(size: 15, color: colors.text),
            cursorColor: colors.accent,
            decoration: const InputDecoration(hintText: 'e.g. Galaxy S21'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: Text('Cancel',
                  style: RelicTheme.sans(size: 13.5, color: colors.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dctx, ctl.text.trim()),
              child: Text('Save',
                  style: RelicTheme.sans(
                      size: 13.5,
                      weight: FontWeight.w600,
                      color: colors.accentMuted)),
            ),
          ],
        ),
      ),
    );
    if (name != null && name.isNotEmpty) {
      setState(() => _deviceName = name);
      setSheet(() {});
      _repo?.deviceLabel = name;
      _captureRepo?.deviceLabel = name;
      await _Creds.setDeviceName(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = _dark ? RelicColors.dark : RelicColors.light;
    final Widget body;
    if (_booting) {
      // Deliberately continuous with the OS splash: same colour, no second
      // logo. See [_showBootLogo] for why the icon is delayed rather than
      // drawn immediately.
      body = Container(
        color: colors.base,
        alignment: Alignment.center,
        child: AnimatedOpacity(
          opacity: _showBootLogo ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          // The bare mark, not the OS icon raster: the tile behind that one
          // exists to survive a taskbar, and reads as a cream square here.
          child: const RelicIcon(size: 116),
        ),
      );
    } else if (_repo == null && _browseOnly) {
      body = _browseOnlyView(colors);
    } else if (_repo == null) {
      body = OnboardingFlow(
        defaultDeviceName: _deviceName,
        autoVault: _autoVault,
        onConnected: _persistAndConnect,
        startAtSignIn: _onboardAtSignIn,
        onBrowseOnly: () => setState(() {
          _browseOnly = true;
          _reconnectMode = false;
        }),
      );
    } else {
      final popup = PopupView(
        // Keyed to brightness so a light/dark flip cleanly remounts the list
        // with the new palette. The key only changes on a flip, so ordinary
        // refreshes keep scroll/search state.
        key: ValueKey(_dark),
        repo: _repo!,
        onClose: () {},
        onSettings: _openMenu,
        onRefresh: _refresh,
        syncing: _showSyncSpinner,
        // Hide the compose FAB while a dialog (edit/share/confirm) is up — it
        // floats above the Scaffold and would cover the dialog's footer.
        onModalChanged: (open) {
          if (mounted && open != _popupModal) {
            setState(() => _popupModal = open);
          }
        },
      );
      // Stack banners above the list: the add-device promo and the
      // verify-to-sync notice (email not confirmed). Both dismiss per-session.
      final banners = <Widget>[
        if (_repo!.sessionRevoked.value) _signedOutBanner(colors),
        if (_promo) _addDeviceBanner(colors),
        if (_repo!.emailUnverified.value && !_emailBannerDismissed)
          _verifyBanner(colors),
      ];
      body = banners.isEmpty
          ? popup
          : Column(children: [...banners, Expanded(child: popup)]);
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Relic',
      navigatorKey: _navKey,
      // Theme above the Navigator too, so pushed routes (AddDevice, Devices,
      // Security, compose) and sheets can read RelicTheme.of without a re-wrap.
      builder: (context, child) => RelicTheme(
        colors: colors,
        isMobile: true,
        child: child ?? const SizedBox.shrink(),
      ),
      home: RelicTheme(
        colors: colors,
        isMobile: true,
        child: Scaffold(
          backgroundColor: colors.base,
          resizeToAvoidBottomInset: false,
          // bottom: false — the popup surface runs under the home indicator
          // (it pads its own list/toast by the inset); a bottom SafeArea here
          // leaves a dead bar under the FAB on iPhone.
          body: SafeArea(bottom: false, child: body),
          // Manual capture — only once connected, and never over a dialog.
          floatingActionButton: _repo == null || _popupModal
              ? null
              : FloatingActionButton(
                  onPressed: _openCompose,
                  backgroundColor: colors.accent,
                  foregroundColor: colors.onAccent,
                  child: const Icon(LucideIcons.plus),
                ),
        ),
      ),
    );
  }

  /// The rich "+" composer (shared with desktop): title, body, tags, and file
  /// attachments, with an optional "Save to Vault". Hosted in a full-screen
  /// route so the soft keyboard pushes the fields up instead of covering them.
  Future<void> _openCompose() async {
    final repo = _repo;
    final ctx = _navKey.currentContext;
    if (repo == null || ctx == null) return;
    final colors = _dark ? RelicColors.dark : RelicColors.light;
    await Navigator.of(ctx).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (routeCtx) => RelicTheme(
        colors: colors,
        isMobile: true,
        child: Scaffold(
          backgroundColor: colors.base,
          resizeToAvoidBottomInset: true,
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: ComposeDialog(
                  repo: repo,
                  onCancel: () => Navigator.of(routeCtx).pop(),
                  onCreate: (title, body, tags, files, promote) {
                    final ok = repo.createNote(
                      title: title,
                      body: body,
                      userTags: tags,
                      files: files,
                      promote: promote,
                    );
                    Navigator.of(routeCtx).pop();
                    if (mounted) setState(() {});
                    _toast(ok
                        ? (promote || repo.autoVault ? 'Created in Vault' : 'Created')
                        : 'Couldn’t create. Too large or empty');
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    ));
  }
}
