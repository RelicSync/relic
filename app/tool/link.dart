// One-off: link this machine to a Relic vault without the UI. Reuses the app's
// own crypto so the unwrapped master key is wire-identical to a UI connect.
// Reads RELIC_URL / RELIC_TOKEN / RELIC_PASS from the environment (not argv, so
// the passphrase doesn't land in shell history), then stores secrets in Windows
// Credential Manager and writes non-secret config.json into %APPDATA%\relic\.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:relic_crypto/relic_crypto.dart';
import 'package:relic_app/data/secure_store.dart';

Future<void> main() async {
  final env = Platform.environment;
  final url = (env['RELIC_URL'] ?? '').replaceAll(RegExp(r'/+$'), '');
  final token = env['RELIC_TOKEN'] ?? '';
  final pass = env['RELIC_PASS'] ?? '';
  if (url.isEmpty || token.isEmpty || pass.isEmpty) {
    stderr.writeln('Set RELIC_URL, RELIC_TOKEN, RELIC_PASS.');
    exit(64);
  }

  final auth = {'Authorization': 'Bearer $token'};
  final resp = await http.get(Uri.parse('$url/keyparams'), headers: auth);
  if (resp.statusCode == 401) {
    stderr.writeln('Unauthorized — bad token.');
    exit(2);
  }
  if (resp.statusCode == 404) {
    stderr.writeln('No vault on this account yet (404). Nothing to unwrap.');
    exit(3);
  }
  if (resp.statusCode != 200) {
    stderr.writeln('keyparams GET failed: ${resp.statusCode} ${resp.body}');
    exit(1);
  }

  final mk = await RelicCrypto.unwrapMasterKey(
    jsonDecode(resp.body) as Map<String, dynamic>,
    pass,
  );
  if (mk == null) {
    stderr.writeln('Wrong passphrase for this account.');
    exit(4);
  }

  final base = env['APPDATA'] ?? env['HOME'] ?? '.';
  final dir = Directory('$base${Platform.pathSeparator}relic')
    ..createSync(recursive: true);
  final scope = WindowsSecureStore.syncScope(url, token);
  final stored =
      WindowsSecureStore.writeString(
        WindowsSecureStore.syncDeviceTokenName(scope),
        token,
      ) &&
      WindowsSecureStore.writeBytes(
        WindowsSecureStore.syncMasterKeyName(scope),
        mk,
      );
  if (!stored) {
    stderr.writeln(
      'Could not store sync credentials in Windows Credential Manager.',
    );
    exit(5);
  }
  File('${dir.path}${Platform.pathSeparator}config.json').writeAsStringSync(
    jsonEncode({
      'url': url,
      'credential_scope': scope,
      'token_store': 'credential_manager',
    }),
  );
  final legacyKey = File('${dir.path}${Platform.pathSeparator}key.bin');
  if (legacyKey.existsSync()) legacyKey.deleteSync();
  stdout.writeln(
    'Linked. Stored sync credentials in Windows Credential Manager and wrote config.json to ${dir.path}',
  );
}
