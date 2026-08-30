import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../data/supabase_auth.dart';
import 'relic_mark.dart';

/// The full Relic logo: the gold shard + the "Relic" wordmark, matching the
/// site nav. The lockup is proportional to the mark — the wordmark is set at
/// the mark's own height in Stack Sans Headline *regular*, tracked −2%, one
/// third of a mark-height away. Use this on brand surfaces instead of a giant
/// bare icon.
class RelicWordmark extends StatelessWidget {
  /// Height of the mark, and the wordmark's font size.
  final double markSize;
  final Color color;
  const RelicWordmark({
    super.key,
    this.markSize = 26,
    this.color = const Color(0xFF111110),
  });

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RelicIcon(size: markSize),
          SizedBox(width: markSize * 0.33),
          Text(
            'Relic',
            style: TextStyle(
              fontFamily: 'StackSansHeadline',
              fontWeight: FontWeight.w400,
              fontSize: markSize,
              letterSpacing: markSize * -0.02,
              height: 1,
              color: color,
            ),
          ),
        ],
      );
}

/// A real, branded "Continue with ..." button (official Google/GitHub/Apple
/// marks + each brand's own button styling). Full-width, 50px.
class OAuthButton extends StatelessWidget {
  final SupabaseProvider provider;
  final VoidCallback? onPressed;
  const OAuthButton({super.key, required this.provider, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, String asset, String label, Color border) =
        switch (provider) {
      SupabaseProvider.google => (
          const Color(0xFFFFFFFF),
          const Color(0xFF1F1F1F),
          'assets/brand/google.svg',
          'Continue with Google',
          const Color(0x1F000000),
        ),
      SupabaseProvider.github => (
          const Color(0xFF24292F),
          Colors.white,
          'assets/brand/github.svg',
          'Continue with GitHub',
          const Color(0x33FFFFFF),
        ),
      SupabaseProvider.apple => (
          Colors.black,
          Colors.white,
          'assets/brand/apple.svg',
          'Continue with Apple',
          const Color(0x33FFFFFF),
        ),
    };
    return SizedBox(
      height: 50,
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          disabledBackgroundColor: bg.withValues(alpha: 0.45),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: border),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset(asset, width: 20, height: 20),
            const SizedBox(width: 12),
            Text(label,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          ],
        ),
      ),
    );
  }
}
