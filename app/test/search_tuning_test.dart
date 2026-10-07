import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/search_tuning.dart';

void main() {
  test('off: every knob is the shipped value, whatever is saved', () {
    final dir = Directory.systemTemp.createTempSync('tuning-off');
    final f = File('${dir.path}/search_tuning.json')..writeAsStringSync('{"sem": 3.0}');
    final t = SearchTuning(enabled: false)..load(f);
    expect(t.value('sem', 1.0), 1.0);
    dir.deleteSync(recursive: true);
  });

  test('on: overrides win, persist, and reset back to shipped', () {
    final dir = Directory.systemTemp.createTempSync('tuning-on');
    final f = File('${dir.path}/search_tuning.json');
    final t = SearchTuning(enabled: true)..load(f);
    var changes = 0;
    t.addListener(() => changes++);

    expect(t.value('fts', 2.0), 2.0);
    t.set('fts', 1.25);
    t.set('semFloor', 0.2);
    expect(t.value('fts', 2.0), 1.25);
    expect(t.isOverridden('fts'), isTrue);

    final again = SearchTuning(enabled: true)..load(f);
    expect(again.value('fts', 2.0), 1.25);
    expect(again.value('semFloor', 0.22), 0.2);

    t.reset('fts');
    expect(t.value('fts', 2.0), 2.0);
    expect(t.value('semFloor', 0.22), 0.2);
    t.reset();
    expect(t.overrides, isEmpty);
    expect(changes, 4);
    dir.deleteSync(recursive: true);
  });

  test('every knob has a sane range and a unique key', () {
    final keys = SearchTuning.knobs.map((k) => k.key).toSet();
    expect(keys.length, SearchTuning.knobs.length);
    for (final k in SearchTuning.knobs) {
      expect(k.max, greaterThan(k.min), reason: k.key);
      expect(k.step, greaterThan(0), reason: k.key);
    }
  });
}
