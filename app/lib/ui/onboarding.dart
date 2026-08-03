import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/relic_mark.dart';

// ---- shared bits ----------------------------------------------------------

Widget _wordmark(RelicColors c, {double gem = 20, double text = 14}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RelicIcon(size: gem),
        const SizedBox(width: 9),
        Text('RELIC',
            style: RelicTheme.mono(
                size: text, weight: FontWeight.w600, color: c.textMuted, letterSpacing: 2.4)),
      ],
    );

Widget _passField(RelicColors c, {bool focused = false, IconData? leading, int dots = 12}) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.input),
        border: Border.all(color: focused ? c.accent : c.borderStrong, width: focused ? 1.5 : 1),
        boxShadow: focused
            ? [BoxShadow(color: c.accent.withValues(alpha: 0.18), spreadRadius: 3, blurRadius: 0)]
            : null,
      ),
      child: Row(children: [
        if (leading != null) ...[Icon(leading, size: 15, color: c.textMuted), const SizedBox(width: 9)],
        Expanded(
          child: Text('•' * dots,
              style: RelicTheme.mono(size: 14, color: c.text, letterSpacing: 1.4)),
        ),
        Icon(LucideIcons.eyeOff, size: 15, color: c.textMuted),
      ]),
    );

Widget _amberButton(RelicColors c, String label, {bool enabled = true}) => Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: enabled ? c.accent : c.surfaceHover,
        borderRadius: BorderRadius.circular(Radii.input),
        border: enabled ? null : Border.all(color: c.border),
      ),
      alignment: Alignment.center,
      child: Text(label,
          style: RelicTheme.sans(
              size: 13.5,
              weight: FontWeight.w600,
              color: enabled ? c.onAccent : c.textFaintest)),
    );

