import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/controls.dart';
import '../widgets/relic_mark.dart';

// ---- shared bits ----------------------------------------------------------

/// The site lockup: the mark, then the wordmark set at the mark's own height in
/// Headline regular and tracked −2%, a third of a mark away. Same construction
/// as the popup header, so first-run and the app read as one brand.
Widget _wordmark(RelicColors c, {double size = 18}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RelicIcon(size: size),
        SizedBox(width: size * 0.33),
        Text(
          'Relic',
          style: RelicTheme.headline(
            size: size,
            weight: FontWeight.w400,
            color: c.text,
            height: 1,
            letterSpacing: size * -0.02,
          ),
        ),
      ],
    );

Widget _passField(RelicColors c, {bool focused = false, IconData? leading, int dots = 12}) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.md),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.input),
        border: Border.all(color: focused ? c.accent : c.borderStrong, width: focused ? 1.5 : 1),
        // Focus reads as the system's warm lift rather than an invented halo.
        boxShadow: focused ? Shadows.selected(c) : null,
      ),
      child: Row(children: [
        if (leading != null) ...[
          Icon(leading, size: 15, color: c.textMuted),
          const SizedBox(width: Insets.sm),
        ],
        Expanded(
          child: Text('•' * dots,
              style: RelicTheme.mono(size: 14, color: c.text, letterSpacing: 1.4)),
        ),
        Icon(LucideIcons.eyeOff, size: 15, color: c.textFaintest),
      ]),
    );

/// The one gold CTA a step is allowed. Full width: [GhostButton] hugs its label
/// under loose constraints, so the tight SizedBox is what stretches it.
Widget _cta(String label, {bool enabled = true}) => SizedBox(
      width: double.infinity,
      child: GhostButton(
        label: label,
        size: 40,
        fontSize: 13.5,
        style: GhostStyle.filled,
        onTap: enabled ? () {} : null,
      ),
    );

BoxDecoration _frame(RelicColors c) => BoxDecoration(
      color: c.base,
      borderRadius: BorderRadius.circular(Radii.popup),
      border: Border.all(color: c.border, width: 1),
      boxShadow: Shadows.window(c),
    );

// ---- setup ----------------------------------------------------------------

enum SetupKind { checking, newAccount, existing, error }

class SetupView extends StatelessWidget {
  final SetupKind kind;
  const SetupView({super.key, required this.kind});

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return SizedBox(
      width: 480,
      child: switch (kind) {
        SetupKind.checking => _checking(c),
        SetupKind.newAccount => _newAccount(c),
        SetupKind.existing => _existing(c),
        SetupKind.error => _error(c),
      },
    );
  }

  Widget _checking(RelicColors c) => Container(
        height: 480,
        decoration: _frame(c),
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _wordmark(c, size: 26),
          const SizedBox(height: Insets.xxl),
          _Spinner(color: c.accent),
          const SizedBox(height: Insets.xxl),
          Text('Checking your account…', style: RelicTheme.sans(size: 13, color: c.textMuted)),
        ]),
      );

  Widget _newAccount(RelicColors c) => Container(
        decoration: _frame(c),
        padding: const EdgeInsets.all(Insets.xxxl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          _wordmark(c),
          const SizedBox(height: Insets.xxl),
          Text('Choose an encryption passphrase',
              style: RelicTheme.headline(size: 22, color: c.text)),
          const SizedBox(height: Insets.sm),
          Text('It encrypts everything on this device. Make it strong and memorable.',
              style: RelicTheme.sans(size: 13, color: c.textMuted, height: 1.5)),
          const SizedBox(height: Insets.xxl),
          _fieldLabel(c, 'Passphrase'),
          _passField(c, focused: true),
          const SizedBox(height: Insets.lg),
          _fieldLabel(c, 'Confirm passphrase'),
          _passField(c),
          const SizedBox(height: Insets.xl),
          // The lost-passphrase warning is the system's warm secret chip, one
          // size up: gold-tint ground, deep-gold text, no outline.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
            decoration: BoxDecoration(
                color: c.secretBg,
                borderRadius: BorderRadius.circular(Radii.card)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(LucideIcons.shieldAlert, size: 16, color: c.secret),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Text('If this passphrase is lost, your data can’t be recovered, by design. Relic never sees it.',
                    style: RelicTheme.sans(size: 12, color: c.secretBright, height: 1.5)),
              ),
            ]),
          ),
          const SizedBox(height: Insets.xl),
          _cta('Create key'),
        ]),
      );

  Widget _existing(RelicColors c) => Container(
        height: 480,
        decoration: _frame(c),
        padding: const EdgeInsets.all(Insets.xxxl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          _wordmark(c),
          const SizedBox(height: Insets.xxl),
          Text('Enter your encryption passphrase',
              style: RelicTheme.headline(size: 22, color: c.text)),
          const SizedBox(height: Insets.sm),
          Text('Unlock your vault on this device. It’s decrypted locally, never on our servers.',
              style: RelicTheme.sans(size: 13, color: c.textMuted, height: 1.5)),
          const SizedBox(height: Insets.xxl),
          _fieldLabel(c, 'Passphrase'),
          _passField(c, focused: true, leading: LucideIcons.keyRound),
          const SizedBox(height: Insets.xl),
          _cta('Unlock'),
        ]),
      );

  Widget _error(RelicColors c) => Container(
        height: 480,
        decoration: _frame(c),
        padding: const EdgeInsets.all(Insets.section),
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 68, height: 68,
            decoration: BoxDecoration(
              color: c.warningBg,
              borderRadius: BorderRadius.circular(Radii.card),
              border: Border.all(color: c.warning.withValues(alpha: 0.3)),
            ),
            alignment: Alignment.center,
            child: Icon(LucideIcons.cloudOff, size: 30, color: c.warning),
          ),
          const SizedBox(height: Insets.xl),
          Text('Can’t reach Relic right now', style: RelicTheme.headline(size: 19, color: c.text)),
          const SizedBox(height: Insets.sm),
          SizedBox(width: 300, child: Text('Check your connection. Your captures are safe and stored locally in the meantime.', textAlign: TextAlign.center, style: RelicTheme.sans(size: 12.5, color: c.textMuted, height: 1.5))),
          const SizedBox(height: Insets.xxl),
          Row(mainAxisSize: MainAxisSize.min, children: [
            GhostButton(
              label: 'Retry',
              size: 36,
              style: GhostStyle.filled,
              onTap: () {},
            ),
            const SizedBox(width: Insets.sm),
            GhostButton(label: 'Work offline', size: 36, onTap: () {}),
          ]),
        ]),
      );

  Widget _fieldLabel(RelicColors c, String t) => Padding(
        padding: const EdgeInsets.only(bottom: Insets.sm),
        child: Text(t.toUpperCase(), style: RelicTheme.label(c.textMuted)),
      );
}

