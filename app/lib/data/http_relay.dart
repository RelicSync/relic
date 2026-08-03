import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'pairing.dart';

class PairingHttpError implements Exception {
  final int status;
  final String body;
  const PairingHttpError(this.status, this.body);
  @override
  String toString() => 'PairingHttpError($status)';
}

/// The production [PairingRelay]: the Worker's `/pair/*` endpoints over HTTPS
/// (docs/cloudflare/13 §5.5). Blobs ride as base64 in JSON; the channel key is
/// never sent (it lives only in the QR). Drop-in for `MockRelay` — the crypto
/// and orchestrators in pairing.dart are unchanged.
///
/// Polls gently (700ms): the relay is Cloudflare KV, where reads cost and a slot
/// miss can be negatively cached at a colo for up to ~60s, so hammering it is
/// both wasteful and counterproductive.
class HttpRelay implements PairingRelay {
  final String baseUrl;
  final Future<String?> Function() bearer;
  final String deviceId;
  HttpRelay({required this.baseUrl, required this.bearer, required this.deviceId});

  @override
  Duration get pollInterval => const Duration(milliseconds: 700);

  Future<Map<String, String>> _headers({bool json = false}) async {
    final t = await bearer();
    return {
      if (t != null && t.isNotEmpty) 'Authorization': 'Bearer $t',
      'X-Relic-Device': deviceId,
      if (json) 'Content-Type': 'application/json',
    };
  }

  @override
  Future<String> allocate() async {
    final r = await http.post(Uri.parse('$baseUrl/pair/start'),
        headers: await _headers());
    if (r.statusCode != 200) throw PairingHttpError(r.statusCode, r.body);
    return (jsonDecode(r.body) as Map<String, dynamic>)['pairing_id'] as String;
  }

  @override
  Future<void> put(String pairingId, String slot, Uint8List blob) async {
    final r = await http.post(Uri.parse('$baseUrl/pair/offer'),
        headers: await _headers(json: true),
        body: jsonEncode(
            {'pairing_id': pairingId, 'slot': slot, 'blob': base64.encode(blob)}));
    if (r.statusCode != 204 && r.statusCode != 200) {
      throw PairingHttpError(r.statusCode, r.body);
    }
  }

  @override
  Future<Uint8List?> poll(String pairingId, String slot) =>
      _read(pairingId, slot, '/pair/poll');

  @override
  Future<Uint8List?> take(String pairingId, String slot) =>
      _read(pairingId, slot, '/pair/claim');

  Future<Uint8List?> _read(String pairingId, String slot, String path) async {
    final r = await http.get(
        Uri.parse('$baseUrl$path?pairing_id=$pairingId&slot=$slot'),
        headers: await _headers());
    if (r.statusCode == 204) return null;
    if (r.statusCode != 200) throw PairingHttpError(r.statusCode, r.body);
    final b = (jsonDecode(r.body) as Map<String, dynamic>)['blob'] as String?;
    return b == null ? null : Uint8List.fromList(base64.decode(b));
  }
}
