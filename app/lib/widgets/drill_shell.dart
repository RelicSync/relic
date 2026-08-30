import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import 'controls.dart';

/// Shared host for the settings drill-down screens (Devices, Security,
/// Recovery kit, Add device). Phones keep the pushed Scaffold+AppBar page;
/// desktop renders the same floating card frame as SettingsView so a
/// drill-down never swaps the settings card for an edge-to-edge page.
class DrillShell extends StatelessWidget {
  final String title;

  /// Trailing header controls (desktop header row / mobile AppBar actions).
  final List<Widget> actions;
  final Widget child;
  final EdgeInsetsGeometry? padding;

  /// Vertically center the body (the Add-device phase UI). Everything else is
  /// a top-aligned scroll column.
  final bool center;

  const DrillShell({
    super.key,
    required this.title,
    this.actions = const [],
    required this.child,
    this.padding,
    this.center = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return RelicTheme.isMobileOf(context)
        ? _mobile(context, c)
        : _desktop(context, c);
  }

  Widget _mobile(BuildContext context, RelicColors c) => Theme(
        data: materialThemeFor(c),
        child: Scaffold(
          backgroundColor: c.base,
          appBar: AppBar(
            backgroundColor: c.base,
            foregroundColor: c.text,
            title: Text(
              title,
              style: RelicTheme.headline(size: 17, color: c.text),
            ),
            actions: [
              for (final a in actions)
                Padding(
                  padding: const EdgeInsets.only(right: Insets.sm),
                  child: Center(child: a),
                ),
            ],
          ),
          body: SafeArea(child: _body(mobile: true)),
        ),
      );

  Widget _desktop(BuildContext context, RelicColors c) => Theme(
        // The body's TextFields and any dialogs it opens stay on-palette.
        data: materialThemeFor(c),
        child: Material(
          color: c.base,
          child: Padding(
            padding: const EdgeInsets.all(Insets.xl),
            child: Container(
              decoration: BoxDecoration(
                color: c.base,
                borderRadius: BorderRadius.circular(Radii.card),
                border: Border.all(color: c.border),
                boxShadow: Shadows.card(c),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(
                        Insets.lg, Insets.md, Insets.lg, Insets.md),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: c.border)),
                    ),
                    child: Row(
                      children: [
                        GhostIconButton(
                          icon: LucideIcons.chevronLeft,
                          size: 26,
                          iconSize: 15,
                          tooltip: 'Back',
                          onTap: () => Navigator.of(context).maybePop(),
                        ),
                        const SizedBox(width: Insets.sm),
                        Text(
                          title,
                          style: RelicTheme.headline(size: 15, color: c.text),
                        ),
                        const Spacer(),
                        ...actions,
                      ],
                    ),
                  ),
                  Expanded(child: _body(mobile: false)),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _body({required bool mobile}) {
    final pad = padding ??
        (mobile
            ? const EdgeInsets.fromLTRB(
                Insets.xl, Insets.lg, Insets.xl, Insets.xxxl)
            : const EdgeInsets.fromLTRB(
                Insets.xxl, Insets.xl, Insets.xxl, Insets.xxl));
    final constrained = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: child,
    );
    if (center) {
      // Centered look, but still scrollable when the window is short (the
      // 520x620 post-connect kit window, phone landscape).
      return Center(
        child: SingleChildScrollView(padding: pad, child: constrained),
      );
    }
    return SingleChildScrollView(
      padding: pad,
      child: Center(child: constrained),
    );
  }
}
