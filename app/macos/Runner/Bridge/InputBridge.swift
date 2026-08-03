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
        postCommandChord(CGKeyCode(kVK_ANSI_V))
        result(nil)

      case "sendCopyChordSafe":
        sendCopyChordSafe { result(nil) }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func postCommandChord(_ key: CGKeyCode) {
    guard AXIsProcessTrustedWithOptions(nil) else { return } // silent, like Windows
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }

  /// Wait (≤15 × 20ms, mirroring win_input.dart) for the hotkey's physical
  /// modifiers to clear, then post ⌘C.
  private static func sendCopyChordSafe(then done: @escaping () -> Void) {
    var tries = 0
    func attempt() {
      let flags = NSEvent.modifierFlags
      let held = !flags.intersection([.shift, .option, .control, .command]).isEmpty
      if !held || tries >= 15 {
        postCommandChord(CGKeyCode(kVK_ANSI_C))
        done()
        return
      }
      tries += 1
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { attempt() }
    }
    attempt()
  }
}
