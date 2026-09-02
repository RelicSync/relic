import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

/// What asked for the popup. Every summon names its source, and the picker
/// mode is decided from that in [miniForSummon].
enum Summon {
  /// The history hotkey: always the full popup.
  historyHotkey,

  /// The dedicated mini hotkey: always the compact picker.
  miniHotkey,

  /// Tray icon click or the tray menu's Show: always the full window.
  tray,

  /// Launched (or relaunched) with the popup showing.
  launch,

  /// A reminder notification the user clicked.
  notification,

  /// A `relic://` deep link.
  deepLink,

  /// Save & annotate: the editor needs the full surface.
  annotate,
}

/// Which picker a summon opens.
///
/// One table, and the source alone decides. The mode used to be a nullable
/// bool passed at each call site, and the history hotkey passed nothing,
/// meaning "follow the mini-picker preference" — which defaulted to on, so the
/// history hotkey and the mini hotkey both opened the mini picker and the full
/// window had no key at all.
///
/// The preference is gone now, because there was nothing left for it to
/// decide. The mini picker is compact and anchored to the text caret: it is
/// the answer to a keystroke, mid-typing. Every other way in is a deliberate
/// "show me Relic" — a tray click, a launch, a reminder, a link — and those
/// want the whole window. That leaves exactly one summon that opens mini, and
/// it has its own hotkey.
///
/// The invariant that must not break again: the two picker hotkeys always
/// disagree, so neither surface can become unreachable.
bool miniForSummon(Summon s) => switch (s) {
  Summon.miniHotkey => true,
  // Everything else. A tray click is a mouse landing in the corner of the
  // screen, nowhere near the caret the mini picker anchors to, and a launch,
  // reminder, deep link or annotate is surfacing something specific. All of
  // them want the room.
  Summon.historyHotkey ||
  Summon.tray ||
  Summon.launch ||
  Summon.notification ||
  Summon.deepLink ||
  Summon.annotate =>
    false,
};

/// A serializable global-hotkey chord (modifiers + one main key), shared by the
/// settings recorder (capture/display) and desktop.dart (registration).
///
/// The main key is stored as its USB-HID usage code so it round-trips through
/// JSON without depending on a key *label* (labels vary by layout); the label
/// is kept only for display.
class HotkeyBinding {
  final bool ctrl;
  final bool shift;
  final bool alt;
  final bool win; // Windows / meta
  final int usbUsage; // PhysicalKeyboardKey.usbHidUsage of the main key
  final String label; // display only, e.g. 'V', 'C', 'F5'

  const HotkeyBinding({
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
    this.win = false,
    required this.usbUsage,
    required this.label,
  });

  bool get hasModifier => ctrl || shift || alt || win;

  List<HotKeyModifier> get modifiers => [
        if (ctrl) HotKeyModifier.control,
        if (alt) HotKeyModifier.alt,
        if (shift) HotKeyModifier.shift,
        if (win) HotKeyModifier.meta,
      ];

  HotKey toHotKey() => HotKey(
        key: PhysicalKeyboardKey(usbUsage),
        modifiers: modifiers,
        scope: HotKeyScope.system,
      );

  /// Keycap chips for the settings UI, modifiers first (stable order). The
  /// chord itself is platform-neutral (Ctrl+Shift+Q/W/E is free on macOS too);
  /// only the meta/alt names differ.
  List<String> get chips =>
      chipsOn(isMacOS: Platform.isMacOS, isLinux: Platform.isLinux);

  /// [chips] with the platform passed in, so every arm is reachable from a test
  /// on any host.
  ///
  /// The meta key is named three ways, because the physical key is the same one
  /// and only its engraving changes: Command on macOS, Super on Linux (X11 and
  /// every desktop name it that, and 'Win' on a machine that has never run
  /// Windows reads as a different key), and the Windows key on Windows.
  List<String> chipsOn({required bool isMacOS, required bool isLinux}) => [
        if (ctrl) 'Ctrl',
        if (alt) isMacOS ? 'Option' : 'Alt',
        if (shift) 'Shift',
        if (win)
          isMacOS
              ? 'Cmd'
              : isLinux
                  ? 'Super'
                  : 'Win',
        label,
      ];

  String get display => chips.join(' + ');

  Map<String, dynamic> toJson() =>
      {'ctrl': ctrl, 'shift': shift, 'alt': alt, 'win': win, 'usage': usbUsage, 'label': label};

  static HotkeyBinding? fromJson(Object? v) {
    if (v is! Map) return null;
    final usage = v['usage'];
    final label = v['label'];
    if (usage is! num || label is! String) return null;
    return HotkeyBinding(
      ctrl: v['ctrl'] == true,
      shift: v['shift'] == true,
      alt: v['alt'] == true,
      win: v['win'] == true,
      usbUsage: usage.toInt(),
      label: label,
    );
  }

  /// Build a binding from a captured key event: the pressed non-modifier key
  /// plus whatever modifiers are currently held. Returns null for a bare
  /// modifier press or a key with no usable label.
  static HotkeyBinding? fromEvent(KeyEvent e) {
    final phys = e.physicalKey;
    if (_modifierUsages.contains(phys.usbHidUsage)) return null;
    final label = _labelFor(e);
    if (label == null) return null;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    bool any(Set<LogicalKeyboardKey> s) => s.any(keys.contains);
    return HotkeyBinding(
      ctrl: any({LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight}),
      shift: any({LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight}),
      alt: any({LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight}),
      win: any({LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight}),
      usbUsage: phys.usbHidUsage,
      label: label,
    );
  }

