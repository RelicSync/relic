import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/controls.dart';
import '../widgets/relic_mark.dart';

/// How long "Not now" keeps the sync card away. It comes back after this
/// until the account has a second device, because an account with one device
/// is an account that has not found the point of Relic yet.
const Duration syncNudgeSnooze = Duration(days: 14);

/// The desktop waits until the person has saved a few things before it says
/// anything about phones; a first launch already has enough on screen. The
/// phone does not wait: its whole problem is the empty list.
const int syncNudgeDesktopMinItems = 5;

/// Whether the sync card belongs above the list right now.
///
/// Phone-only accounts save almost nothing (twelve of them saved one item
/// between them in the two weeks to 2026-09-27), because the phone cannot
/// capture by itself and nothing after the first screen said the computer is
/// where that happens. The card says it, stays until a second device joins,
/// and can be put off for [syncNudgeSnooze] at a time.
bool showSyncNudge({
  required bool connected,
  required int? deviceCount,
  required int itemCount,
  required int snoozedUntil,
  required int now,
  required bool desktop,
}) =>
    connected &&
    deviceCount == 1 &&
    now >= snoozedUntil &&
    (!desktop || itemCount >= syncNudgeDesktopMinItems);

/// The card itself. On a phone it offers the desktop download link; on a
/// desktop it opens the pairing screen. Either way "Not now" snoozes it.
class SyncNudgeCard extends StatefulWidget {
  /// Desktop copy and action (add a phone) rather than the phone's (get the
  /// computer app).
  final bool desktop;

  /// Phone: ask the server to email the desktop link. Throws with a message
  /// to show.
  final Future<void> Function()? onSendDownloadLink;

  /// Desktop: open the pairing screen.
  final VoidCallback? onAddDevice;

  final VoidCallback onDismiss;

  const SyncNudgeCard({
    super.key,
    required this.desktop,
    required this.onDismiss,
    this.onSendDownloadLink,
    this.onAddDevice,
  });

  @override
  State<SyncNudgeCard> createState() => _SyncNudgeCardState();
}

class _SyncNudgeCardState extends State<SyncNudgeCard> {
  bool _sending = false;
  String? _result;
  bool _failed = false;

  Future<void> _send() async {
    final send = widget.onSendDownloadLink;
    if (send == null || _sending) return;
    setState(() {
      _sending = true;
      _result = null;
      _failed = false;
    });
    try {
      await send();
      if (!mounted) return;
      setState(() {
        _sending = false;
        _result = 'Sent. Open it on your computer and sign in with this account.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _result = e.toString().replaceFirst('Bad state: ', '');
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final desktop = widget.desktop;
    final title = desktop
        ? 'Get your clipboard on your phone'
        : 'Relic is built for syncing with your computer';
    final body = desktop
        ? 'Everything you copy here shows up on your phone a second later. '
            'The phone app is free.'
        : 'Copy something on your computer and it shows up here a second '
            'later. Install Relic there and sign in with this account.';
    final sent = _result != null && !_failed;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(Insets.md, Insets.md, Insets.md, 0),
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.sm, Insets.md),
      decoration: BoxDecoration(
        color: c.tagBg,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: c.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  desktop ? LucideIcons.smartphone : LucideIcons.monitor,
                  size: 15,
                  color: c.accent,
                ),
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: RelicTheme.headline(size: 14, color: c.text)),
                    const SizedBox(height: 4),
                    Text(
                      body,
                      style: RelicTheme.sans(
                          size: 12.5, color: c.textSecondary, height: 1.45),
                    ),
                  ],
                ),
              ),
              GhostIconButton(
                icon: LucideIcons.x,
                size: 24,
                iconSize: 13,
                tooltip: 'Not now',
                onTap: widget.onDismiss,
              ),
            ],
          ),
          const SizedBox(height: Insets.md),
          if (_result case final r?)
            Padding(
              padding: const EdgeInsets.only(right: Insets.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_failed ? LucideIcons.circleAlert : LucideIcons.check,
                      size: 14, color: _failed ? c.danger : c.accent),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(r,
                        style: RelicTheme.sans(
                            size: 12,
                            color: _failed ? c.danger : c.textSecondary,
                            height: 1.4)),
                  ),
                ],
              ),
            ),
          if (!sent)
            // A Wrap, not a Row: "Send me the download link" and "Not now"
            // do not fit side by side on a narrow phone, and the second
            // button belongs on the next line there rather than clipped.
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (desktop)
                  PrimaryButton(
                    icon: LucideIcons.qrCode,
                    label: 'Add a phone',
                    height: 32,
                    onTap: widget.onAddDevice,
                  )
                else
                  PrimaryButton(
                    icon: LucideIcons.mail,
                    // Shorter than the first-run screen's button on purpose:
                    // the body above has already said what the link is, and
                    // this one shares a line with "Not now" on a narrow
                    // phone.
                    label: _sending ? 'Sending' : 'Email me the link',
                    height: 32,
                    onTap: _sending ? null : _send,
                  ),
                GhostButton(
                  label: 'Not now',
                  size: 32,
                  onTap: widget.onDismiss,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// A computer and a phone with the same item on both, and the gem between
/// them. Drawn from theme parts so it follows light and dark, and small
/// enough to sit above a paragraph without pushing the buttons off a short
/// phone.
class SyncIllustration extends StatelessWidget {
  const SyncIllustration({super.key});

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    Widget screen({required double width, required double height,
        required IconData icon, required double radius}) {
      return Container(
        width: width,
        height: height,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: c.panel,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: c.borderStrong, width: 1.2),
          boxShadow: Shadows.card(c),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 12, color: c.textFaintest),
            const Spacer(),
            _itemCard(c),
          ],
        ),
      );
    }

    // One centred row with the same gap either side of the gem, and the gem
    // centred on the screens' midline. Giving each screen half the width
    // put the wide computer close to the gem and the narrow phone far from
    // it, so the whole thing read as leaning left.
    return SizedBox(
      height: 118,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            screen(
                width: 128, height: 88, icon: LucideIcons.monitor, radius: 10),
            const SizedBox(width: 22),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const RelicIcon(size: 28),
                const SizedBox(height: 6),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  for (var i = 0; i < 4; i++)
                    Container(
                      width: 4,
                      height: 4,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: c.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  Icon(LucideIcons.chevronRight, size: 12, color: c.accent),
                ]),
              ],
            ),
            const SizedBox(width: 22),
            screen(
                width: 62, height: 112, icon: LucideIcons.smartphone, radius: 14),
          ],
        ),
      ),
    );
  }

  /// The one item, drawn the same on both screens: a gold dot and two lines.
  static Widget _itemCard(RelicColors c) => Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.border, width: 1),
        ),
        child: Row(children: [
          Container(
            width: 6,
            height: 6,
            decoration:
                BoxDecoration(color: c.accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(height: 3, width: double.infinity, color: c.textFaint),
                const SizedBox(height: 3),
                FractionallySizedBox(
                  widthFactor: 0.6,
                  child: Container(height: 3, color: c.textFaintest),
                ),
              ],
            ),
          ),
        ]),
      );
}
