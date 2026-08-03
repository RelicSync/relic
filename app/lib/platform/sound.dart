import 'dart:io' show Platform;

import 'src/macos/sound_macos.dart' as mac;
import 'src/windows/input_win.dart' as win;

/// The promotion chime. Windows plays the bundled wav via PlaySound; macOS
/// resolves the same Flutter asset inside the app bundle and plays it with
/// NSSound. Best-effort everywhere, no fallback beep.

const _promotionAsset = 'assets/sounds/relic-sound.wav';

Future<bool> playPromotionSound() async {
  if (Platform.isWindows) return win.playPromotionSound();
  if (Platform.isMacOS) return mac.playAsset(_promotionAsset);
  return false;
}
