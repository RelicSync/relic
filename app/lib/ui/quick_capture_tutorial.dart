import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart' show showModalBottomSheet;
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/relic_mark.dart';

/// Detect the platform and show the matching quick-capture walkthrough:
///  - iOS has no Quick Settings tile, so it teaches a Shortcut bound to Back Tap
///    / the Action Button (plus the Share sheet).
///  - Android teaches adding the "Capture to Relic" Quick Settings tile; Samsung
///    runs One UI, whose editor differs from stock, so those steps are tailored.
Future<void> showQuickCaptureTutorial(
  BuildContext context, {
  required RelicColors colors,
}) async {
  final ios = Platform.isIOS;
  var oneUi = false;
  if (!ios) {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final m = '${info.manufacturer} ${info.brand}'.toLowerCase();
      oneUi = m.contains('samsung');
    } catch (_) {}
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: colors.panel,
    builder: (_) => RelicTheme(
      colors: colors,
      isMobile: true,
      child: _QuickCaptureTutorial(ios: ios, oneUi: oneUi),
    ),
  );
}

class _QuickCaptureTutorial extends StatelessWidget {
  final bool ios;
  final bool oneUi;
  const _QuickCaptureTutorial({required this.ios, required this.oneUi});

  List<(String, String)> get _steps => ios
      ? const [
          (
            'Create a Shortcut',
            'Open the Shortcuts app → New Shortcut → Add Action → “Open URLs”.'
          ),
          (
            'Point it at Relic',
            'Set the URL to relic://capture and name the shortcut “Capture to Relic”.'
          ),
          (
            'Bind it to a gesture',
            'Settings → Accessibility → Touch → Back Tap → Double Tap → pick “Capture to Relic”. On iPhone 15 Pro and later you can map the Action Button instead.'
          ),
          (
            'Use it',
            'Copy anything, then double-tap the back of your iPhone. Relic opens and grabs your clipboard.'
          ),
        ]
      : oneUi
      // One UI 7/8 (2025+): the Quick panel opens from the top-RIGHT corner
      // when notifications and quick settings are separated (the default on
      // new setups), and editing is a pencil icon, not the old ⋮ menu.
      ? const [
          (
            'Open the Quick panel',
            'Swipe down from the top-right corner of the screen. If your notifications and quick settings are combined, swipe down twice from the top instead.'
          ),
          (
            'Tap the pencil (Edit)',
            'Tap the pencil icon at the top of the panel. On older One UI it hides behind the ⋮ menu as “Edit buttons”.'
          ),
          (
            'Find “Capture to Relic”',
            'Scroll the available buttons. You’ll see the Relic gem labelled Capture to Relic.'
          ),
          (
            'Add it',
            'Tap its ＋, or press and hold and drag it into the buttons you use.'
          ),
          ('Tap Done', 'Save your layout. The tile now lives in your Quick panel.'),
        ]
      : const [
          (
            'Open Quick Settings',
            'Swipe down from the top of the screen twice to open the full Quick Settings panel.'
          ),
          (
            'Tap the edit (pencil) icon',
            'Open the tile editor, usually a pencil or ＋ button.'
          ),
          (
            'Find “Capture to Relic”',
            'Look in the available / inactive tiles for the Relic gem labelled Capture to Relic.'
          ),
          (
            'Drag it into your active tiles',
            'Press and hold, then drop it among the tiles you use.'
          ),
          ('Save', 'Tap done or back to keep the layout.'),
        ];

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final media = MediaQuery.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * 0.86),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(c, context),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The simplest, most reliable route in — lead with it.
                      _shareSection(c),
                      const SizedBox(height: 22),
                      // The other route: one-tap capture of your clipboard.
                      Text(
                        'ONE-TAP CLIPBOARD CAPTURE',
                        style: RelicTheme.mono(
                            size: 10.5, color: c.textMuted, letterSpacing: 0.8),
                      ),
                      const SizedBox(height: 12),
                      _whyNote(c),
                      if (!ios) _tileMock(c), // no Quick Settings tile on iOS
                      const SizedBox(height: 18),
                      Text(
                        ios
                            ? 'On your iPhone'
                            : oneUi
                                ? 'On your Samsung (One UI)'
                                : 'On your phone',
                        style: RelicTheme.mono(
                            size: 10.5, color: c.textMuted, letterSpacing: 0.8),
                      ),
                      const SizedBox(height: 12),
                      for (final (i, step) in _steps.indexed) ...[
                        _step(c, i + 1, step.$1, step.$2),
                        if (i < _steps.length - 1) const SizedBox(height: 14),
                      ],
                      const SizedBox(height: 22),
                      _usage(c),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(RelicColors c, BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 14, 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border, width: 1)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Quick capture from anywhere',
                      style: RelicTheme.sans(
                          size: 17, weight: FontWeight.w600, color: c.text)),
                  const SizedBox(height: 4),
                  Text(
                    ios
                        ? 'Save your clipboard to Relic with one tap: a Shortcut on Back Tap or the Action Button.'
                        : 'Add the Relic tile to your Quick Settings to save your clipboard with one tap, from any app.',
                    style: RelicTheme.sans(
                        size: 12.5, color: c.textMuted, height: 1.45),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(Radii.chip)),
                alignment: Alignment.center,
                child: Icon(LucideIcons.x, size: 17, color: c.textSecondary),
              ),
            ),
          ],
        ),
      );

  /// Explain why capture is a manual tap and not automatic — it's an Android
  /// platform limitation, not a missing feature.
  Widget _whyNote(RelicColors c) => Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: c.border, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(LucideIcons.info, size: 15, color: c.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: RelicTheme.sans(size: 12.5, color: c.textSecondary, height: 1.5),
                  children: [
                    TextSpan(text: ios
                        ? 'iOS doesn’t let any app read what you copy in the background, '
                        : 'Android doesn’t let any app capture what you copy in the background, '),
                    TextSpan(
                      text: 'only the app you’re using or your keyboard can read the clipboard.',
                      style: RelicTheme.sans(size: 12.5, color: c.text, weight: FontWeight.w600, height: 1.5),
                    ),
                    TextSpan(text: ios
                        ? ' So Relic captures with one tap you trigger yourself: a Shortcut on Back Tap or the Action Button.'
                        : ' So Relic captures your clipboard with one tap from a button instead: the Quick Settings tile below.'),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  /// A small mock of a Quick Settings shade with the Relic tile highlighted, so
  /// the user knows exactly what they're looking for.
  Widget _tileMock(RelicColors c) => Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.footer,
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: c.border, width: 1),
        ),
        child: Row(
          children: [
            _dummyTile(c, false),
            const SizedBox(width: 10),
            _relicTile(c),
            const SizedBox(width: 10),
            _dummyTile(c, false),
            const SizedBox(width: 10),
            _dummyTile(c, false),
          ],
        ),
      );

  Widget _relicTile(RelicColors c) => Expanded(
        child: Column(
          children: [
            Container(
              height: 54,
              decoration: BoxDecoration(
                color: c.accent.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(Radii.card),
                border: Border.all(color: c.accent, width: 1.5),
              ),
              alignment: Alignment.center,
              child: const RelicIcon(size: 26),
            ),
            const SizedBox(height: 5),
            Text('Capture\nto Relic',
                textAlign: TextAlign.center,
                style: RelicTheme.mono(size: 8.5, color: c.accentMuted, height: 1.2)),
          ],
        ),
      );

  Widget _dummyTile(RelicColors c, bool on) => Expanded(
        child: Column(
          children: [
            Container(
              height: 54,
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(Radii.card),
                border: Border.all(color: c.border, width: 1),
              ),
              alignment: Alignment.center,
              child: Icon(LucideIcons.circle, size: 18, color: c.textFaintest),
            ),
            const SizedBox(height: 5),
            Container(height: 6, width: 30, decoration: BoxDecoration(color: c.border, borderRadius: BorderRadius.circular(3))),
          ],
        ),
      );

  Widget _step(RelicColors c, int n, String title, String body) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(Radii.chip),
              border: Border.all(color: c.accent.withValues(alpha: 0.3)),
            ),
            alignment: Alignment.center,
            child: Text('$n',
                style: RelicTheme.mono(
                    size: 12, weight: FontWeight.w700, color: c.accent)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(title,
                      style: RelicTheme.sans(
                          size: 14, weight: FontWeight.w600, color: c.text)),
                ),
                const SizedBox(height: 3),
                Text(body,
                    style: RelicTheme.sans(
                        size: 12.5, color: c.textMuted, height: 1.45)),
              ],
            ),
          ),
        ],
      );

  Widget _usage(RelicColors c) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: c.accent.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(LucideIcons.zap, size: 14, color: c.accent),
              const SizedBox(width: 7),
              Text('Then, from anywhere',
                  style: RelicTheme.sans(
                      size: 13, weight: FontWeight.w600, color: c.text)),
            ]),
            const SizedBox(height: 8),
            Text(
              ios
                  ? 'Copy anything → double-tap the back of your iPhone (or press the Action Button) → it’s saved to your vault instantly.'
                  : 'Copy anything → pull down Quick Settings → tap Capture to Relic. It’s saved to your vault instantly.',
              style: RelicTheme.sans(size: 12.5, color: c.textSecondary, height: 1.5),
            ),
          ],
        ),
      );

  /// The primary route in: the system Share sheet. Works everywhere, needs no
  /// setup, and handles things you can't copy as text (images, PDFs, files).
  Widget _shareSection(RelicColors c) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: c.accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: c.accent.withValues(alpha: 0.30)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(LucideIcons.share2, size: 17, color: c.accent),
              const SizedBox(width: 8),
              Text('Share to Relic',
                  style: RelicTheme.sans(
                      size: 15, weight: FontWeight.w700, color: c.text)),
            ]),
            const SizedBox(height: 8),
            Text(
              'The simplest way in. In any app, tap Share and pick Relic. Text, '
              'images, PDFs, links, and files all land in your vault, no setup '
              'required.',
              style: RelicTheme.sans(size: 13, color: c.textSecondary, height: 1.5),
            ),
          ],
        ),
      );
}
