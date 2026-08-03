import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart'
    show
        Material,
        MaterialType,
        TextField,
        InputDecoration,
        InputBorder,
        showDialog;
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';

/// The two-step "Connect…" modal (the Obsidian-style progressive disclosure):
///
///  - **Step 1** — a destination chooser: Relic Cloud (we host it) vs Your own
///    server (self-hosted). Cloud pops and hands off to [onCloud] (the existing
///    account onboarding). Your own server advances to step 2.
///  - **Step 2** — server address + passphrase (+ an optional enrollment secret
///    under Advanced), with a live "Test connection" check. Connect calls
///    [onSelfHost], which returns an error string (shown inline) or null on
///    success; on success the dialog closes itself.
///
/// Settings-only surface: first-run onboarding stays one-tap Relic Cloud.
Future<void> showConnectDialog(
  BuildContext context, {
  required RelicColors colors,
  required VoidCallback onCloud,
  required Future<String?> Function(String url, String pass, String? secret)
  onSelfHost,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x99000000),
    builder: (_) => RelicTheme(
      colors: colors,
      child: _ConnectDialog(onCloud: onCloud, onSelfHost: onSelfHost),
    ),
  );
}

enum _Health { unknown, checking, ok, bad }

class _ConnectDialog extends StatefulWidget {
  final VoidCallback onCloud;
  final Future<String?> Function(String url, String pass, String? secret)
  onSelfHost;
  const _ConnectDialog({required this.onCloud, required this.onSelfHost});

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  int _step = 0; // 0 = destination chooser, 1 = self-host details
  bool _cloud = true; // step-1 selection

  final _url = TextEditingController();
  final _pass = TextEditingController();
  final _secret = TextEditingController();
  bool _advanced = false;
  bool _busy = false;
  String? _error;
  _Health _health = _Health.unknown;

  @override
  void dispose() {
    _url.dispose();
    _pass.dispose();
    _secret.dispose();
    super.dispose();
  }

  /// Trim, add a scheme if missing, strip trailing slashes. Null if empty.
  String? _normalizedUrl() {
    var s = _url.text.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'http://$s';
    return s.replaceAll(RegExp(r'/+$'), '');
  }

  Future<void> _test() async {
    final url = _normalizedUrl();
    if (url == null) {
      setState(() => _health = _Health.bad);
      return;
    }
    setState(() => _health = _Health.checking);
    try {
      final r = await http
          .get(Uri.parse('$url/health'))
          .timeout(const Duration(seconds: 6));
      if (!mounted) return;
      setState(() => _health = r.statusCode == 200 ? _Health.ok : _Health.bad);
    } catch (_) {
      if (mounted) setState(() => _health = _Health.bad);
    }
  }

  void _next() {
    if (_cloud) {
      Navigator.of(context).pop();
      widget.onCloud();
    } else {
      setState(() {
        _step = 1;
        _error = null;
      });
    }
  }

  Future<void> _connect() async {
    final url = _normalizedUrl();
    if (url == null) {
      setState(() => _error = 'Enter your server address.');
      return;
    }
    if (_pass.text.isEmpty) {
      setState(() => _error = 'Enter your passphrase.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.onSelfHost(
      url,
      _pass.text,
      _advanced && _secret.text.trim().isNotEmpty ? _secret.text.trim() : null,
    );
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = err.replaceFirst('Bad state: ', '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    // Transparent Material: dialog routes build in the overlay, outside any
    // Scaffold, and TextField asserts without a Material ancestor.
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: 460,
          child: Container(
            decoration: BoxDecoration(
              color: c.base,
              borderRadius: BorderRadius.circular(Radii.popup),
              border: Border.all(color: c.border),
              boxShadow: [
                BoxShadow(
                  color: const Color(0x99140E04),
                  blurRadius: 80,
                  spreadRadius: -24,
                  offset: const Offset(0, 40),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
            child: _step == 0 ? _chooser(c) : _selfHostForm(c),
          ),
        ),
      ),
    );
  }

  // --- step 1: destination chooser -----------------------------------------

  Widget _chooser(RelicColors c) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        'Connect to your vault',
        style: RelicTheme.sans(
          size: 18,
          weight: FontWeight.w600,
          color: c.text,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        'Where should this device sync?',
        style: RelicTheme.sans(size: 13, color: c.textMuted),
      ),
      const SizedBox(height: 18),
      _choice(
        c,
        selected: _cloud,
        icon: LucideIcons.cloud,
        title: 'Relic Cloud',
        sub: 'We host it. Nothing to set up.',
        onTap: () => setState(() => _cloud = true),
      ),
      const SizedBox(height: 10),
      _choice(
        c,
        selected: !_cloud,
        icon: LucideIcons.server,
        title: 'Your own server',
        sub: "Self-hosted. We can't see it.",
        onTap: () => setState(() => _cloud = false),
      ),
      const SizedBox(height: 20),
      Row(
        children: [
          const Spacer(),
          _ghost(c, 'Cancel', () => Navigator.of(context).pop()),
          const SizedBox(width: 8),
          _primary(c, 'Next', _next),
        ],
      ),
    ],
  );

