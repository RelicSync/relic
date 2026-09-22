import 'package:flutter/widgets.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import 'controls.dart';

/// The same divider and spacing as the main Settings pane.
class SettingsRow extends StatelessWidget {
  const SettingsRow({super.key, required this.child, this.last = false});
  final Widget child;
  final bool last;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: Insets.lg),
    decoration: BoxDecoration(
      border: last
          ? null
          : Border(bottom: BorderSide(color: RelicTheme.of(context).border)),
    ),
    child: child,
  );
}

class SettingsToggleRow extends StatelessWidget {
  const SettingsToggleRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.sub,
    this.last = false,
    this.recommended = false,
    this.leading,
    this.leadingTx = false,
  });
  final String title;
  final bool value, last, recommended, leadingTx;
  final ValueChanged<bool>? onChanged;
  final String? sub;
  final IconData? leading;
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return SettingsRow(
      last: last,
      child: Row(
        children: [
          if (leadingTx) ...[
            Text(
              'Aa',
              style: RelicTheme.mono(
                size: 14,
                weight: FontWeight.w700,
                color: c.textSecondary,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(width: 10),
          ] else if (leading != null) ...[
            Icon(leading, size: 17, color: c.textSecondary),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: RelicTheme.sans(size: 13, color: c.text),
                      ),
                    ),
                    if (recommended) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Insets.sm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: c.tagBg,
                          borderRadius: BorderRadius.circular(Radii.tag),
                        ),
                        child: Text(
                          'recommended',
                          style: RelicTheme.mono(size: 9.5, color: c.tagText),
                        ),
                      ),
                    ],
                  ],
                ),
                if (sub != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    sub!,
                    style: RelicTheme.sans(size: 11.5, color: c.textMuted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          SettingsToggle(
            on: value,
            onTap: onChanged == null ? null : () => onChanged!(!value),
          ),
        ],
      ),
    );
  }
}
