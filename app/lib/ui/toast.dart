import 'dart:async';
import 'package:flutter/widgets.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/controls.dart';

enum ToastSeverity { success, accent, neutral, warning, danger }

class ToastMsg {
  final String text;
  final ToastSeverity severity;
  final IconData icon;
  /// Optional custom leading glyph (e.g. the Relic gem) drawn instead of [icon].
  final Widget Function(double size, Color color)? iconBuilder;
  final String? action;

  /// Invoked when the action label is tapped (e.g. "Undo"). The toast is
  /// dismissed first, then this runs.
  final VoidCallback? onAction;

  /// How long the toast stays up. Actionable toasts get a longer window so
  /// there's time to tap (e.g. Undo).
  final Duration duration;
  ToastMsg(
    this.text, {
    required this.severity,
    required this.icon,
    this.iconBuilder,
    this.action,
    this.onAction,
    Duration? duration,
  }) : duration = duration ?? const Duration(milliseconds: 2400);
}

/// Holds at most a couple of recent toasts and auto-expires them.
class ToastQueue extends ChangeNotifier {
  final List<ToastMsg> _items = [];
  List<ToastMsg> get items => List.unmodifiable(_items);

  void show(ToastMsg m) {
    _items.add(m);
    notifyListeners();
    Timer(m.duration, () {
      if (_items.remove(m)) notifyListeners();
    });
  }

  /// Dismiss a toast early (e.g. after its action is tapped).
  void dismiss(ToastMsg m) {
    if (_items.remove(m)) notifyListeners();
  }
}

class ToastStack extends StatelessWidget {
  final ToastQueue queue;
  const ToastStack({super.key, required this.queue});

  @override
  Widget build(BuildContext context) {
    if (queue.items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in queue.items)
            _Toast(m, onAction: () {
              queue.dismiss(m);
              m.onAction?.call();
            }),
        ],
      ),
    );
  }
}

class _Toast extends StatelessWidget {
  final ToastMsg m;
  final VoidCallback onAction;
  const _Toast(this.m, {required this.onAction});

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final (Color bar, Color icon, Color bg, Color border, Color text) = switch (m.severity) {
      ToastSeverity.success => (c.success, c.success, c.surfaceRaised, c.border, c.text),
      ToastSeverity.accent => (c.accent, c.accent, c.surfaceRaised, c.border, c.text),
      ToastSeverity.neutral => (c.textFaintest, c.textSecondary, c.surfaceRaised, c.border, c.text),
      ToastSeverity.warning => (c.warning, c.warning, c.warningBg, c.warning.withValues(alpha: 0.25), c.text),
      ToastSeverity.danger => (c.danger, c.dangerText, c.dangerBg, c.danger.withValues(alpha: 0.3), c.text),
    };
    // A uniform border + rounded corners (Flutter forbids borderRadius on a
    // border with non-uniform side colors/widths). The accent bar is drawn as a
    // separate left strip, clipped to the rounded corners.
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.input),
        border: Border.all(color: border, width: 1),
        boxShadow: [
          BoxShadow(color: c.shadowModal, blurRadius: 28, spreadRadius: -14, offset: const Offset(0, 12)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.input),
        // IntrinsicHeight bounds the row's height so the full-height accent bar
        // (CrossAxisAlignment.stretch) lays out — without it, the toast sits in
        // an unbounded-height Positioned and fails to render (invisible).
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: bar), // accent bar, full height
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                child: Row(children: [
                  m.iconBuilder?.call(16, icon) ??
                      Icon(m.icon, size: 16, color: icon),
                  const SizedBox(width: 10),
                  Expanded(child: Text(m.text, style: RelicTheme.sans(size: 13, color: text))),
                  if (m.action != null) ...[
                    const SizedBox(width: 10),
                    Hoverable(
                      onTap: m.onAction == null ? null : onAction,
                      builder: (context, hovered) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(Radii.chip),
                          // De-boxed: no border. The mono w600 accent label reads
                          // as a keycap-like action; hover gets a faint accent tint.
                          color: hovered ? c.accent.withValues(alpha: 0.12) : const Color(0x00000000),
                        ),
                        child: Text(m.action!,
                            style: RelicTheme.mono(size: 11, weight: FontWeight.w600, color: c.accent)),
                      ),
                    ),
                  ],
                ]),
              ),
            ),
            ],
          ),
        ),
      ),
    );
  }
}
