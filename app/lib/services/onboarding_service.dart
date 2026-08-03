import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../data/api.dart';
import 'package:relic_crypto/relic_crypto.dart';
import '../data/device_directory.dart';
import '../data/http_relay.dart';
import '../data/recovery.dart';
import '../data/supabase_auth.dart';
import '../data/worker_repo.dart';

/// The MK delivered by a pairing peer did not open this account's vault. The UI
/// zeroes the received key, drops the pairing, and lands back on the unlock
/// chooser with [message]. Nothing is persisted; no device is registered.
class PairedKeyMismatch implements Exception {
  const PairedKeyMismatch();
  String get message =>
      "The key sent by your other device doesn't open this account's vault. "
      'Make sure both devices are signed in to the same Relic account, then try again.';
  @override
  String toString() => message;
}

/// Orchestrates the new device-onboarding flow against the real backend, tying
/// together Supabase auth (the session), the vault crypto (the master key), the
/// QR pairing relay, the recovery kit, and the device registry. The onboarding
/// UI talks to this; the heavy lifting (keyparams create/unlock with a
/// passphrase) is delegated to [WorkerRepo]'s existing Supabase path.
class OnboardingService {
  final String baseUrl;
  final String deviceId;
  OnboardingService({this.baseUrl = kWorkerBaseUrl, required this.deviceId});

  Map<String, String> _authHeaders(String token, {bool json = false}) => {
        'Authorization': 'Bearer $token',
        'X-Relic-Device': deviceId,
        if (json) 'Content-Type': 'application/json',
      };

  // --- Path A: create a new vault (first device) -----------------------------

  /// Sign up + create the vault keyparams under [passphrase]. Returns a connected
  /// repo; read [WorkerRepo.masterKey] for the recovery-kit screen.
  Future<WorkerRepo> createVault({
    required String email,
    required String password,
    required String passphrase,
    required String deviceLabel,
    required bool autoVault,
  }) =>
      WorkerRepo.signInSupabase(
        baseUrl: baseUrl,
        email: email,
        password: password,
        passphrase: passphrase,
        signUp: true,
        deviceLabel: deviceLabel,
        autoVault: autoVault,
        deviceId: deviceId,
      );

  // --- Path B: add this device (join) ----------------------------------------

  /// Sign in + unlock with the passphrase (the universal door).
  Future<WorkerRepo> unlockWithPassphrase({
    required String email,
    required String password,
    required String passphrase,
    required String deviceLabel,
    required bool autoVault,
  }) =>
      WorkerRepo.signInSupabase(
        baseUrl: baseUrl,
        email: email,
        password: password,
        passphrase: passphrase,
        signUp: false,
        deviceLabel: deviceLabel,
        autoVault: autoVault,
        deviceId: deviceId,
      );

  /// Sign in only (no vault unlock) — the first half of the QR and recovery-kit
  /// doors, which obtain the master key by other means.
  Future<SupabaseSession> signIn(String email, String password) =>
      SupabaseAuth.signIn(email, password);

  // --- Path C: OAuth (browser) — session already obtained --------------------
  // The OAuth button runs the browser PKCE flow (oauth_flow.dart) to get a
  // [SupabaseSession], then the UI calls hasVault() to route to create-vs-unlock
  // and finishes with one of these session-based binds. Auth != vault key, so a
  // passphrase is still set (create) or entered (unlock) — OAuth only replaces
  // the email/password half.

  /// Does this account already have a vault? (GET /keyparams: 200 = yes → unlock,
  /// 404 = no → create.) Lets the OAuth path auto-route without asking the user.
  Future<bool> hasVault(SupabaseSession session) async {
    final r = await http.get(
      Uri.parse('$baseUrl/keyparams'),
      headers: _authHeaders(session.accessToken),
    );
    if (r.statusCode == 200) return true;
    if (r.statusCode == 404) return false;
    throw StateError('Could not check your account (${r.statusCode}).');
  }

  /// First device via OAuth: create the vault keyparams under [passphrase].
  Future<WorkerRepo> createVaultFromSession({
    required SupabaseSession session,
    required String passphrase,
    required String deviceLabel,
    required bool autoVault,
  }) =>
      WorkerRepo.fromSession(
        baseUrl: baseUrl,
        session: session,
        passphrase: passphrase,
        allowCreate: true,
        deviceLabel: deviceLabel,
        autoVault: autoVault,
        deviceId: deviceId,
      );

  /// Existing account via OAuth: unlock the vault with [passphrase].
  Future<WorkerRepo> unlockWithSession({
    required SupabaseSession session,
    required String passphrase,
    required String deviceLabel,
    required bool autoVault,
  }) =>
      WorkerRepo.fromSession(
        baseUrl: baseUrl,
        session: session,
        passphrase: passphrase,
        allowCreate: false,
        deviceLabel: deviceLabel,
        autoVault: autoVault,
        deviceId: deviceId,
      );

