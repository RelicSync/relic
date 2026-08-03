import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show TextField, InputDecoration, InputBorder;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
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
            ? (_signUp ? 'Create account & vault' : 'Sign in & decrypt')
            : 'Connect & decrypt');

    return SizedBox(
      width: 480,
      child: Container(
        decoration: BoxDecoration(
          color: c.base,
          borderRadius: BorderRadius.circular(Radii.popup),
          border: Border.all(color: c.border),
          boxShadow: [BoxShadow(color: const Color(0x99140E04), blurRadius: 80, spreadRadius: -24, offset: const Offset(0, 40))],
        ),
        padding: const EdgeInsets.fromLTRB(30, 30, 30, 30),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const RelicIcon(size: 22),
            const SizedBox(width: 9),
            Text('RELIC', style: RelicTheme.mono(size: 14, weight: FontWeight.w600, color: c.textMuted, letterSpacing: 2.4)),
            const Spacer(),
            if (widget.onCancel != null)
              GestureDetector(
                onTap: widget.onCancel,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(Radii.chip),
                      border: Border.all(color: c.border, width: 1),
                    ),
                    alignment: Alignment.center,
                    child: Icon(LucideIcons.x, size: 14, color: c.textSecondary),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 18),
          Text('Connect to your vault',
              style: RelicTheme.sans(size: 19, weight: FontWeight.w600, color: c.text, letterSpacing: -0.2)),
          const SizedBox(height: 6),
          Text(subtitle, style: RelicTheme.sans(size: 13, color: c.textMuted, height: 1.5)),
          const SizedBox(height: 18),
          if (signIn) ...[
            _label(c, 'Email'),
            _field(c, _email, leading: LucideIcons.mail),
            const SizedBox(height: 14),
            _label(c, 'Password'),
            _field(c, _password, obscure: true, leading: LucideIcons.lock),
            const SizedBox(height: 14),
            _label(c, 'Encryption passphrase'),
            _field(c, _pass, obscure: true, focused: true, leading: LucideIcons.keyRound),
          ] else ...[
            _label(c, 'Worker URL'),
            _field(c, _url, mono: true),
            const SizedBox(height: 14),
            _label(c, 'Device token'),
            _field(c, _token, mono: true, obscure: true),
            const SizedBox(height: 14),
            _label(c, 'Encryption passphrase'),
            _field(c, _pass, obscure: true, focused: true, leading: LucideIcons.keyRound),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Row(children: [
              Icon(LucideIcons.circleX, size: 14, color: c.dangerText),
              const SizedBox(width: 7),
              Expanded(child: Text(_error!, style: RelicTheme.sans(size: 12, color: c.dangerText))),
            ]),
          ],
          const SizedBox(height: 18),
          GestureDetector(
            onTap: _busy ? null : _submit,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(Radii.input)),
                alignment: Alignment.center,
                child: Text(buttonLabel,
                    style: RelicTheme.sans(size: 13.5, weight: FontWeight.w600, color: c.onAccent)),
              ),
            ),
          ),
          if (signIn) ...[
            const SizedBox(height: 12),
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
            const SizedBox(height: 10),
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
        padding: const EdgeInsets.only(bottom: 7),
        child: Text(t.toUpperCase(), style: RelicTheme.mono(size: 10, color: c.textMuted, letterSpacing: 0.8)),
      );

  Widget _link(RelicColors c, String t, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Text(t, style: RelicTheme.sans(size: 12, weight: FontWeight.w500, color: c.accent)),
        ),
      );

  Widget _field(RelicColors c, TextEditingController ctl,
      {bool mono = false, bool obscure = false, bool focused = false, IconData? leading}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
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
            decoration: const InputDecoration(
                isCollapsed: true, border: InputBorder.none),
          ),
        ),
      ]),
    );
  }
}
