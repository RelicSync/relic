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
            title: Text(title),
            actions: [
              for (final a in actions)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
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
            padding: const EdgeInsets.all(20),
            child: Container(
              decoration: BoxDecoration(
                color: c.base,
                borderRadius: BorderRadius.circular(Radii.popup),
                border: Border.all(color: c.border),
                boxShadow: [
                  BoxShadow(
                    color: c.shadowStrong,
                    blurRadius: 80,
                    spreadRadius: -24,
                    offset: const Offset(0, 40),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
                        const SizedBox(width: 9),
                        Text(
                          title,
                          style: RelicTheme.sans(
                            size: 13.5,
                            weight: FontWeight.w500,
                            color: c.text,
                          ),
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
            ? const EdgeInsets.fromLTRB(20, 12, 20, 24)
            : const EdgeInsets.fromLTRB(24, 16, 24, 24));
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
