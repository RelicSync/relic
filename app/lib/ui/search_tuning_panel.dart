import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/search_tuning.dart';
import '../theme/relic_theme.dart';

/// The dev-only search tuning strip docked under the popup (Ctrl+Shift+F9
/// when the app runs with `RELIC_SEARCH_TUNING=1`). Each slider starts at the
/// shipped value; moving one re-ranks the current search straight away.
class SearchTuningPanel extends StatelessWidget {
  const SearchTuningPanel({
    super.key,
    required this.tuning,
    required this.shipped,
    required this.model,
    required this.onClose,
  });

  final SearchTuning tuning;
  final Map<String, double> Function() shipped;
  final String? model;
  final VoidCallback onClose;

  static const double height = 248;

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return ListenableBuilder(
      listenable: tuning,
      builder: (context, _) {
        final base = shipped();
        double now(String k) => tuning.value(k, base[k] ?? 0);
        return Container(
          height: height,
          decoration: BoxDecoration(
            color: c.footer,
            border: Border(top: BorderSide(color: c.borderStrong)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('Search tuning',
                      style: TextStyle(
                          color: c.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(model ?? 'no vectors yet',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textFaint, fontSize: 11)),
                  ),
                  _Btn('Copy values', () {
                    final out = {
                      'model': model,
                      for (final k in SearchTuning.knobs)
                        k.key: double.parse(now(k.key).toStringAsFixed(3)),
                      'changed': tuning.overrides.keys.toList(),
                    };
                    Clipboard.setData(ClipboardData(
                        text: const JsonEncoder.withIndent('  ').convert(out)));
                  }),
                  _Btn('Reset all', () => tuning.reset()),
                  _Btn('Close', onClose),
                ],
              ),
              const SizedBox(height: 2),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final w = (box.maxWidth - 12) / 2;
                    return SingleChildScrollView(
                      child: Wrap(
                        spacing: 12,
                        children: [
                          for (final k in SearchTuning.knobs)
                            SizedBox(
                              width: w,
                              child: _KnobRow(
                                knob: k,
                                value: now(k.key),
                                shipped: base[k.key] ?? 0,
                                changed: tuning.isOverridden(k.key),
                                onChanged: (v) => tuning.set(k.key, v),
                                onReset: () => tuning.reset(k.key),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _KnobRow extends StatelessWidget {
  const _KnobRow({
    required this.knob,
    required this.value,
    required this.shipped,
    required this.changed,
    required this.onChanged,
    required this.onReset,
  });

  final TuningKnob knob;
  final double value;
  final double shipped;
  final bool changed;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;

  String _fmt(double v) =>
      knob.step >= 1 ? v.round().toString() : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final divisions = ((knob.max - knob.min) / knob.step).round();
    return Tooltip(
      message: '${knob.help}\nShipped: ${_fmt(shipped)}',
      waitDuration: const Duration(milliseconds: 600),
      child: SizedBox(
        height: 30,
        child: Row(
          children: [
            SizedBox(
              width: 92,
              child: Text(knob.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: changed ? c.accentDeep : c.textSecondary,
                      fontSize: 11,
                      fontWeight: changed ? FontWeight.w600 : FontWeight.w400)),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                ),
                child: Slider(
                  value: value.clamp(knob.min, knob.max),
                  min: knob.min,
                  max: knob.max,
                  divisions: divisions,
                  activeColor: c.accent,
                  inactiveColor: c.border,
                  onChanged: onChanged,
                ),
              ),
            ),
            GestureDetector(
              onDoubleTap: onReset,
              child: SizedBox(
                width: 36,
                child: Text(_fmt(value),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        color: changed ? c.accentDeep : c.textMuted,
                        fontSize: 11,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn(this.label, this.onTap);

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 24),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        foregroundColor: c.textSecondary,
        textStyle: const TextStyle(fontSize: 11),
      ),
      child: Text(label),
    );
  }
}