// ---- lock -----------------------------------------------------------------

class LockView extends StatelessWidget {
  final bool error;
  const LockView({super.key, this.error = false});

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return SizedBox(
      width: 460,
      height: 480,
      child: Container(
        decoration: _frame(c),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          Container(
            padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, Insets.md),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
            child: Row(children: [
              _wordmark(c, size: 16),
              const Spacer(),
              Icon(LucideIcons.lock, size: 14, color: c.secret),
            ]),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.section),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    color: c.secretBg,
                    borderRadius: BorderRadius.circular(Radii.cardLarge),
                  ),
                  alignment: Alignment.center,
                  child: Icon(LucideIcons.lock, size: 30, color: c.secret),
                ),
                const SizedBox(height: Insets.xl),
                Text('Relic is locked', style: RelicTheme.headline(size: 20, color: c.text)),
                const SizedBox(height: Insets.sm),
                Text('Enter your passphrase to continue.', style: RelicTheme.sans(size: 12.5, color: c.textMuted)),
                const SizedBox(height: Insets.xl),
                _LockField(error: error),
                if (error) ...[
                  const SizedBox(height: Insets.md),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(LucideIcons.circleX, size: 13, color: c.dangerText),
                    const SizedBox(width: Insets.sm),
                    Text('Incorrect passphrase. Try again.', style: RelicTheme.sans(size: 12, color: c.dangerText)),
                  ]),
                ],
                const SizedBox(height: Insets.lg),
                _cta('Unlock'),
              ]),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: Insets.md),
            decoration: BoxDecoration(color: c.footer, border: Border(top: BorderSide(color: c.border))),
            alignment: Alignment.center,
            child: Text('On-screen content stays hidden while locked', style: RelicTheme.sans(size: 11, color: c.textFaintest)),
          ),
        ]),
      ),
    );
  }
}

class _LockField extends StatelessWidget {
  final bool error;
  const _LockField({required this.error});
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.md),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.input),
        border: Border.all(color: error ? c.danger : c.accent, width: 1.5),
        boxShadow: error ? null : Shadows.selected(c),
      ),
      child: Row(children: [
        Icon(LucideIcons.keyRound, size: 15, color: c.textMuted),
        const SizedBox(width: Insets.sm),
        Expanded(child: Text('•' * (error ? 8 : 10), style: RelicTheme.mono(size: 14, color: c.text, letterSpacing: 1.6))),
      ]),
    );
  }
}

// ---- recovery kit ---------------------------------------------------------

class RecoveryKitView extends StatefulWidget {
  final String key_;
  const RecoveryKitView({super.key, this.key_ = 'f3a9 7c21 0b4e 88d5 19af 6c30 ee72 4b91 a05f 2d68 cc1a 7f43'});
  @override
  State<RecoveryKitView> createState() => _RecoveryKitViewState();
}

