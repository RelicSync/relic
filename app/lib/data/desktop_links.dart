import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';

/// Desktop `relic://` deep links (e.g. the website's post-checkout "Open Relic"
/// button, or any `relic://open`).
///
/// The two desktop platforms deliver a launch URL differently, so we split:
///
///   * Windows — the URL arrives as a command-line argument (the installer
///     registers `HKCU\Software\Classes\relic` pointing at `relic_app.exe "%1"`,
///     and windows/runner/main.cpp forwards argv to Dart). A SECOND launch while
///     the app is already resident is caught by the single-instance mutex guard,
///     which broadcasts `RelicShowExisting` so the running window surfaces
///     natively. So on Windows we only read argv here (cold start); warm start
///     needs no Dart involvement.
///
///   * macOS — Launch Services never passes the URL as argv; it fires a system
///     URL event that the app_links plugin catches. app_links owns BOTH cold
///     start (`getInitialLink`) and warm start (`uriLinkStream`), because macOS
///     activates the already-running app instead of starting a second copy.
///
/// The app wires [onLink] to surface its window. Any link that arrives before
/// that wiring is buffered and flushed on assignment (covers a `getInitialLink`
/// that resolves before the UI mounts).
class DesktopLinks {
  DesktopLinks._();

  static void Function(Uri uri)? _onLink;
  static Uri? _pending;
  static AppLinks? _links;
  static StreamSubscription<Uri>? _sub;

  /// The window-surfacing handler, set by the desktop app while it is mounted.
  static set onLink(void Function(Uri uri)? cb) {
    _onLink = cb;
    final p = _pending;
    if (cb != null && p != null) {
      _pending = null;
      cb(p);
    }
  }

  /// The `relic://` URL this process was cold-started with, if any. Windows
  /// only: on macOS the launch URL comes through [init], not argv.
  static Uri? launchLinkFromArgs(List<String> args) {
    if (!Platform.isWindows) return null;
    for (final a in args) {
      if (a.startsWith('relic://')) return Uri.tryParse(a);
    }
    return null;
  }

  /// Start listening for links that arrive while the app runs. macOS only:
  /// Windows cold start is handled via [launchLinkFromArgs] and warm start via
  /// the native RelicShowExisting broadcast, so there is nothing to stream.
  static Future<void> init() async {
    if (!Platform.isMacOS) return;
    final links = _links ??= AppLinks();
    _sub ??= links.uriLinkStream.listen(_dispatch, onError: (_) {});
    try {
      final initial = await links.getInitialLink();
      if (initial != null) _dispatch(initial);
    } catch (_) {/* no launch link */}
  }

  static void _dispatch(Uri uri) {
    if (uri.scheme != 'relic') return;
    final cb = _onLink;
    if (cb != null) {
      cb(uri);
    } else {
      _pending = uri; // arrived before the UI wired up; flush on assign
    }
  }
}
