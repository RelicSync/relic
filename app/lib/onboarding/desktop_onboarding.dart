import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/oauth_flow.dart';
import '../data/pairing.dart';
import '../data/supabase_auth.dart';
import '../platform/app_activation.dart';
import '../platform/input_injector.dart';
import '../services/onboarding_service.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/brand.dart';
import '../widgets/passphrase_field.dart';

/// The desktop device-onboarding flow (docs/cloudflare/13-device-onboarding.md),
/// replacing the old two-field ConnectView. Welcome → create a vault, or add
/// this device (sign in, then unlock passphrase-first or via a recovery kit).
/// Desktop has no camera, so there is no "scan a QR" door; the recovery kit is
/// shown after a fresh create by the host (see desktop.dart `_afterDesktopConnect`).
/// Each action callback returns an error string, or null on success (the host
/// then dismisses this surface).
class DesktopOnboarding extends StatefulWidget {
  final Future<String?> Function(String email, String password, String passphrase)
      onSignInPassphrase;
  final Future<String?> Function(
      String email, String password, String kit, String newPass) onRecoveryKit;
  // OAuth (browser) variants: the session is already obtained, so these take a
  // SupabaseSession instead of email/password.
  final Future<String?> Function(SupabaseSession session, String passphrase)
      onOAuthCreate;
  final Future<String?> Function(SupabaseSession session, String passphrase)
      onOAuthUnlock;
  final Future<String?> Function(SupabaseSession session, String kit, String newPass)
      onOAuthRecoveryKit;
  // Pairing door ("use another device"): a master key was received over the
  // pairing handshake and already validated against this account's vault. Binds
  // sync without re-wrapping keyparams. Returns an error string, or null on
  // success (the host then dismisses this surface).
  final Future<String?> Function(SupabaseSession session, Uint8List mk)
      onPairedMk;
  final VoidCallback onCancel;
  // "Try without an account": use Relic locally (no sign-in, no sync), seeded
  // with a few sample relics. Host dismisses onboarding + seeds.
  final VoidCallback onTryDemo;

  /// Start on the sign-in step instead of welcome — used by the guided "switch
  /// account" action so the user lands straight on sign-in after disconnecting.
  final bool startAtSignIn;

  /// Desktop only: called around the browser OAuth handoff so the host can step
  /// the always-on-top, frameless popup out of the system browser's way
  /// ([away] true) and bring it back on top once the sign-in callback lands
  /// ([away] false). No-op when null.
  final Future<void> Function(bool away)? onBrowserHandoff;

  const DesktopOnboarding({
    super.key,
    required this.onSignInPassphrase,
    required this.onRecoveryKit,
    required this.onOAuthCreate,
    required this.onOAuthUnlock,
    required this.onOAuthRecoveryKit,
    required this.onPairedMk,
    required this.onCancel,
    required this.onTryDemo,
    this.startAtSignIn = false,
    this.onBrowserHandoff,
  });

  @override
  State<DesktopOnboarding> createState() => _DesktopOnboardingState();
}

/// Should desktop onboarding open on the macOS Accessibility ask? Only on a
/// Mac, only when the grant is actually missing, and never on the guided
/// "switch account" entry — that user has already been through first run and
/// wants the sign-in form, not a permission screen. Pure so the gate is
/// testable without a Mac or a live TCC database.
bool shouldShowAccessibilityIntro({
  required bool isMacOS,
  required bool trusted,
  required bool startAtSignIn,
}) =>
    isMacOS && !trusted && !startAtSignIn;

/// Watches for the Accessibility grant landing while the user is away in System
/// Settings, so Relic can pull itself back in front instead of sitting in the
/// background after the switch is flipped. There is no TCC change notification
/// to subscribe to, but AXIsProcessTrusted reflects the grant live (no relaunch
/// needed), and reading it without the prompt option is a side-effect-free
/// check — see macos/Runner/Bridge/InputBridge.swift — so a slow poll is both
/// correct and cheap. [window] bounds it: a user who wanders off must not leave
/// a timer ticking for the life of the process.
///
/// Split out of the widget so the grant-watching contract is testable without a
/// Mac: [probe] is `inputInjectionAvailable` in production.
@visibleForTesting
class AccessibilityGrantWatcher {
  static const interval = Duration(seconds: 1);
  static const window = Duration(minutes: 3);

