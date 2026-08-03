import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/secure_key_store.dart';

void main() {
  test('scopeFor is deterministic and 32 chars', () {
    final a = SecureKeyStore.scopeFor('https://api.relic.space', 'acct-1');
    final b = SecureKeyStore.scopeFor('https://api.relic.space', 'acct-1');
    final c = SecureKeyStore.scopeFor('https://api.relic.space', 'acct-2');
    expect(a, b);
    expect(a, isNot(c));
    expect(a.length, 32);
  });

  test('mk and refresh slots are distinct and never collide', () {
    final scope = SecureKeyStore.scopeFor('u', 'a');
    expect(SecureKeyStore.mkSlot(scope),
        isNot(SecureKeyStore.refreshSlot(scope)));
    expect(SecureKeyStore.mkSlot(scope), startsWith('relic.vault.mk:'));
    expect(SecureKeyStore.refreshSlot(scope),
        startsWith('relic.session.refresh:'));
  });

  test('MemoryKeyStore round-trips the key and refresh independently', () async {
    final s = MemoryKeyStore();
    final mk = Uint8List.fromList(List.generate(32, (i) => i));
    await s.putMasterKey('sc', mk);
    await s.putRefreshToken('sc', 'rt-123');
    expect(await s.getMasterKey('sc'), mk);
    expect(await s.getRefreshToken('sc'), 'rt-123');

    await s.deleteMasterKey('sc');
    expect(await s.getMasterKey('sc'), isNull);
    expect(await s.getRefreshToken('sc'), 'rt-123'); // independent slot survives
  });
}
