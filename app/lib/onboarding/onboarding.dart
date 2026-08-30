import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/api.dart';
import '../data/device_directory.dart';
import '../data/oauth_flow.dart';
import '../data/pairing.dart';
import '../data/recovery.dart';
import '../data/selfhost_link.dart';
import '../data/supabase_auth.dart';
import '../data/worker_repo.dart';
import '../platform/store_safe.dart';
import '../services/onboarding_service.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/brand.dart';
import '../widgets/passphrase_field.dart';
import 'add_device.dart';

/// The unified device-onboarding flow (docs/cloudflare/13-device-onboarding.md).
/// Replaces the old URL+token+passphrase connect screen. Two paths: create a new
/// vault, or add this device (sign in, then unlock passphrase-first / QR / kit).
class OnboardingFlow extends StatefulWidget {
  final String defaultDeviceName;
  final bool autoVault;
  final void Function(WorkerRepo repo) onConnected;

  /// Start on the sign-in step instead of the welcome screen — used by the
  /// guided "switch account" and the failed-silent-reconnect ("Reconnect")
  /// paths so the returning user lands straight on sign-in.
  final bool startAtSignIn;

  /// Quiet "Not now" escape on the welcome screen: exit into the host's
  /// browse-only empty state (no repo). Null hides the affordance.
  final VoidCallback? onBrowseOnly;
  const OnboardingFlow({
    super.key,
    required this.onConnected,
    this.defaultDeviceName = 'Phone',
    this.autoVault = true,
    this.startAtSignIn = false,
    this.onBrowseOnly,
  });

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

enum _Step {
  welcome,
  create,
  confirmEmail, // email-confirmation required: created, awaiting the inbox link
  oauthCreatePass, // OAuth path: passphrase-only vault creation (already authed)
  recoveryKit,
  signIn,
  unlockChooser,
  passphrase,
  scanQr,
  codeEntry,
  sas,
  recoveryEntry,
  selfHost, // point this device at the user's own self-hosted server
  selfHostScan, // scan a self-host QR to prefill the server address
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  late final OnboardingService _svc;
  _Step _step = _Step.welcome;
  bool _busy = false;
  String? _error;
  String? _notice; // non-error feedback (e.g. "reset link sent")

  // carried across steps
  String _email = '', _password = '', _deviceName = '';
  String _pendingEmail = ''; // address awaiting email confirmation
  bool _viaOAuth = false; // session came from the browser OAuth flow, not email/pw
  SupabaseSession? _session;
  WorkerRepo? _pendingRepo; // create path: connected, awaiting kit-saved
  NewDevicePairing? _pairing;
  String? _sas;

  // Set when a post-sign-in hasVault() check hit a hard (non-200/404) error, so
  // the current step shows a "Try again" button that re-runs just the routing
  // (the session is kept) instead of dead-ending.
  Future<void> Function()? _retry;

  // Recovery-kit re-entry proof: quiz the user on two random groups before they
  // can leave the kit screen (first save only).

  // Self-host form (persistent so text survives rebuilds).
  final _shUrl = TextEditingController();
  final _shPass = TextEditingController();
  final _shSecret = TextEditingController();
  bool _shAdvanced = false;

  @override
  void initState() {
    super.initState();
    _deviceName = widget.defaultDeviceName;
    if (widget.startAtSignIn) _step = _Step.signIn;
    DeviceId.get().then((id) => _svc = OnboardingService(deviceId: id));
  }

  @override
  void dispose() {
    _pairing?.cancel(); // stop any orphan relay poll when the flow is torn down
    _shUrl.dispose();
    _shPass.dispose();
    _shSecret.dispose();
    super.dispose();
  }

  void _zero(Uint8List b) {
    for (var i = 0; i < b.length; i++) {
      b[i] = 0;
    }
  }

  void _go(_Step s) => setState(() {
        _error = null;
        _notice = null;
        _retry = null;
        _step = s;
      });

  static const _upgradeUrl = 'https://relic.space/upgrade';

