import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/passphrase_strength.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import 'controls.dart';

// Colors come from the active RelicColors (read via RelicTheme.of in build and
// threaded to helpers), so this widget renders on-palette in both light and dark
// wherever it drops in (onboarding, desktop_onboarding, add_device / security).

/// The meter bar's FILL for a band — gold is a fill color, so the okay band
/// takes the bright accent here.
Color _bandColor(RelicColors c, PassphraseBand b) => switch (b) {
      PassphraseBand.weak => c.dangerText,
      PassphraseBand.okay => c.accent,
      PassphraseBand.strong => c.successDim,
      PassphraseBand.excellent => c.success,
    };

/// The band's rating chip: a tint ground and a text-weight color. The label is
/// never the bar's own fill — gold as text is the deep gold on a gold tint, and
/// the other bands follow the same shape so the row reads as one control.
(Color, Color) _bandChip(RelicColors c, PassphraseBand b) => switch (b) {
      PassphraseBand.weak => (c.dangerBg, c.dangerText),
      PassphraseBand.okay => (c.tagBg, c.tagText),
      PassphraseBand.strong => (
          c.success.withValues(alpha: c.isDark ? 0.18 : 0.12),
          c.success,
        ),
      PassphraseBand.excellent => (
          c.success.withValues(alpha: c.isDark ? 0.18 : 0.12),
          c.success,
        ),
    };

/// A vault-passphrase entry field with a live strength meter and a "Suggest a
/// passphrase" affordance. Drops into the create / rotate screens; the confirm
/// field stays a plain [TextField] the host owns.
///
/// Suggesting a passphrase overwrites [controller], clears [confirmController]
/// (so the user re-confirms deliberately), and reveals the text so it can be
/// read and saved. [rng] is injectable for tests; it defaults to a CSPRNG.
class VaultPassphraseField extends StatefulWidget {
  final TextEditingController controller;
  final TextEditingController? confirmController;
  final String hint;
  final Random? rng;

  const VaultPassphraseField({
    super.key,
    required this.controller,
    this.confirmController,
    this.hint = 'Vault passphrase',
    this.rng,
  });

  @override
  State<VaultPassphraseField> createState() => _VaultPassphraseFieldState();
}

class _VaultPassphraseFieldState extends State<VaultPassphraseField> {
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _suggest() {
    widget.controller.text = suggestPassphrase(rng: widget.rng);
    widget.confirmController?.clear();
    setState(() => _obscure = false); // a suggestion is unusable while hidden
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final text = widget.controller.text;
    final strength = estimatePassphrase(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: widget.controller,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          // A passphrase is a secret, not prose: mono, like every other secret
          // value in the app.
          style: RelicTheme.mono(size: 13.5, color: c.text),
          decoration: InputDecoration(
            hintText: widget.hint,
            hintStyle: RelicTheme.sans(size: 13, color: c.textFaintest),
            filled: true,
            fillColor: c.surface,
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: Insets.sm),
              child: GhostButton(
                icon: _obscure ? LucideIcons.eye : LucideIcons.eyeOff,
                size: 28,
                iconSize: 16,
                tooltip: _obscure ? 'Show' : 'Hide',
                onTap: () => setState(() => _obscure = !_obscure),
              ),
            ),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.input),
                borderSide: BorderSide(color: c.borderStrong)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.input),
                borderSide: BorderSide(color: c.accent)),
          ),
        ),
        const SizedBox(height: Insets.md),
        Row(
          children: [
            if (text.isNotEmpty) Expanded(child: _meter(c, strength)),
            if (text.isNotEmpty) const SizedBox(width: Insets.md),
            if (text.isEmpty) const Spacer(),
            GhostButton(
              icon: LucideIcons.refreshCw,
              label: 'Suggest a passphrase',
              size: 30,
              iconSize: 14,
              onTap: _suggest,
            ),
          ],
        ),
        if (text.isNotEmpty && strength.needsNudge) ...[
          const SizedBox(height: Insets.sm),
          Text(
            'Short passphrases are the weakest link in your vault. Try the suggestion.',
            style: RelicTheme.sans(size: 12, color: c.textMuted, height: 1.35),
          ),
        ],
        const SizedBox(height: Insets.md),
      ],
    );
  }

  Widget _meter(RelicColors c, PassphraseStrength s) {
    final color = _bandColor(c, s.band);
    final (chipBg, chipFg) = _bandChip(c, s.band);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.pill),
          child: Stack(children: [
            Container(height: 6, color: c.track),
            FractionallySizedBox(
              widthFactor: s.fraction == 0 ? 0.04 : s.fraction,
              child: Container(height: 6, color: color),
            ),
          ]),
        ),
        const SizedBox(height: Insets.sm),
        // The rating rides a tint chip rather than sitting bare on the card —
        // the same chip shape the tag/meta language uses. Aligned rather than
        // stretched so the chip hugs its word.
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: chipBg,
              borderRadius: BorderRadius.circular(Radii.tag),
            ),
            child: Text(
              s.label,
              style: RelicTheme.mono(
                size: 10,
                weight: FontWeight.w600,
                color: chipFg,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
