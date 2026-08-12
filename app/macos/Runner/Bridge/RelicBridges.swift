import FlutterMacOS

/// Registers every Relic method channel with the Flutter engine. One Swift
/// file per concern, 1:1 with app/lib/platform/src/macos/*.dart
/// (docs/macos-port.md D3). Called from MainFlutterWindow after
/// RegisterGeneratedPlugins.
enum RelicBridges {
  static func register(with messenger: FlutterBinaryMessenger) {
    ActivationBridge.register(with: messenger)
    ClipboardBridge.register(with: messenger)
    InputBridge.register(with: messenger)
    ForegroundAppBridge.register(with: messenger)
    LoginItemBridge.register(with: messenger)
    SoundBridge.register(with: messenger)
    // relic/native_toast (the gem flourish overlay) is deliberately absent:
    // the Dart side falls back to a normal notification until
    // GemToastPanel.swift lands (docs/macos-port.md Phase 7).
  }
}
