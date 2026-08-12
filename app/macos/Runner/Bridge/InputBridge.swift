import Carbon.HIToolbox
import Cocoa
import FlutterMacOS

/// relic/input — synthetic ⌘C/⌘V into the frontmost app via CGEvent, plus the
/// Accessibility (TCC) gate those events require. Dart client:
/// app/lib/platform/src/macos/input_macos.dart.
///
/// Chord-safety: the Windows implementation force-releases the user's held
/// hotkey modifiers before injecting (win_input.dart). On macOS the posted
/// CGEvent carries its own modifier flags (only ⌘), which target apps honor
/// over the physical state — but we still wait briefly for the physical
/// modifiers to clear so apps that read NSEvent.modifierFlags directly don't
/// see a mixed chord.
enum InputBridge {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "relic/input", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "accessibilityTrusted":
        let args = call.arguments as? [String: Any]
        let prompt = args?["prompt"] as? Bool ?? false
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        result(AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary))

      case "openAccessibilitySettings":
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        result(nil)

      case "sendPaste":
        sendChord(CGKeyCode(kVK_ANSI_V), chordSafe: false) { result(nil) }

      case "sendPasteChordSafe":
        sendChord(CGKeyCode(kVK_ANSI_V), chordSafe: true) { result(nil) }

      case "sendCopyChordSafe":
        sendChord(CGKeyCode(kVK_ANSI_C), chordSafe: true) { result(nil) }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func postCommandChord(_ key: CGKeyCode) {
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }

  /// Poll `ready` on the main queue every 20ms, giving up after `tries` and
  /// running `then` anyway. 20ms × 15 is the win_input.dart budget: a normal
  /// hotkey tap clears well inside it, so the common case adds no latency.
  private static func waitUntil(
    _ ready: @escaping () -> Bool,
    tries: Int,
    then: @escaping () -> Void
  ) {
    var left = tries
    func attempt() {
      if ready() || left <= 0 {
        then()
        return
      }
      left -= 1
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { attempt() }
    }
    attempt()
  }

  /// Post ⌘[key] once the keystroke can actually land where the user meant it.
  ///
  /// Two waits, both bounded, both usually no-ops:
  ///
  /// - `chordSafe` callers come straight out of a global-hotkey handler with
  ///   the chord's modifiers still physically down; posting then would read as
  ///   ⌃⇧⌘V in an app that watches NSEvent.modifierFlags. Wait for them.
  /// - Any caller may be firing right after the popup ordered out (paste-on-
  ///   select). AppKit hands activation back to the previous app a beat later,
  ///   and a CGEvent posted while we are still the active app types into a
  ///   window that is already gone. Wait to stop being frontmost.
  ///
  /// Both waits fall through and post on timeout: the item is already on the
  /// clipboard by the time any caller gets here, so the worst case is a paste
  /// the user has to press ⌘V for, never a lost relic. Untrusted (no AX grant)
  /// returns immediately and silently, matching the Windows contract.
  private static func sendChord(
    _ key: CGKeyCode,
    chordSafe: Bool,
    then done: @escaping () -> Void
  ) {
    guard AXIsProcessTrustedWithOptions(nil) else {
      done()
      return
    }
    let fire = {
      waitUntil({ !NSApp.isActive }, tries: 10) {
        postCommandChord(key)
        done()
      }
    }
    guard chordSafe else {
      fire()
      return
    }
    waitUntil({ NSEvent.modifierFlags.intersection(chordModifiers).isEmpty }, tries: 15, then: fire)
  }

  /// The modifiers a Relic hotkey can carry; Caps Lock and fn are deliberately
  /// excluded (Caps Lock is a latched state, not something the user is holding).
  private static let chordModifiers: NSEvent.ModifierFlags = [
    .shift, .option, .control, .command,
  ]
}
