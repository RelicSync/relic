import Cocoa
import FlutterMacOS

/// relic/activate — who holds the foreground, and how the one window gets on
/// and off the screen.
///
/// As an LSUIElement agent Relic never appears in the Dock or the app switcher,
/// and `NSApp.activate(ignoringOtherApps: false)` (what window_manager's focus()
/// issues) is ignored while another app — e.g. the OAuth browser — is frontmost.
///
/// - `activate` is the forceful variant for moments the user expects us to take
///   over: the return leg of the sign-in browser handoff.
/// - `present`/`dismiss` are the window's own show and hide, which window_manager
///   cannot express: its show() always activates the app, so the popup could
///   never appear without stealing focus. Both delegate to MainFlutterWindow,
///   the NSPanel that knows what agent mode and app mode mean.
///
/// Dart client: app/lib/platform/src/macos/activation_macos.dart.
enum ActivationBridge {
  /// The one Relic window. Looked up rather than captured so the bridge holds
  /// no reference to the window it serves (and so a rebuilt window, if AppKit
  /// ever hands us one, is still found).
  private static var window: MainFlutterWindow? {
    NSApp.windows.first { $0 is MainFlutterWindow } as? MainFlutterWindow
  }

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "relic/activate", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "activate":
        NSApp.activate(ignoringOtherApps: true)
        result(true)
      case "present":
        let args = call.arguments as? [String: Any]
        // Default to activating: a caller that forgot to say gets the safe,
        // visible outcome rather than a window nobody can reach.
        let activate = args?["activate"] as? Bool ?? true
        guard let window = window else {
          result(false)
          return
        }
        window.present(activate: activate)
        result(true)
      case "dismiss":
        guard let window = window else {
          result(false)
          return
        }
        window.dismiss()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
