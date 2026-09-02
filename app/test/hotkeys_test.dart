import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:relic_app/data/hotkeys.dart';

void main() {
  test('quick-paste defaults are Ctrl+Shift+1..5', () {
    final qp = HotkeyBinding.defaultQuickPaste;
    expect(qp.length, 5);
    // HID usage page 0x07: '1'=0x1E … '5'=0x22.
    const usages = [0x0007001E, 0x0007001F, 0x00070020, 0x00070021, 0x00070022];
    for (var i = 0; i < qp.length; i++) {
      final b = qp[i];
      expect(b.ctrl, isTrue);
      expect(b.shift, isTrue);
      expect(b.alt, isFalse);
      expect(b.win, isFalse);
      expect(b.label, '${i + 1}');
      expect(b.usbUsage, usages[i]);
      expect(b.display, 'Ctrl + Shift + ${i + 1}');
    }
  });

  test('mini picker default is Ctrl+Shift+Space', () {
    final m = HotkeyBinding.defaultMini;
    expect(m.ctrl, isTrue);
    expect(m.shift, isTrue);
    expect(m.alt, isFalse);
    expect(m.win, isFalse);
    expect(m.usbUsage, 0x0007002C); // Spacebar
    expect(m.display, 'Ctrl + Shift + Space');
  });

  test('all default chords are distinct (incl. quick-paste + paste stack)', () {
    final chords = [
      HotkeyBinding.defaultHistory,
      HotkeyBinding.defaultCapture,
      HotkeyBinding.defaultPromote,
      HotkeyBinding.defaultMini,
      ...HotkeyBinding.defaultQuickPaste,
      HotkeyBinding.defaultStackPush,
      HotkeyBinding.defaultStackPop,
    ];
    for (var i = 0; i < chords.length; i++) {
      for (var j = i + 1; j < chords.length; j++) {
        expect(chords[i].sameChordAs(chords[j]), isFalse,
            reason: 'default hotkeys $i and $j collide');
      }
    }
  });

  test('a quick-paste binding round-trips through JSON', () {
    final orig = HotkeyBinding.defaultQuickPaste[2]; // Ctrl+Shift+3
    final back = HotkeyBinding.fromJson(orig.toJson());
    expect(back, isNotNull);
    expect(back!.sameChordAs(orig), isTrue);
    expect(back.label, '3');
  });

  // --- macOS contract. The defaults are the same chords on both platforms and
  // that is a decision, not an oversight: [ctrl] registers the PHYSICAL Control
  // key on macOS, so the history key is ⌃⇧Q and never ⌘⇧Q (Log Out).

  group('macOS mapping', () {
    final defaults = <HotkeyBinding>[
      HotkeyBinding.defaultHistory,
      HotkeyBinding.defaultPromote,
      HotkeyBinding.defaultCapture,
      HotkeyBinding.defaultMini,
      ...HotkeyBinding.defaultQuickPaste,
    ];

    test('every default is Ctrl+Shift, never Meta', () {
      for (final b in defaults) {
        expect(b.ctrl, isTrue, reason: '${b.display} lost Ctrl');
        expect(b.shift, isTrue, reason: '${b.display} lost Shift');
        expect(b.win, isFalse, reason: '${b.display} would be ⌘ on macOS');
      }
      // Q/W/E — the row the whole default set is named after.
      expect(HotkeyBinding.defaultHistory.usbUsage, 0x00070014); // Q
      expect(HotkeyBinding.defaultPromote.usbUsage, 0x0007001A); // W
      expect(HotkeyBinding.defaultCapture.usbUsage, 0x00070008); // E
    });

    test('registration asks hotkey_manager for control, not meta', () {
      // hotkey_manager's macOS plugin maps `control` → NSEvent .control and
      // `meta` → .command. Anything that flipped these would silently move the
      // defaults onto Command chords.
      for (final b in defaults) {
        final mods = b.toHotKey().modifiers;
        expect(mods, contains(HotKeyModifier.control));
        expect(mods, contains(HotKeyModifier.shift));
        expect(mods, isNot(contains(HotKeyModifier.meta)));
      }
    });

    test('chips name the keys the user is actually holding', () {
      // Control is 'Ctrl' everywhere — it IS the Control key on macOS, so the
      // default's label is honest there without a special case.
      expect(HotkeyBinding.defaultHistory.chips, ['Ctrl', 'Shift', 'Q']);
      // Meta and Alt are the two that rename. Whichever platform this runs on,
      // the chip must never claim a key that host doesn't have.
      const metaAlt = HotkeyBinding(win: true, alt: true, usbUsage: 0x00070014, label: 'Q');
      final chips = metaAlt.chips;
      expect(chips.last, 'Q');
      expect(chips, isNot(contains('Ctrl')));
      expect(
          chips,
          Platform.isMacOS
              ? contains('Cmd')
              : Platform.isLinux
                  ? contains('Super')
                  : contains('Win'));
      expect(chips, Platform.isMacOS ? contains('Option') : contains('Alt'));
    });

    test('the meta chip is engraved per platform', () {
      // The host-independent version of the check above: one physical key, three
      // names. This is the arm the Windows dev box could never reach.
      const metaAlt = HotkeyBinding(win: true, alt: true, usbUsage: 0x00070014, label: 'Q');
      expect(metaAlt.chipsOn(isMacOS: true, isLinux: false), ['Option', 'Cmd', 'Q']);
      expect(metaAlt.chipsOn(isMacOS: false, isLinux: true), ['Alt', 'Super', 'Q']);
      expect(metaAlt.chipsOn(isMacOS: false, isLinux: false), ['Alt', 'Win', 'Q']);
    });

    testWidgets('the recorder files Command under win and Control under ctrl',
        (tester) async {
      Future<HotkeyBinding?> record(List<LogicalKeyboardKey> held) async {
        for (final k in held) {
          await simulateKeyDownEvent(k, platform: 'macos');
        }
        const e = KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyQ,
          logicalKey: LogicalKeyboardKey.keyQ,
          timeStamp: Duration.zero,
        );
        final b = HotkeyBinding.fromEvent(e);
        for (final k in held) {
          await simulateKeyUpEvent(k, platform: 'macos');
        }
        return b;
      }

      final cmd = await record([
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.shiftLeft,
      ]);
      expect(cmd, isNotNull);
      expect(cmd!.win, isTrue, reason: '⌘ must land in the meta/win field');
      expect(cmd.ctrl, isFalse);
      expect(cmd.shift, isTrue);
      expect(cmd.label, 'Q');

      final ctrl = await record([
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.shiftLeft,
      ]);
      expect(ctrl, isNotNull);
      expect(ctrl!.ctrl, isTrue);
      expect(ctrl.win, isFalse);
      expect(ctrl.sameChordAs(HotkeyBinding.defaultHistory), isTrue);
    });

    test('a bare modifier press is never recorded as the main key', () {
      // fn included: macOS keyboards emit it as a real key event, and no
      // OS hotkey API can register it as a chord's main key.
      const bare = <(PhysicalKeyboardKey, LogicalKeyboardKey)>[
        (PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft),
        (PhysicalKeyboardKey.metaRight, LogicalKeyboardKey.metaRight),
        (PhysicalKeyboardKey.altLeft, LogicalKeyboardKey.altLeft),
        (PhysicalKeyboardKey.shiftRight, LogicalKeyboardKey.shiftRight),
        (PhysicalKeyboardKey.fn, LogicalKeyboardKey.fn),
      ];
      for (final (phys, logical) in bare) {
        final e = KeyDownEvent(
          physicalKey: phys,
          logicalKey: logical,
          timeStamp: Duration.zero,
        );
        expect(HotkeyBinding.fromEvent(e), isNull, reason: phys.debugName);
      }
    });
  });

  group('paste stack chords', () {
    test('are Ctrl+Shift+D (add) and Ctrl+Shift+B (paste next)', () {
      const push = HotkeyBinding.defaultStackPush;
      expect(push.ctrl, isTrue);
      expect(push.shift, isTrue);
      expect(push.alt, isFalse);
      expect(push.win, isFalse);
      expect(push.usbUsage, 0x00070007); // 'd'
      expect(push.label, 'D');

      const pop = HotkeyBinding.defaultStackPop;
      expect(pop.ctrl, isTrue);
      expect(pop.shift, isTrue);
      expect(pop.alt, isFalse);
      expect(pop.win, isFalse);
      expect(pop.usbUsage, 0x00070005); // 'b'
      expect(pop.label, 'B');
    });

    test('avoid the chords that were deliberately ruled out', () {
      // Ctrl+Shift+V is legacyHistory (installs may still hold it) and is the
      // Linux terminal paste chord we ourselves synthesize. A global grab does
      // not fail on a contested chord, it silently steals the key, so this
      // stays a test rather than a comment.
      for (final b in [
        HotkeyBinding.defaultStackPush,
        HotkeyBinding.defaultStackPop,
      ]) {
        expect(b.sameChordAs(HotkeyBinding.legacyHistory), isFalse);
        expect(b.usbUsage, isNot(0x00070009), reason: 'F is Find in Files');
        expect(b.usbUsage, isNot(0x00070015), reason: 'R is browser reload');
        expect(b.usbUsage, isNot(0x00070017), reason: 'T reopens a tab');
        expect(b.usbUsage, isNot(0x00070004), reason: 'A is Find Action');
      }
    });

    test('both round-trip through JSON', () {
      for (final orig in [
        HotkeyBinding.defaultStackPush,
        HotkeyBinding.defaultStackPop,
      ]) {
        final back = HotkeyBinding.fromJson(orig.toJson());
        expect(back, isNotNull);
        expect(back!.sameChordAs(orig), isTrue);
        expect(back.label, orig.label);
      }
    });
  });
}
