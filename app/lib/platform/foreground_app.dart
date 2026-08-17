import 'dart:io' show Platform;

import 'src/linux/foreground_linux.dart' as lin;
import 'src/macos/foreground_macos.dart' as mac;
import 'src/windows/foreground_win.dart' as win;

/// Which application the user copied FROM — read at the moment a clipboard
/// event fires, while the source app still owns the foreground. Powers the
/// capture-time source-app tag ("the thing I copied from chrome") and the
/// capture blocklist.
///
/// The platform-neutral currency is a lowercase "app key": the executable stem
/// on Windows ("chrome", "code"), a normalized bundle-id stem on macOS
/// ("chrome", "vscode"), a normalized WM_CLASS on Linux/X11 ("chrome",
/// "nautilus"). Blocklist entries and tags are derived from it, so they stay
/// consistent within a platform. Wayland sessions have no foreground query at
/// all — the key is null there and captures simply go untagged.

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
  if (Platform.isLinux) {
    final c = lin.foregroundWmClass();
    if (c == null) return null;
    return linuxAppKey(c.klass, c.instance);
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

/// Linux: the app key for an X11 WM_CLASS pair (class preferred, instance as
/// the fallback). Null for Relic itself — same rule as [macAppKey].
///
/// Two shapes exist in the wild: plain stems ("Google-chrome", "firefox") and
/// the reverse-DNS ids GTK4/KDE apps use ("org.gnome.Nautilus",
/// "org.kde.dolphin"), where the last segment carries the name. The friendly
/// table is consulted both before and after the reverse-DNS collapse so
/// either spelling of a known app lands on the same key.
String? linuxAppKey(String klass, String instance) {
  var raw = (klass.isNotEmpty ? klass : instance).toLowerCase();
  if (raw.isEmpty) return null;
  // Relic itself: the runner's APPLICATION_ID / g_set_prgname and the dev
  // binary name (linux/CMakeLists.txt; change both together).
  if (raw == 'space.relic.app' || raw == 'relic_app' || raw == 'relic') {
    return null;
  }
  var friendly = _linuxFriendlyClass[raw];
  if (friendly != null) return friendly;
  if (raw.contains('.')) raw = raw.split('.').last;
  friendly = _linuxFriendlyClass[raw];
  if (friendly != null) return friendly;
  final key = raw.replaceAll(RegExp(r'[^a-z0-9+_-]'), '');
  if (key.length < 2) return null;
  return key.length > 24 ? key.substring(0, 24) : key;
}

/// App keys that would be noise as a source tag: our own app, the shell
/// (file copies arrive with the file manager focused), and hosts too generic
/// to mean anything. Public because the blocklist picker filters the same
/// noise out of its running-apps list. Relic's own macOS bundle is absent on
/// purpose: [macAppKey] nulls it outright, so it never reaches a key (and
/// [linuxAppKey] does the same for the Linux WM_CLASS).
const kAppKeyNoise = {
  // Windows exe stems
  'relic_app', 'relic', 'explorer', 'applicationframehost', 'searchhost',
  'shellexperiencehost', 'dllhost', 'sihost', 'lockapp', 'rundll32',
  // macOS keys (see the com.apple.* rows of _macFriendlyBundle)
  'finder', 'dock', 'loginwindow', 'screencaptureui',
  'universalcontrol', 'windowserver',
  // Linux keys: file managers (the copier of record for file copies) and
  // desktop shells / portals
  'nautilus', 'dolphin', 'thunar', 'nemo', 'pcmanfm', 'pcmanfm-qt',
  'gnome-shell', 'plasmashell', 'kwin_x11',
  'xdg-desktop-portal', 'xdg-desktop-portal-gtk', 'xdg-desktop-portal-gnome',
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

/// Linux: WM_CLASS (lowercased) → app key, consulted on both the raw class
/// and its reverse-DNS last segment (see [linuxAppKey]). Anything else keeps
/// its own sanitized stem so niche apps still get attribution.
const _linuxFriendlyClass = {
  'google-chrome': 'chrome',
  'chromium-browser': 'chromium',
  'microsoft-edge': 'edge',
  'brave-browser': 'brave',
  'navigator': 'firefox', // firefox's WM_CLASS instance when class is absent
  'code': 'vscode',
  'code-oss': 'vscode',
  'vscodium': 'vscode',
  'jetbrains-idea': 'intellij',
  'jetbrains-idea-ce': 'intellij',
  'jetbrains-pycharm': 'pycharm',
  'jetbrains-pycharm-ce': 'pycharm',
  'jetbrains-webstorm': 'webstorm',
  'jetbrains-rider': 'rider',
  'jetbrains-clion': 'clion',
  'jetbrains-goland': 'goland',
  'jetbrains-studio': 'androidstudio',
  // terminals: same SIGINT hazard as Windows — the copy chord must skip them
  'gnome-terminal': 'terminal',
  'gnome-terminal-server': 'terminal',
  'ptyxis': 'terminal',
  'konsole': 'terminal',
  'yakuake': 'terminal',
  'alacritty': 'terminal',
  'kitty': 'terminal',
  'wezterm': 'terminal',
  'xterm': 'terminal',
  'uxterm': 'terminal',
  'urxvt': 'terminal',
  'tilix': 'terminal',
  'terminator': 'terminal',
  'xfce4-terminal': 'terminal',
  'foot': 'terminal',
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
