import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One adjustable number in the desktop search ranking.
class TuningKnob {
  const TuningKnob(this.key, this.label, this.help, this.min, this.max,
      {this.step = 0.05});

  final String key;
  final String label;
  final String help;
  final double min;
  final double max;
  final double step;
}

/// Live overrides for the desktop hybrid search ranking, for tuning a new
/// embedding model by feel on a real vault.
///
/// Off unless the app was started with `RELIC_SEARCH_TUNING=1`; then
/// Ctrl+Shift+F9 opens the panel (ui/search_tuning_panel.dart). Each knob
/// starts at the shipped value, which the repo passes in as the fallback, so
/// with no overrides nothing changes. Overrides persist in
/// `search_tuning.json` in the data dir so a tuning session survives a
/// restart. "Copy values" puts them on the clipboard to bake into the code.
class SearchTuning extends ChangeNotifier {
  SearchTuning({bool? enabled})
      : enabled = enabled ??
            Platform.environment['RELIC_SEARCH_TUNING'] == '1';

  final bool enabled;
  final Map<String, double> _over = {};
  File? _file;

  static const List<TuningKnob> knobs = [
    TuningKnob('fts', 'Keyword', 'Weight of exact word matches (bm25).', 0, 4),
    TuningKnob('tri', 'Partial word',
        'Weight of substring and typo matches (trigram).', 0, 3),
    TuningKnob('sem', 'Meaning',
        'Weight of the embedding (semantic) matches.', 0, 4),
    TuningKnob('tag', 'Tag expansion',
        'Weight of items whose tags sit near the query in meaning.', 0, 3),
    TuningKnob('tagIntent', 'Tag named',
        'Weight of items tagged with a word the query literally says.', 0, 4),
    TuningKnob('recency', 'Recency',
        'Weight of the newest-first ordering of all candidates.', 0, 2),
    TuningKnob('kept', 'Kept boost',
        'Score multiplier for kept items in All (tie-break).', 1, 1.5,
        step: 0.01),
    TuningKnob('semFloor', 'Meaning cutoff',
        'Lowest cosine a semantic match may have and still count.', -0.1, 0.6,
        step: 0.01),
    TuningKnob('tagFloor', 'Tag cutoff',
        'Lowest cosine for a query to fire a tag.', -0.1, 0.7, step: 0.01),
    TuningKnob('tagSpread', 'Tag spread',
        'How far below the best tag a second tag may be and still fire.', 0,
        0.3, step: 0.01),
    TuningKnob('rrfK', 'Rank smoothing',
        'RRF k. Lower makes the top ranks of each leg count for more.', 5, 120,
        step: 1),
  ];

  /// The override for [key], or [shipped] when there is none (or tuning is off).
  double value(String key, double shipped) =>
      enabled ? (_over[key] ?? shipped) : shipped;

  bool isOverridden(String key) => _over.containsKey(key);

  Map<String, double> get overrides => Map.unmodifiable(_over);

  void set(String key, double v) {
    _over[key] = v;
    _save();
    notifyListeners();
  }

  void reset([String? key]) {
    if (key == null) {
      _over.clear();
    } else {
      _over.remove(key);
    }
    _save();
    notifyListeners();
  }

  /// Read saved overrides from [file] (no-op when tuning is off).
  void load(File file) {
    if (!enabled) return;
    _file = file;
    try {
      if (file.existsSync()) {
        final j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        j.forEach((k, v) {
          if (v is num) _over[k] = v.toDouble();
        });
      }
    } catch (_) {/* a bad file just means no overrides */}
  }

  void _save() {
    final f = _file;
    if (f == null) return;
    try {
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_over));
    } catch (_) {/* best-effort */}
  }
}
