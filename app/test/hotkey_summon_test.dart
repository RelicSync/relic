// Which picker each summon opens.
//
// This pins two shipped bugs. First, the history hotkey used to mean "follow
// the mini picker preference", and that preference defaulted to ON, so on a
// fresh install the history hotkey and the mini hotkey both opened the compact
// picker and the full window could not be reached from the keyboard at all.
// Second, a tray click followed the same preference, so clicking the tray icon
// in the corner of the screen produced a tiny picker anchored to a text caret
// somewhere else entirely, instead of the app.
//
// The preference is gone. The source decides, and only the mini hotkey opens
// mini.
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/hotkeys.dart';

void main() {
  group('picker hotkeys', () {
    test('the two picker hotkeys never land on the same surface', () {
      // The invariant. Both surfaces stay reachable from the keyboard.
      expect(
        miniForSummon(Summon.historyHotkey),
        isNot(miniForSummon(Summon.miniHotkey)),
        reason: 'one of the two pickers has become unreachable',
      );
    });

    test('the history hotkey opens the full popup', () {
      expect(miniForSummon(Summon.historyHotkey), isFalse);
    });

    test('the mini hotkey opens mini', () {
      expect(miniForSummon(Summon.miniHotkey), isTrue);
    });
  });

  group('summons with no key of their own', () {
    test('the tray opens the whole app, never the mini picker', () {
      // A tray click is a mouse landing in the corner of the screen. The mini
      // picker anchors to the text caret, which is nowhere near it.
      expect(miniForSummon(Summon.tray), isFalse);
    });

    test('surfacing a specific item always gets the full window', () {
      // A launch, a reminder, a deep link, or the annotate editor is about to
      // show one thing in detail. The compact picker has nowhere to put it.
      for (final s in [
        Summon.launch,
        Summon.notification,
        Summon.deepLink,
        Summon.annotate,
      ]) {
        expect(miniForSummon(s), isFalse, reason: '$s should open full');
      }
    });

    test('exactly one summon opens the mini picker, and it has a key', () {
      final mini = Summon.values.where(miniForSummon).toList();
      expect(mini, [Summon.miniHotkey]);
    });
  });
}
