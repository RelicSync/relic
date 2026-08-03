import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/worker_repo.dart';

/// Guards the "a control link got captured as my first relic" bug: the capture
/// trigger reads whatever is on the clipboard, and onboarding puts Relic's own
/// deep links + the recovery kit there. isUncapturable must reject those while
/// still allowing ordinary user content (including normal web links).
void main() {
  group('WorkerRepo.isUncapturable', () {
    test('rejects internal relic:// deep links', () {
      expect(WorkerRepo.isUncapturable('relic://auth-callback?code=abc123'), isTrue);
      expect(WorkerRepo.isUncapturable('relic://capture'), isTrue);
      expect(WorkerRepo.isUncapturable('relic://pair?x=1'), isTrue);
      expect(WorkerRepo.isUncapturable('  RELIC://Auth-Callback  '), isTrue); // trimmed + case
    });

    test('rejects a recovery kit', () {
      const kit = 'relic-mk-v1\nABCD EFGH IJKL MNOP\nQRST UVWX YZ23 4567';
      expect(WorkerRepo.isUncapturable(kit), isTrue);
    });

    test('rejects empty / whitespace', () {
      expect(WorkerRepo.isUncapturable(''), isTrue);
      expect(WorkerRepo.isUncapturable('   \n  '), isTrue);
    });

    test('allows ordinary content, including normal web links', () {
      expect(WorkerRepo.isUncapturable('https://example.com/page'), isFalse);
      expect(WorkerRepo.isUncapturable('kubectl apply -f staging/'), isFalse);
      expect(WorkerRepo.isUncapturable('just some copied text'), isFalse);
    });
  });
}
