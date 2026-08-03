import 'dart:math';

import 'package:flutter/material.dart';

import '../data/passphrase_strength.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';

// Colors come from the active RelicColors (read via RelicTheme.of in build and
// threaded to helpers), so this widget renders on-palette in both light and dark
// wherever it drops in (onboarding, desktop_onboarding, add_device / security).
Color _bandColor(RelicColors c, PassphraseBand b) => switch (b) {
      PassphraseBand.weak => c.dangerText,
      PassphraseBand.okay => c.accent,
      PassphraseBand.strong => c.successDim,
      PassphraseBand.excellent => c.success,
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
          style: TextStyle(color: c.text),
          decoration: InputDecoration(
            hintText: widget.hint,
            hintStyle: TextStyle(color: c.textMuted),
            filled: true,
            fillColor: c.surface,
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility,
                  color: c.textMuted, size: 20),
              tooltip: _obscure ? 'Show' : 'Hide',
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.input),
                borderSide: BorderSide(color: c.borderStrong)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.input),
                borderSide: BorderSide(color: c.accent)),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (text.isNotEmpty) Expanded(child: _meter(c, strength)),
            if (text.isNotEmpty) const SizedBox(width: 12),
            if (text.isEmpty) const Spacer(),
            TextButton.icon(
              onPressed: _suggest,
              style: TextButton.styleFrom(
                  foregroundColor: c.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              icon: const Icon(Icons.autorenew, size: 16),
              label: const Text('Suggest a passphrase',
                  style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
        if (text.isNotEmpty && strength.needsNudge) ...[
          const SizedBox(height: 6),
          Text(
            'Short passphrases are the weakest link in your vault. Try the suggestion.',
            style: TextStyle(color: c.textMuted, fontSize: 12, height: 1.35),
          ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _meter(RelicColors c, PassphraseStrength s) {
    final color = _bandColor(c, s.band);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Stack(children: [
            Container(height: 5, color: c.track),
            FractionallySizedBox(
              widthFactor: s.fraction == 0 ? 0.04 : s.fraction,
              child: Container(height: 5, color: color),
            ),
          ]),
        ),
        const SizedBox(height: 4),
        Text(s.label,
            style: TextStyle(
                color: color, fontSize: 11.5, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
