import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart'
    show
        Material,
        MaterialType,
        TextField,
        showDialog;
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/controls.dart';
import '../widgets/fields.dart';

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
    // The palette has no dedicated scrim token; the window shadow is the
    // closest, and it already darkens correctly in both themes.
    barrierColor: colors.shadowStrong,
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
              // Parchment ground for the dialog itself; the two destination
              // choices below are the white cards that sit on it.
              color: c.base,
              borderRadius: BorderRadius.circular(Radii.card),
              border: Border.all(color: c.border),
              boxShadow: Shadows.window(c),
            ),
            padding: const EdgeInsets.all(Insets.xxl),
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
        style: RelicTheme.headline(size: 20, color: c.text),
      ),
      const SizedBox(height: Insets.sm),
      Text(
        'Where should this device sync?',
        style: RelicTheme.sans(size: 13, color: c.textMuted),
      ),
      const SizedBox(height: Insets.xl),
      _choice(
        c,
        selected: _cloud,
        icon: LucideIcons.cloud,
        title: 'Relic Cloud',
        sub: 'We host it. Nothing to set up.',
        onTap: () => setState(() => _cloud = true),
      ),
      const SizedBox(height: Insets.md),
      _choice(
        c,
        selected: !_cloud,
        icon: LucideIcons.server,
        title: 'Your own server',
        sub: "Self-hosted. We can't see it.",
        onTap: () => setState(() => _cloud = false),
      ),
      const SizedBox(height: Insets.xxl),
      Row(
        children: [
          const Spacer(),
          _ghost(c, 'Cancel', () => Navigator.of(context).pop()),
          const SizedBox(width: Insets.sm),
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
  }) => Hoverable(
    onTap: onTap,
    // The row's selection language: a white card that lifts on a warm gold
    // shadow behind a gold hairline, against a plain hairlined card at rest.
    builder: (context, hovered) => AnimatedContainer(
      duration: Motion.selection,
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: selected
            ? c.selectedCard
            : (hovered ? c.surfaceHover : c.panel),
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(
          color: selected ? c.selectedBorder : c.border,
          width: 1,
        ),
        boxShadow: selected ? Shadows.selected(c) : null,
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: selected ? c.accent : c.textMuted),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: RelicTheme.headline(size: 14, color: c.text),
                ),
                const SizedBox(height: 2),
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
        style: RelicTheme.headline(size: 20, color: c.text),
      ),
      const SizedBox(height: Insets.sm),
      Text(
        'End-to-end encrypted. Your server only ever sees ciphertext.',
        style: RelicTheme.sans(size: 12.5, color: c.textMuted, height: 1.4),
      ),
      const SizedBox(height: Insets.xl),
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
          const SizedBox(width: Insets.sm),
          _testButton(c),
        ],
      ),
      const SizedBox(height: Insets.sm),
      _healthLine(c),
      const SizedBox(height: Insets.lg),
      _label(c, 'Passphrase'),
      _field(c, _pass, obscure: true, leading: LucideIcons.keyRound),
      const SizedBox(height: Insets.sm),
      Text(
        'Same passphrase on every device.',
        style: RelicTheme.sans(size: 11, color: c.textMuted),
      ),
      const SizedBox(height: Insets.lg),
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
        const SizedBox(height: Insets.md),
        _label(c, 'Enrollment secret'),
        _field(c, _secret, obscure: true, mono: true),
        const SizedBox(height: Insets.xs),
        Text(
          'Only if your server sets RELIC_ENROLL_SECRET.',
          style: RelicTheme.sans(size: 11, color: c.textMuted),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: Insets.lg),
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
      const SizedBox(height: Insets.xxl),
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

  // Sized to the field beside it so the pair reads as one control row.
  Widget _testButton(RelicColors c) => GhostButton(
    label: _health == _Health.checking ? 'Testing…' : 'Test',
    size: 40,
    fontSize: 12.5,
    onTap: _health == _Health.checking ? null : _test,
  );

  Widget _healthLine(RelicColors c) {
    final (color, text) = switch (_health) {
      _Health.unknown => (c.textMuted, 'Not tested yet.'),
      _Health.checking => (c.textMuted, 'Checking…'),
      _Health.ok => (c.success, 'Reachable.'),
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
    padding: const EdgeInsets.only(bottom: Insets.sm),
    child: Text(t.toUpperCase(), style: RelicTheme.label(c.textMuted)),
  );

  Widget _field(
    RelicColors c,
    TextEditingController ctl, {
    bool mono = false,
    bool obscure = false,
    IconData? leading,
    String? hint,
  }) => Container(
    padding: const EdgeInsets.all(Insets.md),
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
            decoration: kBareField.copyWith(
              hintText: hint,
              hintStyle: mono
                  ? RelicTheme.mono(size: 13, color: c.textFaintest)
                  : RelicTheme.sans(size: 13.5, color: c.textFaintest),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _ghost(RelicColors c, String t, VoidCallback? onTap) =>
      GhostButton(label: t, size: 34, fontSize: 13, onTap: onTap);

  // The single gold CTA per step. GhostButton's own disabled treatment (track
  // fill, faintest label) replaces the old half-alpha accent.
  Widget _primary(RelicColors c, String t, VoidCallback? onTap) =>
      GhostButton(
        label: t,
        size: 34,
        fontSize: 13,
        style: GhostStyle.filled,
        onTap: onTap,
      );
}
