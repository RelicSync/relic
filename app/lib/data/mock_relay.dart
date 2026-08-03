import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'pairing.dart';

/// In-process [PairingRelay] for development and tests. It holds the same
/// zero-knowledge contract the real Cloudflare `/pair/*` relay must hold: it
/// stores only `{opaque blob, expiresAt, consumed}`, never inspects payloads,
/// expires sessions on a TTL, and never serves a consumed slot. Tests must not
/// rely on it doing anything the real relay couldn't.
///
/// Both pairing ends in a test share one [MockRelay] instance. For a real
/// desktop↔desktop demo a `LoopbackRelay` exposes the same map over 127.0.0.1;
/// mobile↔desktop genuinely needs the deployed relay (the phone can't reach the
/// desktop's loopback), so this stays a dev/test seam.
class MockRelay implements PairingRelay {
  static const _ttl = Duration(seconds: 90);
  final _uuid = const Uuid();
  final Map<String, _Session> _sessions = {};

  @override
  Duration get pollInterval => const Duration(milliseconds: 5); // fast for tests

  @override
  Future<String> allocate() async {
    final id = _uuid.v4();
    _sessions[id] = _Session(DateTime.now().add(_ttl));
    return id;
  }

  @override
  Future<void> put(String pairingId, String slot, Uint8List blob) async {
    // Mirror the real relay (KV): any conforming id is writable — a `/pair/offer`
    // to an id the relay has never seen simply creates the session on first
    // write, with the standard TTL. This is what lets a code-derived session
    // (TRUSTED skips `/pair/start`) work over the mock.
    final s = _live(pairingId) ??
        (_sessions[pairingId] = _Session(DateTime.now().add(_ttl)));
    s.slots[slot] = blob;
  }

  @override
  Future<Uint8List?> poll(String pairingId, String slot) async =>
      _live(pairingId)?.slots[slot];

  @override
  Future<Uint8List?> take(String pairingId, String slot) async {
    final s = _live(pairingId);
    if (s == null) return null;
    return s.slots.remove(slot); // single-use
  }

  _Session? _live(String id) {
    final s = _sessions[id];
    if (s == null) return null;
    if (DateTime.now().isAfter(s.expiresAt)) {
      _sessions.remove(id);
      return null;
    }
    return s;
  }

  /// Test hook: force a session to expire now.
  void expire(String pairingId) => _sessions.remove(pairingId);
}

class _Session {
  final DateTime expiresAt;
  final Map<String, Uint8List> slots = {};
  _Session(this.expiresAt);
}
