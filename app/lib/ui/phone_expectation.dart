import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/relic_mark.dart';

/// The first thing a phone user sees after their first connect.
///
/// A phone-only account dies inside a day. The reason is plain: people install
/// Relic on the phone, wait for it to save what they copy, and nothing
/// happens, because no phone OS lets an app watch the clipboard in the
/// background. So this screen says it out loud on day one, and offers to email
/// the desktop link while the person still cares.
///
/// Shown once (the host keeps the `phone_expectation_seen` flag) and reachable
/// again from the settings sheet.
Future<void> showPhoneExpectation(
  BuildContext context, {
  required RelicColors colors,
  required Future<void> Function() onSendDownloadLink,
}) =>
    Navigator.of(context).push<void>(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => RelicTheme(
        colors: colors,
        isMobile: true,
        child: PhoneExpectationScreen(onSendDownloadLink: onSendDownloadLink),
      ),
    ));

/// The screen itself. Split out from [showPhoneExpectation] so it can be built
/// straight into a test without a route.
class PhoneExpectationScreen extends StatefulWidget {
  /// Ask the server to email the desktop link. Throws with a message to show.
  final Future<void> Function() onSendDownloadLink;

  /// Leave the screen. Defaults to popping the enclosing route.
  final VoidCallback? onContinue;

  const PhoneExpectationScreen({
    super.key,
    required this.onSendDownloadLink,
    this.onContinue,
  });

  @override
  State<PhoneExpectationScreen> createState() => _PhoneExpectationScreenState();
}

class _PhoneExpectationScreenState extends State<PhoneExpectationScreen> {
  bool _sending = false;
  String? _result; // the line under the button, sent or failed
  bool _failed = false;

  Future<void> _send() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _result = null;
      _failed = false;
    });
    try {
      await widget.onSendDownloadLink();
      if (!mounted) return;
      setState(() {
        _sending = false;
        _result = 'Sent. Open it on your computer.';
        _failed = false;
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

  void _continue() {
    final go = widget.onContinue;
    if (go != null) {
      go();
      return;
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Scaffold(
      backgroundColor: c.base,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              Insets.xxl, Insets.xxl, Insets.xxl, Insets.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const RelicIcon(size: 44),
                      const SizedBox(height: Insets.xxl),
                      Text(
                        'Relic on a phone works differently',
                        style: RelicTheme.headline(size: 24, color: c.text),
                      ),
                      const SizedBox(height: Insets.lg),
                      Text(
                        'On a computer, Relic saves what you copy by itself. '
                        'On a phone, you share things to it on purpose. '
                        'Your vault is the same on both.',
                        style: RelicTheme.sans(
                            size: 15, color: c.textSecondary, height: 1.55),
                      ),
                      const SizedBox(height: Insets.xxl),
                      _computerCard(c),
                    ],
                  ),
                ),
              ),
              if (_result case final r?) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(_failed ? LucideIcons.circleAlert : LucideIcons.check,
                          size: 14, color: _failed ? c.danger : c.accent),
                      const SizedBox(width: Insets.sm),
                      Expanded(
                        child: Text(r,
                            style: RelicTheme.sans(
                                size: 12.5,
                                color: _failed ? c.danger : c.textSecondary,
                                height: 1.4)),
                      ),
                    ],
                  ),
                ),
              ],
              _cta(c, 'Send me the download link',
                  primary: true, onTap: _sending ? null : _send),
              const SizedBox(height: Insets.sm),
              _cta(c, 'Continue', primary: false, onTap: _continue),
            ],
          ),
        ),
      ),
    );
  }

  /// A full-width button for a full-screen step. The shared [GhostButton] hugs
  /// its label, which is right for chrome and wrong here: "Send me the
  /// download link" is long enough to run off a narrow phone. This one fills
  /// the width and lets the label shrink instead.
  Widget _cta(
    RelicColors c,
    String label, {
    required bool primary,
    required VoidCallback? onTap,
  }) {
    final disabled = onTap == null;
    return Semantics(
      button: true,
      enabled: !disabled,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: primary
                ? (disabled ? c.track : null)
                : const Color(0x00000000),
            gradient: primary && !disabled ? Gradients.gold : null,
            borderRadius: BorderRadius.circular(Radii.pill),
            border: primary ? null : Border.all(color: c.border, width: 1),
            boxShadow: primary && !disabled ? Shadows.gold : null,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: RelicTheme.sans(
                size: 14.5,
                weight: primary ? FontWeight.w600 : FontWeight.w500,
                color: disabled
                    ? c.textFaintest
                    : (primary ? c.onAccent : c.textSecondary),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The quiet half: what the computer adds, so the mail button has a reason
  /// next to it rather than reading as an ad.
  Widget _computerCard(RelicColors c) => Container(
        padding: const EdgeInsets.all(Insets.lg),
        decoration: BoxDecoration(
          color: c.inset,
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: c.border, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(LucideIcons.monitor, size: 15, color: c.accent),
              const SizedBox(width: Insets.sm),
              Text('On your computer',
                  style: RelicTheme.headline(size: 14, color: c.text)),
            ]),
            const SizedBox(height: Insets.sm),
            Text(
              'Everything you copy is saved for you, and you can pull it back '
              'with a hotkey. The phone is where you read it and share things '
              'in.',
              style: RelicTheme.sans(
                  size: 13, color: c.textSecondary, height: 1.5),
            ),
          ],
        ),
      );
}
