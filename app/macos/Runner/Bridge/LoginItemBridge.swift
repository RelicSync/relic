import FlutterMacOS
import ServiceManagement

/// relic/login_item — run-at-login via SMAppService (macOS 13+), the analog of
/// the HKCU Run key the Windows build writes. Dart client:
/// app/lib/platform/src/macos/login_item_macos.dart. On pre-13 systems both
/// calls report false and the Settings toggle simply doesn't stick.
enum LoginItemBridge {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "relic/login_item", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard #available(macOS 13.0, *) else {
        result(false)
        return
      }
      switch call.method {
      case "set":
        let args = call.arguments as? [String: Any]
        let enable = args?["enable"] as? Bool ?? false
        do {
          if enable {
            try SMAppService.mainApp.register()
          } else {
            try SMAppService.mainApp.unregister()
          }
          result(true)
        } catch {
          // unregister of a never-registered item throws — that's still "off"
          result(!enable && SMAppService.mainApp.status != .enabled)
        }
      case "get":
        // .requiresApproval means the item IS registered and the user turned it
        // off in System Settings → Login Items. Reporting that as "off" makes
        // launch reconciliation re-register on every launch, overriding a
        // deliberate OS-level choice, so it counts as on here.
        let status = SMAppService.mainApp.status
        result(status == .enabled || status == .requiresApproval)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
