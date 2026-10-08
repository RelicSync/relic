/// Is the phone on Wi-Fi? The one question the model download asks before
/// moving hundreds of megabytes. Wraps connectivity_plus so nothing else
/// in the app imports the plugin, and so the download manager can be fed a
/// plain function and stream in tests.
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class WifiWatch {
  final Connectivity _connectivity = Connectivity();

  /// True on Wi-Fi or a wired connection. A phone on cellular, or with no
  /// network, gets false. If the plugin cannot answer, the answer is false:
  /// better to wait than to spend someone's data plan by mistake.
  Future<bool> isWifi() async {
    try {
      return _unmetered(await _connectivity.checkConnectivity());
    } catch (e) {
      debugPrint('wifi watch: $e');
      return false;
    }
  }

  /// Emits whenever the Wi-Fi answer changes.
  Stream<bool> get changes =>
      _connectivity.onConnectivityChanged.map(_unmetered).distinct();

  static bool _unmetered(List<ConnectivityResult> r) =>
      r.contains(ConnectivityResult.wifi) ||
      r.contains(ConnectivityResult.ethernet);
}
