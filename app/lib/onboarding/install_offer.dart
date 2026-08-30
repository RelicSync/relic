import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform/app_install.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/controls.dart';

/// The step before onboarding for anyone running Relic out of the disk image
/// (or the read-only shadow copy macOS makes of it). Offers to move the app
/// into /Applications and reopen from there, because everything the next few
/// screens ask them to set up is thrown away with that copy otherwise.
///
/// The host decides whether this shows at all — see
/// [applicationsInstallOffer] — and owns the actual copying, so this widget is
/// only the two doors: install, or quit.
class InstallOfferView extends StatefulWidget {
  /// Why we are asking, which is the only thing that changes the copy.
  final BundleLocation where;

  /// Copy into /Applications and hand off. False means the copy failed and the
  /// user needs the manual route; on success the process exits and this never
  /// completes.
  final Future<bool> Function() onInstall;

  /// Open Finder on /Applications for the manual drag.
  final Future<void> Function() onReveal;

  final VoidCallback onQuit;

  const InstallOfferView({
    super.key,
    required this.where,
    required this.onInstall,
    required this.onReveal,
    required this.onQuit,
  });

  @override
  State<InstallOfferView> createState() => _InstallOfferViewState();
}

class _InstallOfferViewState extends State<InstallOfferView> {
  bool _busy = false;
  bool _failed = false; // the copy was refused; show the drag-it-yourself route

  Future<void> _install() async {
    setState(() => _busy = true);
    final ok = await widget.onInstall();
    if (!mounted) return;
    // Success never lands here (the process is on its way out), so anything
    // that returns is a failure worth explaining. Finder opens with it so the
    // instructions point at something already on screen.
    setState(() {
      _busy = false;
      _failed = !ok;
    });
    if (!ok) await widget.onReveal();
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
          child: ScrollConfiguration(
            behavior:
                ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Insets.xxl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _failed ? _manual(c) : _offer(c),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _offer(RelicColors c) => [
        _header(c, 'Relic runs from your Applications folder', _why),
        _note(c, LucideIcons.info,
            'It takes a second. Relic reopens by itself from the new spot, and you can eject the disk image after that.'),
        const SizedBox(height: Insets.xl),
        _primary('Install and reopen', _busy ? null : _install),
        _secondary('Quit', _busy ? null : widget.onQuit),
      ];

  List<Widget> _manual(RelicColors c) => [
        _header(
            c,
            'Drag Relic across yourself',
            'Relic could not copy itself over, usually because your Mac wants an admin to write to that folder. Your Applications folder is open in Finder now.'),
        _note(c, LucideIcons.folderInput,
            'Drag Relic.app from the disk image window into Applications, then open Relic from Applications. That second step is the one people miss.'),
        const SizedBox(height: Insets.xl),
        _primary('Open my Applications folder',
            _busy ? null : () => widget.onReveal()),
        _secondary('Quit', _busy ? null : widget.onQuit),
      ];

  /// One sentence for what actually happened. Translocation is worth naming
  /// plainly: the user did nothing wrong and there is no folder they can point
  /// at, so "temporary copy" is the honest description.
  String get _why => switch (widget.where) {
        BundleLocation.diskImage =>
          'You are running Relic straight from the disk image you downloaded. That copy disappears when you eject it, and it takes your settings with it. Relic can move itself into Applications and pick up where you left off.',
        BundleLocation.translocated =>
          'macOS is running Relic from a temporary copy, which is what it does when an app is opened from anywhere but the Applications folder. That copy gets thrown away. Relic can install itself properly and reopen from there.',
        BundleLocation.settled =>
          'Relic works best from your Applications folder. It can move itself there and reopen.',
      };

  Widget _header(RelicColors c, String title, String sub) => Padding(
        padding: const EdgeInsets.only(bottom: Insets.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: RelicTheme.headline(size: 21, color: c.text)),
          const SizedBox(height: Insets.sm),
          Text(sub,
              style: RelicTheme.sans(
                  size: 13, color: c.textSecondary, height: 1.5)),
        ]),
      );

  /// A white card on the parchment ground — the system's resting panel, not an
  /// outlined box.
  Widget _note(RelicColors c, IconData icon, String text) => Container(
        padding: const EdgeInsets.all(Insets.lg),
        decoration: BoxDecoration(
          color: c.panel,
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: c.border),
          boxShadow: Shadows.card(c),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: c.accent),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Text(text,
                style: RelicTheme.sans(
                    size: 12.5, color: c.textSecondary, height: 1.5)),
          ),
        ]),
      );

  /// The one gold CTA on this view: a full-width filled pill carrying its own
  /// glow. While the copy runs the label keeps its place and the leading glyph
  /// becomes the spinner, so the button never changes shape mid-action.
  Widget _primary(String label, VoidCallback? onTap) => SizedBox(
        width: double.infinity,
        child: GhostButton(
          label: label,
          size: 44,
          style: GhostStyle.filled,
          fontSize: 14,
          iconSize: 16,
          iconBuilder: _busy
              ? (size, color) => SizedBox(
                    width: size,
                    height: size,
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: color),
                  )
              : null,
          onTap: onTap,
        ),
      );

  Widget _secondary(String label, VoidCallback? onTap) => SizedBox(
        width: double.infinity,
        child: GhostButton(
          label: label,
          size: 40,
          fontSize: 13.5,
          onTap: onTap,
        ),
      );
}
