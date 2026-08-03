import 'dart:convert';

import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/repo.dart';
import '../models/relic.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/controls.dart';

/// Share a relic: an offline QR of the text itself (nothing leaves the
/// device), and/or an E2EE share link (ciphertext on the Worker, key in the
/// URL fragment, branded no-account recipient page). A plain overlay widget
/// for PopupView's `_setDialog` funnel — NOT a Navigator route.
class ShareDialog extends StatefulWidget {
  final Relic relic;
  final RelicRepo repo;
  final VoidCallback onClose;
  const ShareDialog({
    super.key,
    required this.relic,
    required this.repo,
    required this.onClose,
  });

  @override
  State<ShareDialog> createState() => _ShareDialogState();
}

/// Raw text small enough to scan reliably as a QR at dialog size.
const _kQrMaxBytes = 1000;

class _ShareDialogState extends State<ShareDialog> {
  bool _secretConfirmed = false;
  int _ttlIndex = 1; // 0 = 1 hour, 1 = 1 day, 2 = 7 days
  late bool _oneTime = widget.relic.isSecret; // secrets default to one view
  bool _creating = false;
  ShareLink? _link;
  String? _error;
  bool _copied = false;

  static const _ttls = [Duration(hours: 1), Duration(days: 1), Duration(days: 7)];
  static const _ttlLabels = ['1 hour', '1 day', '7 days'];

  bool get _qrEligible =>
      widget.relic.kind == Kind.string &&
      (widget.relic.content ?? '').isNotEmpty;