  static String? _labelFor(KeyEvent e) {
    final l = e.logicalKey.keyLabel;
    if (l.isNotEmpty) return l.toUpperCase();
    // function/navigation keys have no keyLabel — fall back to a debug name.
    final name = e.logicalKey.debugName;
    return (name != null && name.isNotEmpty) ? name : null;
  }

  /// USB-HID usage codes (page 0x07) for the eight modifier keys, so a bare
  /// modifier press isn't mistaken for the main key while recording. fn joins
  /// them from Flutter's synthetic range: macOS keyboards report fn as a real
  /// key event (Windows ones usually don't), and it is a modifier no OS-level
  /// hotkey API can register as a main key.
  static const Set<int> _modifierUsages = {
    0x000700e0, 0x000700e4, // control L/R
    0x000700e1, 0x000700e5, // shift L/R
    0x000700e2, 0x000700e6, // alt L/R
    0x000700e3, 0x000700e7, // meta (Win / Cmd) L/R
    0x00000012, // fn (PhysicalKeyboardKey.fn)
  };

  /// Same chord (modifiers + physical key), label ignored.
  bool sameChordAs(HotkeyBinding o) =>
      ctrl == o.ctrl &&
      shift == o.shift &&
      alt == o.alt &&
      win == o.win &&
      usbUsage == o.usbUsage;

  // --- defaults: one home-row row, Ctrl+Shift + Q/W/E ---
  //
  // The same chord on macOS, and deliberately so: [ctrl] is the PHYSICAL
  // Control key there (HotKeyModifier.control → NSEvent .control), not Command.
  // Swapping to ⌘⇧ would put the history key on ⌘⇧Q, which is Log Out.
  // ⌃⇧Q/W/E/Space/1-5 are all unclaimed by macOS.
  static const defaultHistory =
      HotkeyBinding(ctrl: true, shift: true, usbUsage: 0x00070014, label: 'Q'); // Ctrl+Shift+Q
  static const defaultPromote =
      HotkeyBinding(ctrl: true, shift: true, usbUsage: 0x0007001A, label: 'W'); // Ctrl+Shift+W
  static const defaultCapture = // save & annotate ("promotion with note")
      HotkeyBinding(ctrl: true, shift: true, usbUsage: 0x00070008, label: 'E'); // Ctrl+Shift+E
  // Mini picker (compact, cursor-anchored). Ctrl+Shift+Space: thumb-reachable
  // while the left hand holds the modifiers, command-palette feel, and free as a
  // global chord on Windows. HID usage 0x2C = Spacebar.
  static const defaultMini =
      HotkeyBinding(ctrl: true, shift: true, usbUsage: 0x0007002C, label: 'Space'); // Ctrl+Shift+Space
  // Quick-paste 1-5: paste the Nth most-recent item from any device. Ctrl+Shift
  // + digit is free globally on Windows (Win+digit is the taskbar; Ctrl+digit is
  // app-local). HID usage page 0x07: '1'=0x1E … '5'=0x22.
  static const defaultQuickPaste = <HotkeyBinding>[
    HotkeyBinding(ctrl: true, shift: true, usbUsage: 0x0007001E, label: '1'),
    HotkeyBinding(ctrl: true, shift: true, usbUsage: 0x0007001F, label: '2'),
    HotkeyBinding(ctrl: true, shift: true, usbUsage: 0x00070020, label: '3'),
    HotkeyBinding(ctrl: true, shift: true, usbUsage: 0x00070021, label: '4'),
    HotkeyBinding(ctrl: true, shift: true, usbUsage: 0x00070022, label: '5'),
  ];

  // Paste stack: Ctrl+Shift+D adds what you copied, Ctrl+Shift+B pastes the
  // next one. Both sit one key from the Q/W/E row, so all five actions stay
  // under the left hand with no reach.
  //
  // A global grab does not FAIL on a contested chord, it silently takes the key
  // from every app, so the bar here is "genuinely low traffic", not "free". D
  // is duplicate-line in VS Code and little else; B is a VS Code build task and
  // is not a browser or JetBrains primary. Ruled out: Ctrl+Shift+F (Find in
  // Files in PyCharm and VS Code), Ctrl+Shift+V ([legacyHistory], and the Linux
  // terminal paste chord we ourselves send), Ctrl+Shift+R/T (browser reload and
  // reopen-tab), Ctrl+Shift+A (JetBrains Find Action).
  //
  // Registered only while feature_paste_stack is on, so an opted-out user gives
  // up nothing. HID usage page 0x07: 'b'=0x05, 'd'=0x07.
  static const defaultStackPush =
      HotkeyBinding(ctrl: true, shift: true, usbUsage: 0x00070007, label: 'D'); // Ctrl+Shift+D
  static const defaultStackPop =
      HotkeyBinding(ctrl: true, shift: true, usbUsage: 0x00070005, label: 'B'); // Ctrl+Shift+B

  // --- pre-July-2026 defaults, kept so _loadPrefs can upgrade installs that
  // never customized: a stored binding equal to the OLD default counts as
  // "never changed" and adopts the new one.
  static const legacyHistory =
      HotkeyBinding(ctrl: true, shift: true, usbUsage: 0x00070019, label: 'V'); // Ctrl+Shift+V
  static const legacyCapture =
      HotkeyBinding(ctrl: true, alt: true, usbUsage: 0x00070006, label: 'C'); // Ctrl+Alt+C
  static const legacyPromote =
      HotkeyBinding(ctrl: true, alt: true, usbUsage: 0x00070013, label: 'P'); // Ctrl+Alt+P
}
