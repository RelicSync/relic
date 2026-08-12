import Cocoa
import FlutterMacOS

/// relic/frontmost — which app owns the foreground right now, for capture-time
/// source attribution ("copied from chrome") and the capture blocklist. Dart
/// client: app/lib/platform/src/macos/foreground_macos.dart (which normalizes
/// the bundle id into the platform-neutral "app key").
///
/// Both methods answer with `{bundleId, name}` maps: the localized name is the
/// only readable fallback for bundle ids whose last component is meaningless
/// ("com.spotify.client"), so it always travels with the id.
enum ForegroundAppBridge {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "relic/frontmost", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "frontmost":
        result(describe(NSWorkspace.shared.frontmostApplication))

      case "runningApps":
        // .regular = has a Dock icon and can own the foreground; agents and
        // daemons can never be a copy source, so they'd only be picker noise.
        result(NSWorkspace.shared.runningApplications
          .filter { $0.activationPolicy == .regular }
          .compactMap { describe($0) })

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// `{bundleId, name}` for an app, or nil when it has no bundle id (the id is
  /// the identity the blocklist stores; a nameless app still resolves).
  private static func describe(_ app: NSRunningApplication?) -> [String: String]? {
    guard let id = app?.bundleIdentifier, !id.isEmpty else { return nil }
    return ["bundleId": id, "name": app?.localizedName ?? ""]
  }
}
