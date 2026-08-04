import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/worker_repo.dart';

void main() {
  test('live decrypt against deployed Worker', () async {
    final url = Platform.environment['RELIC_URL'];
    final token = Platform.environment['RELIC_TOKEN'];
    final pass = Platform.environment['RELIC_PASS'];
    if (url == null || token == null || pass == null) {
      markTestSkipped('set RELIC_URL/RELIC_TOKEN/RELIC_PASS');
      return;
    }
    final repo = WorkerRepo(baseUrl: url, token: token, passphrase: pass);
    await repo.load();
    // Deliberate diagnostic output for the live probe.
    // ignore: avoid_print
    print('ACCOUNT: ${repo.account?.footer}');
    // Deliberate diagnostic output for the live probe.
    // ignore: avoid_print
    print('RELICS: ${repo.all.length}');
    for (final r in repo.all.take(8)) {
      // Deliberate diagnostic output for the live probe.
      // ignore: avoid_print
      print(' - ${r.kind.name} | ${r.promoted ? "★ " : ""}${r.displayTitle}');
    }
    expect(repo.all.length, greaterThanOrEqualTo(0));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