  final Future<bool> Function() probe;
  final VoidCallback onGranted;

  Timer? _timer;
  int _left = 0;
  bool _probing = false;

  AccessibilityGrantWatcher({required this.probe, required this.onGranted});

  bool get watching => _timer != null;

  /// (Re)start from a full [window]. A second trip out to System Settings gets
  /// its own budget, and can never stack a second timer on the first.
  void start() {
    cancel();
    _left = window.inMicroseconds ~/ interval.inMicroseconds;
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_probing) return; // a channel hop slower than the interval must not pile up
    _probing = true;
    final bool trusted;
    try {
      trusted = await probe();
    } finally {
      _probing = false;
    }
    if (_timer == null) return; // canceled while that probe was in flight
    if (trusted) {
      cancel();
      onGranted();
      return;
    }
    if (--_left <= 0) cancel();
  }
}

enum _Step {
  accessibility,
  welcome,
  create,
  confirmEmail,
  oauthCreate,
  signIn,
  chooser,
  passphrase,
  recovery,
  pairCode,
  sas,
}

class _DesktopOnboardingState extends State<DesktopOnboarding> {
  _Step _step = _Step.welcome;
  bool _busy = false;
  String? _error;
  String? _notice; // non-error confirmation (e.g. "reset email sent")
  String _email = '', _password = '';
  String _pendingEmail = ''; // address awaiting email confirmation
  bool _viaOAuth = false; // session came from the browser OAuth flow
  SupabaseSession? _session;

  // macOS Accessibility (TCC): flips once we've sent the user out to System
  // Settings, which turns the skip action into a "done, continue".
  bool _axAsked = false;
  late final _axWatcher = AccessibilityGrantWatcher(
    probe: inputInjectionAvailable,
    onGranted: () => unawaited(_onAccessibilityGranted()),
  );

  final _emailC = TextEditingController();
  final _passC = TextEditingController();
  final _phraseC = TextEditingController();
  final _confirmC = TextEditingController();
  final _kitC = TextEditingController();
  final _pairCodeC = TextEditingController();

  // Pairing door ("use another device"): NEW types the code shown on a trusted
  // device, runs the handshake, confirms the SAS, then binds.
  NewDevicePairing? _pairing;
  String? _sas;

  // Pending "Try again" for a hard hasVault() error — re-runs the routing with
  // the session already obtained (no re-auth). Null when there's nothing to retry.
  Future<void> Function()? _retry;

  @override
  void initState() {
    super.initState();
    if (widget.startAtSignIn) _step = _Step.signIn;
    // macOS opens on the Accessibility ask, then drops straight to welcome if
    // the grant is already there (the check is a one-frame channel hop, so a
    // granted Mac never really sees this step). Every other platform never
    // enters the branch, so the flow is exactly as it was.
    if (Platform.isMacOS && !widget.startAtSignIn) {
      _step = _Step.accessibility;
      _routeAccessibility();
    }
  }

  /// Read the Accessibility grant and skip the ask when it's already given.
  Future<void> _routeAccessibility() async {
    final trusted = await inputInjectionAvailable();
    if (!mounted) return;
    setState(() {
      if (!shouldShowAccessibilityIntro(
          isMacOS: Platform.isMacOS,
          trusted: trusted,
          startAtSignIn: widget.startAtSignIn)) {
        _step = _Step.welcome;
      }
    });
  }

