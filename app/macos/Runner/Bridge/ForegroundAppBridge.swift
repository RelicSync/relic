import Cocoa
import FlutterMacOS

/// relic/frontmost — which app owns the foreground right now, for capture-time
/// source attribution ("copied from chrome") and the capture blocklist. Dart
/// client: app/lib/platform/src/macos/foreground_macos.dart (which normalizes
/// the bundle id into the platform-neutral "app key").
enum ForegroundAppBridge {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "relic/frontmost", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "bundleId":
        result(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
