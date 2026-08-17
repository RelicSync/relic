import 'dart:io';

/// Where Relic keeps its on-device data (vault db, blobs, config, prefs, logs).
///
/// Resolution order:
///   1. RELIC_DATA_DIR — sandboxed test instance / portable mode; keeps its own
///      vault, config, and blobs so it can't touch the real data.
///   2. Windows:  %APPDATA%\relic                     (unchanged, ships today)
///      macOS:    ~/Library/Application Support/relic (matches relic-cli's
///                dirs::config_dir, so the CLI shim finds the same vault)
///      Linux:    $XDG_DATA_HOME/relic or ~/.local/share/relic — the vault is
///                data (a DB + blobs that can run to GBs), not config; matches
///                relic-cli's dirs::data_dir on Linux (app_paths.rs)
///
/// Before this module, non-Windows fell through to a bare `$HOME/relic`;
/// [appDataDir] migrates that legacy folder once on macOS (guarded so it can
/// never grab an unrelated ~/relic such as a source checkout).

String appDataPath() {
  final override = Platform.environment['RELIC_DATA_DIR'];
  if (override != null && override.isNotEmpty) return override;
  final sep = Platform.pathSeparator;
  if (Platform.isWindows) {
    final base =
        Platform.environment['APPDATA'] ?? Platform.environment['HOME'] ?? '.';
    return '$base${sep}relic';
  }
  final home = Platform.environment['HOME'] ?? '.';
  if (Platform.isMacOS) {
    return '$home${sep}Library${sep}Application Support${sep}relic';
  }
  final xdg = Platform.environment['XDG_DATA_HOME'];
  final base =
      (xdg != null && xdg.isNotEmpty) ? xdg : '$home$sep.local${sep}share';
  return '$base${sep}relic';
}

/// The data directory, created on demand (and legacy-migrated on macOS).
Directory appDataDir() {
  final d = Directory(appDataPath());
  if (!d.existsSync()) {
    _migrateLegacyHomeDir(d);
    if (!d.existsSync()) d.createSync(recursive: true);
  }
  return d;
}

/// Where crash logs live, beside the db: <data>/logs.
String logsPath() => '${appDataPath()}${Platform.pathSeparator}logs';

/// One-shot move of the pre-port `$HOME/relic` data dir into the proper
/// macOS location. Only fires when the old folder unmistakably IS a Relic data
/// dir (has our db/prefs and is not a git checkout named "relic").
void _migrateLegacyHomeDir(Directory dest) {
  if (!Platform.isMacOS) return;
  try {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return;
    final sep = Platform.pathSeparator;
    final legacy = Directory('$home${sep}relic');
    if (!legacy.existsSync()) return;
    if (Directory('${legacy.path}$sep.git').existsSync()) return;
    final looksLikeData =
        File('${legacy.path}${sep}relics.db').existsSync() ||
        File('${legacy.path}${sep}prefs.json').existsSync() ||
        File('${legacy.path}${sep}config.json').existsSync();
    if (!looksLikeData) return;
    dest.parent.createSync(recursive: true);
    legacy.renameSync(dest.path);
  } catch (_) {
    // fall through — a fresh dir is created and the legacy one stays intact
  }
}
