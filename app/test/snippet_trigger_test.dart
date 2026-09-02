// Snippet trigger-boost: a relic tagged `snippet` whose title (its "trigger")
// matches what the user typed is pinned to the top of the picker, ahead of
// whatever the ranking legs found.
//
// The DB half (RelicDb.snippetTriggers) is covered in relic_db_test.dart. The
// half that decides what the user actually sees — LocalDeskRepo._snippetPins,
// and the guards in setQuery that can skip it entirely — had no coverage.
//
// Every case here seeds decoys that match the query LEXICALLY and are NEWER
// than the snippet, so ordinary ranking puts a decoy on top. That way "the
// snippet is first" can only mean the pin fired, which a small vault of
// obviously-matching items cannot tell you.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/widgets/chrome.dart' show Scope;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded =
      sandbox == null || sandbox.toLowerCase().contains('roaming');

  /// A repo where [snippetTitle] is an OLD snippet and 20 newer items all
  /// contain [decoyWord], so the decoys win on both recency and lexical match.
  Future<LocalDeskRepo> seed({
    required String snippetTitle,
    required String decoyWord,
  }) async {
    final repo = LocalDeskRepo();
    await repo.load();
    repo.setMlEnrich(false);
    repo.captureText('88-1234567');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final snip = repo.all.firstWhere((r) => r.content == '88-1234567');
    await repo.updateMeta(snip, title: snippetTitle, userTags: ['snippet']);
    for (var i = 0; i < 20; i++) {
      repo.captureText('$decoyWord $decoyWord filing paperwork note $i');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return repo;
  }

  String? top(LocalDeskRepo repo) =>
      repo.visible.isEmpty ? null : repo.visible.first.title;

  test('typing the start of a snippet title pins it above better matches',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final repo = await seed(snippetTitle: 'EIN Number', decoyWord: 'ein');
    addTearDown(repo.dispose);

    await repo.setQuery('ein', Scope.all);
    expect(top(repo), 'EIN Number',
        reason: 'the trigger prefix must outrank 20 newer literal matches');
  });

  test('a word from the middle of the title does not pin', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final repo =
        await seed(snippetTitle: 'Relic Support Email', decoyWord: 'support');
    addTearDown(repo.dispose);

    // "support" is the word a person would reach for, but the pin matches a
    // prefix of the WHOLE title, so only "rel..." fires it.
    await repo.setQuery('support', Scope.all);
    expect(top(repo), isNot('Relic Support Email'),
        reason: 'documents the prefix-only rule; flip this if it changes');

    await repo.setQuery('relic sup', Scope.all);
    expect(top(repo), 'Relic Support Email',
        reason: 'a prefix of the full title does fire');
  });

  test('under three characters the pin never runs', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final repo = await seed(snippetTitle: 'EIN Number', decoyWord: 'ein');
    addTearDown(repo.dispose);

    // setQuery skips the whole hybrid stage under 3 characters and the pin
    // lives inside it, so a two-letter trigger cannot fire — even though
    // _snippetPins itself would have matched "ei".
    await repo.setQuery('ei', Scope.all);
    expect(top(repo), isNot('EIN Number'));
  });

  test('an active facet chip suppresses the pin', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final repo = await seed(snippetTitle: 'EIN Number', decoyWord: 'ein');
    addTearDown(repo.dispose);
    // A second, newer snippet that matches "ein" literally, so the filtered
    // set still has something to outrank the trigger.
    repo.captureText('ein ein ein ein');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final other = repo.all.firstWhere((r) => r.content == 'ein ein ein ein');
    await repo.updateMeta(other,
        title: 'Ein Paperwork', userTags: ['snippet']);

    // This is the query the picker builds when a chip is on and the user then
    // types: popup.dart joins 'tag:snippet' onto the text. Two things break.
    // setQuery bails out of the hybrid stage on ANY tag: clause, and even if
    // it did not, _snippetPins is handed the raw string with 'tag:snippet'
    // still in it, which no trigger can prefix-match.
    await repo.setQuery('tag:snippet ein', Scope.all);
    expect(repo.visible.map((r) => r.title), contains('EIN Number'),
        reason: 'the lexical path still finds it');
    expect(top(repo), isNot('EIN Number'),
        reason: 'documents the chip+type interaction; flip this when fixed');
  });
}