  /// Surface the system grant dialog, then open System Settings → Privacy &
  /// Security → Accessibility so the switch is right there. If the grant is
  /// somehow already in hand we move on instead of sending the user out to
  /// System Settings for nothing.
  ///
  /// Sending the user out puts Relic in the background behind System Settings,
  /// where nothing brings it back on its own, so we watch for the grant from
  /// here (see [AccessibilityGrantWatcher]). The manual "Done, continue" stays
  /// the guaranteed path.
  Future<void> _openAccessibility() async {
    setState(() => _busy = true);
    final trusted = await inputInjectionAvailable(prompt: true);
    if (!trusted) await openInputPermissionSettings();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _axAsked = true;
    });
    if (trusted) {
      _go(_Step.welcome);
    } else {
      _axWatcher.start();
    }
  }

  /// The user flipped the switch over in System Settings. Relic is buried
  /// behind that window, so take the foreground before advancing — otherwise
  /// the flow continues where nobody can see it.
  Future<void> _onAccessibilityGranted() async {
    if (!mounted) return;
    await activateApp();
    if (!mounted) return;
    _go(_Step.welcome);
  }

  @override
  void dispose() {
    _axWatcher.cancel();
    _pairing?.cancel(); // stop any orphan relay poll on teardown
    for (final c in [_emailC, _passC, _phraseC, _confirmC, _kitC, _pairCodeC]) {
      c.dispose();
    }
    super.dispose();
  }

  void _zero(Uint8List b) {
    for (var i = 0; i < b.length; i++) {
      b[i] = 0;
    }
  }

  String _humanPair(Object e) {
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
    return e
        .toString()
        .replaceFirst('StateError: ', '')
        .replaceFirst('Exception: ', '');
  }

  /// NEW types the code shown on a trusted device, then runs the handshake to
  /// the shared SAS.
  Future<void> _connectPairCode() async {
    if (_pairCodeC.text.trim().isEmpty) {
      setState(() => _error = 'Enter the pairing code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await DeviceId.get();
      final relay = OnboardingService(deviceId: id).relayForSession(_session!);
      final pairing = await NewDevicePairing.fromCode(relay, _pairCodeC.text,
          localAccountId: _session!.userId);
      _pairing = pairing;
      final sas = await pairing.handshake();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _sas = sas;
        _step = _Step.sas;
      });
    } catch (e) {
      // Tear down the half-open session so Connect is immediately retryable
      // (the other device must show a fresh code; slots are single-use).
      _pairing?.cancel();
      _pairing = null;
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _humanPair(e);
      });
    }
  }

  /// NEW confirmed the SAS matches. Fetch the sealed MK, prove it opens this
  /// account's vault, then hand it to the host to bind. A validation failure
  /// zeroes the key and returns to the chooser with the error.
  Future<void> _confirmPairSas() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final mk = await _pairing!.receiveMk();
      final id = await DeviceId.get();
      try {
        await OnboardingService(deviceId: id).verifyPairedMk(_session!, mk);
      } on PairedKeyMismatch catch (e) {
        _zero(mk);
        _pairing = null;
        if (!mounted) return;
        setState(() {
          _busy = false;
          _step = _Step.chooser;
          _error = e.message;
        });
        return;
      }
      final err = await widget.onPairedMk(_session!, mk);
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (err != null) _error = err;
      });
    } catch (e) {
      // A failed receive kills the session on BOTH sides (single-use slots,
      // ~2-minute TTL). Retrying from the SAS screen can never succeed, so
      // land back on the chooser where "Use another device" mints fresh.
      _pairing?.cancel();
      _pairing = null;
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = _Step.chooser;
        _error = '${_humanPair(e)} Start again: choose Add a device on your '
            'other device, then enter the new code.';
      });
    }
  }

  /// NEW rejected the SAS (the codes differ). Cancel — the MK is never
  /// requested — and return to the chooser with a tamper warning.
  void _rejectPairSas() {
    _pairing?.cancel();
    _pairing = null;
    setState(() {
      _step = _Step.chooser;
      _error =
          'Pairing canceled. If the codes keep differing, someone may be interfering with your connection. Try again on a network you trust.';
    });
  }

  void _go(_Step s) => setState(() {
        _error = null;
        _notice = null;
        _retry = null;
        _step = s;
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
      final id = await DeviceId.get();
      final existing = await OnboardingService(deviceId: id).hasVault(_session!);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _retry = null;
        _error = null;
        _notice = null;
        _step = existing ? _Step.chooser : _Step.oauthCreate;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('StateError: ', '')
            .replaceFirst('Exception: ', '');
        _retry = _routeAfterAuth;
      });
    }
  }

  /// Send a Supabase password-reset email for the address in the sign-in form.
  Future<void> _forgotPassword() async {
    final email = _emailC.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email above, then tap Forgot password.');
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

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (err != null) _error = err;
    });
  }

  /// Email sign-up: create the ACCOUNT only — no vault, no passphrase yet. The
  /// vault passphrase is deliberately chosen later, after the user confirms their
  /// email and signs in (auth != vault key), so a discarded passphrase can never
  /// happen. Email confirmation is required, so signUp throws
  /// [EmailConfirmationPending] and we route to the confirm step. If confirmation
  /// is ever turned off, a session comes back and we route straight to the
  /// set-passphrase step, exactly like the OAuth flow.
  Future<void> _signUpEmail() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await SupabaseAuth.signUp(_email, _password);
      if (!mounted) return;
      _session = session;
      _viaOAuth = true; // route through the session-based (set-passphrase) path
      await _routeAfterAuth();
    } on EmailConfirmationPending catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = null;
        _pendingEmail = e.email;
        _step = _Step.confirmEmail;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('StateError: ', '')
            .replaceFirst('Exception: ', '');
      });
    }
  }

  /// Re-send the sign-up confirmation email from the confirm-your-email step.
  Future<void> _resendConfirmation() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await SupabaseAuth.resendSignupConfirmation(_pendingEmail);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = 'Confirmation email sent to $_pendingEmail.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  /// Email sign-in: authenticate, then auto-route to create (no vault yet — e.g.
  /// a fresh account) or unlock (existing vault), exactly like OAuth. This is why
  /// an empty account now shows "set a passphrase" instead of "enter" it.
  Future<void> _signInEmail() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await SupabaseAuth.signIn(_email, _password);
      if (!mounted) return;
      _session = session;
      _viaOAuth = true; // route through the session-based callbacks
      await _routeAfterAuth();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('Exception: ', '');
      });
    }
  }

  /// Browser OAuth: open the provider in the system browser, then auto-route to
  /// create (no vault) or unlock (existing vault). A passphrase step still
  /// follows (auth != vault key).
  Future<void> _startOAuth(SupabaseProvider provider) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    // Step the always-on-top popup aside so it isn't covering the provider's
    // consent screen in the browser; we reappear on top the moment the loopback
    // callback lands (whether it succeeds or fails), so sign-in never gets
    // buried behind our window.
    await widget.onBrowserHandoff?.call(true);
    SupabaseSession session;
    try {
      session = await OAuthFlow.signInWithProvider(provider, desktop: true);
    } catch (e) {
      await widget.onBrowserHandoff?.call(false);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('StateError: ', '');
      });
      return;
    }
    await widget.onBrowserHandoff?.call(false);
    if (!mounted) return;
    _session = session;
    _viaOAuth = true;
    await _routeAfterAuth();
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Theme(
      data: materialThemeFor(c),
      child: Container(
        color: c.base,
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          // Hide the janky desktop scrollbar; content still scrolls if a small
          // window makes it overflow.
          child: ScrollConfiguration(
            behavior:
                ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: _body(c),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(RelicColors c) {
    switch (_step) {
      case _Step.accessibility:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(c, 'Let Relic paste for you',
              'macOS asks permission before any app can press keys for you. Relic uses it to paste the item you pick straight into the app you were just in, and to grab your selection when you press the save & annotate hotkey.'),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: c.panel,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.borderStrong),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline, size: 18, color: c.textMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    'Skipping is fine. Relic still keeps everything you copy, and picking an item still copies it. You just press ⌘V yourself.',
                    style: TextStyle(color: c.textMuted, height: 1.4, fontSize: 12.5)),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          _primary(c, 'Open Accessibility settings',
              _busy ? null : _openAccessibility),
          _secondary(c, _axAsked ? 'Done, continue' : 'Skip for now',
              _busy
                  ? null
                  : () {
                      _axWatcher.cancel(); // the user got there first
                      _go(_Step.welcome);
                    }),
        ]);
      case _Step.welcome:
        return Column(children: [
          const SizedBox(height: 4),
          // Wordmark follows the theme ink — the cream default is only
          // readable on dark.
          RelicWordmark(gemSize: 34, color: c.text),
          const SizedBox(height: 20),
          Text('Everything you copy,\non every device.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: c.text,
                  fontSize: 21,
                  height: 1.25,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('Sign in to sync and back up your vault, end-to-end encrypted.',
              textAlign: TextAlign.center, style: TextStyle(color: c.textSecondary, height: 1.4)),
          const SizedBox(height: 26),
          OAuthButton(
              provider: SupabaseProvider.google,
              onPressed: _busy ? null : () => _startOAuth(SupabaseProvider.google)),
          const SizedBox(height: 10),
          OAuthButton(
              provider: SupabaseProvider.github,
              onPressed: _busy ? null : () => _startOAuth(SupabaseProvider.github)),
          const SizedBox(height: 10),
          OAuthButton(
              provider: SupabaseProvider.apple,
              onPressed: _busy ? null : () => _startOAuth(SupabaseProvider.apple)),
          if (_busy)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('Waiting for your browser…',
                  style: TextStyle(color: c.textMuted, fontSize: 12.5)),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.dangerText, height: 1.3)),
            ),
          _retryButton(c),
          const _OrDivider(),
          _secondary(c, 'Create with email', _busy ? null : () => _go(_Step.create)),
          const SizedBox(height: 10),
          _secondary(c, 'Sign in with email', _busy ? null : () => _go(_Step.signIn)),
          const SizedBox(height: 16),
          TextButton(
            onPressed: _busy ? null : widget.onTryDemo,
            style: TextButton.styleFrom(foregroundColor: c.accent),
            child: const Text('Just exploring? Try the demo  →'),
          ),
          _back(c, widget.onCancel, label: 'Not now'),
        ]);
      case _Step.oauthCreate:
        return _form(c, 'Set your vault passphrase',
            'Signed in. Your vault passphrase seals your data. We never see it and cannot reset it.',
            [
              VaultPassphraseField(
                  controller: _phraseC,
                  confirmController: _confirmC,
                  hint: 'Choose a vault passphrase'),
              _field(c, _confirmC, 'Repeat the vault passphrase', obscure: true),
            ], 'Create vault', () {
          if (_phraseC.text.isEmpty) {
            setState(() => _error = 'Choose a passphrase.');
            return;
          }
          if (_phraseC.text != _confirmC.text) {
            setState(() => _error = "Passphrases don't match.");
            return;
          }
          _run(() => widget.onOAuthCreate(_session!, _phraseC.text));
        }, back: () => _go(_Step.welcome));
      case _Step.create:
        return _form(c, 'Create your account',
            'Start with just an email and a password. You will set your vault passphrase after you confirm your email.',
            [
          _field(c, _emailC, 'Email'),
          _field(c, _passC, 'Account password', obscure: true),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                'Your account password signs you in. Your vault passphrase, which seals your data end-to-end, comes next and we never see it.',
                style: TextStyle(color: c.textMuted, fontSize: 12, height: 1.35)),
          ),
        ], 'Create account', () {
          _email = _emailC.text.trim();
          _password = _passC.text;
          if (_email.isEmpty || _password.isEmpty) {
            setState(() => _error = 'Enter your email and a password.');
            return;
          }
          _signUpEmail();
        }, back: () => _go(_Step.welcome));
      case _Step.confirmEmail:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(c, 'Confirm your email',
              'We sent a link to $_pendingEmail. Confirm it, then sign in to finish setting up your vault. You will choose your vault passphrase then.'),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(_error!,
                  style: TextStyle(color: c.dangerText, height: 1.3)),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(_notice!,
                  style: TextStyle(color: c.accent, height: 1.3)),
            ),
          const SizedBox(height: 8),
          _primary(c, "I've confirmed, sign me in", _busy
              ? null
              : () {
                  _emailC.text = _pendingEmail;
                  _go(_Step.signIn);
                }),
          const SizedBox(height: 8),
          _secondary(c, 'Resend email', _busy ? null : _resendConfirmation),
          _back(c, () => _go(_Step.welcome)),
        ]);
      case _Step.signIn:
        return _form(c, 'Sign in', 'Sign in to your Relic account.', [
          _field(c, _emailC, 'Email'),
          _field(c, _passC, 'Account password', obscure: true),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: _busy ? null : _forgotPassword,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 2),
                  child: Text('Forgot password?',
                      style: TextStyle(color: c.textMuted, fontSize: 12.5)),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                'This resets your account password only. Your vault passphrase is separate; if you lost that, use your recovery kit.',
                style: TextStyle(color: c.textMuted, fontSize: 12, height: 1.35)),
          ),
        ], 'Continue', () {
          _email = _emailC.text.trim();
          _password = _passC.text;
          if (_email.isEmpty || _password.isEmpty) {
            setState(() => _error = 'Enter your email and password.');
            return;
          }
          _signInEmail();
        }, back: () => _go(_Step.welcome));
      case _Step.chooser:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(c, 'Unlock your vault', 'Choose how to unlock on this computer.'),
          _door(c, Icons.password, 'Enter your vault passphrase', 'Works anywhere.',
              () => _go(_Step.passphrase)),
          _door(c, Icons.keyboard, 'Use another device',
              'Type the pairing code shown on a device you already use.',
              () => _go(_Step.pairCode)),
          _door(c, Icons.vpn_key, 'I lost my vault passphrase', 'Use your recovery kit.',
              () => _go(_Step.recovery)),
          const SizedBox(height: 4),
          _back(c, () => _go(_viaOAuth ? _Step.welcome : _Step.signIn)),
        ]);
      case _Step.passphrase:
        return _form(c, 'Enter your passphrase',
            'The one you set when you created your vault.', [
          _field(c, _phraseC, 'Vault passphrase', obscure: true),
        ], 'Unlock', () {
          if (_phraseC.text.isEmpty) return;
          _run(() => _viaOAuth
              ? widget.onOAuthUnlock(_session!, _phraseC.text)
              : widget.onSignInPassphrase(_email, _password, _phraseC.text));
        }, back: () => _go(_Step.chooser));
      case _Step.recovery:
        return _form(c, 'Use your recovery kit',
            'Paste the kit you saved, then set a new vault passphrase.', [
          _field(c, _kitC, 'Recovery kit', maxLines: 4),
          _field(c, _phraseC, 'New vault passphrase', obscure: true),
          _field(c, _confirmC, 'Repeat the vault passphrase', obscure: true),
        ], 'Unlock', () {
          if (_kitC.text.trim().isEmpty || _phraseC.text.isEmpty) {
            setState(() => _error = 'Paste the kit and choose a passphrase.');
            return;
          }
          if (_phraseC.text != _confirmC.text) {
            setState(() => _error = "Passphrases don't match.");
            return;
          }
          _run(() => _viaOAuth
              ? widget.onOAuthRecoveryKit(_session!, _kitC.text, _phraseC.text)
              : widget.onRecoveryKit(_email, _password, _kitC.text, _phraseC.text));
        }, back: () => _go(_Step.chooser));
      case _Step.pairCode:
        return _form(c, 'Use another device',
            'Open Relic on a device you already use, choose Add a device, and type the code it shows.',
            [
              _field(c, _pairCodeC, '2XXX-XXXX-XXXX-XXXX-XXXX'),
            ], 'Connect', _connectPairCode, back: () {
          _pairing?.cancel();
          _pairing = null;
          _go(_Step.chooser);
        });
      case _Step.sas:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(c, 'Check the code',
              'Make sure this code matches the one shown on your other device, then approve there.'),
          const SizedBox(height: 8),
          Center(
            child: Text(_sas ?? '----',
                style: TextStyle(
                    color: c.accent,
                    fontSize: 44,
                    letterSpacing: 10,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'IBMPlexMono')),
          ),
          const SizedBox(height: 20),
          if (_busy)
            Center(
                child: Text('Waiting for the other device to approve…',
                    style: TextStyle(color: c.textMuted)))
          else ...[
            _primary(c, 'The codes match', _confirmPairSas),
            const SizedBox(height: 8),
            // Destructive ghost: danger-tinted text, no border box.
            SizedBox(
              height: 48,
              child: TextButton(
                onPressed: _rejectPairSas,
                style: TextButton.styleFrom(foregroundColor: c.dangerText),
                child: const Text("They don't match",
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              ),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!,
                  style: TextStyle(color: c.dangerText, height: 1.3)),
            ),
          _back(c, () {
            _pairing?.cancel();
            _pairing = null;
            _go(_Step.chooser);
          }),
        ]);
    }
  }

  // --- helpers ---

  Widget _form(RelicColors c, String title, String sub, List<Widget> fields,
          String cta, VoidCallback onCta, {required VoidCallback back}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _header(c, title, sub),
        ...fields,
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(_error!,
                style: TextStyle(color: c.dangerText, height: 1.3)),
          ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(_notice!,
                style: TextStyle(color: c.accent, height: 1.3)),
          ),
        _retryButton(c),
        const SizedBox(height: 8),
        _primary(c, cta, _busy ? null : onCta),
        _back(c, back),
      ]);

  /// "Try again" for a hard hasVault() failure — re-runs the routing check with
  /// the session already in hand. Renders nothing when there's no pending retry.
  Widget _retryButton(RelicColors c) {
    final retry = _retry;
    if (retry == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: _secondary(c, 'Try again', _busy ? null : retry),
    );
  }

  Widget _header(RelicColors c, String title, String sub) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: TextStyle(
                  color: c.text, fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(sub, style: TextStyle(color: c.textMuted, height: 1.4)),
        ]),
      );

  Widget _field(RelicColors c, TextEditingController ctrl, String hint,
          {bool obscure = false, int maxLines = 1}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: ctrl,
          obscureText: obscure,
          maxLines: obscure ? 1 : maxLines,
          style: TextStyle(color: c.text),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: c.textMuted),
            filled: true,
            fillColor: c.surface,
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.input),
                borderSide: BorderSide(color: c.borderStrong)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.input),
                borderSide: BorderSide(color: c.accent)),
          ),
        ),
      );

  Widget _primary(RelicColors c, String label, VoidCallback? onTap) => SizedBox(
        height: 48,
        child: FilledButton(
          onPressed: onTap,
          style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: c.onAccent,
              disabledBackgroundColor: c.track,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: _busy && onTap != null
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: c.onAccent))
              : Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        ),
      );

  // Secondary/back actions de-boxed to the ghost language: no border, quiet text.
  Widget _secondary(RelicColors c, String label, VoidCallback? onTap) => SizedBox(
        height: 48,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(foregroundColor: c.text),
          child: Text(label,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        ),
      );

  // Door option cards keep their hairline border — they are region separators.
  Widget _door(RelicColors c, IconData icon, String title, String sub,
          VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: c.panel,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _busy ? null : onTap,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: c.borderStrong)),
              child: Row(children: [
                Icon(icon, color: c.accent, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: TextStyle(
                                color: c.text, fontWeight: FontWeight.w600)),
                        Text(sub,
                            style:
                                TextStyle(color: c.textMuted, fontSize: 12)),
                      ]),
                ),
                Icon(Icons.chevron_right, color: c.textMuted),
              ]),
            ),
          ),
        ),
      );

  Widget _back(RelicColors c, VoidCallback onTap, {String label = 'Back'}) =>
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: TextButton(
          onPressed: _busy ? null : onTap,
          style: TextButton.styleFrom(foregroundColor: c.textMuted),
          child: Text(label),
        ),
      );
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(children: [
        Expanded(child: Divider(color: c.borderStrong)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('or', style: TextStyle(color: c.textMuted, fontSize: 12)),
        ),
        Expanded(child: Divider(color: c.borderStrong)),
      ]),
    );
  }
}
