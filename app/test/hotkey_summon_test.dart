// Which picker each summon opens.
//
// This pins a shipped bug. The history hotkey used to mean "follow the mini
// picker preference", and that preference defaults to ON, so on a fresh install
// the history hotkey and the mini hotkey both opened the compact picker and the
// full window could not be reached from the keyboard at all. It looked
// machine-specific — it was really just whichever machine had the preference
// turned off.
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/hotkeys.dart';

void main() {
  group('picker hotkeys', () {
    test('the two picker hotkeys never land on the same surface', () {
      // The invariant. Whatever the preference is, both pickers stay reachable.
      for (final pref in [true, false]) {
        expect(
          miniForSummon(Summon.historyHotkey, miniByDefault: pref),
          isNot(miniForSummon(Summon.miniHotkey, miniByDefault: pref)),
          reason: 'with "mini by default" = $pref, one picker is unreachable',
        );
      }
    });

    test('the history hotkey opens the full popup, including by default', () {
      expect(miniForSummon(Summon.historyHotkey, miniByDefault: true), isFalse);
      expect(miniForSummon(Summon.historyHotkey, miniByDefault: false), isFalse);
    });

    test('the mini hotkey opens mini regardless of the preference', () {
      expect(miniForSummon(Summon.miniHotkey, miniByDefault: false), isTrue);
      expect(miniForSummon(Summon.miniHotkey, miniByDefault: true), isTrue);
    });
  });

  group('summons with no key of their own', () {
    test('tray and launch follow the preference', () {
      // Which is what the Settings copy has always said they do.
      for (final s in [Summon.tray, Summon.launch]) {
        expect(miniForSummon(s, miniByDefault: true), isTrue);
        expect(miniForSummon(s, miniByDefault: false), isFalse);
      }
    });

    test('surfacing a specific item always gets the full window', () {
      // A reminder, a deep link, or the annotate editor is about to show one
      // thing in detail. The compact picker has nowhere to put it.
      for (final s in [Summon.notification, Summon.deepLink, Summon.annotate]) {
        expect(miniForSummon(s, miniByDefault: true), isFalse);
      }
    });
  });
}