  Widget _choice(
    RelicColors c, {
    required bool selected,
    required IconData icon,
    required String title,
    required String sub,
    required VoidCallback onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: selected ? c.surface : c.base,
          borderRadius: BorderRadius.circular(Radii.input),
          border: Border.all(
            color: selected ? c.accent : c.borderStrong,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: selected ? c.accent : c.textMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: RelicTheme.sans(
                      size: 13.5,
                      weight: FontWeight.w600,
                      color: c.text,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    sub,
                    style: RelicTheme.sans(size: 11.5, color: c.textMuted),
                  ),
                ],
              ),
            ),
            _radioDot(c, selected),
          ],
        ),
      ),
    ),
  );

  Widget _radioDot(RelicColors c, bool selected) => Container(
    width: 16,
    height: 16,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(
        color: selected ? c.accent : c.borderStrong,
        width: 1.5,
      ),
    ),
    alignment: Alignment.center,
    child: selected
        ? Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: c.accent),
          )
        : null,
  );

  // --- step 2: self-host details -------------------------------------------

  Widget _selfHostForm(RelicColors c) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        'Your own server',
        style: RelicTheme.sans(
          size: 18,
          weight: FontWeight.w600,
          color: c.text,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        'End-to-end encrypted. Your server only ever sees ciphertext.',
        style: RelicTheme.sans(size: 12.5, color: c.textMuted, height: 1.4),
      ),
      const SizedBox(height: 18),
      _label(c, 'Server address'),
      Row(
        children: [
          Expanded(
            child: _field(
              c,
              _url,
              mono: true,
              hint: 'http://192.168.1.10:8787',
            ),
          ),
          const SizedBox(width: 8),
          _testButton(c),
        ],
      ),
      const SizedBox(height: 6),
      _healthLine(c),
      const SizedBox(height: 12),
      _label(c, 'Passphrase'),
      _field(c, _pass, obscure: true, leading: LucideIcons.keyRound),
      const SizedBox(height: 6),
      Text(
        'Same passphrase on every device.',
        style: RelicTheme.sans(size: 11, color: c.textMuted),
      ),
      const SizedBox(height: 12),
      GestureDetector(
        onTap: () => setState(() => _advanced = !_advanced),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Row(
            children: [
              Icon(
                _advanced ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                size: 14,
                color: c.textMuted,
              ),
              const SizedBox(width: 4),
              Text(
                'Advanced',
                style: RelicTheme.sans(
                  size: 12,
                  weight: FontWeight.w500,
                  color: c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
      if (_advanced) ...[
        const SizedBox(height: 10),
        _label(c, 'Enrollment secret'),
        _field(c, _secret, obscure: true, mono: true),
        const SizedBox(height: 4),
        Text(
          'Only if your server sets RELIC_ENROLL_SECRET.',
          style: RelicTheme.sans(size: 11, color: c.textMuted),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 14),
        Row(
          children: [
            Icon(LucideIcons.circleX, size: 14, color: c.dangerText),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                _error!,
                style: RelicTheme.sans(size: 12, color: c.dangerText),
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 20),
      Row(
        children: [
          _ghost(c, 'Back', _busy ? null : () => setState(() => _step = 0)),
          const Spacer(),
          _primary(
            c,
            _busy ? 'Connecting…' : 'Connect',
            _busy ? null : _connect,
          ),
        ],
      ),
    ],
  );

  Widget _testButton(RelicColors c) => GestureDetector(
    onTap: _health == _Health.checking ? null : _test,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(Radii.input),
          border: Border.all(color: c.borderStrong),
        ),
        child: Text(
          _health == _Health.checking ? 'Testing…' : 'Test',
          style: RelicTheme.sans(
            size: 12.5,
            weight: FontWeight.w500,
            color: c.textSecondary,
          ),
        ),
      ),
    ),
  );

  Widget _healthLine(RelicColors c) {
    final (color, text) = switch (_health) {
      _Health.unknown => (c.textMuted, 'Not tested yet.'),
      _Health.checking => (c.textMuted, 'Checking…'),
      _Health.ok => (const Color(0xFF3FB950), 'Reachable.'),
      _Health.bad => (c.dangerText, "Can't reach that server."),
    };
    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 7),
        Text(text, style: RelicTheme.sans(size: 11.5, color: color)),
      ],
    );
  }

  // --- shared bits ---------------------------------------------------------

  Widget _label(RelicColors c, String t) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Text(
      t.toUpperCase(),
      style: RelicTheme.mono(size: 10, color: c.textMuted, letterSpacing: 0.8),
    ),
  );

  Widget _field(
    RelicColors c,
    TextEditingController ctl, {
    bool mono = false,
    bool obscure = false,
    IconData? leading,
    String? hint,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
    decoration: BoxDecoration(
      color: c.surface,
      borderRadius: BorderRadius.circular(Radii.input),
      border: Border.all(color: c.borderStrong, width: 1),
    ),
    child: Row(
      children: [
        if (leading != null) ...[
          Icon(leading, size: 15, color: c.textMuted),
          const SizedBox(width: 9),
        ],
        Expanded(
          child: TextField(
            controller: ctl,
            obscureText: obscure,
            style: mono
                ? RelicTheme.mono(size: 13, color: c.text)
                : RelicTheme.sans(size: 13.5, color: c.text),
            cursorColor: c.accent,
            maxLines: 1,
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              hintText: hint,
              hintStyle: mono
                  ? RelicTheme.mono(size: 13, color: c.textMuted)
                  : RelicTheme.sans(size: 13.5, color: c.textMuted),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _ghost(RelicColors c, String t, VoidCallback? onTap) =>
      GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: onTap == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(Radii.input),
              border: Border.all(color: c.border),
            ),
            child: Text(
              t,
              style: RelicTheme.sans(
                size: 13,
                weight: FontWeight.w500,
                color: c.textSecondary,
              ),
            ),
          ),
        ),
      );

  Widget _primary(RelicColors c, String t, VoidCallback? onTap) =>
      GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: onTap == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: onTap == null ? c.accent.withValues(alpha: 0.5) : c.accent,
              borderRadius: BorderRadius.circular(Radii.input),
            ),
            child: Text(
              t,
              style: RelicTheme.sans(
                size: 13,
                weight: FontWeight.w600,
                color: c.onAccent,
              ),
            ),
          ),
        ),
      );
}
