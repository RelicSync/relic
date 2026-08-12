import Cocoa
import FlutterMacOS

/// relic/sound — play a bundled Flutter asset (the promotion chime) with
/// NSSound. The Windows build reaches the asset on disk next to the exe; here
/// it lives inside the .app, resolved via FlutterDartProject.lookupKey. Dart
/// client: app/lib/platform/src/macos/sound_macos.dart.
enum SoundBridge {
  /// NSSound stops when deallocated — hold the current one until it finishes.
  private static var current: NSSound?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "relic/sound", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "play":
        guard let args = call.arguments as? [String: Any],
              let asset = args["asset"] as? String else {
          result(false)
          return
        }
        // lookupKey returns a path relative to the BUNDLE ROOT
        // (Contents/Frameworks/App.framework/Resources/flutter_assets/…), not
        // to Contents/Resources — Bundle.path(forResource:) never finds it.
        let key = FlutterDartProject.lookupKey(forAsset: asset)
        let path = Bundle.main.bundlePath + "/" + key
        guard FileManager.default.fileExists(atPath: path),
              let sound = NSSound(contentsOfFile: path, byReference: true) else {
          result(false)
          return
        }
        current = sound
        result(sound.play())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