  /// Upgrade guidance for the device-cap dialog: open relic.space/upgrade in
  /// the browser, falling back to copying the link. Mobile sells nothing
  /// in-app; upgrades happen on desktop or the web. Never reached on
  /// [storeSafeBuild] builds (App Store 3.1.1) — call sites pass null.
  Future<void> _openUpgradeGuidance() async {
    if (storeSafeBuild) return;
    final messenger = ScaffoldMessenger.of(context);
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
    messenger.showSnackBar(const SnackBar(
        content: Text('Upgrade link copied. Open it on your computer.')));
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
    } catch (e) {
      setState(() => _error = _human(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _human(Object e) {
    if (e is RecoveryKitException) {
      return e.kind == RecoveryKitError.format
          ? "That doesn't look like a Relic recovery kit."
          : 'That recovery kit looks mistyped. Check it and try again.';
    }
    if (e is PairingCodeException) {
      return e.kind == PairingCodeError.checksum
          ? 'That code looks mistyped. Check it and try again.'
          : "That doesn't look like a Relic pairing code.";
    }
    if (e is PairingAccountMismatch) return e.message;
    if (e is PairedKeyMismatch) return e.message;
    if (e is PairingTimeout) {
      return 'Pairing timed out. The code is only live for about two minutes.';
    }
    final s = e.toString().replaceFirst('StateError: ', '').replaceFirst('Exception: ', '');
    return s.isEmpty ? 'Something went wrong.' : s;
  }

  /// Register this device, then hand the connected repo to the host. A device-cap
  /// 409 is surfaced (remove-or-upgrade) rather than silently swallowed; any other
  /// failure (offline) is non-fatal — the vault already works on this device.
  Future<void> _finish(WorkerRepo repo) async {
    final dir = _svc.devicesForRepo(repo);
    try {
      await dir.register(label: _deviceName, platform: DeviceId.platform());
    } on DeviceCapException catch (e) {
      if (mounted) {
        await showDeviceCapDialog(context,
            directory: dir,
            devices: e.devices,
            label: _deviceName,
            platform: DeviceId.platform(),
            onUpgrade: storeSafeBuild ? null : _openUpgradeGuidance,
            upgradeLabel: storeSafeBuild
                ? ''
                : 'Upgrade on your computer or at relic.space/upgrade');
      }
    } catch (_) {/* offline: non-fatal, the vault still works here */}
    widget.onConnected(repo);
  }

  // --- actions ---------------------------------------------------------------

  /// Email sign-up: create the ACCOUNT only — no vault, no passphrase yet. The
  /// vault passphrase is chosen later, after the user confirms their email and
  /// signs in (auth != vault key), so a passphrase can never be silently
  /// discarded. Confirmation is required, so signUp throws
  /// [EmailConfirmationPending] and we route to the confirm step. If confirmation
  /// is ever off, a session comes back and we route straight to set-passphrase,
  /// exactly like the OAuth path.
  Future<void> _signUpAccount() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _session = await SupabaseAuth.signUp(_email, _password);
      _viaOAuth = true; // route the passphrase step through the session
      await _routeAfterAuth();
    } on EmailConfirmationPending catch (e) {
      _pendingEmail = e.email;
      _go(_Step.confirmEmail);
    } catch (e) {
      setState(() => _error = _human(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Enter the recovery-kit step. (The old re-type-two-groups proof was cut
  /// 2026-08-12 as too much friction on a phone keyboard; the copy/download
  /// buttons and the warning header carry the weight now. Desktop still has
  /// its own version of the proof — see docs/android-apple-parity.md.)
  void _enterRecoveryKit(WorkerRepo repo) {
    _pendingRepo = repo;
    _go(_Step.recoveryKit);
  }

  Future<void> _resendConfirmation() => _run(() async {
        await SupabaseAuth.resendSignupConfirmation(_pendingEmail);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Confirmation email sent')));
        }
      });

  /// Send a Supabase password-reset email for the address typed in the
  /// sign-in form. Mirrors the desktop flow (desktop_onboarding.dart); this
  /// resets the ACCOUNT password only, never the vault passphrase.
  Future<void> _forgotPassword(String email) async {
    email = email.trim();
    if (email.isEmpty) {
      setState(() {
        _error = 'Enter your email above, then tap Forgot password.';
        _notice = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await SupabaseAuth.sendPasswordReset(email);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = 'Reset link sent to $email. Check your email.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _downloadKit(String kit) async {
    try {
      await downloadRecoveryKit(kit);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Recovery kit saved')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not save the recovery kit')));
      }
    }
  }

  /// Browser OAuth: sign in via provider, then auto-route to create (no vault
  /// yet) or unlock (existing vault). Auth != vault key, so a passphrase step
  /// still follows.
  Future<void> _startOAuth(SupabaseProvider provider) => _run(() async {
        final session = await OAuthFlow.signInWithProvider(provider, desktop: false);
        _session = session;
        _viaOAuth = true;
        _email = session.email ?? '';
        await _routeAfterAuth();
      });

  /// Post-sign-in routing: does this account already have a vault? A hard error
  /// (GET /keyparams not 200/404) leaves the user on the current step with a
  /// "Try again" button ([_retry]) that re-runs just this check — the session is
  /// already valid, so we never make them re-authenticate.
  Future<void> _routeAfterAuth() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final existing = await _svc.hasVault(_session!);
      _retry = null;
      _go(existing ? _Step.unlockChooser : _Step.oauthCreatePass);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _human(e);
          _retry = _routeAfterAuth;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// OAuth create path: make the vault under [passphrase] from the OAuth session.
  Future<void> _createVaultViaSession(String passphrase) => _run(() async {
        final repo = await _svc.createVaultFromSession(
          session: _session!,
          passphrase: passphrase,
          deviceLabel: _deviceName,
          autoVault: widget.autoVault,
        );
        _enterRecoveryKit(repo);
      });

  Future<void> _unlockPassphrase(String passphrase) => _run(() async {
        final repo = _viaOAuth
            ? await _svc.unlockWithSession(
                session: _session!,
                passphrase: passphrase,
                deviceLabel: _deviceName,
                autoVault: widget.autoVault,
              )
            : await _svc.unlockWithPassphrase(
                email: _email,
                password: _password,
                passphrase: passphrase,
                deviceLabel: _deviceName,
                autoVault: widget.autoVault,
              );
        await _finish(repo);
      });

  Future<void> _signInForUnlock() => _run(() async {
        _session = await _svc.signIn(_email, _password);
        _viaOAuth = true; // route the passphrase step through the session
        // Auto-detect: a fresh/empty account has no vault yet → set a passphrase;
        // an existing one → unlock (passphrase / QR / recovery kit). A hard
        // hasVault error surfaces a "Try again" (see [_routeAfterAuth]).
        await _routeAfterAuth();
      });

  Future<void> _onQrScanned(String raw) => _run(() async {
        final relay = _svc.relayForSession(_session!);
        try {
          final pairing = await NewDevicePairing.fromQr(relay, raw,
              localAccountId: _session!.userId);
          _pairing = pairing;
          final sas = await pairing.handshake();
          _sas = sas;
          _go(_Step.sas);
        } catch (e) {
          // Reset on failure so the scanner accepts a fresh QR immediately —
          // without this the `_pairing == null` guard in onDetect silently
          // blocks every retry after a timeout.
          _pairing?.cancel();
          _pairing = null;
          rethrow;
        }
      });

  Future<void> _onCodeEntered(String typed) => _run(() async {
        final relay = _svc.relayForSession(_session!);
        try {
          final pairing = await NewDevicePairing.fromCode(relay, typed,
              localAccountId: _session!.userId);
          _pairing = pairing;
          final sas = await pairing.handshake();
          _sas = sas;
          _go(_Step.sas);
        } catch (e) {
          // Same reset as the QR path: a dead handshake must not leave a
          // half-open pairing behind the retry.
          _pairing?.cancel();
          _pairing = null;
          rethrow;
        }
      });

  /// The user confirmed the SAS matches. Fetch the sealed MK, prove it opens
  /// this account's vault (defends against a same-SAS but wrong-account handoff),
  /// then bind. A validation failure zeroes the key, drops the pairing, and lands
  /// back on the chooser with the error — nothing is persisted.
  Future<void> _confirmSasAndReceive() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final mk = await _pairing!.receiveMk();
      try {
        await _svc.verifyPairedMk(_session!, mk);
      } on PairedKeyMismatch catch (e) {
        _zero(mk);
        _pairing = null;
        if (mounted) {
          setState(() {
            _busy = false;
            _step = _Step.unlockChooser;
            _error = e.message;
          });
        }
        return;
      }
      final repo = await _svc.bindFromPairedKey(
        session: _session!,
        mk: mk,
        deviceLabel: _deviceName,
        autoVault: widget.autoVault,
      );
      await _finish(repo);
    } catch (e) {
      // The relay slots are single-use with a short TTL: after a failed
      // receive, this pairing session is dead on BOTH sides. Retrying from the
      // SAS screen can never succeed, so tear down and land on the chooser
      // where "Scan a QR" starts a fresh session.
      _pairing?.cancel();
      _pairing = null;
      if (mounted) {
        setState(() {
          _step = _Step.unlockChooser;
          _error =
              '${_human(e)} Start again: choose Add a device on your other device, then scan the new code.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// NEW rejected the SAS (the codes differ). Cancel the handshake — the MK is
  /// never requested — and return to the chooser with a tamper warning.
  void _rejectSas() {
    _pairing?.cancel();
    _pairing = null;
    setState(() {
      _step = _Step.unlockChooser;
      _error =
          'Pairing canceled. If the codes keep differing, someone may be interfering with your connection. Try again on a network you trust.';
    });
  }

  Future<void> _unlockKit(String kit, String newPass) => _run(() async {
        final repo = await _svc.unlockWithRecoveryKit(
          session: _session!,
          kitText: kit,
          newPassphrase: newPass,
          deviceLabel: _deviceName,
          autoVault: widget.autoVault,
        );
        await _finish(repo);
      });

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Theme(
      data: materialThemeFor(c),
      child: Scaffold(
        backgroundColor: c.base,
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: Motion.panel,
            child: _body(c),
          ),
        ),
      ),
    );
  }

  Widget _body(RelicColors c) {
    switch (_step) {
      case _Step.welcome:
        return _welcome(c);
      case _Step.create:
        return _createForm(c);
      case _Step.confirmEmail:
        return _confirmEmailView(c);
      case _Step.oauthCreatePass:
        return _oauthCreatePassView(c);
      case _Step.recoveryKit:
        return _recoveryKitView(c);
      case _Step.signIn:
        return _signInForm(c);
      case _Step.unlockChooser:
        return _unlockChooser(c);
      case _Step.passphrase:
        return _passphraseView(c);
      case _Step.scanQr:
        return _scanView(c);
      case _Step.codeEntry:
        return _codeEntryView(c);
      case _Step.sas:
        return _sasView(c);
      case _Step.recoveryEntry:
        return _recoveryEntryView(c);
      case _Step.selfHost:
        return _selfHostForm(c);
      case _Step.selfHostScan:
        return _selfHostScanView(c);
    }
  }

  // --- screens ---------------------------------------------------------------

  Widget _scroll(List<Widget> children, {Key? key}) => SingleChildScrollView(
        key: key,
        padding: const EdgeInsets.fromLTRB(
            Insets.xxl, Insets.xxxl, Insets.xxl, Insets.xxxl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );

  Widget _welcome(RelicColors c) => _scroll(key: const ValueKey('welcome'), [
        const SizedBox(height: Insets.xxxl),
        // Wordmark follows the theme ink — the cream default is only readable
        // on dark.
        Center(child: RelicWordmark(markSize: 40, color: c.text)),
        const SizedBox(height: Insets.xxxl),
        // The one hero line in the app: display face, set tight.
        Text('Everything you copy,\non every device.',
            textAlign: TextAlign.center,
            style: RelicTheme.headline(size: 30, color: c.text, height: 1.15)),
        const SizedBox(height: Insets.md),
        Text('Sign in to sync and back up your vault, end-to-end encrypted.',
            textAlign: TextAlign.center,
            style: RelicTheme.sans(size: 14, color: c.textSecondary, height: 1.5)),
        const SizedBox(height: Insets.section),
        OAuthButton(
            provider: SupabaseProvider.google,
            onPressed: _busy ? null : () => _startOAuth(SupabaseProvider.google)),
        const SizedBox(height: Insets.md),
        OAuthButton(
            provider: SupabaseProvider.github,
            onPressed: _busy ? null : () => _startOAuth(SupabaseProvider.github)),
        const SizedBox(height: Insets.md),
        OAuthButton(
            provider: SupabaseProvider.apple,
            onPressed: _busy ? null : () => _startOAuth(SupabaseProvider.apple)),
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(top: Insets.md),
            child: Text('Waiting for your browser…',
                textAlign: TextAlign.center,
                style: RelicTheme.sans(size: 12.5, color: c.textMuted)),
          ),
        if (_error != null) _errorText(c, _error!),
        _retryButton(c),
        _orDivider(c),
        _secondaryBtn(c, 'Create with email', _busy ? null : () => _go(_Step.create)),
        const SizedBox(height: Insets.md),
        _secondaryBtn(c, 'Add this device', _busy ? null : () => _go(_Step.signIn)),
        const SizedBox(height: Insets.xs),
        _quietBtn(c, 'Use your own server', _busy ? null : () => _go(_Step.selfHost)),
        if (widget.onBrowseOnly != null)
          _quietBtn(c, 'Not now', _busy ? null : widget.onBrowseOnly),
      ]);

  // OAuth create: already signed in via a provider; just set the vault passphrase.
  Widget _oauthCreatePassView(RelicColors c) {
    final phrase = TextEditingController();
    final confirm = TextEditingController();
    final name = TextEditingController(text: _deviceName);
    return _scroll(key: const ValueKey('oauthcreate'), [
      _header(c, 'Set your vault passphrase',
          '${_email.isEmpty ? 'Signed in' : 'Signed in as $_email'}. Your vault passphrase seals your data. We never see it and cannot reset it. Use a long phrase.'),
      VaultPassphraseField(
          controller: phrase, confirmController: confirm, hint: 'Choose a vault passphrase'),
      _field(c, confirm, 'Repeat the vault passphrase', obscure: true, mono: true),
      _field(c, name, 'Device name', onChanged: (v) => _deviceName = v),
      if (_error != null) _errorText(c, _error!),
      const SizedBox(height: Insets.lg),
      _primaryBtn(c, 'Create vault', _busy
          ? null
          : () {
              _deviceName = name.text.trim().isEmpty ? 'Device' : name.text.trim();
              if (phrase.text.isEmpty) {
                setState(() => _error = 'Choose a passphrase.');
                return;
              }
              if (phrase.text != confirm.text) {
                setState(() => _error = "Passphrases don't match.");
                return;
              }
              _createVaultViaSession(phrase.text);
            }),
      _backBtn(c, () => _go(_Step.welcome)),
    ]);
  }

  // Create: the ACCOUNT only (email + password). The vault passphrase is set
  // later, after email confirmation and sign-in (see _signUpAccount, which routes
  // through the same set-passphrase step as OAuth).
  Widget _createForm(RelicColors c) {
    final email = TextEditingController(text: _email);
    final pass = TextEditingController(text: _password);
    final name = TextEditingController(text: _deviceName);
    return _scroll(key: const ValueKey('create'), [
      _header(c, 'Create your account',
          'Start with just an email and a password. You will set your vault passphrase after you confirm your email.'),
      Text(
          'Your account password signs you in. Your vault passphrase, which seals your data end-to-end, comes next and we never see it.',
          style: RelicTheme.sans(size: 12, color: c.textMuted, height: 1.5)),
      const SizedBox(height: Insets.lg),
      _field(c, email, 'Email', keyboard: TextInputType.emailAddress),
      _field(c, pass, 'Account password', obscure: true, mono: true),
      _field(c, name, 'Device name', onChanged: (v) => _deviceName = v),
      if (_error != null) _errorText(c, _error!),
      const SizedBox(height: Insets.lg),
      _primaryBtn(c, 'Create account', _busy
          ? null
          : () {
              _email = email.text.trim();
              _password = pass.text;
              _deviceName = name.text.trim().isEmpty ? 'Device' : name.text.trim();
              if (_email.isEmpty || _password.isEmpty) {
                setState(() => _error = 'Enter your email and a password.');
                return;
              }
              _signUpAccount();
            }),
      _backBtn(c, () => _go(_Step.welcome)),
    ]);
  }

  Widget _recoveryKitView(RelicColors c) {
    final repo = _pendingRepo!;
    final kit = RecoveryKit.fromMk(repo.masterKey!, repo.accountEmail ?? '');
    return _scroll(key: const ValueKey('kit'), [
      _header(c, 'Save your recovery kit',
          'The only way back into your data if you forget your vault passphrase. We cannot recover it for you.'),
      // The kit is a secret, so it sits in the system's warm well: gold-tint
      // ground with deep-gold mono text. Bright gold as text on a bare card is
      // the one thing this palette must never do.
      Container(
        padding: const EdgeInsets.all(Insets.xl),
        decoration: BoxDecoration(
            color: c.tagBg,
            borderRadius: BorderRadius.circular(Radii.card)),
        child: SelectableText(kit,
            style: RelicTheme.mono(size: 13, color: c.tagText, height: 1.8)),
      ),
      const SizedBox(height: Insets.md),
      Row(children: [
        Expanded(
          child: _secondaryBtn(c, 'Copy', () {
            Clipboard.setData(ClipboardData(text: kit));
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Recovery kit copied')));
          }),
        ),
        const SizedBox(width: Insets.md),
        Expanded(child: _secondaryBtn(c, 'Download', () => _downloadKit(kit))),
      ]),
      const SizedBox(height: Insets.lg),
      _primaryBtn(c, 'Continue', () => _finish(repo)),
    ]);
  }

  Widget _confirmEmailView(RelicColors c) => _scroll(key: const ValueKey('confirm'), [
        _header(c, 'Confirm your email',
            'We sent a link to $_pendingEmail. Confirm it, then sign in to finish setting up your vault. You will choose your vault passphrase then.'),
        if (_error != null) _errorText(c, _error!),
        const SizedBox(height: Insets.lg),
        _primaryBtn(c, "I've confirmed, sign me in", _busy
            ? null
            : () {
                _email = _pendingEmail;
                _go(_Step.signIn);
              }),
        const SizedBox(height: Insets.md),
        _secondaryBtn(c, 'Resend email', _busy ? null : _resendConfirmation),
        _backBtn(c, () => _go(_Step.welcome)),
      ]);

  Widget _signInForm(RelicColors c) {
    final email = TextEditingController(text: _email);
    final pass = TextEditingController(text: _password);
    final name = TextEditingController(text: _deviceName);
    return _scroll(key: const ValueKey('signin'), [
      _header(c, 'Add this device', 'Sign in to your Relic account.'),
      // The switch-account entry (startAtSignIn) skips the welcome step, so
      // the OAuth doors must exist here too — most accounts are OAuth, and
      // without these the flow dead-ends on email/password.
      OAuthButton(
          provider: SupabaseProvider.google,
          onPressed: _busy ? null : () => _startOAuth(SupabaseProvider.google)),
      const SizedBox(height: Insets.md),
      OAuthButton(
          provider: SupabaseProvider.github,
          onPressed: _busy ? null : () => _startOAuth(SupabaseProvider.github)),
      const SizedBox(height: Insets.md),
      OAuthButton(
          provider: SupabaseProvider.apple,
          onPressed: _busy ? null : () => _startOAuth(SupabaseProvider.apple)),
      const SizedBox(height: Insets.lg),
      Row(children: [
        Expanded(child: Divider(color: c.border)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.md),
          child: Text('or use your email',
              style: RelicTheme.mono(size: 11, color: c.textFaintest)),
        ),
        Expanded(child: Divider(color: c.border)),
      ]),
      const SizedBox(height: Insets.lg),
      _field(c, email, 'Email', keyboard: TextInputType.emailAddress),
      _field(c, pass, 'Account password', obscure: true, mono: true),
      Padding(
        padding: const EdgeInsets.only(bottom: Insets.md),
        child: Text(
            'This is your account password only. Your vault passphrase is separate; if you lost that, use your recovery kit.',
            style: RelicTheme.sans(size: 12, color: c.textMuted, height: 1.5)),
      ),
      _field(c, name, 'Device name', onChanged: (v) => _deviceName = v),
      if (_error != null) _errorText(c, _error!),
      if (_notice != null) _noticeText(c, _notice!),
      _retryButton(c),
      const SizedBox(height: Insets.lg),
      _primaryBtn(c, 'Continue', _busy
          ? null
          : () {
              _email = email.text.trim();
              _password = pass.text;
              _deviceName = name.text.trim().isEmpty ? 'Device' : name.text.trim();
              if (_email.isEmpty || _password.isEmpty) {
                setState(() => _error = 'Enter your email and password.');
                return;
              }
              _signInForUnlock();
            }),
      Center(
        child: _quietBtn(
            c, 'Forgot password?', _busy ? null : () => _forgotPassword(email.text)),
      ),
      _backBtn(c, () => _go(_Step.welcome)),
    ]);
  }

  Widget _unlockChooser(RelicColors c) => _scroll(key: const ValueKey('chooser'), [
        _header(c, 'Unlock your vault', 'Choose how to unlock on this device.'),
        _doorTile(c, Icons.password, 'Enter your vault passphrase',
            'Works anywhere.', () => _go(_Step.passphrase)),
        _doorTile(c, Icons.qr_code_scanner, 'Scan a QR from another device',
            'Fastest if you have Relic open elsewhere.', () => _go(_Step.scanQr)),
        _doorTile(c, Icons.vpn_key, 'I lost my vault passphrase',
            'Use your recovery kit.', () => _go(_Step.recoveryEntry)),
        if (_error != null) _errorText(c, _error!),
        _backBtn(c, () => _go(_viaOAuth ? _Step.welcome : _Step.signIn)),
      ]);

  Widget _passphraseView(RelicColors c) {
    final phrase = TextEditingController();
    return _scroll(key: const ValueKey('pass'), [
      _header(c, 'Enter your passphrase', 'The one you set when you created your vault.'),
      _field(c, phrase, 'Vault passphrase', obscure: true, mono: true),
      if (_error != null) _errorText(c, _error!),
      const SizedBox(height: Insets.lg),
      _primaryBtn(c, 'Unlock', _busy
          ? null
          : () {
              if (phrase.text.isEmpty) return;
              _unlockPassphrase(phrase.text);
            }),
      _backBtn(c, () => _go(_Step.unlockChooser)),
    ]);
  }

  Widget _scanView(RelicColors c) => Column(key: const ValueKey('scan'), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              Insets.xxl, Insets.xxl, Insets.xxl, Insets.sm),
          child: _header(c, 'Scan the QR',
              'Open Relic on a device you already use, choose Add a device, and point this camera at its screen.'),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.xxl),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.cardLarge),
              child: _busy
                  ? Center(child: CircularProgressIndicator(color: c.accent))
                  : MobileScanner(onDetect: (capture) {
                      final raw = capture.barcodes
                          .map((b) => b.rawValue)
                          .firstWhere((v) => v != null && v.startsWith('relic-pair:'),
                              orElse: () => null);
                      if (raw != null && _pairing == null) _onQrScanned(raw);
                    }),
            ),
          ),
        ),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.xxl),
              child: _errorText(c, _error!)),
        Padding(
          padding: const EdgeInsets.fromLTRB(Insets.xxl, Insets.sm, Insets.xxl, 0),
          child: TextButton(
            onPressed: _busy ? null : () => _go(_Step.codeEntry),
            style: TextButton.styleFrom(
              foregroundColor: c.accentDeep,
              backgroundColor: c.tagBg,
              disabledForegroundColor: c.textFaintest,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Radii.pill)),
            ),
            child: Text("Can't scan? Type the code instead",
                style: RelicTheme.sans(size: 13.5, weight: FontWeight.w500)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Insets.xxl, 0, Insets.xxl, Insets.xxl),
          child: _backBtn(c, () => _go(_Step.unlockChooser)),
        ),
      ]);

  Widget _codeEntryView(RelicColors c) {
    final code = TextEditingController();
    return _scroll(key: const ValueKey('codeentry'), [
      _header(c, 'Type the pairing code',
          'Open Relic on a device you already use, choose Add a device, and enter the code it shows.'),
      Padding(
        padding: const EdgeInsets.only(bottom: Insets.md),
        child: TextField(
          controller: code,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          style: RelicTheme.mono(size: 15, color: c.text, letterSpacing: 2),
          cursorColor: c.accent,
          decoration: InputDecoration(
            hintText: '2XXX-XXXX-XXXX-XXXX-XXXX',
            // hintStyle merges OVER the field's own style, so the tracking has
            // to be zeroed explicitly or the placeholder inherits it.
            hintStyle: RelicTheme.mono(
                size: 15, color: c.textFaintest, letterSpacing: 0),
            filled: true,
            fillColor: c.surface,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: Insets.lg, vertical: Insets.lg),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.input),
                borderSide: BorderSide(color: c.border)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.input),
                borderSide: BorderSide(color: c.accent, width: 1.5)),
          ),
        ),
      ),
      if (_error != null) _errorText(c, _error!),
      const SizedBox(height: Insets.lg),
      _primaryBtn(c, 'Connect', _busy
          ? null
          : () {
              if (code.text.trim().isEmpty) {
                setState(() => _error = 'Enter the pairing code.');
                return;
              }
              _onCodeEntered(code.text);
            }),
      _backBtn(c, () => _go(_Step.scanQr)),
    ]);
  }

  Widget _sasView(RelicColors c) => _scroll(key: const ValueKey('sas'), [
        _header(c, 'Check the code',
            'Make sure this code matches the one shown on your other device, then approve there.'),
        const SizedBox(height: Insets.md),
        // The short-authentication string is a machine fact, so it stays mono —
        // but gold never sits bare on the ground, so it gets the warm well the
        // system reserves for secrets and keycaps.
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: Insets.xxl, vertical: Insets.xl),
            decoration: BoxDecoration(
              color: c.tagBg,
              borderRadius: BorderRadius.circular(Radii.cardLarge),
            ),
            child: Text(_sas ?? '----',
                style: RelicTheme.mono(
                    size: 44,
                    weight: FontWeight.w700,
                    color: c.tagText,
                    letterSpacing: 10)),
          ),
        ),
        const SizedBox(height: Insets.xxxl),
        if (_busy)
          Center(
              child: Text('Waiting for the other device to approve…',
                  style: RelicTheme.sans(size: 13.5, color: c.textMuted)))
        else ...[
          _primaryBtn(c, 'The codes match', _confirmSasAndReceive),
          const SizedBox(height: Insets.md),
          // Destructive ghost: danger-tinted text, no border box.
          SizedBox(
            height: 52,
            child: TextButton(
              onPressed: _rejectSas,
              style: TextButton.styleFrom(
                foregroundColor: c.dangerText,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Radii.pill)),
              ),
              child: Text("They don't match",
                  style: RelicTheme.sans(size: 15, weight: FontWeight.w600)),
            ),
          ),
        ],
        if (_error != null) _errorText(c, _error!),
        _backBtn(c, () {
          _pairing?.cancel();
          _pairing = null;
          _go(_Step.unlockChooser);
        }),
      ]);

  Widget _recoveryEntryView(RelicColors c) {
    final kit = TextEditingController();
    final phrase = TextEditingController();
    final confirm = TextEditingController();
    return _scroll(key: const ValueKey('recentry'), [
      _header(c, 'Use your recovery kit',
          'Paste the kit you saved, then set a new passphrase for this account.'),
      _field(c, kit, 'Recovery kit', maxLines: 4, mono: true),
      _field(c, phrase, 'New vault passphrase', obscure: true, mono: true),
      _field(c, confirm, 'Repeat the vault passphrase', obscure: true, mono: true),
      if (_error != null) _errorText(c, _error!),
      const SizedBox(height: Insets.lg),
      _primaryBtn(c, 'Unlock', _busy
          ? null
          : () {
              if (kit.text.trim().isEmpty || phrase.text.isEmpty) {
                setState(() => _error = 'Paste the kit and choose a passphrase.');
                return;
              }
              if (phrase.text != confirm.text) {
                setState(() => _error = "Passphrases don't match.");
                return;
              }
              _unlockKit(kit.text, phrase.text);
            }),
      _backBtn(c, () => _go(_Step.unlockChooser)),
    ]);
  }

  // --- widget helpers --------------------------------------------------------

  /// Step header: display title, quiet sans standfirst. The headline face at
  /// this size is most of what makes a step read as converted.
  Widget _header(RelicColors c, String title, String sub) => Padding(
        padding: const EdgeInsets.only(bottom: Insets.xxl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: RelicTheme.headline(size: 26, color: c.text)),
          const SizedBox(height: Insets.md),
          Text(sub, style: RelicTheme.sans(size: 14, color: c.textMuted, height: 1.5)),
        ]),
      );

  /// [mono] is for the fields whose content is a machine fact — passphrases,
  /// server addresses, the pasted recovery kit — not for prose fields like the
  /// email or the device name.
  Widget _field(RelicColors c, TextEditingController ctrl, String hint,
      {bool obscure = false,
      TextInputType? keyboard,
      int maxLines = 1,
      bool mono = false,
      ValueChanged<String>? onChanged}) {
    final style = mono
        ? RelicTheme.mono(size: 14, color: c.text)
        : RelicTheme.sans(size: 15, color: c.text);
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        keyboardType: keyboard,
        maxLines: obscure ? 1 : maxLines,
        onChanged: onChanged,
        style: style,
        cursorColor: c.accent,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: style.copyWith(color: c.textFaintest),
          filled: true,
          fillColor: c.surface,
          contentPadding: const EdgeInsets.symmetric(
              horizontal: Insets.lg, vertical: Insets.lg),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.input),
              borderSide: BorderSide(color: c.border)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.input),
              borderSide: BorderSide(color: c.accent, width: 1.5)),
        ),
      ),
    );
  }

  // Point this device at the user's OWN self-hosted server (the "Obsidian
  // model"). Account-less: just the server address + the vault passphrase.
  Widget _selfHostForm(RelicColors c) => _scroll(key: const ValueKey('selfhost'), [
        _header(c, 'Your own server',
            "Sync through a server you run. End-to-end encrypted — it only ever sees ciphertext."),
        _field(c, _shUrl, 'http://192.168.1.10:8787',
            keyboard: TextInputType.url, mono: true),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy
                ? null
                : () {
                    _shScanned = false;
                    _go(_Step.selfHostScan);
                  },
            style: TextButton.styleFrom(
                foregroundColor: c.accentDeep,
                backgroundColor: c.tagBg,
                disabledForegroundColor: c.textFaintest,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Radii.pill)),
                padding: const EdgeInsets.symmetric(horizontal: Insets.lg)),
            icon: const Icon(Icons.qr_code_scanner, size: 17),
            label: Text('Scan QR from another device',
                style: RelicTheme.sans(size: 13, weight: FontWeight.w500)),
          ),
        ),
        const SizedBox(height: Insets.md),
        _field(c, _shPass, 'Vault passphrase', obscure: true, mono: true),
        Padding(
          padding: const EdgeInsets.only(bottom: Insets.md, left: Insets.xs),
          child: Text('Same passphrase on every device.',
              style: RelicTheme.sans(size: 12, color: c.textMuted)),
        ),
        GestureDetector(
          onTap: () => setState(() => _shAdvanced = !_shAdvanced),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Insets.sm),
            child: Row(children: [
              Icon(_shAdvanced ? Icons.expand_more : Icons.chevron_right,
                  size: 18, color: c.textMuted),
              const SizedBox(width: Insets.xs),
              Text('Advanced',
                  style: RelicTheme.sans(
                      size: 13, weight: FontWeight.w600, color: c.textSecondary)),
            ]),
          ),
        ),
        if (_shAdvanced) ...[
          const SizedBox(height: Insets.sm),
          _field(c, _shSecret, 'Enrollment secret', obscure: true, mono: true),
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm, left: Insets.xs),
            child: Text('Only if your server sets RELIC_ENROLL_SECRET.',
                style: RelicTheme.sans(size: 12, color: c.textMuted)),
          ),
        ],
        if (_error != null) _errorText(c, _error!),
        const SizedBox(height: Insets.lg),
        _primaryBtn(c, 'Connect', _busy ? null : _connectSelfHost),
        _backBtn(c, () => _go(_Step.welcome)),
      ]);

  // Scan a `relic://selfhost?url=…` QR shown by a device that's already
  // connected, to prefill the address (and optional enrollment secret). The
  // passphrase is never in the QR — the user still types it on the form.
  bool _shScanned = false; // debounce repeated frames
  Widget _selfHostScanView(RelicColors c) =>
      Column(key: const ValueKey('selfhostscan'), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              Insets.xxl, Insets.xxl, Insets.xxl, Insets.sm),
          child: _header(c, 'Scan the QR',
              'On the connected device: Settings → Add a device → Show QR, then point this camera at it.'),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.xxl),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.cardLarge),
              child: MobileScanner(onDetect: (capture) {
                if (_shScanned) return;
                final raw = capture.barcodes
                    .map((b) => b.rawValue)
                    .firstWhere(
                        (v) => v != null && v.startsWith(SelfHostLink.prefix),
                        orElse: () => null);
                if (raw == null) return;
                final parsed = SelfHostLink.parse(raw);
                if (parsed == null) return;
                _shScanned = true;
                _shUrl.text = parsed.url;
                if (parsed.secret != null) {
                  _shSecret.text = parsed.secret!;
                  _shAdvanced = true;
                }
                _go(_Step.selfHost);
              }),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              Insets.xxl, Insets.md, Insets.xxl, Insets.xxl),
          child: _backBtn(c, () {
            _shScanned = false;
            _go(_Step.selfHost);
          }),
        ),
      ]);

  Future<void> _connectSelfHost() async {
    var url = _shUrl.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Enter your server address.');
      return;
    }
    if (!url.contains('://')) url = 'http://$url';
    if (_shPass.text.isEmpty) {
      setState(() => _error = 'Enter your passphrase.');
      return;
    }
    await _run(() async {
      final repo = await WorkerRepo.connectSelfHost(
        baseUrl: url,
        passphrase: _shPass.text,
        enrollSecret:
            _shAdvanced && _shSecret.text.trim().isNotEmpty ? _shSecret.text.trim() : null,
        deviceLabel: _deviceName,
        autoVault: widget.autoVault,
        deviceId: await DeviceId.get(),
      );
      // A freshly created vault shows the recovery kit once (the passphrase is
      // the only way in — no email reset for self-host); an existing vault hands
      // the connected repo straight to the host (persists on isSelfHost).
      if (repo.vaultJustCreated) {
        _enterRecoveryKit(repo);
      } else {
        widget.onConnected(repo);
      }
    });
  }

  /// The one gold CTA per step. Flutter can't paint a gradient through
  /// [FilledButton], so the gradient + the system's gold glow live on the
  /// wrapper and the button itself is a transparent, correctly-disabled hit
  /// target on top of it.
  Widget _primaryBtn(RelicColors c, String label, VoidCallback? onTap) {
    final on = onTap != null;
    final shape = BorderRadius.circular(Radii.pill);
    return Container(
      height: 52,
      decoration: BoxDecoration(
        gradient: on ? Gradients.gold : null,
        color: on ? null : c.track,
        borderRadius: shape,
        boxShadow: on ? Shadows.gold : null,
      ),
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
          foregroundColor: c.onAccent,
          disabledForegroundColor: c.textFaintest,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: shape),
        ),
        child: _busy && on
            ? SizedBox(
                width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: c.onAccent))
            : Text(label, style: RelicTheme.sans(size: 15, weight: FontWeight.w600)),
      ),
    );
  }

  // Secondary actions are the ghost language's quiet pill: no border, a plain
  // panel ground so they still read as tappable on a touch device.
  Widget _secondaryBtn(RelicColors c, String label, VoidCallback? onTap) => SizedBox(
        height: 52,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: c.text,
            disabledForegroundColor: c.textFaintest,
            backgroundColor: c.panel,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.pill)),
          ),
          child: Text(label, style: RelicTheme.sans(size: 15, weight: FontWeight.w600)),
        ),
      );

  // The quietest tier: a bare tracked label, no ground at all.
  Widget _quietBtn(RelicColors c, String label, VoidCallback? onTap) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: c.textMuted,
          disabledForegroundColor: c.textFaintest,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.pill)),
        ),
        child: Text(label, style: RelicTheme.sans(size: 13.5, weight: FontWeight.w500)),
      );

  Widget _orDivider(RelicColors c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xl),
        child: Row(children: [
          Expanded(child: Divider(color: c.border)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.md),
            child: Text('or', style: RelicTheme.mono(size: 11, color: c.textFaintest)),
          ),
          Expanded(child: Divider(color: c.border)),
        ]),
      );

  // Door option tiles are white cards on the parchment ground: a gold glyph in
  // its own tile, a hairline, and the system's resting card shadow.
  Widget _doorTile(RelicColors c, IconData icon, String title, String sub,
          VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(bottom: Insets.md),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.card),
            boxShadow: Shadows.card(c),
          ),
          child: Material(
            color: c.panel,
            borderRadius: BorderRadius.circular(Radii.card),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.card),
              onTap: _busy ? null : onTap,
              child: Container(
                padding: const EdgeInsets.all(Insets.lg),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.card),
                    border: Border.all(color: c.border)),
                child: Row(children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: c.selectedTile,
                      borderRadius: BorderRadius.circular(Radii.tile),
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, size: 19, color: c.accent),
                  ),
                  const SizedBox(width: Insets.lg),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title,
                          style: RelicTheme.sans(
                              size: 14, weight: FontWeight.w600, color: c.text)),
                      const SizedBox(height: Insets.xs),
                      Text(sub, style: RelicTheme.sans(size: 12, color: c.textMuted)),
                    ]),
                  ),
                  Icon(Icons.chevron_right, size: 20, color: c.textFaintest),
                ]),
              ),
            ),
          ),
        ),
      );

  Widget _backBtn(RelicColors c, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(top: Insets.sm),
        child: _quietBtn(c, 'Back', _busy ? null : onTap),
      );

  // Errors get the system's danger tint rather than a bare red line — the flow
  // is full-screen and a loose sentence gets lost between the fields.
  Widget _errorText(RelicColors c, String e) => Padding(
        padding: const EdgeInsets.only(top: Insets.md),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: Insets.lg, vertical: Insets.md),
          decoration: BoxDecoration(
            color: c.dangerBg,
            borderRadius: BorderRadius.circular(Radii.card),
          ),
          child: Text(e,
              style: RelicTheme.sans(size: 13, color: c.dangerText, height: 1.5)),
        ),
      );

  Widget _noticeText(RelicColors c, String n) => Padding(
        padding: const EdgeInsets.only(top: Insets.md),
        child: Text(n,
            style: RelicTheme.sans(size: 13, color: c.success, height: 1.5)),
      );

  /// "Try again" for a hard hasVault() failure — re-runs the routing check with
  /// the session already in hand. Renders nothing when there's no pending retry.
  Widget _retryButton(RelicColors c) {
    final retry = _retry;
    if (retry == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md),
      child: _secondaryBtn(c, 'Try again', _busy ? null : retry),
    );
  }
}