  bool get _qrFits =>
      _qrEligible && utf8.encode(widget.relic.content!).length <= _kQrMaxBytes;

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final link = await widget.repo
          .createShare(widget.relic, ttl: _ttls[_ttlIndex], oneTime: _oneTime);
      if (mounted) setState(() => _link = link);
    } on ShareException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = "Couldn't create the link. Check your connection.");
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _copyLink() async {
    final url = _link?.url;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final needsGate = widget.relic.isSecret && !_secretConfirmed;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Container(
        width: 460,
        decoration: BoxDecoration(
          color: c.panel,
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: c.border, width: 1),
          boxShadow: [
            BoxShadow(
                color: c.shadowModal,
                blurRadius: 70,
                spreadRadius: -18,
                offset: const Offset(0, 30)),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(c),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                child: needsGate ? _secretGate(c) : _body(c),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(RelicColors c) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.border, width: 1))),
        child: Row(children: [
          Icon(LucideIcons.share2, size: 15, color: c.textSecondary),
          const SizedBox(width: 9),
          Expanded(
            child: Text('Share',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RelicTheme.sans(
                    size: 14, weight: FontWeight.w500, color: c.text)),
          ),
          GhostIconButton(icon: LucideIcons.x, size: 26, iconSize: 15, onTap: widget.onClose),
        ]),
      );

  Widget _secretGate(RelicColors c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(LucideIcons.keyRound, size: 16, color: c.secretBright),
            const SizedBox(width: 8),
            Text('Share this secret?',
                style: RelicTheme.sans(
                    size: 14.5, weight: FontWeight.w600, color: c.text)),
          ]),
          const SizedBox(height: 8),
          Text(
            'Anyone with the link or QR can read it. One-time view is recommended.',
            style: RelicTheme.sans(
                size: 12.5, color: c.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            _ghostBtn(c, 'Cancel', widget.onClose),
            const SizedBox(width: 8),
            _primaryBtn(c, 'Continue',
                () => setState(() => _secretConfirmed = true)),
          ]),
        ],
      );

  Widget _body(RelicColors c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_qrEligible) ...[
            _sectionTitle(c, LucideIcons.qrCode, 'Scan directly, offline'),
            const SizedBox(height: 8),
            if (_qrFits) ...[
              Center(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  // QR backgrounds stay white in both themes for scanability.
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFFFF),
                    borderRadius: BorderRadius.circular(Radii.input),
                  ),
                  child: QrImageView(
                    data: widget.relic.content!,
                    size: 200,
                    version: QrVersions.auto,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text('Encodes the text itself. Nothing leaves this device.',
                    style: RelicTheme.sans(size: 11, color: c.textMuted)),
              ),
            ] else
              Text('Too long for a QR code. Use a link instead.',
                  style: RelicTheme.sans(size: 12, color: c.textMuted)),
            const SizedBox(height: 16),
            Container(height: 1, color: c.border),
            const SizedBox(height: 14),
          ],
          _sectionTitle(c, LucideIcons.link, 'Send a link'),
          const SizedBox(height: 8),
          if (!widget.repo.canShare)
            Text(
              'Sign in to create encrypted share links. Recipients just open a web page. No account needed on their side.',
              style: RelicTheme.sans(
                  size: 12.5, color: c.textSecondary, height: 1.5),
            )
          else if (_link == null)
            _options(c)
          else
            _result(c),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: RelicTheme.sans(size: 12, color: c.dangerText)),
          ],
        ],
      );

  Widget _options(RelicColors c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The item is encrypted on this device. The key travels inside the link and never reaches the server.',
            style:
                RelicTheme.sans(size: 12, color: c.textMuted, height: 1.5),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Text('Expires',
                style: RelicTheme.sans(size: 12.5, color: c.textSecondary)),
            const SizedBox(width: 10),
            for (var i = 0; i < _ttlLabels.length; i++) ...[
              _chip(c, _ttlLabels[i], i == _ttlIndex,
                  () => setState(() => _ttlIndex = i)),
              const SizedBox(width: 6),
            ],
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _chip(c, 'One-time view', _oneTime,
                () => setState(() => _oneTime = !_oneTime)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _oneTime
                    ? 'The link dies after the first reveal.'
                    : 'Anyone with the link can view until it expires.',
                style: RelicTheme.sans(size: 11, color: c.textMuted),
              ),
            ),
          ]),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            _primaryBtn(c, _creating ? 'Encrypting…' : 'Create link',
                _creating ? null : _create),
          ]),
        ],
      );

  Widget _result(RelicColors c) {
    final link = _link!;
    final when = DateTime.fromMillisecondsSinceEpoch(link.expiresAt * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final caption =
        '${link.oneTime ? 'One-time view · ' : ''}expires ${months[when.month - 1]} ${when.day}, ${two(when.hour)}:${two(when.minute)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(Radii.input),
            border: Border.all(color: c.borderStrong),
          ),
          child: Row(children: [
            Expanded(
              child: SelectableText(
                link.url,
                maxLines: 1,
                style: RelicTheme.mono(size: 11, color: c.text),
              ),
            ),
            const SizedBox(width: 8),
            _ghostBtn(c, _copied ? 'Copied ✓' : 'Copy', _copyLink),
          ]),
        ),
        const SizedBox(height: 12),
        Center(
          child: Container(
            padding: const EdgeInsets.all(10),
            // QR backgrounds stay white in both themes for scanability.
            decoration: BoxDecoration(
              color: const Color(0xFFFFFFFF),
              borderRadius: BorderRadius.circular(Radii.input),
            ),
            child: QrImageView(
                data: link.url, size: 180, version: QrVersions.auto),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(caption,
              style: RelicTheme.sans(size: 11.5, color: c.textMuted)),
        ),
      ],
    );
  }

  Widget _sectionTitle(RelicColors c, IconData icon, String t) => Row(children: [
        Icon(icon, size: 14, color: c.accentMuted),
        const SizedBox(width: 7),
        Text(t,
            style: RelicTheme.sans(
                size: 13, weight: FontWeight.w600, color: c.text)),
      ]);

  Widget _chip(RelicColors c, String label, bool on, VoidCallback onTap) =>
      Hoverable(
        onTap: onTap,
        builder: (context, hovered) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            // ON: selected fill, no border. OFF: transparent (ghostHover on
            // hover), a hairline in light only.
            color: on
                ? c.selected
                : (hovered ? c.ghostHover : const Color(0x00000000)),
            borderRadius: BorderRadius.circular(Radii.pill),
            border: on
                ? null
                : (c.isDark ? null : Border.all(color: c.border)),
          ),
          child: Text(label,
              style: RelicTheme.sans(
                  size: 11.5,
                  weight: on ? FontWeight.w600 : FontWeight.w400,
                  color: on ? c.textOnSelected : c.textSecondary)),
        ),
      );

  // Disabled (onTap == null) falls back to the track fill + faintest fg that
  // GhostButton applies automatically for a filled style with no handler.
  Widget _primaryBtn(RelicColors c, String label, VoidCallback? onTap) =>
      PrimaryButton(label: label, onTap: onTap);

  Widget _ghostBtn(RelicColors c, String label, VoidCallback onTap) =>
      GhostButton(label: label, size: 28, onTap: onTap);
}
