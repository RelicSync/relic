/// Apple platform identifiers, in one place so the Dart side, the Xcode
/// targets, and the future Share Extension can never drift
/// (docs/apple-port-2026-08.md §3b.4, docs/ios-port.md §7.5).
///
/// The native mirror is `ios/Flutter/RelicIds.xcconfig`; change both together.
/// The bundle id is D1 of the Apple program plan and is PERMANENT once the
/// App Store Connect record exists.
library;

/// Main app bundle identifier (iOS/iPadOS).
const appleBundleId = 'space.relic.app';

/// Share Extension bundle identifier (Phase 2; target does not exist yet).
const appleShareExtensionBundleId = 'space.relic.app.RelicShare';

/// App Group shared container: the share extension writes its payload here
/// and the app drains it (a queue, never a second vault-cache writer).
const appleAppGroupId = 'group.space.relic.app';

/// Custom URL scheme (`relic://capture`, `relic://` hand-off from the share
/// extension). Registered in ios/Runner/Info.plist CFBundleURLTypes and in
/// AndroidManifest.xml — shared across platforms.
const relicUrlScheme = 'relic';
