import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Live-sync doorbell client. Holds one WebSocket to the Worker's `/sync/socket`.
///
/// When some other device writes, the server broadcasts a content-free
/// `{"t":"wake"}` nudge and [onWake] fires — the repo then pulls with its own
/// cursor over the normal authenticated `GET /relics`. The socket carries no
/// ciphertext and no payload, so it touches none of the E2E crypto; it only says
/// "pull now". This is what turns the up-to-8s poll lag on the receiving device
/// into a sub-second update.
///
/// It reconnects with capped backoff, re-reads [headers] on every connect (so a
/// rotated bearer is picked up), and pings to keep idle/NAT timeouts open. When a
/// connect fails (self-host has no Durable Object, or the device is offline) it
/// simply leaves [connected] false and the repo stays on its faster poll cadence
/// as the safety net.
class SyncSocket {
  SyncSocket({
    required this.baseUrl,
    required this.headers,
    required this.onWake,
    this.onConnectedChanged,
  });

  /// Current sync base URL (e.g. `https://relic-worker...`). Null/empty → not
  /// connectable yet; the socket keeps retrying.
  final String? Function() baseUrl;

  /// Current auth headers (`Authorization` + `X-Relic-Device`). Re-read per
  /// connect so a refreshed token is used on reconnect.
  final Map<String, String> Function() headers;

  /// Fires (debounced) when the server says "something changed, pull now".
  final void Function() onWake;

  /// Optional: notified when [connected] flips, so the host can widen its poll
  /// while the socket is live and tighten it again when the socket drops.
  final void Function(bool connected)? onConnectedChanged;

  static const _pingEvery = Duration(seconds: 30);
  static const _debounce = Duration(milliseconds: 250);
  static const _maxBackoff = Duration(seconds: 30);

  WebSocket? _ws;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  Timer? _debounceTimer;
  Duration _backoff = const Duration(seconds: 1);
  bool _running = false;
  bool _connected = false;

  bool get connected => _connected;

  void start() {
    if (_running || kIsWeb) return; // web has no dart:io socket → stays on poll
    _running = true;
    _connect();
  }

  Future<void> stop() async {
    _running = false;
    _reconnectTimer?.cancel();
    _debounceTimer?.cancel();
    await _teardownSocket();
    _setConnected(false);
  }

  Future<void> _connect() async {
    if (!_running) return;
    final base = baseUrl();
    if (base == null || base.isEmpty) {
      _scheduleReconnect();
      return;
    }
    try {
      final ws = await WebSocket.connect(wsUrlFor(base), headers: headers());
      if (!_running) {
        await ws.close();
        return;
      }
      _ws = ws;
      _backoff = const Duration(seconds: 1);
      _setConnected(true);
      _sub = ws.listen(
        _onData,
        onDone: _onClosed,
        onError: (Object _) => _onClosed(),
        cancelOnError: true,
      );
      _startPing();
    } catch (_) {
      _setConnected(false);
      _scheduleReconnect();
    }
  }

  void _onData(dynamic _) {
    // Every server frame is a "pull now" nudge (we only ever send wake). Debounce
    // so a burst of writes coalesces into a single pull.
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, onWake);
  }

  void _onClosed() {
    unawaited(_teardownSocket());
    _setConnected(false);
    _scheduleReconnect();
  }

  Future<void> _teardownSocket() async {
    _pingTimer?.cancel();
    _pingTimer = null;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    final ws = _ws;
    _ws = null;
    try {
      await ws?.close();
    } catch (_) {}
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingEvery, (_) {
      try {
        _ws?.add(jsonEncode({'t': 'ping'}));
      } catch (_) {}
    });
  }

  void _scheduleReconnect() {
    if (!_running) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_backoff, _connect);
    final next = _backoff * 2;
    _backoff = next > _maxBackoff ? _maxBackoff : next;
  }

  void _setConnected(bool v) {
    if (_connected == v) return;
    _connected = v;
    onConnectedChanged?.call(v);
  }

  /// `http(s)://host[/base]` → `ws(s)://host[/base]/sync/socket`. Static + pure
  /// so it can be unit-tested without a live socket.
  static String wsUrlFor(String base) {
    var b = base.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (b.startsWith('https://')) {
      b = 'wss://${b.substring('https://'.length)}';
    } else if (b.startsWith('http://')) {
      b = 'ws://${b.substring('http://'.length)}';
    }
    return '$b/sync/socket';
  }
}