class _RecoveryKitViewState extends State<RecoveryKitView> {
  bool _saved = false;
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return SizedBox(
      width: 560,
      child: Container(
        decoration: _frame(c),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // The top rule is a gold FILL, so it takes the system's gradient.
          Container(
            height: 3,
            decoration: const BoxDecoration(gradient: Gradients.gold),
          ),
          Padding(
            padding: const EdgeInsets.all(Insets.section),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Container(
                  width: 60, height: 60,
                  decoration: BoxDecoration(
                    color: c.selectedTile,
                    borderRadius: BorderRadius.circular(Radii.card),
                    boxShadow: Shadows.selected(c),
                  ),
                  alignment: Alignment.center,
                  child: Icon(LucideIcons.keyRound, size: 28, color: c.accent),
                ),
                const SizedBox(width: Insets.lg),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('SHOWN ONCE · RELIC KEEPS NO COPY',
                        style: RelicTheme.kicker(c.accentMuted)),
                    const SizedBox(height: Insets.sm),
                    Text('Save your recovery key', style: RelicTheme.headline(size: 26, color: c.text)),
                  ]),
                ),
              ]),
              const SizedBox(height: Insets.xxl),
              Text.rich(TextSpan(style: RelicTheme.sans(size: 13.5, color: c.textSecondary, height: 1.6), children: [
                const TextSpan(text: 'This is the '),
                TextSpan(text: 'only', style: RelicTheme.sans(size: 13.5, weight: FontWeight.w500, color: c.text)),
                const TextSpan(text: ' way back into your vault if you forget your passphrase. Write it down or store it in a password manager, somewhere offline and safe.'),
              ])),
              const SizedBox(height: Insets.xxl),
              _keyBlock(c),
              const SizedBox(height: Insets.xxl),
              GestureDetector(
                onTap: () => setState(() => _saved = !_saved),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Row(children: [
                    Container(
                      width: 22, height: 22,
                      decoration: BoxDecoration(
                        // Ticked is a gold fill, so it carries the gradient.
                        color: _saved ? null : c.surface,
                        gradient: _saved ? Gradients.gold : null,
                        borderRadius: BorderRadius.circular(Radii.chip),
                        border: _saved ? null : Border.all(color: c.borderStrong, width: 1.5),
                      ),
                      alignment: Alignment.center,
                      child: _saved ? Icon(LucideIcons.check, size: 15, color: c.onAccent) : null,
                    ),
                    const SizedBox(width: Insets.md),
                    Text('I’ve saved this somewhere safe.', style: RelicTheme.sans(size: 13.5, color: _saved ? c.text : c.textMuted)),
                  ]),
                ),
              ),
              const SizedBox(height: Insets.xxl),
              _cta('Continue', enabled: _saved),
              const SizedBox(height: Insets.md),
              Center(child: Text('Continue stays disabled until the box is ticked.', style: RelicTheme.sans(size: 11, color: c.textFaintest))),
            ]),
          ),
        ]),
      ),
    );
  }

  /// The key itself is a secret, so it sits in the system's warm well: gold-tint
  /// ground, deep-gold mono text. Bright gold as *text* on a bare card is the
  /// one thing this palette must never do.
  Widget _keyBlock(RelicColors c) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Insets.xl),
        decoration: BoxDecoration(
          color: c.tagBg,
          borderRadius: BorderRadius.circular(Radii.card),
        ),
        child: Stack(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('RECOVERY KEY', style: RelicTheme.kicker(c.accentMuted)),
            const SizedBox(height: Insets.md),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: SelectableTextProxy(widget.key_, style: RelicTheme.mono(size: 15, color: c.tagText, height: 1.9, letterSpacing: 0.8)),
            ),
          ]),
          Positioned(
            top: 0, right: 0,
            child: GhostButton(
              icon: LucideIcons.copy,
              label: 'Copy',
              size: 26,
              iconSize: 13,
              fontSize: 11,
              onTap: () {},
            ),
          ),
        ]),
      );
}

/// Plain Text proxy (avoids importing Material for SelectableText here).
class SelectableTextProxy extends StatelessWidget {
  final String text;
  final TextStyle style;
  const SelectableTextProxy(this.text, {super.key, required this.style});
  @override
  Widget build(BuildContext context) => Text(text, style: style);
}

class _Spinner extends StatefulWidget {
  final Color color;
  const _Spinner({required this.color});
  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner> with SingleTickerProviderStateMixin {
  late final _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat();
  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
        turns: _ctl,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: widget.color.withValues(alpha: 0.25), width: 2.5),
          ),
          child: CustomPaint(painter: _ArcPainter(widget.color)),
        ),
      );
}

class _ArcPainter extends CustomPainter {
  final Color color;
  _ArcPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Offset.zero & size, -1.2, 1.6, false, p);
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color;
}
