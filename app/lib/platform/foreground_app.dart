import 'dart:io' show Platform;

import 'src/macos/foreground_macos.dart' as mac;
import 'src/windows/foreground_win.dart' as win;

/// Which application the user copied FROM — read at the moment a clipboard
/// event fires, while the source app still owns the foreground. Powers the
/// capture-time source-app tag ("the thing I copied from chrome") and the
/// capture blocklist.
///
/// The platform-neutral currency is a lowercase "app key": the executable stem
/// on Windows ("chrome", "code"), a normalized bundle-id stem on macOS
/// ("chrome", "vscode"). Blocklist entries and tags are derived from it, so
/// they stay consistent within a platform.

/// The focused control's caret as `[x, y]` (bottom-left), or null when no app
/// reports one. Used by caret anchoring to open the picker where the user is
/// typing. Units differ by platform and the caller's scale derivation absorbs
/// it: Windows answers in PHYSICAL pixels (paired with
/// [cursorScreenPointPhysical] to derive the display scale); macOS answers in
/// global points, which already ARE the logical space — its
/// [cursorScreenPointPhysical] stays null, so the scale stays 1.
Future<List<double>?> caretScreenPoint() async {
  if (Platform.isWindows) return win.caretScreenPointPhysical();
  if (Platform.isMacOS) return mac.caretScreenPoint();
  return null;
}

/// The mouse cursor in PHYSICAL screen pixels `[x, y]`, or null. Paired with a
/// logical cursor read to derive the effective display scale for caret
/// anchoring (Windows-only; macOS carets arrive in points, see above).
List<double>? cursorScreenPointPhysical() =>
    Platform.isWindows ? win.cursorScreenPointPhysical() : null;

/// The current foreground app's key, or null when it can't be determined.
Future<String?> foregroundAppKey() async {
  if (Platform.isWindows) return win.foregroundAppExe();
  if (Platform.isMacOS) {
    final app = await mac.frontmostApp();
    if (app == null) return null;
    return macAppKey(app.bundleId, app.name);
  }
  return null;
}

/// Relic's own macOS bundle id — PRODUCT_BUNDLE_IDENTIFIER in
/// macos/Runner/Configs/AppInfo.xcconfig; change both together.
const _relicMacBundleId = 'space.relic.mac';

/// macOS: the app key for a bundle id plus the localized name macOS reports
/// for it. Null for Relic itself, which must never be a source tag or a
/// paste-destination ranking context (desktop.dart's summon read).
///
/// Bundle ids are not stems: the last component is routinely meaningless
/// ("com.spotify.client", "us.zoom.xos", "notion.id"), so the localized name
/// carries the fallback and the id only backstops a nameless app.
String? macAppKey(String bundleId, String name) {
  final id = bundleId.toLowerCase();
  if (id == _relicMacBundleId) return null;
  final friendly = _macFriendlyBundle[id];
  if (friendly != null) return friendly;
  final fromName = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (fromName.length >= 2) {
    return fromName.length > 24 ? fromName.substring(0, 24) : fromName;
  }
  return id.split('.').last;
}

/// App keys that would be noise as a source tag: our own app, the shell
/// (file copies arrive with the file manager focused), and hosts too generic
/// to mean anything. Public because the blocklist picker filters the same
/// noise out of its running-apps list. Relic's own macOS bundle is absent on
/// purpose: [macAppKey] nulls it outright, so it never reaches a key.
const kAppKeyNoise = {
  // Windows exe stems
  'relic_app', 'relic', 'explorer', 'applicationframehost', 'searchhost',
  'shellexperiencehost', 'dllhost', 'sihost', 'lockapp', 'rundll32',
  // macOS keys (see the com.apple.* rows of _macFriendlyBundle)
  'finder', 'dock', 'loginwindow', 'screencaptureui',
  'universalcontrol', 'windowserver',
};

/// Friendly tag for a well-known Windows exe stem; anything else keeps its own
/// stem (sanitized) so niche apps still get attribution.
const _friendly = {
  'msedge': 'edge',
  'code': 'vscode',
  'code - insiders': 'vscode',
  'devenv': 'visualstudio',
  'idea64': 'intellij',
  'pycharm64': 'pycharm',
  'webstorm64': 'webstorm',
  'rider64': 'rider',
  'clion64': 'clion',
  'goland64': 'goland',
  'studio64': 'androidstudio',
  'notepad++': 'notepad',
  'winword': 'word',
  'powerpnt': 'powerpoint',
  'olk': 'outlook',
  'ms-teams': 'teams',
  'acrord32': 'acrobat',
  'windowsterminal': 'terminal',
  'wt': 'terminal',
  'openconsole': 'terminal',
  'powershell': 'terminal',
  'pwsh': 'terminal',
  'cmd': 'terminal',
};

/// macOS: bundle id (lowercased) → app key, for ids whose derived key would be
/// wrong, inconsistent, or locale-dependent. Anything else falls back to the
/// localized name (see [macAppKey]).
const _macFriendlyBundle = {
  'com.microsoft.edgemac': 'edge',
  'com.microsoft.vscode': 'vscode',
  'com.google.chrome': 'chrome',
  'com.brave.browser': 'brave',
  'org.mozilla.firefox': 'firefox',
  'com.tinyspeck.slackmacgap': 'slack',
  'com.hnc.discord': 'discord',
  'com.microsoft.word': 'word',
  'com.microsoft.powerpoint': 'powerpoint',
  'com.microsoft.outlook': 'outlook',
  'com.microsoft.teams2': 'teams',
  'com.adobe.reader': 'acrobat',
  'com.jetbrains.intellij': 'intellij',
  'com.jetbrains.pycharm': 'pycharm',
  'com.jetbrains.webstorm': 'webstorm',
  'com.jetbrains.rider': 'rider',
  'com.jetbrains.clion': 'clion',
  'com.jetbrains.goland': 'goland',
  'com.google.android.studio': 'androidstudio',
  'com.spotify.client': 'spotify',
  'notion.id': 'notion',
  'us.zoom.xos': 'zoom',
  'company.thebrowser.browser': 'arc',
  'com.apple.mobilesms': 'messages',
  // terminals: same SIGINT hazard as Windows — the copy chord must skip them
  'com.apple.terminal': 'terminal',
  'com.googlecode.iterm2': 'terminal',
  'dev.warp.warp-stable': 'terminal',
  'com.mitchellh.ghostty': 'terminal',
  'net.kovidgoyal.kitty': 'terminal',
  'io.alacritty': 'terminal',
  // system surfaces, pinned so the kAppKeyNoise keys hold in every locale
  'com.apple.finder': 'finder',
  'com.apple.dock': 'dock',
  'com.apple.loginwindow': 'loginwindow',
  'com.apple.screencaptureui': 'screencaptureui',
  'com.apple.universalcontrol': 'universalcontrol',
  'com.apple.windowserver': 'windowserver',
};

/// The machine tag to stamp on a capture from the current foreground app, or
/// null when there's no meaningful attribution. Lowercase, tag-safe.
Future<String?> foregroundAppTag() async =>
    foregroundAppTagFrom(await foregroundAppKey());

/// Tag derivation split from the foreground read so callers that already
/// queried the foreground app (e.g. the capture blocklist gate) don't pay a
/// second native round-trip.
String? foregroundAppTagFrom(String? key) {
  if (key == null || kAppKeyNoise.contains(key)) return null;
  final name = _friendly[key] ?? key;
  final tag = name.replaceAll(RegExp(r'[^a-z0-9+.-]'), '');
  if (tag.length < 2 || tag.length > 24) return null;
  return tag;
}
