import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/data/help_urls.dart';

/// Every key the desktop app links to must resolve, and every page must live
/// under relic.space/help. A dead "Learn more" is worse than none.
void main() {
  const wired = [
    'settings.general',
    'settings.capture',
    'settings.searchAi',
    'settings.vault',
    'settings.sync',
    'settings.about',
    'hotkey.change',
    'hotkey.registerFailed',
    'tray.menu',
    'tray.pause',
    'sync.addDevice',
    'sync.notSynced',
    'linux.wayland',
    'backup.setup',
    'privacy.recoveryKit',
    'onboarding.recoveryKit',
    'fix.lostPassphrase',
    'help.shortcuts',
    'help.faq',
    'help.popup',
  ];

  test('every wired key resolves to a help page', () {
    for (final k in wired) {
      expect(helpUrl(k), startsWith('$helpBase/'), reason: k);
    }
  });

  test('every url is https, under /help, and has no spaces', () {
    for (final e in helpUrls.entries) {
      expect(e.value, startsWith('https://relic.space/help/'), reason: e.key);
      expect(e.value.contains(' '), isFalse, reason: e.key);
    }
  });

  test('an unknown key throws instead of returning a dead link', () {
    expect(() => helpUrl('nope.nothing'), throwsArgumentError);
  });
}
