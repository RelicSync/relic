import Cocoa
import FlutterMacOS

/// relic/activate — bring the app to the foreground. As an LSUIElement agent
/// Relic never appears in the Dock or the app switcher, and
/// `NSApp.activate(ignoringOtherApps: false)` (what window_manager's focus()
/// issues) is ignored while another app — e.g. the OAuth browser — is
/// frontmost. This is the forceful variant for moments the user expects us to
/// take over: the return leg of the sign-in browser handoff, and showing
/// settings/onboarding windows. Dart client:
/// app/lib/platform/src/macos/activation_macos.dart.
enum ActivationBridge {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "relic/activate", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "activate":
        NSApp.activate(ignoringOtherApps: true)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
