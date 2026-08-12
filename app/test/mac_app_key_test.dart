import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/platform/foreground_app.dart';

/// macAppKey is the single macOS source-tag/blocklist key derivation
/// (bundle id + localized name → key). Pure function, so the contract is
/// pinned here: Relic-self nulls, the friendly table wins over the name,
/// the name carries unknown apps, and the id's last component is only the
/// nameless backstop.
void main() {
  test('Relic itself never yields a key', () {
    expect(macAppKey('space.relic.mac', 'Relic'), isNull);
    expect(macAppKey('SPACE.RELIC.MAC', 'Relic'), isNull);
  });

  test('friendly-table ids beat the localized name', () {
    expect(macAppKey('com.spotify.client', 'Spotify'), 'spotify');
    expect(macAppKey('us.zoom.xos', 'zoom.us'), 'zoom');
    expect(macAppKey('notion.id', 'Notion'), 'notion');
    expect(macAppKey('com.apple.finder', 'Finder'), 'finder');
  });

  test('unknown apps fall back to the sanitized localized name', () {
    expect(macAppKey('com.culturedcode.ThingsMac', 'Things'), 'things');
    expect(macAppKey('company.thebrowser.Browser', 'Arc'), 'arc');
    expect(macAppKey('com.example.x', 'My App 2!'), 'myapp2');
  });

  test('long names truncate to 24 sanitized chars', () {
    final key = macAppKey(
        'com.example.longname', 'A Very Long Application Name Indeed');
    expect(key, hasLength(24));
    expect(key, 'averylongapplicationname');
  });

  test('nameless or unusable names backstop to the id last component', () {
    expect(macAppKey('com.example.editor', ''), 'editor');
    expect(macAppKey('com.example.editor', '™'), 'editor');
    // A single usable char is below the 2-char floor — still the backstop.
    expect(macAppKey('com.example.editor', 'X'), 'editor');
  });

  test('noise keys from the friendly table stay inside kAppKeyNoise', () {
    // The com.apple.* rows pin system processes to stable keys; the noise
    // filter depends on that pinning staying in sync.
    for (final key in ['finder', 'dock', 'loginwindow', 'screencaptureui']) {
      expect(kAppKeyNoise, contains(key));
    }
  });
}
