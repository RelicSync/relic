import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show TextField;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/controls.dart';
import '../widgets/fields.dart';
import '../widgets/relic_mark.dart';

/// Connect to your vault. Two modes:
///  - **Sign in** (default): email + password via Supabase ([onSignIn]); the
///    passphrase unlocks/creates the E2E vault key and never leaves the device.
///  - **Device token** (advanced): paste a Worker URL + token ([onConnect]).
/// Each callback returns an error string (shown inline) or null on success.
class ConnectView extends StatefulWidget {
  final String defaultUrl;
  final String defaultToken;
  final Future<String?> Function(String url, String token, String pass) onConnect;
  final Future<String?> Function(
    String email,
    String password,
    String pass,
    bool signUp,
  )? onSignIn;
  final VoidCallback? onCancel;
  const ConnectView({
    super.key,
    required this.defaultUrl,
    this.defaultToken = '',
    required this.onConnect,
    this.onSignIn,
    this.onCancel,
  });

  @override
  State<ConnectView> createState() => _ConnectViewState();
}

class _ConnectViewState extends State<ConnectView> {
  late final _url = TextEditingController(text: widget.defaultUrl);
  late final _token = TextEditingController(text: widget.defaultToken);
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _pass = TextEditingController();
  late bool _signInMode = widget.onSignIn != null;
  bool _signUp = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _email.dispose();
    _password.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final String? err;
    if (_signInMode && widget.onSignIn != null) {
      err = await widget.onSignIn!(
        _email.text.trim(),
        _password.text,
        _pass.text,
        _signUp,
      );
    } else {
      err = await widget.onConnect(_url.text.trim(), _token.text.trim(), _pass.text);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err?.replaceFirst('Bad state: ', '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final signIn = _signInMode;
    final subtitle = signIn
        ? (_signUp
            ? 'Create an account, then choose a passphrase to encrypt your vault. The passphrase never leaves this device and cannot be recovered.'
            : 'Sign in to sync this device. Your passphrase decrypts your vault locally and never leaves this device.')
        : 'Paste a Worker URL + device token. The passphrase never leaves this device.';
    final buttonLabel = _busy
        ? (signIn && _signUp ? 'Creating…' : (signIn ? 'Signing in…' : 'Connecting…'))
        : (signIn
            ? (_signUp ? 'Create account and vault' : 'Sign in and decrypt')
            : 'Connect and decrypt');

    return SizedBox(
      width: 480,
      child: Container(
        decoration: BoxDecoration(
          // A floating panel over the app: the system's card shape and the one
          // window elevation, never a hand-rolled shadow.
          color: c.base,
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: c.border),
          boxShadow: Shadows.window(c),
        ),
        padding: const EdgeInsets.all(Insets.xxxl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const RelicIcon(size: 22),
            const SizedBox(width: 9),
            // The lockup's wordmark is the system's kicker: tracked mono, quiet,
            // sitting above the headline rather than competing with it.
            Text('RELIC', style: RelicTheme.kicker(c.textMuted, size: 13)),
            const Spacer(),
            if (widget.onCancel != null)
              GhostIconButton(
                icon: LucideIcons.x,
                size: 26,
                iconSize: 14,
                onTap: widget.onCancel,
              ),
          ]),
          const SizedBox(height: Insets.xl),
          Text('Connect to your vault',
              style: RelicTheme.headline(size: 22, color: c.text)),
          const SizedBox(height: Insets.sm),
          Text(subtitle, style: RelicTheme.sans(size: 13, color: c.textMuted, height: 1.5)),
          const SizedBox(height: Insets.xxl),
          if (signIn) ...[
            _label(c, 'Email'),
            _field(c, _email, leading: LucideIcons.mail),
            const SizedBox(height: Insets.lg),
            _label(c, 'Password'),
            _field(c, _password, obscure: true, leading: LucideIcons.lock),
            const SizedBox(height: Insets.lg),
            _label(c, 'Encryption passphrase'),
            _field(c, _pass, obscure: true, focused: true, leading: LucideIcons.keyRound),
          ] else ...[
            _label(c, 'Worker URL'),
            _field(c, _url, mono: true),
            const SizedBox(height: Insets.lg),
            _label(c, 'Device token'),
            _field(c, _token, mono: true, obscure: true),
            const SizedBox(height: Insets.lg),
            _label(c, 'Encryption passphrase'),
            _field(c, _pass, obscure: true, focused: true, leading: LucideIcons.keyRound),
          ],
          if (_error != null) ...[
            const SizedBox(height: Insets.md),
            Row(children: [
              Icon(LucideIcons.circleX, size: 14, color: c.dangerText),
              const SizedBox(width: 7),
              Expanded(child: Text(_error!, style: RelicTheme.sans(size: 12, color: c.dangerText))),
            ]),
          ],
          const SizedBox(height: Insets.xxl),
          // The one gold CTA on this surface: the system's gradient fill and
          // its glow, full width. A null handler is the disabled state.
          SizedBox(
            width: double.infinity,
            child: GhostButton(
              label: buttonLabel,
              size: 40,
              fontSize: 13.5,
              style: GhostStyle.filled,
              onTap: _busy ? null : _submit,
            ),
          ),
          if (signIn) ...[
            const SizedBox(height: Insets.lg),
            Center(
              child: _link(
                c,
                _signUp ? 'Have an account? Sign in' : 'New to Relic? Create an account',
                () => setState(() {
                  _signUp = !_signUp;
                  _error = null;
                }),
              ),
            ),
          ],
          if (widget.onSignIn != null) ...[
            const SizedBox(height: Insets.md),
            Center(
              child: _link(
                c,
                signIn ? 'Use a device token instead' : 'Sign in with email instead',
                () => setState(() {
                  _signInMode = !_signInMode;
                  _error = null;
                }),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _label(RelicColors c, String t) => Padding(
        padding: const EdgeInsets.only(bottom: Insets.sm),
        child: Text(t.toUpperCase(), style: RelicTheme.label(c.textMuted)),
      );

  // Gold as *text* is the deep gold, never the fill gold; the hover cue is an
  // underline rather than a brighter yellow.
  Widget _link(RelicColors c, String t, VoidCallback onTap) => Hoverable(
        onTap: onTap,
        builder: (context, hovered) => Text(
          t,
          style: RelicTheme.sans(size: 12, weight: FontWeight.w500, color: c.accentMuted).copyWith(
            decoration: hovered ? TextDecoration.underline : TextDecoration.none,
            decorationColor: c.accentMuted,
          ),
        ),
      );

  Widget _field(RelicColors c, TextEditingController ctl,
      {bool mono = false, bool obscure = false, bool focused = false, IconData? leading}) {
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.input),
        border: Border.all(color: focused ? c.accent : c.borderStrong, width: focused ? 1.5 : 1),
      ),
      child: Row(children: [
        if (leading != null) ...[Icon(leading, size: 15, color: c.textMuted), const SizedBox(width: 9)],
        Expanded(
          child: TextField(
            controller: ctl,
            obscureText: obscure,
            style: (mono ? RelicTheme.mono(size: 13, color: c.text) : RelicTheme.sans(size: 13.5, color: c.text)),
            cursorColor: c.accent,
            maxLines: 1,
            decoration: kBareField,
          ),
        ),
      ]),
    );
  }
}
