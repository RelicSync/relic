import 'dart:io';

import 'package:image/image.dart' as img;

/// One-shot generator for assets/tray_icon_template.png — the macOS menu-bar
/// "template" variant of the Windows tray icon: pure black with the source's
/// alpha, so the menu bar can tint it for light/dark. Run from app/:
///
///   dart run tool/make_tray_template.dart
void main() {
  final bytes = File('assets/tray_icon.ico').readAsBytesSync();
  final src = img.decodeIco(bytes);
  if (src == null) {
    stderr.writeln('could not decode assets/tray_icon.ico');
    exit(1);
  }
  final scaled = img.copyResize(
    src,
    width: 44,
    height: 44,
    interpolation: img.Interpolation.cubic,
  );
  final out = img.Image(width: 44, height: 44, numChannels: 4);
  for (final p in scaled) {
    out.setPixelRgba(p.x, p.y, 0, 0, 0, p.a.toInt());
  }
  File('assets/tray_icon_template.png')
      .writeAsBytesSync(img.encodePng(out));
  stdout.writeln('wrote assets/tray_icon_template.png (44x44 template)');
}
