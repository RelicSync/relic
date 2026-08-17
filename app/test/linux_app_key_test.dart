import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/platform/foreground_app.dart';

/// linuxAppKey is pure (WM_CLASS strings in, key out), so the whole Linux
/// attribution derivation pins down from any host — the mac_app_key pattern.
void main() {
  test('plain WM_CLASS stems normalize and map to friendly keys', () {
    expect(linuxAppKey('Google-chrome', 'google-chrome'), 'chrome');
    expect(linuxAppKey('firefox', 'Navigator'), 'firefox');
    expect(linuxAppKey('Code', 'code'), 'vscode');
    expect(linuxAppKey('Signal', 'signal'), 'signal');
    expect(linuxAppKey('jetbrains-pycharm-ce', ''), 'pycharm');
  });

  test('reverse-DNS ids collapse to their last segment', () {
    expect(linuxAppKey('org.gnome.Nautilus', 'org.gnome.Nautilus'), 'nautilus');
    expect(linuxAppKey('org.kde.dolphin', 'dolphin'), 'dolphin');
    expect(linuxAppKey('org.gnome.Ptyxis', ''), 'terminal');
    expect(linuxAppKey('org.wezfurlong.wezterm', ''), 'terminal');
  });

  test('every terminal lands on the shared terminal key (SIGINT guard)', () {
    for (final klass in [
      'Gnome-terminal', 'gnome-terminal-server', 'konsole', 'Alacritty',
      'kitty', 'XTerm', 'tilix', 'terminator', 'xfce4-terminal', 'foot',
    ]) {
      expect(linuxAppKey(klass, ''), 'terminal', reason: klass);
    }
  });

  test('the instance is the fallback when the class is empty', () {
    expect(linuxAppKey('', 'Navigator'), 'firefox');
    expect(linuxAppKey('', 'xterm'), 'terminal');
  });

  test('Relic itself never becomes a key', () {
    expect(linuxAppKey('Relic_app', 'relic_app'), isNull);
    expect(linuxAppKey('space.relic.app', 'relic_app'), isNull);
    expect(linuxAppKey('relic', ''), isNull);
  });

  test('degenerate input is rejected, long keys truncate', () {
    expect(linuxAppKey('', ''), isNull);
    expect(linuxAppKey('@', '!'), isNull);
    expect(linuxAppKey('x', ''), isNull, reason: 'one char is noise');
    final long = linuxAppKey('a' * 40, '');
    expect(long, isNotNull);
    expect(long!.length, 24);
  });

  test('file managers and shells derive to keys the noise set drops', () {
    for (final klass in [
      'org.gnome.Nautilus', 'org.kde.dolphin', 'Thunar', 'nemo',
      'Gnome-shell', 'plasmashell',
    ]) {
      final key = linuxAppKey(klass, '');
      expect(key, isNotNull, reason: klass);
      expect(kAppKeyNoise.contains(key), isTrue, reason: klass);
      expect(foregroundAppTagFrom(key), isNull, reason: klass);
    }
  });

  test('normal keys survive tag derivation unchanged', () {
    expect(foregroundAppTagFrom(linuxAppKey('Google-chrome', '')), 'chrome');
    expect(foregroundAppTagFrom(linuxAppKey('org.kde.kate', '')), 'kate');
  });
}