  /// Recovery-kit door: paste the kit, re-wrap the master key under a new
  /// passphrase, and bind a connected repo. The kit IS the raw master key.
  Future<WorkerRepo> unlockWithRecoveryKit({
    required SupabaseSession session,
    required String kitText,
    required String newPassphrase,
    required String deviceLabel,
    required bool autoVault,
  }) async {
    final mk = RecoveryKit.parse(kitText).mk; // throws RecoveryKitException
    final kp = await RelicCrypto.rewrapKeyParams(mk, newPassphrase);
    final put = await http.put(
      Uri.parse('$baseUrl/keyparams?replace=1'),
      headers: _authHeaders(session.accessToken, json: true),
      body: jsonEncode(kp),
    );
    if (put.statusCode != 200) {
      throw StateError('Could not re-wrap the vault key (${put.statusCode}).');
    }
    return WorkerRepo.bindSupabaseWithMk(
      baseUrl: baseUrl,
      session: session,
      mk: mk,
      deviceLabel: deviceLabel,
      autoVault: autoVault,
      deviceId: deviceId,
    );
  }

  /// Decide whether a paired MK is valid, given the observations gathered from
  /// the backend. Pure, so the branch order is unit-testable without HTTP:
  /// - [fpMatch] non-null → definitive (the keyparams carried an `mk_fp`).
  /// - else if [envelopePresent] → valid iff [envelopeOpens] (trial-decrypt).
  /// - else (legacy keyparams AND an empty vault) → accept.
  static bool decidePairedMk({
    bool? fpMatch,
    bool envelopePresent = false,
    bool envelopeOpens = false,
  }) {
    if (fpMatch != null) return fpMatch;
    if (envelopePresent) return envelopeOpens;
    return true;
  }

  /// Constant-time byte compare (no early-out on the first differing byte).
  static bool _ctEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Verify an MK obtained via pairing actually opens this account's vault
  /// BEFORE binding a device to it. Throws [PairedKeyMismatch] otherwise. Reads
  /// only — no keyparams backfill is ever written from the receiving device.
  ///
  /// 1. `GET /keyparams`; if `mk_fp` is present, a constant-time compare is
  ///    definitive. 2. Else `GET /relics?limit=1`; if an envelope exists,
  ///    trial-open it. 3. Else (legacy keyparams AND an empty vault) accept.
  Future<void> verifyPairedMk(SupabaseSession session, Uint8List mk) async {
    final kpResp = await http.get(
      Uri.parse('$baseUrl/keyparams'),
      headers: _authHeaders(session.accessToken),
    );
    bool? fpMatch;
    if (kpResp.statusCode == 200) {
      final kp = jsonDecode(kpResp.body) as Map<String, dynamic>;
      final fp = kp['mk_fp'];
      if (fp is String && fp.isNotEmpty) {
        fpMatch = _ctEq(RelicCrypto.mkFingerprint(mk),
            Uint8List.fromList(base64.decode(fp)));
      }
    }
    var envelopePresent = false;
    var envelopeOpens = false;
    if (fpMatch == null) {
      final rResp = await http.get(
        Uri.parse('$baseUrl/relics?limit=1'),
        headers: _authHeaders(session.accessToken),
      );
      if (rResp.statusCode == 200) {
        final items = (jsonDecode(rResp.body)['items'] as List?) ?? const [];
        if (items.isNotEmpty) {
          envelopePresent = true;
          envelopeOpens = await RelicCrypto.openRelicPayload(
                  mk, items.first as Map<String, dynamic>) !=
              null;
        }
      }
    }
    if (!decidePairedMk(
        fpMatch: fpMatch,
        envelopePresent: envelopePresent,
        envelopeOpens: envelopeOpens)) {
      throw const PairedKeyMismatch();
    }
  }

  /// Bind a connected repo from a master key obtained via QR pairing.
  Future<WorkerRepo> bindFromPairedKey({
    required SupabaseSession session,
    required Uint8List mk,
    required String deviceLabel,
    required bool autoVault,
  }) =>
      WorkerRepo.bindSupabaseWithMk(
        baseUrl: baseUrl,
        session: session,
        mk: mk,
        deviceLabel: deviceLabel,
        autoVault: autoVault,
        deviceId: deviceId,
      );

  // --- pairing relays --------------------------------------------------------

  /// The relay for a NEW device, authed by its just-obtained session.
  HttpRelay relayForSession(SupabaseSession session) => HttpRelay(
        baseUrl: baseUrl,
        bearer: () async => session.accessToken,
        deviceId: deviceId,
      );

  /// The relay for a TRUSTED (already-connected) device, authed by its repo.
  HttpRelay relayForRepo(WorkerRepo repo) => HttpRelay(
        baseUrl: baseUrl,
        bearer: () async => repo.token,
        deviceId: deviceId,
      );

  /// A relay/directory authed by an arbitrary bearer source — lets the pairing
  /// and device-list screens work against any connected repo (desktop or mobile).
  HttpRelay relayWith(Future<String?> Function() bearer) =>
      HttpRelay(baseUrl: baseUrl, bearer: bearer, deviceId: deviceId);

  DeviceDirectory devicesWith(Future<String?> Function() bearer) =>
      DeviceDirectory(baseUrl: baseUrl, bearer: bearer, deviceId: deviceId);

  // --- device registry -------------------------------------------------------

  DeviceDirectory devicesForSession(SupabaseSession session) => DeviceDirectory(
        baseUrl: baseUrl,
        bearer: () async => session.accessToken,
        deviceId: deviceId,
      );

  DeviceDirectory devicesForRepo(WorkerRepo repo) => DeviceDirectory(
        baseUrl: baseUrl,
        bearer: () async => repo.token,
        deviceId: deviceId,
      );
}
