import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/help_urls.dart';
import '../theme/relic_theme.dart';
import 'controls.dart';

/// Open the help page for [key] in the system browser.
Future<bool> openHelp(String key) async {
  try {
    return await launchUrl(Uri.parse(helpUrl(key)),
        mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// A quiet text link to one help page: the deep gold of the About links,
/// underlined on hover, never a button. Sits beside a title or under a row.
class LearnMore extends StatelessWidget {
  final String helpKey;
  final String label;
  final double size;
  const LearnMore(this.helpKey,
      {super.key, this.label = 'Learn more', this.size = 11.5});

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Hoverable(
      onTap: () => openHelp(helpKey),
      builder: (context, hovered) => Text(
        label,
        style: RelicTheme.sans(
          size: size,
          weight: FontWeight.w500,
          color: c.accentMuted,
        ).copyWith(
          decoration: hovered ? TextDecoration.underline : null,
          decorationColor: c.accentMuted,
        ),
      ),
    );
  }
}
