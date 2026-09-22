import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/controls.dart';

/// The one-time Voice opt-in, shown as a modal over the popup the first time
/// the window opens on a build that ships the Voice worker. One click turns
/// Voice on and starts the model download; "Not now" leaves it off. Either
/// answer is remembered, so the card never comes back. Voice settings keeps
/// the switch for later.
class VoiceOffer extends StatelessWidget {
  final bool dark;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const VoiceOffer({
    super.key,
    required this.dark,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final c = dark ? RelicColors.dark : RelicColors.light;
    // Same scrim strength as the coach marks: parchment is too light to dim
    // with a thin veil.
    return Material(
      color: c.shadowStrong.withValues(alpha: c.isDark ? 0.74 : 0.58),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(Insets.xl),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: c.surfaceRaised,
                borderRadius: BorderRadius.circular(Radii.card),
                border: Border.all(color: c.border, width: 1),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.xl,
                  Insets.xl,
                  Insets.xl,
                  Insets.lg,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(LucideIcons.mic, color: c.accent, size: 18),
                        const SizedBox(width: Insets.sm),
                        Expanded(
                          child: Text(
                            'Relic can take dictation now',
                            style: RelicTheme.headline(size: 17, color: c.text),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Insets.md),
                    Text(
                      'Hold Right Alt, speak, and let go. The words land in '
                      'whatever you were typing into, and a copy is kept in '
                      'Relic. Hold Left Ctrl too and it saves a voice note '
                      'to your vault instead.',
                      style: RelicTheme.sans(
                        size: 13,
                        color: c.text,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: Insets.sm),
                    Text(
                      'Speech is recognized on this PC and never sent '
                      'anywhere. Turning it on downloads about 716 MB of '
                      'models once. The microphone only opens while you '
                      'hold the key. You can turn it off any time in Settings.',
                      style: RelicTheme.sans(
                        size: 12.5,
                        color: c.textMuted,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: Insets.lg),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: Insets.sm,
                      runSpacing: Insets.sm,
                      children: [
                        GhostButton(label: 'Not now', onTap: onDecline),
                        PrimaryButton(
                          icon: LucideIcons.mic,
                          label: 'Turn on voice',
                          onTap: onAccept,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