BoxDecoration _frame(RelicColors c) => BoxDecoration(
      color: c.base,
      borderRadius: BorderRadius.circular(Radii.popup),
      border: Border.all(color: c.border, width: 1),
      boxShadow: [
        BoxShadow(color: c.shadowStrong, blurRadius: 80, spreadRadius: -24, offset: const Offset(0, 40)),
      ],
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
          _wordmark(c, gem: 26, text: 22),
          const SizedBox(height: 22),
          _Spinner(color: c.accent),
          const SizedBox(height: 22),
          Text('Checking your account…', style: RelicTheme.sans(size: 13, color: c.textMuted)),
        ]),
      );

  Widget _newAccount(RelicColors c) => Container(
        decoration: _frame(c),
        padding: const EdgeInsets.fromLTRB(30, 32, 30, 32),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          _wordmark(c),
          const SizedBox(height: 18),
          Text('Choose an encryption passphrase',
              style: RelicTheme.sans(size: 19, weight: FontWeight.w600, color: c.text, letterSpacing: -0.2)),
          const SizedBox(height: 6),
          Text('It encrypts everything on this device. Make it strong and memorable.',
              style: RelicTheme.sans(size: 13, color: c.textMuted, height: 1.5)),
          const SizedBox(height: 18),
          _fieldLabel(c, 'Passphrase'),
          _passField(c, focused: true),
          const SizedBox(height: 16),
          _fieldLabel(c, 'Confirm passphrase'),
          _passField(c),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            decoration: BoxDecoration(
                color: c.secretBg,
                borderRadius: BorderRadius.circular(Radii.tile),
                border: Border.all(color: c.secret.withValues(alpha: 0.3))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(LucideIcons.shieldAlert, size: 16, color: c.secret),
              const SizedBox(width: 10),
              Expanded(
                child: Text('If this passphrase is lost, your data can’t be recovered, by design. Relic never sees it.',
                    style: RelicTheme.sans(size: 12, color: c.secretBright, height: 1.5)),
              ),
            ]),
          ),
          const SizedBox(height: 18),
          _amberButton(c, 'Create key'),
        ]),
      );

  Widget _existing(RelicColors c) => Container(
        height: 480,
        decoration: _frame(c),
        padding: const EdgeInsets.fromLTRB(30, 32, 30, 32),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          _wordmark(c),
          const SizedBox(height: 18),
          Text('Enter your encryption passphrase',
              style: RelicTheme.sans(size: 19, weight: FontWeight.w600, color: c.text, letterSpacing: -0.2)),
          const SizedBox(height: 6),
          Text('Unlock your vault on this device. It’s decrypted locally, never on our servers.',
              style: RelicTheme.sans(size: 13, color: c.textMuted, height: 1.5)),
          const SizedBox(height: 18),
          _fieldLabel(c, 'Passphrase'),
          _passField(c, focused: true, leading: LucideIcons.keyRound),
          const SizedBox(height: 18),
          _amberButton(c, 'Unlock'),
        ]),
      );

  Widget _error(RelicColors c) => Container(
        height: 480,
        decoration: _frame(c),
        padding: const EdgeInsets.all(36),
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 68, height: 68,
            decoration: BoxDecoration(color: c.warningBg, borderRadius: BorderRadius.circular(17), border: Border.all(color: c.warning.withValues(alpha: 0.3))),
            alignment: Alignment.center,
            child: Icon(LucideIcons.cloudOff, size: 30, color: c.warning),
          ),
          const SizedBox(height: 18),
          Text('Can’t reach Relic right now', style: RelicTheme.sans(size: 16, weight: FontWeight.w600, color: c.text)),
          const SizedBox(height: 6),
          SizedBox(width: 300, child: Text('Check your connection. Your captures are safe and stored locally in the meantime.', textAlign: TextAlign.center, style: RelicTheme.sans(size: 12.5, color: c.textMuted, height: 1.5))),
          const SizedBox(height: 18),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(Radii.input), border: Border.all(color: c.borderStrong)),
              child: Text('Retry', style: RelicTheme.sans(size: 13, weight: FontWeight.w500, color: c.text)),
            ),
            const SizedBox(width: 10),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), child: Text('Work offline', style: RelicTheme.sans(size: 13, color: c.textMuted))),
          ]),
        ]),
      );

  Widget _fieldLabel(RelicColors c, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Text(t.toUpperCase(), style: RelicTheme.mono(size: 10, color: c.textMuted, letterSpacing: 0.8)),
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
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
            child: Row(children: [
              _wordmark(c, gem: 15, text: 11),
              const Spacer(),
              Icon(LucideIcons.lock, size: 14, color: c.secret),
            ]),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(color: c.secretBg, borderRadius: BorderRadius.circular(18), border: Border.all(color: c.secret.withValues(alpha: 0.35))),
                  alignment: Alignment.center,
                  child: Icon(LucideIcons.lock, size: 30, color: c.secret),
                ),
                const SizedBox(height: 18),
                Text('Relic is locked', style: RelicTheme.sans(size: 17, weight: FontWeight.w600, color: c.text)),
                const SizedBox(height: 6),
                Text('Enter your passphrase to continue.', style: RelicTheme.sans(size: 12.5, color: c.textMuted)),
                const SizedBox(height: 18),
                _LockField(error: error),
                if (error) ...[
                  const SizedBox(height: 10),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(LucideIcons.circleX, size: 13, color: c.dangerText),
                    const SizedBox(width: 7),
                    Text('Incorrect passphrase. Try again.', style: RelicTheme.sans(size: 12, color: c.dangerText)),
                  ]),
                ],
                const SizedBox(height: 16),
                _amberButton(c, 'Unlock'),
              ]),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(color: c.footer, border: Border(top: BorderSide(color: c.border))),
            alignment: Alignment.center,
            child: Text('On-screen content stays hidden while locked', style: RelicTheme.mono(size: 10, color: c.textFaintest)),
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
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.input),
        border: Border.all(color: error ? c.danger : c.accent, width: 1.5),
        boxShadow: error ? null : [BoxShadow(color: c.accent.withValues(alpha: 0.18), spreadRadius: 3)],
      ),
      child: Row(children: [
        Icon(LucideIcons.keyRound, size: 15, color: c.textMuted),
        const SizedBox(width: 9),
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
          Container(height: 3, color: c.accent),
          Padding(
            padding: const EdgeInsets.fromLTRB(38, 34, 38, 34),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Container(
                  width: 60, height: 60,
                  decoration: BoxDecoration(color: c.warningBg, borderRadius: BorderRadius.circular(16), border: Border.all(color: c.accent.withValues(alpha: 0.4)), boxShadow: [BoxShadow(color: c.accent.withValues(alpha: 0.1), spreadRadius: 5)]),
                  alignment: Alignment.center,
                  child: Icon(LucideIcons.keyRound, size: 28, color: c.accent),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('Save your recovery key', style: RelicTheme.sans(size: 22, weight: FontWeight.w600, color: c.text, letterSpacing: -0.2)),
                    const SizedBox(height: 4),
                    Text('SHOWN ONCE · RELIC KEEPS NO COPY', style: RelicTheme.mono(size: 11, color: c.accentMuted, letterSpacing: 0.4)),
                  ]),
                ),
              ]),
              const SizedBox(height: 20),
              Text.rich(TextSpan(style: RelicTheme.sans(size: 13.5, color: c.textSecondary, height: 1.6), children: [
                const TextSpan(text: 'This is the '),
                TextSpan(text: 'only', style: RelicTheme.sans(size: 13.5, weight: FontWeight.w500, color: c.text)),
                const TextSpan(text: ' way back into your vault if you forget your passphrase. Write it down or store it in a password manager, somewhere offline and safe.'),
              ])),
              const SizedBox(height: 20),
              _keyBlock(c),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () => setState(() => _saved = !_saved),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Row(children: [
                    Container(
                      width: 22, height: 22,
                      decoration: BoxDecoration(
                        color: _saved ? c.accent : c.surface,
                        borderRadius: BorderRadius.circular(Radii.chip),
                        border: _saved ? null : Border.all(color: c.borderStrong, width: 1.5),
                      ),
                      alignment: Alignment.center,
                      child: _saved ? Icon(LucideIcons.check, size: 15, color: c.onAccent) : null,
                    ),
                    const SizedBox(width: 11),
                    Text('I’ve saved this somewhere safe.', style: RelicTheme.sans(size: 13.5, color: _saved ? c.text : c.textMuted)),
                  ]),
                ),
              ),
              const SizedBox(height: 20),
              _amberButton(c, 'Continue', enabled: _saved),
              const SizedBox(height: 10),
              Center(child: Text('Continue stays disabled until the box is ticked.', style: RelicTheme.mono(size: 10, color: c.textFaintest))),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _keyBlock(RelicColors c) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        decoration: BoxDecoration(
          color: c.inset,
          borderRadius: BorderRadius.circular(Radii.row),
          border: Border.all(color: c.isDark ? c.selected : c.border),
        ),
        child: Stack(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('RECOVERY KEY', style: RelicTheme.mono(size: 10, color: c.textFaintest, letterSpacing: 1)),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: SelectableTextProxy(widget.key_, style: RelicTheme.mono(size: 15, color: c.accentBright, height: 1.9, letterSpacing: 0.8)),
            ),
          ]),
          Positioned(
            top: 0, right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(7), border: Border.all(color: c.borderStrong)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(LucideIcons.copy, size: 13, color: c.accent),
                const SizedBox(width: 6),
                Text('Copy', style: RelicTheme.mono(size: 11, color: c.accent)),
              ]),
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
