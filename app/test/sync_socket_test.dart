import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/sync_socket.dart';

void main() {
  group('SyncSocket.wsUrlFor', () {
    test('https → wss with the /sync/socket path appended', () {
      expect(
        SyncSocket.wsUrlFor('https://relic-worker.example.com'),
        'wss://relic-worker.example.com/sync/socket',
      );
    });

    test('http → ws (self-host / local dev)', () {
      expect(
        SyncSocket.wsUrlFor('http://localhost:8787'),
        'ws://localhost:8787/sync/socket',
      );
    });

    test('trailing slashes are trimmed before appending', () {
      expect(
        SyncSocket.wsUrlFor('https://relic.space///'),
        'wss://relic.space/sync/socket',
      );
    });

    test('a base that already carries a path is preserved', () {
      expect(
        SyncSocket.wsUrlFor('https://host.tld/api'),
        'wss://host.tld/api/sync/socket',
      );
    });

    test('surrounding whitespace is ignored', () {
      expect(
        SyncSocket.wsUrlFor('  https://host.tld  '),
        'wss://host.tld/sync/socket',
      );
    });
  });
}
