import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../models/relic.dart';
import '../widgets/chrome.dart';
import 'file_types.dart';
import 'heuristic_tags.dart'; // detectTags, for the v4 semantic backfill
import 'tag_synonyms.dart'; // tagSearchTerms, indexed into the FTS/trigram body

/// SQLite-backed store for relics with an FTS5 full-text index. Replaces the
/// flat JSON file: writes are incremental (one row, not the whole corpus),
/// search is indexed, and reads are windowed (LIMIT/OFFSET) so the UI never
/// holds the entire corpus in memory. Scales to tens of thousands of relics.
/// The derived text for one relic's FTS + trigram index rows.
///
/// Plain strings only, so it can cross an isolate boundary — that is the whole
/// point of it existing. See [RelicDb.deriveIndexText].
class IndexText {
  final String uid;
  final String named;
  final String body;
  final String aux;
  final String tags;
  final String tri;
  const IndexText({
    required this.uid,
    required this.named,
    required this.body,
    required this.aux,
    required this.tags,
    required this.tri,
  });
}

class RelicDb {
  final Database _db;
  RelicDb._(this._db);

  factory RelicDb.open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('PRAGMA synchronous=NORMAL;');
    _migrate(db);
    return RelicDb._(db);
  }

  /// In-memory DB, for tests.
  factory RelicDb.memory() {
    final db = sqlite3.openInMemory();
    _migrate(db);
    return RelicDb._(db);
  }

  static void _migrate(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS relics (
        uid          TEXT PRIMARY KEY,
        created_at   INTEGER NOT NULL,
        updated_at   INTEGER NOT NULL,
        kind         TEXT NOT NULL,
        source       TEXT NOT NULL,
        promoted     INTEGER NOT NULL DEFAULT 0,
        byte_size    INTEGER NOT NULL DEFAULT 0,
        device       TEXT,
        mime         TEXT,
        filename     TEXT,
        blob_key     TEXT,
        content_hash INTEGER,
        have_blob    INTEGER NOT NULL DEFAULT 0,
        enrich_level INTEGER NOT NULL DEFAULT 0,
        tags         TEXT,
        user_tags    TEXT,
        title        TEXT,
        note         TEXT,
        content      TEXT,
        preview      TEXT
      );
    ''');
    // Add columns introduced after the first schema, for DBs created earlier.
    _ensureColumn(db, 'have_blob', 'INTEGER NOT NULL DEFAULT 0');
    _ensureColumn(db, 'enrich_level', 'INTEGER NOT NULL DEFAULT 0');
    _ensureColumn(db, 'attachments', 'TEXT'); // JSON manifest for bundle blobs
    // Machine tags the user explicitly removed — enrichment must not re-add
    // them. Local-only, like enrich_level (upsert never touches it).
    _ensureColumn(db, 'suppressed_tags', 'TEXT');
    // Text extracted from a relic's ATTACHMENTS (a note's bundled PDF etc.),
    // indexed into the FTS body so the note is findable by what its files
    // say. Local-only; each device re-extracts deterministically.
    _ensureColumn(db, 'attachment_text', 'TEXT');
    // Usage frecency (cornerstone ranking): a decaying touch counter + its
    // last-touch stamp — see [recordUse]. Local-only like enrich_level (the
    // sync upsert never writes them, recordUse never queues a push), so the
    // wire format is untouched and each device ranks by its own habits.
    _ensureColumn(db, 'use_count', 'REAL NOT NULL DEFAULT 0');
    _ensureColumn(db, 'last_used_at', 'INTEGER');
    // Account-switch HOLDBACK. NULL for every ordinary row. When the user signs
    // into a different account than this vault last synced with, the existing
    // rows are stamped with the PREVIOUS identity ('supabase:<sub>' /
    // 'legacy:<scope>', or the 'previous-account' sentinel for pre-holdback
    // installs) instead of being uploaded — see the 2026-07-14 leak. A held row
    // is invisible to every normal read path (list, search, counts, sync push,
    // capture dedupe, retention) until the user decides in Settings; signing
    // back into that account releases exactly its own rows. Local-only: the
    // wire format never carries it, and `upsert` never writes it, so a pull
    // that re-touches a held row cannot un-hide it.
    _ensureColumn(db, 'held_by', 'TEXT');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_relics_held ON relics(held_by) '
      'WHERE held_by IS NOT NULL;',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_relics_created ON relics(created_at DESC);',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_relics_promoted ON relics(promoted, created_at DESC);',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_relics_chash ON relics(content_hash);',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_relics_photo ON relics(kind, have_blob) WHERE blob_key IS NOT NULL;',
    );
    // Standalone FTS index (we keep it in sync manually on every write). The
    // Porter stemmer matches word-forms (handwritten ~ handwriting), which is
    // especially useful for the machine `tags` column. Columns: `named` is
    // what the user deliberately called the relic (title/note/filename),
    // `body` the rest of its literal text, `aux` the injected concept terms
    // (synonyms, type words, domain nouns), `tags` the literal tag words —
    // kept separate so bm25 can weight a name above body text above injected
    // vocabulary.
    db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS relics_fts USING fts5(
        uid UNINDEXED, named, body, aux, tags, tokenize = 'porter unicode61'
      );
    ''');
    // Trigram index for substring matching ("kuber" finds "kubernetes") and —
    // via the per-word trigram expansion in [trigramCandidates] — fuzzy typo
    // recall ("kubernetse" shares most trigrams with "kubernetes").
    db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS relics_tri USING fts5(
        uid UNINDEXED, body, tokenize = 'trigram'
      );
    ''');
    // Document embeddings for semantic / hybrid search (f32 blob per chunk;
    // chunk 0 is the whole-doc vector, further rows cover long documents).
    db.execute('''
      CREATE TABLE IF NOT EXISTS vectors (
        uid TEXT NOT NULL, chunk INTEGER NOT NULL DEFAULT 0,
        dim INTEGER NOT NULL, vec BLOB NOT NULL,
        PRIMARY KEY (uid, chunk)
      );
    ''');
    // AI records: the generated title + tags for a relic, as produced by
    // whichever device ran the models. Synced, but NOT through the relic
    // envelope — see worker/src/ai.ts. A relic push is rejected unless it
    // advances updated_at, so folding AI output into it would make every
    // background tagging pass look like a user edit and reorder the vault.
    //
    // A table of its own rather than columns on `relics`, because an AI record
    // and its relic arrive on independent cursors and either order is normal.
    // Keyed by uid with no foreign key, so a record that lands first simply
    // waits for its relic instead of being dropped on the floor.
    //
    // `pushed` IS the outbound queue: 0 means this device generated the record
    // and still owes it to the server.
    db.execute('''
      CREATE TABLE IF NOT EXISTS ai_records (
        uid      TEXT PRIMARY KEY,
        ai_at    INTEGER NOT NULL,
        ai_level INTEGER NOT NULL,
        ai_by    TEXT,
        title    TEXT,
        tags     TEXT,
        ai_text  TEXT,
        att_text TEXT,
        pushed   INTEGER NOT NULL DEFAULT 0
      );
    ''');
    // The text columns arrived after the table did. No user_version bump: the
    // table is young enough that the only databases without them are
    // development ones, and an added nullable column needs no backfill.
    final aiCols = db
        .select('PRAGMA table_info(ai_records)')
        .map((r) => r['name'] as String)
        .toSet();
    for (final c in ['ai_text', 'att_text']) {
      if (!aiCols.contains(c)) {
        db.execute('ALTER TABLE ai_records ADD COLUMN $c TEXT');
      }
    }
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ai_unpushed ON ai_records(pushed) WHERE pushed = 0;',
    );
    // The open-vocabulary tag vocabulary (see relic-sift/src/tag_vocab.rs).
    // ONE ROW PER DISTINCT EMITTED STRING, aliases included — `canonical` is
    // the representative its group snapped onto, and equals `tag` for a
    // representative. Storing aliases is not optional: the periodic reconcile
    // re-derives the whole grouping in frequency order and is a silent no-op
    // if it only ever sees representatives.
    //
    // Local-only and fully rebuildable from relics.tags, so it never syncs.
    db.execute('''
      CREATE TABLE IF NOT EXISTS tag_vocab (
        tag       TEXT PRIMARY KEY,
        canonical TEXT NOT NULL,
        count     INTEGER NOT NULL DEFAULT 0,
        dim       INTEGER NOT NULL DEFAULT 0,
        vec       BLOB
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tag_vocab_canonical ON tag_vocab(canonical)',
    );
    db.execute('''
      CREATE TABLE IF NOT EXISTS pending_ops (
        uid TEXT NOT NULL,
        op TEXT NOT NULL CHECK (op IN ('push','delete')),
        queued_at INTEGER NOT NULL,
        PRIMARY KEY (uid, op)
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS sync_rejections (
        uid TEXT NOT NULL,
        op TEXT NOT NULL CHECK (op IN ('push','delete')),
        status INTEGER NOT NULL,
        rejected_at INTEGER NOT NULL,
        PRIMARY KEY (uid, op)
      );
    ''');
    // Personalized-ranking memory (local-only, never synced; see
    // [recordQueryPick] / [recordContextPick]). query_memory: "searching
    // <term>, the user picked <uid>" — the VS Code picker / Kupfer mnemonics
    // pattern. context_memory: "summoned over <app>, the user picked <uid>
    // / an item tagged <tag>". Both hold decaying counters like use_count.
    db.execute('''
      CREATE TABLE IF NOT EXISTS query_memory (
        term TEXT NOT NULL, uid TEXT NOT NULL,
        count REAL NOT NULL, last_at INTEGER NOT NULL,
        PRIMARY KEY (term, uid)
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS context_memory (
        app TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('uid','tag')),
        key TEXT NOT NULL,
        count REAL NOT NULL, last_at INTEGER NOT NULL,
        PRIMARY KEY (app, kind, key)
      );
    ''');
    // Clip reminders (local-only, never synced — the `upsert` wire column list
    // and `pending_ops` never reference this table, so it stays off the wire
    // like query_memory/context_memory). `remind_at` is epoch MILLISECONDS
    // (DateTime.now().millisecondsSinceEpoch), self-contained and independent of
    // the repo's seconds-based `_now`.
    db.execute('''
      CREATE TABLE IF NOT EXISTS reminders (
        id INTEGER PRIMARY KEY,
        relic_uid TEXT NOT NULL,
        remind_at INTEGER NOT NULL,
        note TEXT,
        fired INTEGER NOT NULL DEFAULT 0
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS reminders_due '
      'ON reminders (fired, remind_at);',
    );
    // (The old raw-SQL trigram backfill lived here; the uv<7 migration's
    // _reindexAll now rebuilds relics_tri through _triText — folded, no JSON
    // tag arrays — so a separate backfill would only write an inconsistent
    // index.)
    _migrateFileTypes(db);
  }

  /// Rebuild the FTS + trigram rows for every relic from the current `relics`
  /// table (used after a migration changes tags/preview or the body recipe).
  /// Recreates both virtual tables with the CURRENT canonical schema first, so
  /// every migration step (old ones included) converges on the same shape.
  static void _reindexAll(Database db) {
    db.execute('DROP TABLE IF EXISTS relics_fts');
    db.execute('''
      CREATE VIRTUAL TABLE relics_fts USING fts5(
        uid UNINDEXED, named, body, aux, tags, tokenize = 'porter unicode61'
      );
    ''');
    db.execute('DROP TABLE IF EXISTS relics_tri');
    db.execute('''
      CREATE VIRTUAL TABLE relics_tri USING fts5(
        uid UNINDEXED, body, tokenize = 'trigram'
      );
    ''');
    for (final rs in db.select('SELECT * FROM relics')) {
      final r = _toRelic(rs);
      final att = (rs['attachment_text'] as String?) ?? '';
      _writeIndexRows(db, r, att);
    }
  }

  /// Write the FTS + trigram rows for [r] (delete-then-insert, so it serves
  /// both first index and reindex). THE one place the index recipe lives —
  /// upsert, per-row reindex, and the full rebuild all route through it.
  ///
  /// `named` is a BONUS column, not a partition: names are indexed in body
  /// too, so the v7-calibrated body ranking is untouched and a name hit adds
  /// score on top. It cannot be a partition — bm25's per-column length
  /// normalization computes avgdl over ALL rows, and most relics have no
  /// name, so a sparse named-only column makes any real name look "long"
  /// and penalizes exactly the hits it exists to reward.
  static void _writeIndexRows(Database db, Relic r, String att) {
    db.execute('DELETE FROM relics_fts WHERE uid = ?', [r.uid]);
    db.execute(
        'INSERT INTO relics_fts (uid, named, body, aux, tags) VALUES (?,?,?,?,?)',
        [
          r.uid,
          _namedText(r),
          '${_bodyText(r)} ${_namedText(r)} $att',
          _auxText(r),
          _tagText(r),
        ]);
    db.execute('DELETE FROM relics_tri WHERE uid = ?', [r.uid]);
    db.execute('INSERT INTO relics_tri (uid, body) VALUES (?,?)', [
      r.uid,
      _triText(r, att),
    ]);
  }

  /// Versioned one-time migrations for file relics. Local-only (not pushed), so
  /// peers update lazily on the next touch.
  ///  - v1: retag with friendly extension chips (drop generic file/archive/
  ///    binary) and reindex so files are findable by type ("blender").
  ///  - v2: restore the filename as a file's headline (older enrichment had
  ///    renamed files to the first line of their extracted text) and strip
  ///    content-shape tags (code/json/markdown) that are noise on a document.
  static void _migrateFileTypes(Database db) {
    var uv = (db.select('PRAGMA user_version').first.values.first as int?) ?? 0;
    if (uv < 1) {
      const genericFileTags = {'file', 'archive', 'binary'};
      db.execute('BEGIN');
      try {
        for (final row in db.select(
          "SELECT uid, filename, tags FROM relics WHERE kind = 'file'",
        )) {
          final chips = fileTypeChips(row['filename'] as String?);
          if (chips.isEmpty) continue;
          final merged = <String>[];
          for (final t in [...chips, ..._jsonList(row['tags'])]) {
            if (genericFileTags.contains(t.toLowerCase())) continue;
            if (!merged.contains(t)) merged.add(t);
          }
          db.execute('UPDATE relics SET tags = ? WHERE uid = ?', [
            jsonEncode(merged),
            row['uid'],
          ]);
        }
        _reindexAll(db);
        db.execute('PRAGMA user_version = 1');
        db.execute('COMMIT');
        uv = 1;
      } catch (_) {
        db.execute('ROLLBACK');
        return;
      }
    }
    if (uv < 2) {
      const contentShapeTags = {'code', 'json', 'markdown'};
      db.execute('BEGIN');
      try {
        for (final row in db.select(
          "SELECT uid, filename, tags FROM relics WHERE kind = 'file'",
        )) {
          final cleaned = _jsonList(row['tags'])
              .where((t) => !contentShapeTags.contains(t.toLowerCase()))
              .toList();
          db.execute('UPDATE relics SET preview = ?, tags = ? WHERE uid = ?', [
            row['filename'], // headline reverts to the filename
            jsonEncode(cleaned),
            row['uid'],
          ]);
        }
        _reindexAll(db);
        db.execute('PRAGMA user_version = 2');
        db.execute('COMMIT');
      } catch (_) {
        // Leave this version un-stamped and STOP: letting a later block run
        // (and stamp its higher version) would permanently skip this one, and
        // runtime writes against a half-migrated schema would fail loudly.
        db.execute('ROLLBACK');
        return;
      }
    }
    if (uv < 3) {
      // Switch the FTS tokenizer to Porter (stemming). The table was created
      // with the old tokenizer on existing DBs, so recreate + reindex it.
      db.execute('BEGIN');
      try {
        db.execute('DROP TABLE IF EXISTS relics_fts');
        db.execute('''
          CREATE VIRTUAL TABLE relics_fts USING fts5(
            uid UNINDEXED, body, tags, tokenize = 'porter unicode61'
          );
        ''');
        _reindexAll(db);
        db.execute('PRAGMA user_version = 3');
        db.execute('COMMIT');
      } catch (_) {
        // Leave this version un-stamped and STOP: letting a later block run
        // (and stamp its higher version) would permanently skip this one, and
        // runtime writes against a half-migrated schema would fail loudly.
        db.execute('ROLLBACK');
        return;
      }
    }
    if (uv < 4) {
      // Backfill the new semantic/number categories on existing text relics,
      // and (via _reindexAll + the new _bodyText recipe) index tag synonyms for
      // ALL relics. ADD-only for the new categories; the migration has no
      // maskSecrets pref, so it must NEVER add or remove secret-class tags —
      // the `newCats` filter excludes them, preserving each row's capture-time
      // decision verbatim.
      const newCats = {
        'number', 'currency', 'percent', 'duration', 'time', 'measurement',
        'handle', 'hashtag',
      };
      db.execute('BEGIN');
      try {
        for (final row in db.select(
          "SELECT uid, tags, content, title, preview FROM relics WHERE kind = 'string'",
        )) {
          final text = (row['content'] as String?) ??
              (row['title'] as String?) ??
              (row['preview'] as String?) ??
              '';
          if (text.isEmpty) continue;
          final detected = detectTags(text); // pure; applies `number` precedence
          final merged = _jsonList(row['tags']);
          var changed = false;
          for (final t in detected) {
            if (newCats.contains(t) && !merged.contains(t)) {
              merged.add(t);
              changed = true;
            }
          }
          if (changed) {
            db.execute('UPDATE relics SET tags = ? WHERE uid = ?', [
              jsonEncode(merged),
              row['uid'],
            ]);
          }
        }
        _reindexAll(db);
        db.execute('PRAGMA user_version = 4');
        db.execute('COMMIT');
      } catch (_) {
        // Leave this version un-stamped and STOP: letting a later block run
        // (and stamp its higher version) would permanently skip this one, and
        // runtime writes against a half-migrated schema would fail loudly.
        db.execute('ROLLBACK');
        return;
      }
    }
    if (uv < 5) {
      // Reindex so the in-prose entity terms (embedded links/emails) added to
      // the `_bodyText` recipe reach relics captured before this — makes a
      // github URL sitting inside a snippet findable by "link". Pure reindex.
      db.execute('BEGIN');
      try {
        _reindexAll(db);
        db.execute('PRAGMA user_version = 5');
        db.execute('COMMIT');
      } catch (_) {
        // Leave this version un-stamped and STOP: letting a later block run
        // (and stamp its higher version) would permanently skip this one, and
        // runtime writes against a half-migrated schema would fail loudly.
        db.execute('ROLLBACK');
        return;
      }
    }
    if (uv < 6) {
      // Backfill the new detector categories (books/papers/iban/tables/tickets/
      // …) on existing text relics, and — via _reindexAll + the extended
      // _bodyText recipe — index the expanded synonyms + domain→noun terms for
      // ALL relics. ADD-only; NEVER touches secret-class: `secret`/`jwt` are
      // excluded from `newCats`, so an old SSN gains `ssn` (findable) but is not
      // retroactively masked — capture-time masking decisions are preserved,
      // exactly as in the v4 step.
      const newCats = {
        'doi', 'arxiv', 'orcid', 'paper', 'iban', 'bank', 'ssn', 'vin',
        'vehicle', 'postcode', 'base64', 'geo', 'location', 'table', 'csv',
        'markdown', 'isbn', 'book', 'swift', 'commit', 'port', 'hexdump', 'env',
        'math', 'ticket', 'routing', 'coupon', 'color', 'currency',
      };
      db.execute('BEGIN');
      try {
        for (final row in db.select(
          "SELECT uid, tags, content, title, preview FROM relics WHERE kind = 'string'",
        )) {
          final text = (row['content'] as String?) ??
              (row['title'] as String?) ??
              (row['preview'] as String?) ??
              '';
          if (text.isEmpty) continue;
          final detected = detectTags(text); // pure; secret decisions unused here
          final merged = _jsonList(row['tags']);
          var changed = false;
          for (final t in detected) {
            if (newCats.contains(t) && !merged.contains(t)) {
              merged.add(t);
              changed = true;
            }
          }
          if (changed) {
            db.execute('UPDATE relics SET tags = ? WHERE uid = ?', [
              jsonEncode(merged),
              row['uid'],
            ]);
          }
        }
        _reindexAll(db);
        db.execute('PRAGMA user_version = 6');
        db.execute('COMMIT');
      } catch (_) {
        // Leave this version un-stamped and STOP: letting a later block run
        // (and stamp its higher version) would permanently skip this one, and
        // runtime writes against a half-migrated schema would fail loudly.
        db.execute('ROLLBACK');
        return;
      }
    }
    if (uv < 7) {
      // Search-quality overhaul: (a) split the FTS body into literal `body` +
      // injected `aux` (synonyms/type words/domain nouns) so bm25 can weight
      // literal content above injected vocabulary — _reindexAll recreates the
      // virtual tables with the new shape; (b) key `vectors` by (uid, chunk)
      // so long documents can store one embedding per chunk. Existing vectors
      // migrate as chunk 0.
      db.execute('BEGIN');
      try {
        final vcols = db
            .select('PRAGMA table_info(vectors)')
            .map((r) => r['name'] as String)
            .toSet();
        if (!vcols.contains('chunk')) {
          db.execute('ALTER TABLE vectors RENAME TO vectors_old');
          db.execute('''
            CREATE TABLE vectors (
              uid TEXT NOT NULL, chunk INTEGER NOT NULL DEFAULT 0,
              dim INTEGER NOT NULL, vec BLOB NOT NULL,
              PRIMARY KEY (uid, chunk)
            );
          ''');
          db.execute(
            'INSERT INTO vectors (uid, chunk, dim, vec) '
            'SELECT uid, 0, dim, vec FROM vectors_old',
          );
          db.execute('DROP TABLE vectors_old');
        }
        _reindexAll(db);
        db.execute('PRAGMA user_version = 7');
        db.execute('COMMIT');
      } catch (_) {
        // Leave this version un-stamped and STOP: letting a later block run
        // (and stamp its higher version) would permanently skip this one, and
        // runtime writes against a half-migrated schema would fail loudly.
        db.execute('ROLLBACK');
        return;
      }
    }
    if (uv < 8) {
      // The value-shape detectors (currency/percent/duration/time/measurement/
      // number/handle/hashtag/color) are now gated to naked/near-naked values —
      // a 200k-char transcript that mentions one "30%" is a transcript, not a
      // `percent`. Strip the stale tags earlier backfills left behind.
      // REMOVE-only, and ONLY this tag class: secret-class and every other tag
      // is untouched, and a tag stays whenever the detector still fires.
      const valueShape = {
        'currency', 'percent', 'duration', 'time', 'measurement', 'number',
        'handle', 'hashtag', 'color',
      };
      db.execute('BEGIN');
      try {
        for (final row in db.select(
          'SELECT uid, tags, content, title, preview FROM relics',
        )) {
          final tags = _jsonList(row['tags']);
          if (!tags.any(valueShape.contains)) continue;
          final text = (row['content'] as String?) ??
              (row['title'] as String?) ??
              (row['preview'] as String?) ??
              '';
          final detected =
              text.isEmpty ? const <String>{} : detectTags(text).toSet();
          final cleaned = [
            for (final t in tags)
              if (!valueShape.contains(t) || detected.contains(t)) t,
          ];
          if (cleaned.length != tags.length) {
            db.execute('UPDATE relics SET tags = ? WHERE uid = ?', [
              jsonEncode(cleaned),
              row['uid'],
            ]);
          }
        }
        _reindexAll(db);
        db.execute('PRAGMA user_version = 8');
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        return;
      }
    }
    if (uv < 9) {
      // Reconcile stored detector tags with the CURRENT detectors, which
      // gained both precision (bounded sql, 2-digit tickets, octet-checked ip,
      // gated value shapes — the classes v8 didn't sweep) and recall (kubectl
      // commands, bare-domain urls, whole-value cleanup of invisible chars).
      // Strip detector-vocabulary tags that no longer fire and merge ones that
      // newly do — ONLY within kDetectorTags (sift ML tags, extension chips,
      // capture seeds, and source-app tags belong to other producers).
      // Secret-class is one-way: never removed here, and never ADDED either
      // (capture-time masking decisions are preserved, exactly as in v4/v6).
      // Additions honor the user's suppressed_tags.
      db.execute('BEGIN');
      try {
        for (final row in db.select(
          'SELECT uid, tags, suppressed_tags, content, title, preview '
          "FROM relics WHERE kind = 'string'",
        )) {
          final text = (row['content'] as String?) ??
              (row['title'] as String?) ??
              (row['preview'] as String?) ??
              '';
          if (text.isEmpty) continue;
          final tags = _jsonList(row['tags']);
          final suppressed = _jsonList(row['suppressed_tags']).toSet();
          final detected = detectTags(text).toSet();
          final next = <String>[
            for (final t in tags)
              if (!kDetectorTags.contains(t) ||
                  detected.contains(t) ||
                  t == 'secret' ||
                  t == 'jwt')
                t,
            for (final t in detected)
              if (!tags.contains(t) &&
                  t != 'secret' &&
                  t != 'jwt' &&
                  !suppressed.contains(t))
                t,
          ];
          if (jsonEncode(next) != jsonEncode(tags)) {
            db.execute('UPDATE relics SET tags = ? WHERE uid = ?', [
              jsonEncode(next),
              row['uid'],
            ]);
          }
        }
        _reindexAll(db);
        db.execute('PRAGMA user_version = 9');
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        return;
      }
    }
    if (uv < 10) {
      // Finish the reconcile for non-string relics: (a) REMOVE-only sweep of
      // detector tags the current detectors no longer find in the extracted
      // text (stale OCR-era false positives — the ADD side stays gated in the
      // enrichment path, which owns blob-relic tagging); (b) case-insensitive
      // dedupe of stored tags, first occurrence wins (an extension chip
      // 'Markdown' and detector 'markdown' coexisted on old rows). Never
      // touches secret-class.
      db.execute('BEGIN');
      try {
        for (final row in db.select(
          'SELECT uid, kind, tags, content, title, preview FROM relics',
        )) {
          final tags = _jsonList(row['tags']);
          if (tags.isEmpty) continue;
          var next = tags;
          if ((row['kind'] as String?) != 'string') {
            final text = (row['content'] as String?) ??
                (row['title'] as String?) ??
                (row['preview'] as String?) ??
                '';
            final detected =
                text.isEmpty ? const <String>{} : detectTags(text).toSet();
            next = [
              for (final t in next)
                if (!kDetectorTags.contains(t) ||
                    detected.contains(t) ||
                    t == 'secret' ||
                    t == 'jwt')
                  t,
            ];
          }
          final seen = <String>{};
          next = [
            for (final t in next)
              if (seen.add(t.toLowerCase())) t,
          ];
          if (jsonEncode(next) != jsonEncode(tags)) {
            db.execute('UPDATE relics SET tags = ? WHERE uid = ?', [
              jsonEncode(next),
              row['uid'],
            ]);
          }
        }
        _reindexAll(db);
        db.execute('PRAGMA user_version = 10');
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        return;
      }
    }
    if (uv < 11) {
      // v11: add the `named` BONUS column (title/note/filename/attachment
      // names, also still in body) weighted ABOVE body (see kFtsRank), so
      // deliberate annotation ranks first. Pure reindex — _reindexAll
      // recreates the canonical 5-column schema and re-derives every row.
      db.execute('BEGIN');
      try {
        _reindexAll(db);
        db.execute('PRAGMA user_version = 11');
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        return;
      }
    }
  }

  static void _ensureColumn(Database db, String col, String decl) {
    final cols = db
        .select('PRAGMA table_info(relics)')
        .map((r) => r['name'] as String);
    if (!cols.contains(col)) {
      db.execute('ALTER TABLE relics ADD COLUMN $col $decl');
    }
  }

  void dispose() => _db.dispose();

  // --- writes (incremental) ---

  /// Insert a relic (or update it in place) plus its FTS row, atomically.
  /// `have_blob` is set only on first insert; conflict updates leave it alone
  /// (so editing/merging a relic never forgets that its bytes are already
  /// local). Use [markBlobLocal] to flip it after a download.
  void upsert(Relic r, {bool haveBlob = false, bool queuePush = false}) {
    _db.execute('BEGIN');
    try {
      _db.execute(
        '''INSERT INTO relics
           (uid, created_at, updated_at, kind, source, promoted, byte_size,
            device, mime, filename, blob_key, content_hash, have_blob,
            tags, user_tags, title, note, content, preview, attachments)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(uid) DO UPDATE SET
             created_at=excluded.created_at, updated_at=excluded.updated_at,
             kind=excluded.kind, source=excluded.source, promoted=excluded.promoted,
             byte_size=excluded.byte_size, device=excluded.device, mime=excluded.mime,
             filename=excluded.filename, blob_key=excluded.blob_key,
             content_hash=excluded.content_hash, tags=excluded.tags,
             user_tags=excluded.user_tags, title=excluded.title, note=excluded.note,
             content=excluded.content, preview=excluded.preview,
             attachments=excluded.attachments''',
        [
          r.uid,
          r.createdAt,
          r.updatedAt,
          kindToStr(r.kind),
          r.source.name,
          r.promoted ? 1 : 0,
          r.byteSize,
          r.device,
          r.mime,
          r.filename,
          r.blobKey,
          r.content == null ? null : _hash(r.content!),
          haveBlob ? 1 : 0,
          jsonEncode(r.tags),
          jsonEncode(r.userTags),
          r.title,
          r.note,
          r.content,
          r.preview,
          r.attachments.isEmpty
              ? null
              : jsonEncode(Attachment.listToJson(r.attachments)),
        ],
      );
      final attRs = _db.select(
        'SELECT attachment_text FROM relics WHERE uid = ?',
        [r.uid],
      );
      final att = attRs.isEmpty
          ? ''
          : (attRs.first['attachment_text'] as String?) ?? '';
      _writeIndexRows(_db, r, att);
      if (queuePush) _queueOpInTxn(r.uid, 'push', r.updatedAt);
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Load a whole corpus into a FRESH database in one pass.
  ///
  /// [upsert] is correct per relic but expensive per relic: it opens its own
  /// transaction and re-prepares roughly eight statements from SQL text on
  /// every call. The mobile launch builds its entire search index that way, and
  /// on a real vault that measured 6.1 SECONDS — the single largest cost in the
  /// whole launch, dwarfing everything else put together.
  ///
  /// This does the same work with one transaction and three prepared statements
  /// reused across every row. It also drops two things [upsert] must do but a
  /// fresh load cannot need: the delete-then-insert on the index tables (there
  /// is nothing to delete) and the `attachment_text` read-back (only ever
  /// written later, by [setAttachmentText], so it is always NULL here).
  ///
  /// Precondition: the database holds no rows for these uids. That is true of
  /// the [RelicDb.memory] instance the mobile index is built into. Use [upsert]
  /// for anything incremental.
  /// Every string the index tables need for one relic, already derived.
  ///
  /// Deriving these is the ENTIRE cost of building the mobile search index —
  /// benchmarked at 1000 relics of 3KB: 2900ms total, of which 2658ms is
  /// [_auxText] (its in-prose scanners run a dozen regexes over the body) and
  /// only ~70ms is SQLite. The database can't leave the main isolate, but this
  /// can: it's pure string work over plain data. See [deriveIndexText].
  static List<IndexText> deriveIndexText(List<Relic> relics) =>
      [for (final r in relics) _deriveOne(r)];

  static IndexText _deriveOne(Relic r) {
    final named = _namedText(r);
    return IndexText(
      uid: r.uid,
      named: named,
      body: '${_bodyText(r)} $named ',
      aux: _auxText(r),
      tags: _tagText(r),
      tri: _triText(r, ''),
    );
  }

  /// [derived] supplies precomputed [IndexText] by uid (see [deriveIndexText]),
  /// letting the caller do the expensive half on another isolate. Any relic
  /// missing from the map is derived inline, so a partial map is safe.
  void bulkLoad(
    Iterable<Relic> relics, {
    bool Function(Relic)? haveBlob,
    Map<String, IndexText>? derived,
  }) {
    final ins = _db.prepare(
      '''INSERT OR REPLACE INTO relics
         (uid, created_at, updated_at, kind, source, promoted, byte_size,
          device, mime, filename, blob_key, content_hash, have_blob,
          tags, user_tags, title, note, content, preview, attachments)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
    );
    final fts = _db.prepare(
      'INSERT INTO relics_fts (uid, named, body, aux, tags) VALUES (?,?,?,?,?)',
    );
    final tri = _db.prepare(
      'INSERT INTO relics_tri (uid, body) VALUES (?,?)',
    );
    _db.execute('BEGIN');
    try {
      for (final r in relics) {
        ins.execute([
          r.uid,
          r.createdAt,
          r.updatedAt,
          kindToStr(r.kind),
          r.source.name,
          r.promoted ? 1 : 0,
          r.byteSize,
          r.device,
          r.mime,
          r.filename,
          r.blobKey,
          r.content == null ? null : _hash(r.content!),
          (haveBlob?.call(r) ?? false) ? 1 : 0,
          jsonEncode(r.tags),
          jsonEncode(r.userTags),
          r.title,
          r.note,
          r.content,
          r.preview,
          r.attachments.isEmpty
              ? null
              : jsonEncode(Attachment.listToJson(r.attachments)),
        ]);
        // Same recipe as _writeIndexRows, minus the deletes. Kept in step with
        // it by relic_db_test's bulk-vs-upsert equivalence test.
        final d = derived?[r.uid] ?? _deriveOne(r);
        fts.execute([r.uid, d.named, d.body, d.aux, d.tags]);
        tri.execute([r.uid, d.tri]);
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      ins.dispose();
      fts.dispose();
      tri.dispose();
    }
  }

  void delete(String uid) {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM relics WHERE uid = ?', [uid]);
      _db.execute('DELETE FROM relics_fts WHERE uid = ?', [uid]);
      _db.execute('DELETE FROM relics_tri WHERE uid = ?', [uid]);
      _db.execute('DELETE FROM vectors WHERE uid = ?', [uid]);
      // The AI record dies with its relic, exactly as it does on the server.
      // Leaving it would let a re-created uid inherit a stranger's title.
      _db.execute('DELETE FROM ai_records WHERE uid = ?', [uid]);
      _deletePersonalRowsInTxn(uid);
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void deleteAndQueue(String uid, int deletedAt, {bool queueDelete = false}) {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM pending_ops WHERE uid = ? AND op = ?', [
        uid,
        'push',
      ]);
      _db.execute('DELETE FROM sync_rejections WHERE uid = ? AND op = ?', [
        uid,
        'push',
      ]);
      if (queueDelete) _queueOpInTxn(uid, 'delete', deletedAt);
      _db.execute('DELETE FROM relics WHERE uid = ?', [uid]);
      _db.execute('DELETE FROM relics_fts WHERE uid = ?', [uid]);
      _db.execute('DELETE FROM relics_tri WHERE uid = ?', [uid]);
      _db.execute('DELETE FROM vectors WHERE uid = ?', [uid]);
      // The AI record dies with its relic, exactly as it does on the server.
      // Leaving it would let a re-created uid inherit a stranger's title.
      _db.execute('DELETE FROM ai_records WHERE uid = ?', [uid]);
      _deletePersonalRowsInTxn(uid);
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Delete every unpromoted (history) relic in ONE transaction — the
  /// settings "Clear all history" action. Set-based statements instead of
  /// 10k per-row transactions. When [queueDeletes], a 'delete' tombstone is
  /// queued per uid (batch equivalent of [_queueOpInTxn]) so synced peers
  /// and the server drop the items too — tombstones and row deletes commit
  /// atomically, so a crash can never lose one without the other. Returns
  /// the deleted uids (for the caller's cache cleanup) and the blob keys no
  /// surviving promoted row still references — only those files may be
  /// removed from disk (blob keys can be shared across rows).
  ({List<String> uids, Set<String> orphanBlobKeys}) clearUnpromoted(
    int deletedAt, {
    required bool queueDeletes,
  }) {
    // Held rows are exempt: "clear all history" clears the history the user can
    // SEE. Sweeping the previous account's hidden items into it (and queueing
    // tombstones for them against the current account) would destroy data the
    // user has not decided about yet.
    const history =
        'SELECT uid FROM relics WHERE promoted = 0 AND held_by IS NULL';
    _db.execute('BEGIN');
    try {
      final uids = _db
          .select('SELECT uid FROM relics WHERE promoted = 0 AND held_by IS NULL')
          .map((r) => r['uid'] as String)
          .toList();
      if (uids.isEmpty) {
        _db.execute('COMMIT');
        return (uids: const [], orphanBlobKeys: const {});
      }
      // A blob is orphaned only when NOTHING that survives still points at it —
      // surviving means promoted OR held.
      final orphanKeys = _db
          .select('''
            SELECT DISTINCT blob_key FROM relics
             WHERE promoted = 0 AND held_by IS NULL AND blob_key IS NOT NULL
               AND blob_key NOT IN (
                 SELECT blob_key FROM relics
                  WHERE (promoted = 1 OR held_by IS NOT NULL)
                    AND blob_key IS NOT NULL)
          ''')
          .map((r) => r['blob_key'] as String)
          .toSet();
      _db.execute(
          "DELETE FROM pending_ops WHERE op = 'push' AND uid IN ($history)");
      _db.execute('DELETE FROM sync_rejections WHERE uid IN ($history)');
      if (queueDeletes) {
        _db.execute('''
          INSERT INTO pending_ops (uid, op, queued_at)
            SELECT uid, 'delete', ? FROM relics
             WHERE promoted = 0 AND held_by IS NULL
            ON CONFLICT(uid, op) DO UPDATE SET queued_at = excluded.queued_at
        ''', [deletedAt]);
      }
      // Everything referencing promoted = 0 must precede the row delete.
      for (final sql in [
        'DELETE FROM relics_fts WHERE uid IN ($history)',
        'DELETE FROM relics_tri WHERE uid IN ($history)',
        'DELETE FROM vectors WHERE uid IN ($history)',
        'DELETE FROM ai_records WHERE uid IN ($history)',
        'DELETE FROM query_memory WHERE uid IN ($history)',
        "DELETE FROM context_memory WHERE kind = 'uid' AND key IN ($history)",
        'DELETE FROM relics WHERE promoted = 0 AND held_by IS NULL',
      ]) {
        _db.execute(sql);
      }
      _db.execute('COMMIT');
      return (uids: uids, orphanBlobKeys: orphanKeys);
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Whether a delete tombstone is queued for [uid] — the pull path checks
  /// this before treating an unknown remote row as new, so an in-flight pull
  /// can't resurrect a locally deleted item before its tombstone lands.
  bool hasPendingDelete(String uid) => _db.select(
        "SELECT 1 FROM pending_ops WHERE uid = ? AND op = 'delete' LIMIT 1",
        [uid],
      ).isNotEmpty;

  /// Re-copy dedupe: resurface the item as the newest capture. Every list,
  /// browse, and sync surface orders by created_at, so both stamps must move
  /// or the bump is invisible and a re-copy looks like a dropped capture.
  /// FTS body untouched.
  void touch(String uid, int touchedAt, {bool queuePush = false}) {
    _db.execute('BEGIN');
    try {
      _db.execute(
        'UPDATE relics SET created_at = ?, updated_at = ? WHERE uid = ?',
        [touchedAt, touchedAt, uid],
      );
      if (queuePush) _queueOpInTxn(uid, 'push', touchedAt);
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Usage half-life: an untouched item's use_count halves every 30 days, so
  /// a cornerstone stays a cornerstone only while it keeps being reached for
  /// — heavy use last March can't outrank what's used weekly now.
  static const int kUseHalfLifeSecs = 30 * 24 * 3600;

  /// The stored counter decayed to [now]. The pair (use_count, last_used_at)
  /// IS the whole frecency state: decay-then-increment on every touch makes
  /// the counter equivalent to a sum of exponentially-decayed events without
  /// an event log.
  static double decayedUse(double count, int? lastUsedAt, int now) {
    if (count <= 0 || lastUsedAt == null) return 0;
    final dt = now - lastUsedAt;
    if (dt <= 0) return count;
    return count * math.exp(-dt * math.ln2 / kUseHalfLifeSecs);
  }

  /// Record one "touch": the user reached for this item (copied it out of
  /// Relic, or re-copied identical content from another app). Timestamps
  /// are epoch SECONDS. Local-only — never queues a push, never bumps
  /// created_at/updated_at (that's [touch]'s job on the re-copy path).
  void recordUse(String uid, int now) {
    final rows = _db.select(
      'SELECT use_count, last_used_at FROM relics WHERE uid = ?',
      [uid],
    );
    if (rows.isEmpty) return;
    final prev = (rows.first['use_count'] as num?)?.toDouble() ?? 0;
    final last = rows.first['last_used_at'] as int?;
    _db.execute(
      'UPDATE relics SET use_count = ?, last_used_at = ? WHERE uid = ?',
      [decayedUse(prev, last, now) + 1, now, uid],
    );
  }

  /// Memory rows idle this long are pruned on the next record: after 8
  /// half-lives a counter has decayed 256x, below any rank-visible factor,
  /// and the age test needs no SQL exp().
  static const int kMemoryIdleSecs = 8 * kUseHalfLifeSecs;

  /// Query terms worth remembering for [recordQueryPick]: operator clauses
  /// dropped whole (their split halves are ranking noise), then the same
  /// tokenizer as search, minus one-letter terms, capped at the first 6.
  static List<String> memoryTerms(String query) => _queryTerms(
        query.replaceAll(RegExp(r'\b(kind|is|has|tag):\S+', caseSensitive: false), ' '),
      ).where((t) => t.length >= 2).take(6).toList();

  /// Remember "searching [query], the user picked [uid]" — decaying (term,
  /// uid) counters, so future queries sharing these terms rank the pick
  /// higher (see [rankFactors]). Local-only, like all personal signals.
  void recordQueryPick(String query, String uid, int now) {
    final terms = memoryTerms(query);
    if (terms.isEmpty) return;
    _db.execute('BEGIN');
    try {
      for (final t in terms) {
        final rows = _db.select(
          'SELECT count, last_at FROM query_memory WHERE term = ? AND uid = ?',
          [t, uid],
        );
        final prev = rows.isEmpty
            ? 0.0
            : decayedUse((rows.first['count'] as num).toDouble(),
                rows.first['last_at'] as int, now);
        _db.execute(
          'INSERT INTO query_memory (term, uid, count, last_at) VALUES (?,?,?,?) '
          'ON CONFLICT(term, uid) DO UPDATE SET count = excluded.count, '
          'last_at = excluded.last_at',
          [t, uid, prev + 1, now],
        );
      }
      _db.execute(
          'DELETE FROM query_memory WHERE last_at < ?', [now - kMemoryIdleSecs]);
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Remember "summoned over [app], the user picked [uid] (an item tagged
  /// [tags])" — the destination-context prior. The uid rows boost the exact
  /// items pasted into this app before; the tag rows generalize weakly to
  /// new items of the same type (see [rankFactors]).
  void recordContextPick(String app, String uid, List<String> tags, int now) {
    _db.execute('BEGIN');
    try {
      void bump(String kind, String key) {
        final rows = _db.select(
          'SELECT count, last_at FROM context_memory '
          'WHERE app = ? AND kind = ? AND key = ?',
          [app, kind, key],
        );
        final prev = rows.isEmpty
            ? 0.0
            : decayedUse((rows.first['count'] as num).toDouble(),
                rows.first['last_at'] as int, now);
        _db.execute(
          'INSERT INTO context_memory (app, kind, key, count, last_at) '
          'VALUES (?,?,?,?,?) '
          'ON CONFLICT(app, kind, key) DO UPDATE SET count = excluded.count, '
          'last_at = excluded.last_at',
          [app, kind, key, prev + 1, now],
        );
      }

      bump('uid', uid);
      for (final t in tags.take(4)) {
        bump('tag', t.toLowerCase());
      }
      _db.execute('DELETE FROM context_memory WHERE last_at < ?',
          [now - kMemoryIdleSecs]);
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Forget everything personalized ranking has learned on this device:
  /// both memory tables plus the usage-frecency columns.
  void clearPersonalMemory() {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM query_memory');
      _db.execute('DELETE FROM context_memory');
      _db.execute('UPDATE relics SET use_count = 0, last_used_at = NULL');
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Deleting a relic forgets its personal-memory rows too (inside the
  /// caller's transaction). Tag-level context rows describe a CLASS, not
  /// this item — they stay and age out via decay.
  void _deletePersonalRowsInTxn(String uid) {
    _db.execute('DELETE FROM query_memory WHERE uid = ?', [uid]);
    _db.execute(
        "DELETE FROM context_memory WHERE kind = 'uid' AND key = ?", [uid]);
  }

  void markBlobLocal(String uid) =>
      _db.execute('UPDATE relics SET have_blob = 1 WHERE uid = ?', [uid]);

  void markBlobMissing(String uid) =>
      _db.execute('UPDATE relics SET have_blob = 0 WHERE uid = ?', [uid]);

  void queueOp(String uid, String op, int queuedAt) {
    _queueOpInTxn(uid, op, queuedAt);
  }

  void _queueOpInTxn(String uid, String op, int queuedAt) {
    _db.execute(
      '''INSERT INTO pending_ops (uid, op, queued_at) VALUES (?,?,?)
         ON CONFLICT(uid, op) DO UPDATE SET queued_at = excluded.queued_at''',
      [uid, op, queuedAt],
    );
    _db.execute('DELETE FROM sync_rejections WHERE uid = ? AND op = ?', [
      uid,
      op,
    ]);
  }

  void clearOp(String uid, String op) => _db.execute(
    'DELETE FROM pending_ops WHERE uid = ? AND op = ?',
    [uid, op],
  );

  void clearOpsForUid(String uid) =>
      _db.execute('DELETE FROM pending_ops WHERE uid = ?', [uid]);

  /// Drop the ENTIRE outbound queue + rejection ledger. Account-switch path
  /// only: ops queued while bound to one account are meaningless (and unsafe
  /// to replay) against another.
  void clearAllPendingSync() {
    _db.execute('DELETE FROM pending_ops');
    _db.execute('DELETE FROM sync_rejections');
    // Same reasoning for AI records still owed to the server: publishing work
    // generated while bound to one account INTO another is exactly the leak the
    // account-switch guard exists to prevent. The records stay for local
    // display; they just stop being outbound.
    _db.execute('UPDATE ai_records SET pushed = 1 WHERE pushed = 0');
  }

  // --- account-switch holdback (the `held_by` column) ---
  //
  // Policy, applied deliberately query by query in this file:
  //
  //  * HIDDEN from held rows: the list/browse query, every search leg (FTS,
  //    trigram, tag-intent, the LIKE fallback), the uid materializer [byUids],
  //    counts the user reads (countAll / countUnpromoted / countTag /
  //    countMatching / tagFrequencies / countNeedingEnrich), the sync push
  //    surface [allRows], capture dedupe [uidByContent], the recency lookups
  //    behind paste-latest and quick-paste, snippet triggers, retention
  //    eviction, the vault-full gate, blob prefetch, and the enrichment /
  //    attachment-text / AI-record backlogs.
  //  * STILL COUNTED: [allWithBlob] and [localAggregate] — blob GC and disk
  //    accounting must keep seeing held rows, or the cache sweeper would
  //    collect bytes the user has not agreed to lose. Their FTS/trigram/vector
  //    index rows are kept too, so accepting them back needs no reindex; the
  //    read paths above are what makes them invisible.
  //  * BY-UID lookups ([getByUid], [updatedAtOf], [touch], [recordUse], …) stay
  //    unfiltered: nothing hands the UI a held uid, and the accept/delete paths
  //    need to resolve one.

  /// Stamp every currently-visible row as belonging to [identity] — the
  /// account this vault synced with BEFORE the switch. Returns how many.
  int holdAll(String identity) {
    _db.execute(
      'UPDATE relics SET held_by = ? WHERE held_by IS NULL',
      [identity],
    );
    return _db.updatedRows;
  }

  /// Release the rows held for [identity] (the user signed back into that
  /// account, so its items are its own again). Returns how many came back.
  int releaseHeld(String identity) {
    _db.execute('UPDATE relics SET held_by = NULL WHERE held_by = ?', [
      identity,
    ]);
    return _db.updatedRows;
  }

  /// Release EVERY held row — the "upload all into this account" decision.
  int releaseAllHeld() {
    _db.execute('UPDATE relics SET held_by = NULL WHERE held_by IS NOT NULL');
    return _db.updatedRows;
  }

  int countHeld() =>
      (_db.select('SELECT COUNT(*) AS n FROM relics WHERE held_by IS NOT NULL')
              .first['n'] as num)
          .toInt();

  /// (uid, blobKey) for every held row — what the "delete them from this
  /// device" action deletes, and what its blob cleanup needs.
  List<({String uid, String? blobKey})> heldRows() => _db
      .select(
        'SELECT uid, blob_key FROM relics WHERE held_by IS NOT NULL '
        'ORDER BY created_at DESC',
      )
      .map((r) => (uid: r['uid'] as String, blobKey: r['blob_key'] as String?))
      .toList();

  /// The holdback stamp on one row (null = visible). Testing/diagnostics.
  String? heldByOf(String uid) {
    final rs = _db.select('SELECT held_by FROM relics WHERE uid = ?', [uid]);
    return rs.isEmpty ? null : rs.first['held_by'] as String?;
  }

  /// Legacy-install migration: stamp the [n] OLDEST currently-visible rows with
  /// [identity]. Installs that took the first version of the holdback carry a
  /// merge-offer COUNT in prefs but no marked rows, and the identity those
  /// items belonged to was never recorded — so the oldest N (the ones that
  /// predate the switch) are tagged with a sentinel. Returns how many.
  ///
  /// Ties on `created_at` break by rowid, i.e. capture order: a burst of copies
  /// inside one second must not make the boundary arbitrary.
  int holdOldest(int n, String identity) {
    if (n <= 0) return 0;
    _db.execute(
      '''UPDATE relics SET held_by = ? WHERE uid IN (
           SELECT uid FROM relics WHERE held_by IS NULL
            ORDER BY created_at ASC, rowid ASC LIMIT ?)''',
      [identity, n],
    );
    return _db.updatedRows;
  }

  void recordSyncRejection(String uid, String op, int status, int rejectedAt) {
    _db.execute(
      '''INSERT INTO sync_rejections (uid, op, status, rejected_at)
         VALUES (?,?,?,?)
         ON CONFLICT(uid, op) DO UPDATE SET
           status = excluded.status, rejected_at = excluded.rejected_at''',
      [uid, op, status, rejectedAt],
    );
  }

  void clearSyncRejection(String uid, String op) => _db.execute(
    'DELETE FROM sync_rejections WHERE uid = ? AND op = ?',
    [uid, op],
  );

  List<({String uid, String op, int queuedAt})> pendingOps({int limit = 100}) =>
      _db
          .select(
            '''SELECT uid, op, queued_at FROM pending_ops
               ORDER BY queued_at ASC LIMIT ?''',
            [limit],
          )
          .map(
            (r) => (
              uid: r['uid'] as String,
              op: r['op'] as String,
              queuedAt: r['queued_at'] as int,
            ),
          )
          .toList();

  int pendingCount() =>
      _db.select('SELECT COUNT(*) AS n FROM pending_ops').first['n'] as int;

  int rejectionCount() =>
      _db.select('SELECT COUNT(*) AS n FROM sync_rejections').first['n'] as int;

  /// The most recent rejection for one relic (drives the row badge popover).
  ({String op, int status, int rejectedAt})? rejectionFor(String uid) {
    final rs = _db.select(
      '''SELECT op, status, rejected_at FROM sync_rejections
         WHERE uid = ? ORDER BY rejected_at DESC LIMIT 1''',
      [uid],
    );
    if (rs.isEmpty) return null;
    final r = rs.first;
    return (
      op: r['op'] as String,
      status: r['status'] as int,
      rejectedAt: r['rejected_at'] as int,
    );
  }

  /// Every blocked op, newest first (drives the "not synced" summary sheet).
  List<({String uid, String op, int status, int rejectedAt})> allRejections({
    int limit = 50,
  }) => _db
      .select(
        '''SELECT uid, op, status, rejected_at FROM sync_rejections
           ORDER BY rejected_at DESC LIMIT ?''',
        [limit],
      )
      .map(
        (r) => (
          uid: r['uid'] as String,
          op: r['op'] as String,
          status: r['status'] as int,
          rejectedAt: r['rejected_at'] as int,
        ),
      )
      .toList();

  bool hasPendingOrRejected(String uid) => _db
      .select(
        '''SELECT 1 FROM pending_ops WHERE uid = ?
               UNION ALL
               SELECT 1 FROM sync_rejections WHERE uid = ?
               LIMIT 1''',
        [uid, uid],
      )
      .isNotEmpty;

  /// Per-relic sync state for the row badge: 1 = a queued op is in flight
  /// (syncing), 2 = the server rejected it (blocked), 0 = clean. Pending wins
  /// over rejected — a re-queued op is actively retrying.
  int syncStateFor(String uid) {
    if (_db
        .select('SELECT 1 FROM pending_ops WHERE uid = ? LIMIT 1', [uid])
        .isNotEmpty) {
      return 1;
    }
    if (_db
        .select('SELECT 1 FROM sync_rejections WHERE uid = ? LIMIT 1', [uid])
        .isNotEmpty) {
      return 2;
    }
    return 0;
  }

  /// (uid, blobKey) for every relic with a blob, newest first — used to map
  /// on-disk blob files back to relics when clearing/re-downloading the cache.
  /// Deliberately includes HELD rows: blob accounting has to see them, or the
  /// cache sweeper would treat their bytes as unreferenced and collect data the
  /// user hasn't decided about yet.
  List<({String uid, String blobKey})> allWithBlob() => _db
      .select(
        "SELECT uid, blob_key FROM relics WHERE blob_key IS NOT NULL ORDER BY created_at DESC",
      )
      .map((r) => (uid: r['uid'] as String, blobKey: r['blob_key'] as String))
      .toList();

  void setEnrichLevel(String uid, int level) => _db.execute(
    'UPDATE relics SET enrich_level = ? WHERE uid = ?',
    [level, uid],
  );

  int? enrichLevelOf(String uid) {
    final rs = _db.select('SELECT enrich_level FROM relics WHERE uid = ?', [uid]);
    return rs.isEmpty ? null : rs.first['enrich_level'] as int;
  }

  /// Raise [uid]'s enrich level to [level], never lower it.
  ///
  /// This is how a device stops redoing work a peer already did: adopting a
  /// received AI record's level takes the item out of `needingEnrich` for good.
  /// It must not be able to move BACKWARDS, or a record produced by a device on
  /// an older model generation would re-queue the whole corpus on a newer one.
  void raiseEnrichLevel(String uid, int level) => _db.execute(
    'UPDATE relics SET enrich_level = ? WHERE uid = ? AND enrich_level < ?',
    [level, uid, level],
  );

  // --- AI records (generated title + tags; see the ai_records DDL) ---

  /// Whether an incoming AI record should replace [stored].
  ///
  /// A byte-for-byte mirror of `aiResultWins` in worker/src/ai.ts, and it has to
  /// stay that way: if a device disagreed with the server about which result
  /// wins, it would keep re-publishing a record the server keeps rejecting and
  /// the two would never settle.
  ///
  ///   1. a higher enrich level always wins (a real model upgrade should apply)
  ///   2. a device may amend its OWN record with its latest word — it is adding
  ///      to its answer, not competing with it, and the halves of a record are
  ///      produced by different passes that finish at different times. Its own
  ///      OLDER word is still refused, so nothing moves backwards.
  ///   3. at equal level the EARLIEST result wins, so a title the user is
  ///      already looking at stops moving — this is what stops a device whose
  ///      lease expired mid-job from overwriting the result that landed first
  ///   4. exact ties break on device id, so every device picks the same winner
  static bool aiResultWins(AiRecord incoming, AiRecord? stored) {
    if (stored == null) return true;
    if (incoming.level != stored.level) return incoming.level > stored.level;
    if (incoming.by != null && incoming.by == stored.by) {
      return incoming.at >= stored.at;
    }
    if (incoming.at != stored.at) return incoming.at < stored.at;
    return (incoming.by ?? '').compareTo(stored.by ?? '￿') < 0;
  }

  AiRecord? aiRecord(String uid) {
    final rs = _db.select('SELECT * FROM ai_records WHERE uid = ?', [uid]);
    return rs.isEmpty ? null : _toAiRecord(rs.first);
  }

  static AiRecord _toAiRecord(Row r) => AiRecord(
    uid: r['uid'] as String,
    at: r['ai_at'] as int,
    level: r['ai_level'] as int,
    by: r['ai_by'] as String?,
    title: r['title'] as String?,
    tags: _jsonList(r['tags']),
    text: r['ai_text'] as String?,
    att: r['att_text'] as String?,
  );

  /// Store [rec] if it beats what's already here, and return whether it landed.
  ///
  /// [needsPush] marks it as owed to the server (this device generated it); a
  /// record that arrived FROM the server is already published, so it is stored
  /// with pushed = 1 and never echoed back.
  ///
  /// The merge is field-wise, not wholesale: a winning record never clears a
  /// field it does not carry. The two halves of a record are produced by
  /// different passes at different times (the models caption an item; a
  /// separate, model-free pass reads its attachments once their bytes are
  /// local), so a record that replaced its predecessor outright would throw
  /// away whichever half arrived first.
  bool putAiRecord(AiRecord rec, {required bool needsPush}) {
    final stored = aiRecord(rec.uid);
    if (!aiResultWins(rec, stored)) return false;
    final merged = stored == null
        ? rec
        : AiRecord(
            uid: rec.uid,
            at: rec.at,
            level: rec.level,
            by: rec.by,
            title: rec.title ?? stored.title,
            tags: rec.tags.isNotEmpty ? rec.tags : stored.tags,
            text: rec.text ?? stored.text,
            att: rec.att ?? stored.att,
          );
    _db.execute(
      '''INSERT INTO ai_records
           (uid, ai_at, ai_level, ai_by, title, tags, ai_text, att_text, pushed)
         VALUES (?,?,?,?,?,?,?,?,?)
         ON CONFLICT(uid) DO UPDATE SET
           ai_at=excluded.ai_at, ai_level=excluded.ai_level, ai_by=excluded.ai_by,
           title=excluded.title, tags=excluded.tags, ai_text=excluded.ai_text,
           att_text=excluded.att_text, pushed=excluded.pushed''',
      [
        merged.uid,
        merged.at,
        merged.level,
        merged.by,
        merged.title,
        jsonEncode(merged.tags),
        // Stored already trimmed to the wire budget: the full text is in the
        // relic's own columns, and a second untrimmed copy of every document
        // would grow the vault file for nothing.
        aiTextForWire(merged.text),
        merged.att == null ? null : (aiTextForWire(merged.att) ?? ''),
        needsPush ? 0 : 1,
      ],
    );
    return true;
  }

  /// Publish what this device has ALREADY generated, as AI records.
  ///
  /// Before AI records existed, enrichment was a purely local side effect: the
  /// title and machine tags were written to the row and never left the machine.
  /// So two devices that both enriched the same vault now hold two different
  /// sets of titles, and neither knows about the other's. This is the one-time
  /// reconciliation that makes them agree. It runs no models: it publishes
  /// results that already exist.
  ///
  /// `ai_at` is the relic's OWN created_at, not the wall clock, and that choice
  /// is what makes convergence deterministic. Both devices derive the same
  /// timestamp for the same item, so the earliest-wins rule reduces to the
  /// device-id tiebreak and both machines independently pick the same winner.
  /// Using "now" instead would hand it to whichever device happened to run the
  /// pass second, which is not a decision anyone made.
  ///
  /// Titles the USER typed get published too, since nothing recorded which was
  /// which. That is harmless: a user title reached the peer through ordinary
  /// relic sync already, so applying the record there is a no-op. The records
  /// that actually do something are exactly the ones the peer is missing, which
  /// are exactly the locally-generated ones.
  ///
  /// The same goes for extracted text, and there it matters more: the OCR of a
  /// screenshot only ever existed on the machine that read it, so seeding it is
  /// what makes an already-enriched vault searchable on the phone instead of
  /// only from that one desk. Text relics are excluded — their content is the
  /// relic body, which syncs on its own and must not get a second copy here.
  ///
  /// Returns how many were seeded. Only rows the ML pass actually reached, and
  /// only ones with something worth sending.
  int seedAiRecordsFromRelics({required int minLevel, String? by}) {
    _db.execute(
      '''INSERT INTO ai_records
           (uid, ai_at, ai_level, ai_by, title, tags, ai_text, att_text, pushed)
         SELECT r.uid, r.created_at, r.enrich_level, ?, r.title,
                COALESCE(r.tags, '[]'),
                CASE WHEN r.kind <> 'string' THEN substr(r.content, 1, ?) END,
                substr(r.attachment_text, 1, ?), 0
           FROM relics r
          WHERE r.enrich_level >= ? AND r.held_by IS NULL
            AND (COALESCE(TRIM(r.title), '') <> ''
                 OR COALESCE(r.tags, '[]') NOT IN ('[]', '')
                 OR (r.kind <> 'string' AND COALESCE(TRIM(r.content), '') <> '')
                 OR COALESCE(TRIM(r.attachment_text), '') <> '')
            AND NOT EXISTS (SELECT 1 FROM ai_records a WHERE a.uid = r.uid)''',
      // Characters, not bytes: this only bounds what the local table holds, and
      // the real budget is enforced in bytes on the way out.
      [by, kAiTextBytes, kAiTextBytes, minLevel],
    );
    return _db.updatedRows;
  }

  /// Records this device generated and still owes the server, oldest first.
  List<AiRecord> aiRecordsNeedingPush({int limit = 50}) => _db
      .select(
        'SELECT * FROM ai_records WHERE pushed = 0 ORDER BY ai_at ASC LIMIT ?',
        [limit],
      )
      .map(_toAiRecord)
      .toList();

  int countAiRecordsNeedingPush() =>
      _db.select('SELECT COUNT(*) AS n FROM ai_records WHERE pushed = 0').first['n']
          as int;

  /// Settle a record with the server. Also the right call when the server says
  /// `stale`: a peer's result won, so we stop owing this one.
  void markAiPushed(String uid) =>
      _db.execute('UPDATE ai_records SET pushed = 1 WHERE uid = ?', [uid]);

  /// Uids that have an AI record but whose relic has not adopted it yet.
  ///
  /// Covers the ordinary case where a record arrives before its relic does:
  /// the two ride independent cursors, so either order happens, and the record
  /// simply waits here until the relic shows up.
  List<String> aiRecordsUnapplied({int limit = 200}) => _db
      .select(
        '''SELECT a.uid FROM ai_records a
           JOIN relics r ON r.uid = a.uid
           WHERE r.enrich_level < a.ai_level AND r.held_by IS NULL
           ORDER BY a.ai_at ASC LIMIT ?''',
        [limit],
      )
      .map((r) => r['uid'] as String)
      .toList();

  /// Reset attachment-text extraction (after an attachment edit rebuilt the
  /// bundle) so the backlog pass / direct re-extract reads the new bytes —
  /// it only retries rows where attachment_text IS NULL.
  void clearAttachmentText(String uid) {
    _db.execute(
      'UPDATE relics SET attachment_text = NULL WHERE uid = ?',
      [uid],
    );
    final r = getByUid(uid);
    if (r != null) _writeIndexRows(_db, r, '');
  }

  /// Machine tags the user explicitly removed from this relic — enrichment
  /// must never re-add them. Local-only metadata (survives upsert). Stored and
  /// returned LOWERCASED: producers emit both cased chips ('MP3') and
  /// lowercase detector tags, so suppression matching must be case-blind —
  /// consumers compare `t.toLowerCase()` against this set.
  List<String> suppressedTags(String uid) {
    final rs = _db.select(
      'SELECT suppressed_tags FROM relics WHERE uid = ?',
      [uid],
    );
    return rs.isEmpty
        ? const []
        : [
            for (final t in _jsonList(rs.first['suppressed_tags']))
              t.toLowerCase(),
          ];
  }

  void setSuppressedTags(String uid, List<String> tags) {
    final norm = {for (final t in tags) t.toLowerCase()}.toList();
    _db.execute(
      'UPDATE relics SET suppressed_tags = ? WHERE uid = ?',
      [norm.isEmpty ? null : jsonEncode(norm), uid],
    );
  }

  /// Relics not yet enriched to [level], newest first. Covers the whole corpus
  /// (stream + vault) so semantic search reaches everything.
  List<Relic> needingEnrich(int level, int limit) => _db
      .select(
        'SELECT * FROM relics WHERE enrich_level < ? AND held_by IS NULL '
        'ORDER BY created_at DESC LIMIT ?',
        [level, limit],
      )
      .map(_toRelic)
      .toList();

  /// Relics this device considers enriched but holds no embedding for.
  ///
  /// This is the hole the work-claim opened. Only one device runs the models on
  /// a given item now, and every other device adopts its result and marks the
  /// item done — which also means those devices never embed it, so the item is
  /// missing from their semantic index and findable there by keyword only.
  ///
  /// The fix is not to sync the vectors: they are meaningless to a device on a
  /// different embedding model, and useless to one that cannot embed a query at
  /// all. It is to embed locally from the text that now travels. Embedding is
  /// cheap and deterministic, so every device can afford to redo it and they
  /// all land on the same answer — unlike captioning, which is neither.
  ///
  /// Items with no text are excluded rather than retried: there is nothing to
  /// embed, so they would otherwise sit in this queue forever. Newest first.
  List<Relic> needingVectors(int level, int limit) => _db
      .select(
        '''SELECT * FROM relics r
            WHERE r.enrich_level >= ? AND r.held_by IS NULL
              AND COALESCE(TRIM(r.content), '') <> ''
              AND NOT EXISTS (SELECT 1 FROM vectors v WHERE v.uid = r.uid)
            ORDER BY r.created_at DESC LIMIT ?''',
        [level, limit],
      )
      .map(_toRelic)
      .toList();

  /// How many relics still sit below [level] — the settings "tagging N
  /// items…" progress line. Full-table scan (enrich_level is unindexed);
  /// fine at the enrich worker's 6 s cadence.
  int countNeedingEnrich(int level) => (_db
          .select(
              'SELECT COUNT(*) AS n FROM relics '
              'WHERE enrich_level < ? AND held_by IS NULL',
              [level])
          .first['n'] as num)
      .toInt();

  /// Every tag present, with counts, split into auto (machine) and the user's
  /// own. Scans the JSON tag columns; cheap enough to run when a sheet opens.
  ({Map<String, int> machine, Map<String, int> user}) tagFrequencies(
    bool vaultOnly,
  ) {
    final where = vaultOnly
        ? 'WHERE promoted = 1 AND held_by IS NULL'
        : 'WHERE held_by IS NULL';
    final machine = <String, int>{};
    final user = <String, int>{};
    for (final r in _db.select('SELECT tags, user_tags FROM relics $where')) {
      for (final t in _jsonList(r['tags'])) {
        machine[t] = (machine[t] ?? 0) + 1;
      }
      for (final t in _jsonList(r['user_tags'])) {
        user[t] = (user[t] ?? 0) + 1;
      }
    }
    return (machine: machine, user: user);
  }

  /// Rebuild the FTS + trigram index rows for one relic (after editing its
  /// tag columns out-of-band).
  void _reindexFts(String uid) {
    final rs = _db.select('SELECT * FROM relics WHERE uid = ?', [uid]);
    if (rs.isEmpty) return;
    final r = _toRelic(rs.first);
    final att = (rs.first['attachment_text'] as String?) ?? '';
    _writeIndexRows(_db, r, att);
  }

  /// Store the text extracted from [uid]'s attachments and reindex, so a note
  /// is findable by what its bundled files SAY, not just their names. An empty
  /// string is stored as-is — it marks "extraction ran, nothing to index" so
  /// the backlog pass (which scans for NULL) doesn't retry forever. Local-only
  /// (each device extracts deterministically).
  void setAttachmentText(String uid, String text) {
    _db.execute(
      'UPDATE relics SET attachment_text = ? WHERE uid = ?',
      [text, uid],
    );
    _reindexFts(uid);
  }

  /// Store attachment text that came from another device, but only where this
  /// one has none of its own. Returns whether it landed.
  ///
  /// Local extraction outranks a peer's copy for the same reason a local
  /// content column does: it was read from the bytes this device holds. The
  /// stored value may legitimately be the empty string ("ran, found nothing"),
  /// which is an answer, so this checks for NULL rather than for emptiness.
  bool applyAttachmentText(String uid, String text) {
    final rs = _db.select(
      'SELECT attachment_text FROM relics WHERE uid = ?',
      [uid],
    );
    if (rs.isEmpty || rs.first['attachment_text'] != null) return false;
    setAttachmentText(uid, text);
    return true;
  }

  /// Uids of relics that have attachments but no extracted attachment text
  /// yet — the backlog for the attachment-text pass. Newest first.
  List<String> attachmentsNeedingText(int limit) => _db
      .select(
        "SELECT uid FROM relics WHERE attachments IS NOT NULL "
        "AND attachments != '' AND attachment_text IS NULL "
        'AND held_by IS NULL '
        "ORDER BY created_at DESC LIMIT ?",
        [limit],
      )
      .map((r) => r['uid'] as String)
      .toList();

  /// Rename a tag across the whole corpus in the given column (machine `tags`
  /// or `user_tags`), de-duplicating. Returns the number of relics changed.
  /// Rename [from] → [to] corpus-wide in the given column, de-duplicating.
  /// Case-INSENSITIVE on the match (every read path is — `tag:mp3` finds
  /// 'MP3', so a rename typed as 'mp3' must hit it too). For machine tags the
  /// old name is recorded as suppressed per relic, so enrichment can't just
  /// re-emit it. Returns the number of relics changed.
  int renameTag(String from, String to, {required bool userTag}) {
    final col = userTag ? 'user_tags' : 'tags';
    final fromLower = from.toLowerCase();
    final rows = _db.select(
      'SELECT uid, $col AS j FROM relics '
      'WHERE lower($col) LIKE ? AND held_by IS NULL',
      ['%"$fromLower"%'],
    );
    var n = 0;
    _db.execute('BEGIN');
    try {
      for (final row in rows) {
        final list = _jsonList(row['j']);
        if (!list.any((t) => t.toLowerCase() == fromLower)) continue;
        final out = <String>[];
        for (final t in list) {
          final v = t.toLowerCase() == fromLower ? to : t;
          if (v.isNotEmpty && !out.contains(v)) out.add(v);
        }
        final uid = row['uid'] as String;
        _db.execute('UPDATE relics SET $col = ? WHERE uid = ?', [
          jsonEncode(out),
          uid,
        ]);
        // A case-only rename (MP3 → mp3) keeps the tag — suppressing it would
        // make sync/enrichment strip the surviving variant.
        if (!userTag && to.toLowerCase() != fromLower) {
          _addSuppressed(uid, from);
        }
        _reindexFts(uid);
        n++;
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return n;
  }

  /// Remove a tag from the given column across the corpus (case-insensitive,
  /// matching the read paths). Machine-tag deletions are recorded as
  /// suppressed per relic so re-enrichment can't resurrect them. Returns the
  /// number of relics changed.
  int deleteTag(String tag, {required bool userTag}) {
    final col = userTag ? 'user_tags' : 'tags';
    final tagLower = tag.toLowerCase();
    final rows = _db.select(
      'SELECT uid, $col AS j FROM relics '
      'WHERE lower($col) LIKE ? AND held_by IS NULL',
      ['%"$tagLower"%'],
    );
    var n = 0;
    _db.execute('BEGIN');
    try {
      for (final row in rows) {
        final list = _jsonList(row['j']);
        if (!list.any((t) => t.toLowerCase() == tagLower)) continue;
        final out = [
          for (final t in list)
            if (t.toLowerCase() != tagLower) t,
        ];
        final uid = row['uid'] as String;
        _db.execute('UPDATE relics SET $col = ? WHERE uid = ?', [
          jsonEncode(out),
          uid,
        ]);
        if (!userTag) _addSuppressed(uid, tag);
        _reindexFts(uid);
        n++;
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return n;
  }

  /// Merge [tag] into a relic's suppressed set (used by corpus-wide machine
  /// tag removals — same semantics as updateMeta's per-relic bookkeeping).
  void _addSuppressed(String uid, String tag) {
    final t = tag.toLowerCase();
    final cur = suppressedTags(uid);
    if (cur.contains(t)) return;
    setSuppressedTags(uid, [...cur, t]);
  }

  /// Of [uids], the subset that are promoted (vault) — for scope-filtering the
  /// semantic candidate list.
  Set<String> promotedAmong(List<String> uids) {
    if (uids.isEmpty) return const {};
    final ph = List.filled(uids.length, '?').join(',');
    return _db
        .select(
          'SELECT uid FROM relics '
          'WHERE promoted = 1 AND held_by IS NULL AND uid IN ($ph)',
          uids,
        )
        .map((r) => r['uid'] as String)
        .toSet();
  }

  /// File relics whose text hasn't been extracted yet (empty content) but whose
  /// bytes are local — for ML-independent document text extraction. Newest first.
  List<Relic> filesNeedingText(int limit) => _db
      .select(
        "SELECT * FROM relics WHERE kind = 'file' AND have_blob = 1 "
        "AND (content IS NULL OR content = '') AND held_by IS NULL "
        'ORDER BY created_at DESC LIMIT ?',
        [limit],
      )
      .map(_toRelic)
      .toList();

  /// How many relics carry [tag] (exact tag match against the JSON tag array,
  /// case-insensitive), optionally within the vault — drives the collections
  /// strip. Matches the `tag:` filter in [_runQuery] exactly, so chip badges
  /// and result counts agree.
  /// LIKE-pattern for an exact JSON-array tag element, with the tag's own
  /// `%`/`_`/`\` escaped so they can't act as wildcards (pair with ESCAPE '\').
  static String _tagLike(String tag) {
    final esc = tag
        .toLowerCase()
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    return '%"$esc"%';
  }

  int countTag(String tag, {bool vaultOnly = false}) {
    final scope =
        vaultOnly ? 'AND promoted = 1 AND held_by IS NULL' : 'AND held_by IS NULL';
    final like = _tagLike(tag);
    final rs = _db.select(
      'SELECT COUNT(*) AS n FROM relics '
      "WHERE (lower(tags) LIKE ? ESCAPE '\\' OR lower(user_tags) LIKE ? ESCAPE '\\') $scope",
      [like, like],
    );
    return rs.first['n'] as int;
  }

  /// Uids of relics carrying [tag] (exact JSON-array match, case-insensitive),
  /// most-recent first, capped at [limit]. Used by query-side tag expansion to
  /// feed the RRF fusion.
  List<String> uidsWithTag(String tag, {bool vaultOnly = false, int limit = 50}) {
    final scope =
        vaultOnly ? 'AND promoted = 1 AND held_by IS NULL' : 'AND held_by IS NULL';
    final like = _tagLike(tag);
    return _db
        .select(
          'SELECT uid FROM relics '
          "WHERE (lower(tags) LIKE ? ESCAPE '\\' OR lower(user_tags) LIKE ? ESCAPE '\\') $scope "
          'ORDER BY created_at DESC LIMIT ?',
          [like, like, limit],
        )
        .map((r) => r['uid'] as String)
        .toList();
  }

  /// (uid, trigger-label) for every snippet — a relic carrying the reserved
  /// 'snippet' user tag. The trigger is the relic's title (fallback: preview);
  /// the picker's trigger-boost matches what the user typed against it. Newest
  /// first, so a fresher snippet wins a trigger collision.
  List<(String, String)> snippetTriggers({bool vaultOnly = false, int limit = 200}) {
    final scope =
        vaultOnly ? 'AND promoted = 1 AND held_by IS NULL' : 'AND held_by IS NULL';
    final like = _tagLike('snippet');
    return _db
        .select(
          'SELECT uid, title, preview FROM relics '
          "WHERE (lower(tags) LIKE ? ESCAPE '\\' OR lower(user_tags) LIKE ? ESCAPE '\\') $scope "
          'ORDER BY created_at DESC LIMIT ?',
          [like, like, limit],
        )
        .map((r) {
          final title = (r['title'] as String?)?.trim() ?? '';
          final trigger = title.isNotEmpty
              ? title
              : ((r['preview'] as String?)?.trim() ?? '');
          return (r['uid'] as String, trigger);
        })
        .toList();
  }

  // --- reads ---

  Relic? getByUid(String uid) {
    final rs = _db.select('SELECT * FROM relics WHERE uid = ?', [uid]);
    return rs.isEmpty ? null : _toRelic(rs.first);
  }

  int? updatedAtOf(String uid) {
    final rs = _db.select('SELECT updated_at FROM relics WHERE uid = ?', [uid]);
    return rs.isEmpty ? null : rs.first['updated_at'] as int;
  }

  // --- Clip reminders (local-only) ---
  // remindAtMs / nowMs are epoch milliseconds. Reminders never sync (this table
  // is off the wire; see the CREATE in _migrate).

  /// Schedule a reminder for [uid] at [remindAtMs]; returns the new row id.
  int addReminder(String uid, int remindAtMs, {String? note}) {
    _db.execute(
      'INSERT INTO reminders (relic_uid, remind_at, note, fired) '
      'VALUES (?, ?, ?, 0)',
      [uid, remindAtMs, note],
    );
    return _db.lastInsertRowId;
  }

  Reminder _toReminder(Row r) => Reminder(
        r['id'] as int,
        r['relic_uid'] as String,
        r['remind_at'] as int,
        r['note'] as String?,
      );

  /// Un-fired reminders whose time has arrived (`remind_at <= nowMs`), oldest
  /// first.
  List<Reminder> dueReminders(int nowMs) {
    final rs = _db.select(
      'SELECT id, relic_uid, remind_at, note FROM reminders '
      'WHERE fired = 0 AND remind_at <= ? ORDER BY remind_at',
      [nowMs],
    );
    return [for (final r in rs) _toReminder(r)];
  }

  /// Pending (un-fired) reminders for one item.
  List<Reminder> remindersFor(String uid) {
    final rs = _db.select(
      'SELECT id, relic_uid, remind_at, note FROM reminders '
      'WHERE relic_uid = ? AND fired = 0 ORDER BY remind_at',
      [uid],
    );
    return [for (final r in rs) _toReminder(r)];
  }

  void markFired(int id) =>
      _db.execute('UPDATE reminders SET fired = 1 WHERE id = ?', [id]);

  void clearReminder(int id) =>
      _db.execute('DELETE FROM reminders WHERE id = ?', [id]);

  /// Find an existing text relic with identical content (for capture dedupe).
  /// Held rows are invisible here on purpose: matching one would swallow the
  /// new copy into a hidden item, and the user would watch a fresh capture
  /// vanish. A re-copy of held content simply becomes a new, visible relic.
  String? uidByContent(String content) {
    final rs = _db.select(
      'SELECT uid FROM relics '
      'WHERE content_hash = ? AND content = ? AND held_by IS NULL LIMIT 1',
      [_hash(content), content],
    );
    return rs.isEmpty ? null : rs.first['uid'] as String;
  }

  String? mostRecentUid() {
    final rs = _db.select(
      'SELECT uid FROM relics WHERE held_by IS NULL '
      'ORDER BY created_at DESC LIMIT 1',
    );
    return rs.isEmpty ? null : rs.first['uid'] as String;
  }

  /// The uid of the [n]-th most recent item across ALL devices (1 = newest),
  /// or null if fewer than [n] items exist. Backs the quick-paste 1-5 hotkeys.
  String? nthMostRecentUid(int n) {
    if (n < 1) return null;
    final rs = _db.select(
      'SELECT uid FROM relics WHERE held_by IS NULL '
      'ORDER BY created_at DESC LIMIT 1 OFFSET ?',
      [n - 1],
    );
    return rs.isEmpty ? null : rs.first['uid'] as String;
  }

  /// A windowed page of results for the active query + scope. Newest first by
  /// default; [oldestFirst] flips to ascending date order. When [byRelevance]
  /// and there's free text, ranks by lexical relevance (bm25) instead of date,
  /// so an exact/concise match outranks a long doc that merely contains the
  /// terms — recency is only the tiebreak.
  List<Relic> queryPage(
    String search,
    Scope scope,
    int limit,
    int offset, {
    bool oldestFirst = false,
    bool byRelevance = false,
    int? createdAfter,
    int? createdBefore,
  }) => _runQuery(
    search,
    scope,
    'r.*',
    limit,
    offset,
    oldestFirst: oldestFirst,
    byRelevance: byRelevance,
    createdAfter: createdAfter,
    createdBefore: createdBefore,
  ).map(_toRelic).toList();

  /// Total matches for the active query + scope (for the result counter).
  int countMatching(
    String search,
    Scope scope, {
    int? createdAfter,
    int? createdBefore,
  }) {
    final rs = _runQuery(
      search,
      scope,
      'COUNT(*) AS n',
      null,
      null,
      createdAfter: createdAfter,
      createdBefore: createdBefore,
    );
    return rs.isEmpty ? 0 : rs.first['n'] as int;
  }

  /// Half-open `[after, before)` predicate fragments on [col], plus their bound
  /// args, for the date filter. Empty list when both bounds are null.
  static (List<String>, List<Object?>) _dateConds(
    int? after,
    int? before,
    String col,
  ) {
    final conds = <String>[];
    final args = <Object?>[];
    if (after != null) {
      conds.add('$col >= ?');
      args.add(after);
    }
    if (before != null) {
      conds.add('$col < ?');
      args.add(before);
    }
    return (conds, args);
  }

  ResultSet _runQuery(
    String search,
    Scope scope,
    String cols,
    int? limit,
    int? offset, {
    bool oldestFirst = false,
    bool byRelevance = false,
    int? createdAfter,
    int? createdBefore,
  }) {
    // Scope gate for every candidate/result query: held rows (the previous
    // account's, awaiting the user's decision) are never search results.
    final scopeAnd = 'AND r.held_by IS NULL'
        "${scope == Scope.vault ? ' AND r.promoted = 1' : ''}";
    final order = oldestFirst ? 'ASC' : 'DESC';
    final tail = limit == null ? '' : 'LIMIT ? OFFSET ?';
    final lim = limit == null ? const <Object?>[] : [limit, offset ?? 0];
    final s = search.trim();

    // Date range — same threading shape as the tag clauses below.
    final (dateConds, dateArgs) = _dateConds(
      createdAfter,
      createdBefore,
      'r.created_at',
    );
    final dateAnd = dateConds.isEmpty ? '' : 'AND ${dateConds.join(' AND ')}';

    // Split the query into `tag:` clauses (AND-ed) and the free-text remainder.
    // Case-insensitive so "Tag:foo" doesn't both filter AND leak "tag foo"
    // into the free text.
    final tagRe = RegExp(r'tag:(\S+)', caseSensitive: false);
    final tags = tagRe
        .allMatches(s)
        .map((m) => m.group(1)!.toLowerCase())
        .toList();

    // Structured operators, same vocabulary as the web vault: `kind:image`,
    // `is:kept`/`is:vault`, `has:file`/`has:image`/`has:blob` become SQL
    // filters and are stripped from the free text. kind: consumes any value
    // (an unknown kind simply matches nothing, like the web); unknown is:/
    // has: values stay literal text. Word-boundary anchored so "analysis:report"
    // isn't half-eaten as is:report.
    final opRe = RegExp(r'(^|\s)(kind|is|has):(\S+)', caseSensitive: false);
    final opConds = <String>[];
    final opArgs = <Object?>[];
    final text = s.replaceAll(tagRe, ' ').replaceAllMapped(opRe, (m) {
      final val = m.group(3)!.toLowerCase();
      switch (m.group(2)!.toLowerCase()) {
        case 'kind':
          opConds.add('r.kind = ?');
          opArgs.add(kKindAliases[val] ?? val);
          return '${m.group(1)} ';
        case 'is':
          if (val == 'kept' || val == 'vault') {
            opConds.add('r.promoted = 1');
            return '${m.group(1)} ';
          }
          break;
        case 'has':
          if (val == 'file' || val == 'image' || val == 'blob') {
            opConds.add('r.blob_key IS NOT NULL');
            return '${m.group(1)} ';
          }
          break;
      }
      return m.group(0)!;
    }).trim();
    final opAnd = opConds.isEmpty ? '' : 'AND ${opConds.join(' AND ')}';

    // Reusable AND-ed LIKE clauses for the tag filters. The JSON-array quotes
    // make this an exact tag match (`tag:ip` must not match `zip`/`script`),
    // consistent with [countTag]/[uidsWithTag]; wildcards in the tag escaped.
    final tagSql = <String>[];
    final tagArgs = <Object?>[];
    for (final t in tags) {
      tagSql.add(
          "(lower(r.tags) LIKE ? ESCAPE '\\' OR lower(r.user_tags) LIKE ? ESCAPE '\\')");
      final like = _tagLike(t);
      tagArgs
        ..add(like)
        ..add(like);
    }
    final tagAnd = tagSql.isEmpty ? '' : 'AND ${tagSql.join(' AND ')}';

    // No free text → browse / filter-only (tags/operators), ordered by date.
    if (text.isEmpty) {
      final conds = <String>[
        'r.held_by IS NULL',
        if (scope == Scope.vault) 'r.promoted = 1',
        ...tagSql,
        ...opConds,
        ...dateConds,
      ];
      final where = conds.isEmpty ? '' : 'WHERE ${conds.join(' AND ')}';
      return _db.select(
        'SELECT $cols FROM relics r $where ORDER BY r.created_at $order $tail',
        [...tagArgs, ...opArgs, ...dateArgs, ...lim],
      );
    }

    final terms = _queryTerms(text);
    final match = _ftsExpr(text);
    if (match == null) {
      // free text present but not tokenizable: fall back to filter-only if
      // any tags/operators, else no matches.
      if (tagSql.isNotEmpty || opConds.isNotEmpty) {
        return _db.select(
          'SELECT $cols FROM relics r '
          'WHERE ${[...tagSql, ...opConds].join(' AND ')} $scopeAnd $dateAnd '
          'ORDER BY r.created_at $order $tail',
          [...tagArgs, ...opArgs, ...dateArgs, ...lim],
        );
      }
      return _db.select('SELECT $cols FROM relics r WHERE 0');
    }
    // Relevance ordering: literal body > literal tags > injected aux (see
    // kFtsRank), with bm25 ties broken by recency. NB: bm25 weights are
    // positional over ALL declared columns including UNINDEXED ones, so the
    // leading 0.0 covers `uid`. Skipped for COUNT(*) (limit == null) — bm25 in
    // an aggregate ORDER BY is meaningless and can error.
    final ftsOrder = (byRelevance && limit != null)
        ? '$kFtsRank, r.created_at DESC'
        : 'r.created_at $order';
    // The fallback reuses `ftsOrder`, so it honors the user's chosen sort
    // (newest/oldest stay date-ordered; relevance uses bm25) instead of forcing
    // relevance on a date-sorted query.
    ResultSet runMatch(String expr) => _db.select(
          '''SELECT $cols FROM relics_fts JOIN relics r ON r.uid = relics_fts.uid
               WHERE relics_fts MATCH ? $scopeAnd $tagAnd $opAnd $dateAnd
               ORDER BY $ftsOrder $tail''',
          [expr, ...tagArgs, ...opArgs, ...dateArgs, ...lim],
        );
    bool noHits(ResultSet rs) => cols.startsWith('COUNT(')
        ? (rs.isEmpty || (rs.first['n'] as int? ?? 0) == 0)
        : rs.isEmpty;
    try {
      final andRs = runMatch(match);
      if (!noHits(andRs)) return andRs;
      // Relax only when strict AND found nothing, the terms aren't all
      // stopwords (an all-stopword query stays precise rather than
      // OR-exploding to most of the corpus), and we're on the FIRST page —
      // with an offset, "no rows" just means the offset passed the rung's hit
      // count, and silently switching rungs mid-pagination would splice
      // different result sets together.
      final allStop = terms.every(_stopwords.contains);
      final neg = _negTerms(text);
      if (!allStop && (offset ?? 0) == 0) {
        // (a) concept phrases stored as ONE token: "api key"→apikey,
        // "ip address"→ipaddress, "zip code"→zipcode. Precise, so try first.
        if (terms.length >= 2 && terms.length <= 4) {
          final concatRs = runMatch(_applyNeg('"${terms.join()}"*', neg));
          if (!noHits(concatRs)) return concatRs;
        }
        // (b) synonym-expanded AND: a term that is a known tag synonym also
        // tries its canonical words ("pw" → password/secret). Recall-only —
        // it runs only after the literal query found nothing.
        final expanded = _ftsExpr(text, expand: true);
        if (expanded != null && expanded != match) {
          final expRs = runMatch(expanded);
          if (!noHits(expRs)) return expRs;
        }
        // (c) broad OR recall — bm25 keeps items matching more terms on top.
        if (terms.length >= 2) {
          return runMatch(_ftsExpr(text, or: true)!);
        }
      }
      return andRs;
    } on SqliteException {
      // FTS rejected the expression — fall back to a LIKE scan so search
      // never hard-fails on odd input. Per-term AND-ed substrings (not one
      // contiguous phrase), over the same user-visible text columns + note;
      // `-word` exclusions still apply.
      final likeTerms = terms.isEmpty ? [text.toLowerCase()] : terms;
      final negTerms = _negTerms(text);
      const likeCols = [
        "lower(coalesce(r.content,''))",
        "lower(coalesce(r.title,''))",
        "lower(coalesce(r.preview,''))",
        "lower(coalesce(r.filename,''))",
        "lower(coalesce(r.note,''))",
      ];
      String anyCol() => '(${likeCols.map((c) => '$c LIKE ?').join(' OR ')})';
      final termSql = [
        ...likeTerms.map((_) => anyCol()),
        ...negTerms.map((_) => 'NOT ${anyCol()}'),
      ].join(' AND ');
      final likeArgs = [
        for (final t in [...likeTerms, ...negTerms])
          ...List.filled(likeCols.length, '%$t%'),
      ];
      return _db.select(
        '''SELECT $cols FROM relics r
             WHERE $termSql $scopeAnd $tagAnd $opAnd $dateAnd
             ORDER BY r.created_at $order $tail''',
        [...likeArgs, ...tagArgs, ...opArgs, ...dateArgs, ...lim],
      );
    }
  }

  /// Lexical candidate uids for [search], ranked by relevance (bm25). Empty on
  /// no tokenizable terms. For the hybrid-search candidate pool.
  List<String> ftsCandidates(
    String search,
    Scope scope,
    int limit, {
    int? createdAfter,
    int? createdBefore,
  }) {
    final terms = _queryTerms(search);
    final match = _ftsExpr(search);
    if (match == null) return const [];
    // Scope gate for every candidate/result query: held rows (the previous
    // account's, awaiting the user's decision) are never search results.
    final scopeAnd = 'AND r.held_by IS NULL'
        "${scope == Scope.vault ? ' AND r.promoted = 1' : ''}";
    final (dateConds, dateArgs) =
        _dateConds(createdAfter, createdBefore, 'r.created_at');
    final dateAnd = dateConds.isEmpty ? '' : 'AND ${dateConds.join(' AND ')}';
    List<String> run(String expr) {
      try {
        return _db
            .select(
              'SELECT r.uid FROM relics_fts JOIN relics r ON r.uid = relics_fts.uid '
              // Same weighted rank as the instant view, so the hybrid lexical
              // anchor doesn't reshuffle results when the refine lands.
              'WHERE relics_fts MATCH ? $scopeAnd $dateAnd ORDER BY $kFtsRank LIMIT ?',
              [expr, ...dateArgs, limit],
            )
            .map((r) => r['uid'] as String)
            .toList();
      } on SqliteException {
        return const [];
      }
    }

    // Same AND → concat → expanded → OR relaxation as _runQuery, so the hybrid
    // lexical anchor matches what the instant lexical view already showed (a
    // fallback-only hit doesn't vanish when the async refine swaps the window).
    final and = run(match);
    if (and.isNotEmpty || terms.every(_stopwords.contains)) return and;
    if (terms.length >= 2 && terms.length <= 4) {
      final concat = run(_applyNeg('"${terms.join()}"*', _negTerms(search)));
      if (concat.isNotEmpty) return concat;
    }
    final expanded = _ftsExpr(search, expand: true);
    if (expanded != null && expanded != match) {
      final exp = run(expanded);
      if (exp.isNotEmpty) return exp;
    }
    if (terms.length >= 2) return run(_ftsExpr(search, or: true)!);
    return and;
  }

  /// Substring / typo-tolerant candidate uids via the trigram index. Each query
  /// word ≥3 chars is matched as an exact substring (quoted phrase = contiguous
  /// trigrams) OR as its individual 3-grams — the OR of loose trigrams is what
  /// gives real typo recall: a misspelled word ("kubernetse") is no substring
  /// of the stored text, but it still shares most trigrams, and bm25 floats the
  /// docs sharing the most of them to the top. Words are OR-combined; both the
  /// indexed body and the query are diacritic-folded so "cafe" finds "café".
  List<String> trigramCandidates(
    String search,
    Scope scope,
    int limit, {
    int? createdAfter,
    int? createdBefore,
  }) {
    final words = _foldDiacritics(search)
        .split(RegExp(r'\s+'))
        .map((w) => w.replaceAll('"', ''))
        .where((w) => w.length >= 3)
        .toList();
    if (words.isEmpty) return const [];
    String wordExpr(String w) {
      // Exact-substring phrase first; loose trigrams (deduped) for fuzz. Words
      // of exactly 3 chars ARE a single trigram — the phrase alone covers them.
      final parts = <String>{'"$w"'};
      if (w.length >= 4) {
        for (var i = 0; i + 3 <= w.length; i++) {
          parts.add('"${w.substring(i, i + 3)}"');
        }
      }
      return parts.length == 1 ? parts.first : '(${parts.join(' OR ')})';
    }

    final expr = words.map(wordExpr).join(' OR ');
    // Scope gate for every candidate/result query: held rows (the previous
    // account's, awaiting the user's decision) are never search results.
    final scopeAnd = 'AND r.held_by IS NULL'
        "${scope == Scope.vault ? ' AND r.promoted = 1' : ''}";
    final (dateConds, dateArgs) =
        _dateConds(createdAfter, createdBefore, 'r.created_at');
    final dateAnd = dateConds.isEmpty ? '' : 'AND ${dateConds.join(' AND ')}';
    try {
      return _db
          .select(
            'SELECT r.uid FROM relics_tri JOIN relics r ON r.uid = relics_tri.uid '
            'WHERE relics_tri MATCH ? $scopeAnd $dateAnd ORDER BY bm25(relics_tri) LIMIT ?',
            [expr, ...dateArgs, limit],
          )
          .map((r) => r['uid'] as String)
          .toList();
    } on SqliteException {
      return const [];
    }
  }

  /// Candidate uids for a query that NAMES a tag: in "relic link", "link"
  /// unambiguously names the `url` tag (via [tagIntentOf]), so items CARRYING
  /// that tag — filtered by the residual terms ("relic") and ranked by the
  /// same weighted bm25 as the lexical leg — are what the user means. This is
  /// the lexical answer to type-word queries: for an actual link, the type
  /// word only exists in the injected aux vocabulary (bm25 weight 3), so
  /// plain FTS ranks it below any long document whose BODY merely says
  /// "link" (weight 10) — a screenshot OCR beats the real thing.
  ///
  /// Precise by construction: fires only on unambiguous tag names (max 2),
  /// and a residual that matches nothing inside the tag set returns empty
  /// rather than degrading to a bare tag dump. No residual (the whole query
  /// is tag names — "links") → the tag's items newest-first, like its
  /// collection chip. Quoted queries mean literal text and skip the leg.
  List<String> tagIntentCandidates(
    String search,
    Scope scope,
    int limit, {
    int? createdAfter,
    int? createdBefore,
  }) {
    final s = search.trim();
    if (s.contains('"')) return const [];
    final fired = <String>[];
    final residual = <String>[];
    for (final t in _queryTerms(s)) {
      final tag = tagIntentOf(t);
      if (tag != null && !fired.contains(tag) && fired.length < 2) {
        fired.add(tag);
      } else if (tag == null) {
        residual.add(t);
      }
    }
    if (fired.isEmpty) return const [];
    final tagSql = [
      for (final _ in fired)
        "(lower(r.tags) LIKE ? ESCAPE '\\' OR lower(r.user_tags) LIKE ? ESCAPE '\\')",
    ].join(' OR ');
    final tagArgs = <Object?>[
      for (final t in fired) ...[_tagLike(t), _tagLike(t)],
    ];
    // Scope gate for every candidate/result query: held rows (the previous
    // account's, awaiting the user's decision) are never search results.
    final scopeAnd = 'AND r.held_by IS NULL'
        "${scope == Scope.vault ? ' AND r.promoted = 1' : ''}";
    final (dateConds, dateArgs) =
        _dateConds(createdAfter, createdBefore, 'r.created_at');
    final dateAnd = dateConds.isEmpty ? '' : 'AND ${dateConds.join(' AND ')}';
    if (residual.isEmpty) {
      return _db
          .select(
            'SELECT r.uid FROM relics r WHERE ($tagSql) $scopeAnd $dateAnd '
            'ORDER BY r.created_at DESC LIMIT ?',
            [...tagArgs, ...dateArgs, limit],
          )
          .map((r) => r['uid'] as String)
          .toList();
    }
    List<String> run(String expr) {
      try {
        return _db
            .select(
              'SELECT r.uid FROM relics_fts JOIN relics r ON r.uid = relics_fts.uid '
              'WHERE relics_fts MATCH ? AND ($tagSql) $scopeAnd $dateAnd '
              'ORDER BY $kFtsRank LIMIT ?',
              [expr, ...tagArgs, ...dateArgs, limit],
            )
            .map((r) => r['uid'] as String)
            .toList();
      } on SqliteException {
        return const [];
      }
    }

    final and = run(residual.map((t) => '"$t"*').join(' AND '));
    if (and.isNotEmpty || residual.length < 2) return and;
    return run(residual.map((t) => '"$t"*').join(' OR '));
  }

  /// RRF weight of the tag-intent leg wherever the hybrid fusion runs. Equal
  /// to the lexical leg's: a term the user typed that names a tag is explicit
  /// intent, and it must survive the fts+trigram agreement boost that long
  /// documents containing the literal type word otherwise collect. Calibrated
  /// 2026-07 on the live corpus ("relic link"): 1.0 left OCR'd screenshots of
  /// the app above the actual relic.space links, 1.5 was the tipping point
  /// ML-free, 2.0 also holds against the semantic legs.
  static const double kTagIntentWeight = 2.0;

  /// Multiplicative fused-score factor for promoted (vault-kept) items.
  /// Deliberately saved items should win TIES against clipboard noise — and
  /// a multiplier is the only shape that can express "tie-break only": in
  /// RRF space rank-adjacent items sit ~1.5% apart while a clear relevance
  /// win leads by 10%+, so ANY exclusive extra leg (even recency-weight)
  /// jumps kept items over clearly better matches, but a 5% factor flips
  /// near-ties and nothing else. All scope only (in Vault everything is
  /// kept).
  static const double kKeptBoostFactor = 1.05;

  /// Max fused-score gain from usage (the cornerstone boost). A multiplier,
  /// not a leg, for the same reason as [kKeptBoostFactor] — it only ever
  /// amplifies items that already matched the query, so usage alone can never
  /// surface a non-match. Unlike the kept boost it SCALES with use: in RRF
  /// space adjacent ranks sit ~1.5% apart and a clear relevance win leads by
  /// 10%+, so the 25% cap lets a true cornerstone jump one-to-two clear-win
  /// tiers while a barely-touched item moves a rank or two at most.
  static const double kUseBoostMax = 0.25;

  /// Decayed touches at which the boost reaches half of [kUseBoostMax]
  /// (saturating curve `d / (d + half)` — bounded, monotone, no cliff).
  static const double kUseBoostHalf = 5.0;

  /// Fused-score multiplier for a decayed use count.
  static double useFactor(double decayed) => decayed <= 0
      ? 1.0
      : 1.0 + kUseBoostMax * decayed / (decayed + kUseBoostHalf);

  /// Per-uid usage factors for a candidate union (one IN query; only uids
  /// with any usage appear — absent means 1.0). [now] in epoch seconds.
  Map<String, double> useFactors(List<String> uids, int now) {
    if (uids.isEmpty) return const {};
    final ph = List.filled(uids.length, '?').join(',');
    final rows = _db.select(
      'SELECT uid, use_count, last_used_at FROM relics '
      'WHERE uid IN ($ph) AND use_count > 0',
      uids,
    );
    final out = <String, double>{};
    for (final r in rows) {
      final d = decayedUse(
          (r['use_count'] as num).toDouble(), r['last_used_at'] as int?, now);
      if (d > 0) out[r['uid'] as String] = useFactor(d);
    }
    return out;
  }

  /// Query-pick boost curve: as strong as usage ([kUseBoostMax]) but earned
  /// faster (half the cap at 3 picks vs 5 touches) — "I searched these words
  /// and chose THIS" is the most explicit personal signal there is.
  static const double kQueryBoostMax = 0.25;
  static const double kQueryBoostHalf = 3.0;

  /// Context boosts are deliberately weaker: "summoned over this app" is a
  /// prior, not intent. The uid curve rewards the exact items pasted into
  /// the app before; the tag curve generalizes to new items of a type and
  /// is capped near tie-break territory so a wrong prior can't reorder
  /// anything the user would call a mistake.
  static const double kCtxBoostMax = 0.15;
  static const double kCtxBoostHalf = 3.0;
  static const double kCtxTagBoostMax = 0.08;
  static const double kCtxTagBoostHalf = 5.0;

  /// Ceiling on the PRODUCT of all personal factors (usage x query-pick x
  /// context). In RRF space a clear relevance win leads by 10%+, so 1.5x
  /// lets a fully-earned cornerstone jump at most ~3 clear-win tiers among
  /// items that matched the query; unbounded stacking would read as "search
  /// is broken", not "search knows me".
  static const double kPersonalBoostCap = 1.5;

  static double _sat(double s, double max, double half) =>
      s <= 0 ? 1.0 : 1.0 + max * s / (s + half);

  /// All personal ranking factors for a candidate union, multiplied and
  /// clamped at [kPersonalBoostCap]: usage frecency, query-pick memory (when
  /// [query] has free text), and destination-context memory (when [app] is
  /// the summon-time foreground app). Every component reads only decaying
  /// local counters; an absent uid means 1.0 — personalization can only
  /// amplify items that already matched.
  Map<String, double> rankFactors(
    List<String> union, {
    String? query,
    String? app,
    required int now,
  }) {
    if (union.isEmpty) return const {};
    final out = useFactors(union, now);
    void mul(Map<String, double> part) {
      part.forEach((u, f) {
        if (f != 1.0) out[u] = (out[u] ?? 1.0) * f;
      });
    }

    if (query != null) mul(_queryPickFactors(query, union, now));
    if (app != null) mul(_contextFactors(app, union, now));
    out.updateAll((_, f) => f > kPersonalBoostCap ? kPersonalBoostCap : f);
    return out;
  }

  Map<String, double> _queryPickFactors(
      String query, List<String> union, int now) {
    final terms = memoryTerms(query);
    if (terms.isEmpty) return const {};
    final tph = List.filled(terms.length, '?').join(',');
    final uph = List.filled(union.length, '?').join(',');
    final rows = _db.select(
      'SELECT uid, count, last_at FROM query_memory '
      'WHERE term IN ($tph) AND uid IN ($uph)',
      [...terms, ...union],
    );
    if (rows.isEmpty) return const {};
    final sum = <String, double>{};
    for (final r in rows) {
      final d = decayedUse(
          (r['count'] as num).toDouble(), r['last_at'] as int, now);
      sum[r['uid'] as String] = (sum[r['uid'] as String] ?? 0) + d;
    }
    return sum.map((u, s) => MapEntry(u, _sat(s, kQueryBoostMax, kQueryBoostHalf)));
  }

  Map<String, double> _contextFactors(String app, List<String> union, int now) {
    final uph = List.filled(union.length, '?').join(',');
    final out = <String, double>{};
    for (final r in _db.select(
      "SELECT key, count, last_at FROM context_memory "
      "WHERE app = ? AND kind = 'uid' AND key IN ($uph)",
      [app, ...union],
    )) {
      final d = decayedUse(
          (r['count'] as num).toDouble(), r['last_at'] as int, now);
      if (d > 0) out[r['key'] as String] = _sat(d, kCtxBoostMax, kCtxBoostHalf);
    }
    // Tag generalization: decayed weight per tag pasted into this app, then
    // summed over each candidate's tags. Skips the union tags fetch when the
    // app has no tag history (the common case).
    final tagWeight = <String, double>{};
    for (final r in _db.select(
      "SELECT key, count, last_at FROM context_memory "
      "WHERE app = ? AND kind = 'tag'",
      [app],
    )) {
      final d = decayedUse(
          (r['count'] as num).toDouble(), r['last_at'] as int, now);
      if (d > 0) tagWeight[r['key'] as String] = d;
    }
    if (tagWeight.isEmpty) return out;
    for (final r in _db.select(
      'SELECT uid, tags, user_tags FROM relics WHERE uid IN ($uph)',
      union,
    )) {
      var s = 0.0;
      for (final t in [..._jsonList(r['tags']), ..._jsonList(r['user_tags'])]) {
        s += tagWeight[t.toLowerCase()] ?? 0;
      }
      if (s > 0) {
        final u = r['uid'] as String;
        out[u] =
            (out[u] ?? 1.0) * _sat(s, kCtxTagBoostMax, kCtxTagBoostHalf);
      }
    }
    return out;
  }

  /// `kind:` operator aliases — the same vocabulary as the web vault
  /// (vault-search.ts KIND_ALIASES). Unknown values pass through raw and
  /// simply match nothing.
  static const kKindAliases = <String, String>{
    'text': 'string',
    'string': 'string',
    'image': 'photo',
    'photo': 'photo',
    'img': 'photo',
    'file': 'file',
    'files': 'file',
    'other': 'other',
  };

  /// Subset of [uids] (preserving their order) whose `created_at` falls in the
  /// half-open `[after, before)` range. Returns the input untouched when both
  /// bounds are null. Used to date-filter the in-memory semantic candidates.
  List<String> filterByDate(List<String> uids, int? after, int? before) {
    if ((after == null && before == null) || uids.isEmpty) return uids;
    final ph = List.filled(uids.length, '?').join(',');
    final (conds, dateArgs) = _dateConds(after, before, 'created_at');
    final ok = _db
        .select(
          'SELECT uid FROM relics WHERE uid IN ($ph) AND ${conds.join(' AND ')}',
          [...uids, ...dateArgs],
        )
        .map((r) => r['uid'] as String)
        .toSet();
    return [
      for (final u in uids)
        if (ok.contains(u)) u,
    ];
  }

  /// [uids] reordered newest-first — the recency leg for the RRF fusion, so
  /// two similarly-relevant items rank the recent one first.
  List<String> byRecency(List<String> uids) {
    if (uids.isEmpty) return const [];
    final ph = List.filled(uids.length, '?').join(',');
    return _db
        .select(
          'SELECT uid FROM relics WHERE uid IN ($ph) ORDER BY created_at DESC',
          uids,
        )
        .map((r) => r['uid'] as String)
        .toList();
  }

  /// Fetch relics by uid, returned in the given uid order (for ranked results).
  ///
  /// This is where a ranked list becomes rows on screen, so it is also the
  /// backstop for the holdback: the in-memory semantic legs rank from cached
  /// embeddings that still cover held rows, and a held uid that reaches a
  /// ranking simply materializes to nothing (the caller prunes the gap).
  List<Relic> byUids(List<String> uids) {
    if (uids.isEmpty) return const [];
    final ph = List.filled(uids.length, '?').join(',');
    final rows = _db.select(
      'SELECT * FROM relics WHERE uid IN ($ph) AND held_by IS NULL',
      uids,
    );
    final byId = {for (final row in rows) row['uid'] as String: _toRelic(row)};
    return [
      for (final u in uids)
        if (byId[u] != null) byId[u]!,
    ];
  }

  /// ML-free hybrid ranking: the portable core of the desktop hybrid search.
  /// Fuses the lexical (bm25 FTS), trigram (substring/typo), and a mild recency
  /// prior via weighted Reciprocal Rank Fusion — no on-device ML, so the mobile
  /// lens (which has no sift sidecar) gets the same relevance ranking, synonym
  /// expansion, and typo recall the desktop shows. The desktop repo layers the
  /// semantic + tag-expansion legs on top of the same primitives when sift is
  /// present. Returns the ranked uid list, or null when there's nothing to rank.
  List<String>? lexicalHybridUids(
    String search,
    Scope scope, {
    int? createdAfter,
    int? createdBefore,
    int? now, // injectable clock (epoch secs) for the usage decay, tests only
    // Extra per-uid personal factors for the candidate union, multiplied into
    // the internal [rankFactors] and re-clamped at [kPersonalBoostCap]. The
    // mobile lens supplies these from its on-disk PersonalStore (this index is
    // ephemeral and its terms-at-rest are hashed, so the counters can't live
    // in here); absent → behavior unchanged.
    Map<String, double> Function(List<String> union)? factorsFor,
  }) {
    final s = search.trim();
    if (s.isEmpty) return null;
    final fts = ftsCandidates(s, scope, _hybridPool,
        createdAfter: createdAfter, createdBefore: createdBefore);
    // When the literal query already hits, keep only a short fuzzy tail (typo
    // recall matters most when the exact words found nothing).
    final tri = trigramCandidates(s, scope, fts.isEmpty ? _hybridTriPool : 15,
        createdAfter: createdAfter, createdBefore: createdBefore);
    final tagIntent = tagIntentCandidates(s, scope, 50,
        createdAfter: createdAfter, createdBefore: createdBefore);
    final union = <String>{...fts, ...tri, ...tagIntent}.toList();
    final recency = byRecency(union);
    // Lexical leg carries double weight so an exact/concise match stays on top;
    // trigram adds recall; tag-intent puts items that ARE the named type above
    // items that merely say its word; recency is a light tiebreak; kept items
    // win near-ties via the score factor; often-touched / often-picked-for-
    // these-terms items climb via the personal factors. Mirrors the desktop
    // weights (minus the ML semantic/tag legs and the summon context, which
    // only desktop has).
    var factors = rankFactors(union,
        query: s, now: now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final extra = factorsFor?.call(union);
    if (extra != null && extra.isNotEmpty) {
      factors = Map.of(factors); // rankFactors may hand back const {}
      extra.forEach((u, f) {
        if (f != 1.0) factors[u] = (factors[u] ?? 1.0) * f;
      });
      factors.updateAll(
          (_, f) => f > kPersonalBoostCap ? kPersonalBoostCap : f);
    }
    final ranked = rrfFuse(
      [fts, tri, tagIntent, recency],
      weights: const [2.0, 1.0, kTagIntentWeight, 0.5],
      boostUids: scope == Scope.vault ? null : promotedUids(),
      boostFactor: kKeptBoostFactor,
      factors: factors,
    );
    return ranked.isEmpty ? null : ranked;
  }

  static const int _hybridPool = 150; // lexical candidate pool
  static const int _hybridTriPool = 50; // trigram pool (recall leg — kept tight)

  /// Weighted Reciprocal Rank Fusion of several ranked uid lists. A uid found by
  /// several legs sums their contributions (agreement boost). Shared so both the
  /// desktop and mobile hybrids fuse identically. Uids in [boostUids] get their
  /// fused score multiplied by [boostFactor] — a near-tie tiebreak (see
  /// [kKeptBoostFactor] for why a multiplier and not a leg). [factors] are
  /// per-uid multipliers on top (the usage boost — see [kUseBoostMax]); a
  /// factor for a uid no leg found is ignored.
  static List<String> rrfFuse(
    List<List<String>> lists, {
    int k = 60,
    List<double>? weights,
    Set<String>? boostUids,
    double boostFactor = 1.0,
    Map<String, double>? factors,
  }) {
    final score = <String, double>{};
    for (var l = 0; l < lists.length; l++) {
      final w = (weights != null && l < weights.length) ? weights[l] : 1.0;
      final list = lists[l];
      for (var i = 0; i < list.length; i++) {
        score[list[i]] = (score[list[i]] ?? 0) + w / (k + i + 1);
      }
    }
    if (boostUids != null && boostFactor != 1.0) {
      for (final u in boostUids) {
        final s = score[u];
        if (s != null) score[u] = s * boostFactor;
      }
    }
    if (factors != null) {
      factors.forEach((u, f) {
        final s = score[u];
        if (s != null && f != 1.0) score[u] = s * f;
      });
    }
    final entries = score.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return [for (final e in entries) e.key];
  }

  // --- vectors (semantic search) ---

  /// Replace ALL stored chunk vectors for [uid] atomically. Chunk 0 is the
  /// whole-doc embedding; further entries cover long-document chunks. An empty
  /// [chunks] is a no-op — clearing vectors happens only via delete.
  void upsertVectors(String uid, List<List<double>> chunks) {
    if (chunks.isEmpty) return;
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM vectors WHERE uid = ?', [uid]);
      for (var i = 0; i < chunks.length; i++) {
        final bytes = Float32List.fromList(chunks[i]).buffer.asUint8List();
        _db.execute(
          'INSERT INTO vectors (uid, chunk, dim, vec) VALUES (?,?,?,?)',
          [uid, i, chunks[i].length, bytes],
        );
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void upsertVector(String uid, List<double> vec) => upsertVectors(uid, [vec]);

  // --- open-vocabulary tag vocabulary ---------------------------------------

  /// Current representatives with their **group** totals — the shape
  /// `sift tags bound` wants as `vocabulary`. A representative's count is the
  /// sum over its whole group, because that is what promotion is measured on.
  List<TagVocabRow> tagVocabReps() {
    final rs = _db.select('''
      SELECT v.tag AS tag, v.dim AS dim, v.vec AS vec,
             (SELECT SUM(w.count) FROM tag_vocab w WHERE w.canonical = v.tag) AS total
      FROM tag_vocab v WHERE v.tag = v.canonical
    ''');
    return [
      for (final r in rs)
        TagVocabRow(
          tag: r['tag'] as String,
          canonical: r['tag'] as String,
          count: (r['total'] as int?) ?? 0,
          vec: _vecOf(r['vec'], (r['dim'] as int?) ?? 0),
        ),
    ];
  }

  /// Every row, aliases included — what reconcile needs (see the table comment).
  List<TagVocabRow> tagVocabAll() {
    final rs = _db.select(
      'SELECT tag, canonical, count, dim, vec FROM tag_vocab',
    );
    return [
      for (final r in rs)
        TagVocabRow(
          tag: r['tag'] as String,
          canonical: r['canonical'] as String,
          count: (r['count'] as int?) ?? 0,
          vec: _vecOf(r['vec'], (r['dim'] as int?) ?? 0),
        ),
    ];
  }

  static List<double> _vecOf(Object? blob, int dim) {
    if (blob is! Uint8List || dim == 0) return const [];
    return Float32List.view(blob.buffer, blob.offsetInBytes, dim).toList();
  }

  /// Record one batch of emissions: bump each emitted string's own count,
  /// inserting it (with its vector) the first time it is seen.
  ///
  /// [emitted] may repeat — repetition is the promotion signal. [mapping] is
  /// the sidecar's `emitted -> canonical`, and [vectors] its `added` payload.
  void recordTagEmissions(
    List<String> emitted,
    Map<String, String> mapping,
    Map<String, List<double>> vectors,
  ) {
    if (emitted.isEmpty) return;
    _db.execute('BEGIN');
    try {
      for (final t in emitted) {
        final canonical = mapping[t] ?? t;
        final vec = vectors[t];
        _db.execute(
          '''
          INSERT INTO tag_vocab (tag, canonical, count, dim, vec)
          VALUES (?, ?, 1, ?, ?)
          ON CONFLICT(tag) DO UPDATE SET count = count + 1
          ''',
          [
            t,
            canonical,
            vec?.length ?? 0,
            vec == null ? null : Float32List.fromList(vec).buffer.asUint8List(),
          ],
        );
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Canonical forms that have NOT yet earned a visible facet chip — group
  /// total below [minCount]. They stay in `relics.tags` so full-text search
  /// finds them; the UI just doesn't render them as chips.
  Set<String> provisionalTags(int minCount) {
    final rs = _db.select(
      '''
      SELECT canonical, SUM(count) AS total FROM tag_vocab
      GROUP BY canonical HAVING total < ?
      ''',
      [minCount],
    );
    return {for (final r in rs) r['canonical'] as String};
  }

  /// Apply a reconcile mapping: repoint every row at its new representative and
  /// rewrite the stored tags of every relic that used an old one.
  ///
  /// Returns the number of relics rewritten.
  int applyTagReconcile(Map<String, String> mapping) {
    final moved = {
      for (final e in mapping.entries)
        if (e.key != e.value) e.key: e.value,
    };
    if (moved.isEmpty) return 0;
    var touched = 0;
    _db.execute('BEGIN');
    try {
      for (final e in mapping.entries) {
        _db.execute('UPDATE tag_vocab SET canonical = ? WHERE tag = ?', [
          e.value,
          e.key,
        ]);
      }
      // Only relics actually carrying a moved tag need rewriting.
      final rows = _db.select('SELECT uid, tags FROM relics WHERE tags IS NOT NULL');
      for (final row in rows) {
        final tags = _jsonList(row['tags']);
        var changed = false;
        final out = <String>[];
        for (final t in tags) {
          final to = moved[t];
          if (to == null) {
            if (!out.contains(t)) out.add(t);
            continue;
          }
          changed = true;
          if (!out.contains(to)) out.add(to);
        }
        if (!changed) continue;
        _db.execute('UPDATE relics SET tags = ? WHERE uid = ?', [
          jsonEncode(out),
          row['uid'],
        ]);
        touched++;
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    if (touched > 0) _reindexAll(_db);
    return touched;
  }

  bool hasVector(String uid) => _db.select(
    'SELECT 1 FROM vectors WHERE uid = ? LIMIT 1',
    [uid],
  ).isNotEmpty;

  /// Number of relics with at least one stored embedding.
  int get vectorCount =>
      (_db.select('SELECT COUNT(DISTINCT uid) AS n FROM vectors').first['n']
          as int);

  /// All stored vectors (one row per chunk), for brute-force cosine search.
  List<({String uid, int chunk, Float32List vec})> allVectors() => _db
      .select('SELECT uid, chunk, dim, vec FROM vectors ORDER BY uid, chunk')
      .map((r) {
        final blob = r['vec'] as Uint8List;
        final dim = r['dim'] as int;
        final f = blob.buffer.asFloat32List(blob.offsetInBytes, dim);
        return (
          uid: r['uid'] as String,
          chunk: r['chunk'] as int,
          vec: Float32List.fromList(f),
        );
      })
      .toList();

  /// Uids of all vault (promoted) relics — the allow-set for vault-scoped
  /// semantic search (filtering BEFORE top-K, so strong vault matches aren't
  /// truncated away by unpromoted neighbors).
  Set<String> promotedUids() => _db
      .select('SELECT uid FROM relics WHERE promoted = 1 AND held_by IS NULL')
      .map((r) => r['uid'] as String)
      .toSet();

  /// All relics, newest first — used at connect time (push) and for `all`.
  /// Held rows are excluded: this is both the whole-vault push surface (they
  /// must never reach the account they don't belong to) and the repo's `all`.
  List<Relic> allRows() => _db
      .select(
        'SELECT * FROM relics WHERE held_by IS NULL ORDER BY created_at DESC',
      )
      .map(_toRelic)
      .toList();

  /// (uid, blobKey) for photos whose bytes aren't local yet — for eager
  /// thumbnail prefetch. Bounded by [limit].
  List<({String uid, String blobKey})> photosMissingBlob(int limit) => _db
      .select(
        "SELECT uid, blob_key FROM relics WHERE kind = 'photo' "
        'AND blob_key IS NOT NULL AND have_blob = 0 AND held_by IS NULL '
        'LIMIT ?',
        [limit],
      )
      .map((r) => (uid: r['uid'] as String, blobKey: r['blob_key'] as String))
      .toList();

  /// Nothing to show. A vault whose every row is held back reads as empty,
  /// which is exactly what the user sees.
  bool get isEmpty =>
      (_db.select('SELECT 1 FROM relics WHERE held_by IS NULL LIMIT 1')).isEmpty;

  /// Local-only account aggregates: total bytes + promoted count. Counts HELD
  /// rows too — this is disk accounting, and their bytes are really on disk.
  (int bytes, int vault) localAggregate() {
    final rs = _db.select(
      'SELECT COALESCE(SUM(byte_size),0) AS b, COALESCE(SUM(promoted),0) AS v FROM relics',
    );
    final row = rs.first;
    return ((row['b'] as num).toInt(), (row['v'] as num).toInt());
  }

  /// Count of unpromoted (history/stream) relics — the pool a keep-N cap rings.
  int countUnpromoted() {
    final rs = _db.select(
      'SELECT COUNT(*) AS n FROM relics WHERE promoted = 0 AND held_by IS NULL',
    );
    return (rs.first['n'] as num).toInt();
  }

  /// Every relic the user can actually see. Held rows are counted by
  /// [countHeld] instead — they are not part of this vault right now.
  int countAll() {
    final rs = _db.select(
      'SELECT COUNT(*) AS n FROM relics WHERE held_by IS NULL',
    );
    return (rs.first['n'] as num).toInt();
  }

  /// The oldest unpromoted relics beyond the newest [keep] — i.e. the ones a
  /// keep-N retention cap should evict. Mirrors the server ring prune query
  /// (`worker/src/index.ts`). Returns (uid, blobKey) newest-skipped, oldest-first.
  List<({String uid, String? blobKey})> unpromotedBeyond(int keep) => _db
      .select(
        'SELECT uid, blob_key FROM relics '
        'WHERE promoted = 0 AND held_by IS NULL '
        'ORDER BY created_at DESC LIMIT -1 OFFSET ?',
        [keep],
      )
      .map((r) => (uid: r['uid'] as String, blobKey: r['blob_key'] as String?))
      .toList();

  /// Unpromoted relics captured strictly before [cutoff] (epoch s) — the
  /// age-based retention sibling of [unpromotedBeyond]. Vault is immune.
  List<({String uid, String? blobKey})> unpromotedOlderThan(int cutoff) => _db
      .select(
        'SELECT uid, blob_key FROM relics '
        'WHERE promoted = 0 AND held_by IS NULL AND created_at < ?',
        [cutoff],
      )
      .map((r) => (uid: r['uid'] as String, blobKey: r['blob_key'] as String?))
      .toList();

  /// Vault (promoted) usage: item count + total bytes. For the vault-full gate,
  /// which mirrors the CURRENT account's server-side quota — held rows were
  /// never uploaded to it, so they don't count against it.
  (int count, int bytes) vaultUsage() {
    final rs = _db.select(
      'SELECT COUNT(*) AS n, COALESCE(SUM(byte_size),0) AS b FROM relics '
      'WHERE promoted = 1 AND held_by IS NULL',
    );
    final row = rs.first;
    return ((row['n'] as num).toInt(), (row['b'] as num).toInt());
  }

  // --- mapping helpers ---

  /// Weighted bm25 rank over the FTS columns. Positional over ALL declared
  /// columns (uid UNINDEXED, named, body, aux, tags): the `named` BONUS
  /// column (14) sits above literal body (10) above a literal tag word (5)
  /// above injected aux vocabulary (3). Deliberate annotation must pay off —
  /// a word in a hand-written title/note ranks above the same word buried in
  /// some long OCR body — while a relic's own text still beats a synonym-only
  /// match, and heavy tagging can't dilute literal hits. Names are indexed in
  /// body TOO (see [_writeIndexRows]): the named column only ever adds score,
  /// so the v7 body calibration stands.
  static const kFtsRank = 'bm25(relics_fts, 0.0, 14.0, 10.0, 3.0, 5.0)';

  /// The relic's NAMES — what the user deliberately called it (title, note)
  /// plus its filename(s). Feeds the FTS `named` bonus column.
  static String _namedText(Relic r) => [
    r.title,
    r.note,
    r.filename,
    // Attachment filenames, so a note is findable by what it carries.
    for (final a in r.attachments) a.name,
  ].whereType<String>().join(' ');

  /// The relic's body text sans names. `preview` is DERIVED (a prefix/caption
  /// of the content), so it's indexed only when it carries text the content
  /// doesn't already — otherwise every early-content word counts twice,
  /// inflating body term frequency against the named bonus.
  static String _bodyText(Relic r) {
    final c = r.content;
    final p = r.preview;
    if (c == null || c.isEmpty) return p ?? '';
    if (p == null || p.isEmpty || c.contains(p.trim())) return c;
    return '$c $p';
  }

  /// The relic's LITERAL text — what the user actually typed/copied/named.
  /// Feeds the trigram index (which has a single body column).
  static String _literalText(Relic r) => [
    r.content,
    r.title,
    r.preview,
    r.filename,
    r.note,
    for (final a in r.attachments) a.name,
  ].whereType<String>().join(' ');

  /// INJECTED concept vocabulary — everything search adds on the relic's
  /// behalf, deduped across sources so repeated terms can't inflate term
  /// frequency. Feeds the FTS `aux` column (weighted below literal body).
  static String _auxText(Relic r) {
    // `preview` is DERIVED (a prefix/caption of content), so scanning it again
    // means running every in-prose scanner over the same characters twice.
    // Dropped when content already carries it — the same rule [_bodyText] uses,
    // for the same reason.
    final c = r.content;
    final p = r.preview;
    final dupPreview =
        c != null && c.isNotEmpty && p != null && p.isNotEmpty && c.contains(p.trim());
    final literal = [
      c,
      r.title,
      if (!dupPreview) p,
      r.note,
    ].whereType<String>().join(' ');
    final terms = <String>{
      // Type words derived from the extension (e.g. "blender", "3d",
      // "photoshop") so a file is findable by what it *is*.
      ...fileTypeSearchTerms(r.filename),
      for (final a in r.attachments) ...fileTypeSearchTerms(a.name),
      // Concept synonyms for every machine AND user tag, so "numeric"/"link"/
      // "password" queries resolve offline.
      for (final t in r.tags) ...tagSearchTerms(t),
      for (final t in r.userTags) ...tagSearchTerms(t),
      // Concept words for entities embedded mid-text (a link/email inside a
      // snippet that never earned a whole-value tag) — so "github link" finds
      // a github URL wherever it sits. Scans content+title+preview+note so a
      // URL stored as a bookmark title or in a note still yields its nouns.
      ...inProseSearchTerms(literal),
      // Separator-stripped digit runs, so "5551234567" finds "555-123-4567"
      // (the reverse direction — separated query, compact body — is covered
      // by the query ladder's concat rung).
      ..._compactDigitRuns(literal),
      // The capturing device's label, so "that link from my s21" has an
      // anchor. Aux-weighted: it's attribution, not content.
      if (r.device != null) r.device!,
    };
    return terms.join(' ');
  }

  /// Compact forms of digit runs that contain separators: "555-123-4567" →
  /// "5551234567", "4111 1111 1111 1111" → the 16-digit run. Only emitted when
  /// stripping actually changed something, for runs of phone-to-IBAN length.
  // Hoisted: these were being constructed inside [_compactDigitRuns] — one
  // compile per relic for the run scanner, and one per MATCH for the stripper.
  static final RegExp _digitRun = RegExp(r'\d(?:[\d\s().\-]*\d)?');
  static final RegExp _nonDigit = RegExp(r'\D');

  static Iterable<String> _compactDigitRuns(String s) sync* {
    for (final m in _digitRun.allMatches(s)) {
      final raw = m.group(0)!;
      final compact = raw.replaceAll(_nonDigit, '');
      if (compact.length >= 7 &&
          compact.length <= 34 &&
          compact.length != raw.length) {
        yield compact;
      }
    }
  }

  /// Trigram body: literal text + literal tag words only, diacritic-folded.
  /// Synonyms/misspellings stay OUT of the substring index — they exist to
  /// catch mistyped queries, which the trigram expansion already handles.
  static String _triText(Relic r, [String attText = '']) =>
      _foldDiacritics('${_literalText(r)} $attText ${_tagText(r)}');

  static String _tagText(Relic r) => [...r.tags, ...r.userTags].join(' ');

  /// Lowercase + strip common latin diacritics, so the (accent-sensitive)
  /// trigram index matches "cafe" ↔ "café". The porter unicode61 FTS table
  /// already folds diacritics itself; this is only for `relics_tri`.
  static String _foldDiacritics(String s) {
    final sb = StringBuffer();
    for (final c in s.toLowerCase().codeUnits) {
      final m = _foldMap[c];
      if (m != null) {
        sb.write(m);
      } else {
        sb.writeCharCode(c);
      }
    }
    return sb.toString();
  }

  static final Map<int, String> _foldMap = () {
    const pairs = <String, String>{
      'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
      'ă': 'a', 'ą': 'a', 'ç': 'c', 'ć': 'c', 'č': 'c', 'è': 'e', 'é': 'e',
      'ê': 'e', 'ë': 'e', 'ē': 'e', 'ė': 'e', 'ę': 'e', 'ě': 'e', 'ì': 'i',
      'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'į': 'i', 'ñ': 'n', 'ń': 'n',
      'ň': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o',
      'ō': 'o', 'ő': 'o', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
      'ů': 'u', 'ű': 'u', 'ý': 'y', 'ÿ': 'y', 'ś': 's', 'š': 's', 'ş': 's',
      'ș': 's', 'ť': 't', 'ț': 't', 'ź': 'z', 'ż': 'z', 'ž': 'z', 'ř': 'r',
      'ğ': 'g', 'ł': 'l', 'đ': 'd', 'ď': 'd', 'ß': 'ss', 'æ': 'ae', 'œ': 'oe',
      'ð': 'd', 'þ': 'th',
    };
    return {for (final e in pairs.entries) e.key.codeUnitAt(0): e.value};
  }();

  /// Function words dropped from a multi-word query so a filler word ("the link
  /// I saved") doesn't force a strict-AND miss. If a query is *all* stopwords we
  /// keep them, so a literal search for "the" still works. NB: no "it" — it's a
  /// real content word ("IT ticket").
  static const _stopwords = {
    'the', 'a', 'an', 'of', 'to', 'in', 'on', 'at', 'for', 'and', 'or', 'is',
    'are', 'be', 'with', 'from', 'by', 'as', 'this', 'that', 'my', 'me',
    'i', 'you', 'your', 'our', 'please',
  };

  /// Cleaned, stopword-filtered query tokens (order preserved). Specials are
  /// stripped BEFORE splitting so `foo:bar` becomes two terms, not one phrase.
  static List<String> _queryTerms(String s) {
    final raw = s
        .toLowerCase()
        .replaceAll(RegExp(r'["()*:^]'), ' ')
        .split(RegExp(r'\s+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty && !t.startsWith('-')) // negations separate
        .toList();
    if (raw.isEmpty) return const [];
    final kept = raw.where((t) => !_stopwords.contains(t)).toList();
    return kept.isEmpty ? raw : kept; // never strip the query away entirely
  }

  /// Exact-phrase spans the user quoted ("api key"), lowercased with FTS
  /// specials stripped from the inside. Matched as real FTS5 phrases (word
  /// order + adjacency), not AND-of-words.
  static List<String> _queryPhrases(String s) => [
    for (final m in RegExp(r'"([^"]+)"').allMatches(s.toLowerCase()))
      if (m
          .group(1)!
          .replaceAll(RegExp(r'[()*:^]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim()
          .isNotEmpty)
        m
            .group(1)!
            .replaceAll(RegExp(r'[()*:^]'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim(),
  ];

  /// Words the user excluded with a leading minus ("invoice -stripe").
  static List<String> _negTerms(String s) => [
    for (final t in s
        .toLowerCase()
        .replaceAll(RegExp(r'"[^"]*"'), ' ') // a '-' inside quotes is literal
        .replaceAll(RegExp(r'[()*:^"]'), ' ')
        .split(RegExp(r'\s+')))
      if (t.length > 1 && t.startsWith('-') && !t.startsWith('--'))
        t.replaceFirst('-', ''),
  ];

  /// Chain `NOT "n"` exclusions onto a positive FTS expression.
  static String _applyNeg(String expr, List<String> neg) {
    if (neg.isEmpty) return expr;
    return '($expr)${neg.map((n) => ' NOT "$n"').join()}';
  }

  /// FTS5 MATCH expression: quoted spans become exact phrases, other tokens
  /// quoted prefix terms, joined with AND (default, precise) or OR ([or] true —
  /// the recall fallback); `-word` tokens become NOT exclusions in every mode.
  /// Null when nothing positive remains (pure-negation queries can't run).
  /// With [expand], a term that is a known tag synonym also OR-tries its
  /// canonical words within its AND group ("pw" → ("pw"* OR "password"* OR
  /// "secret"*)) — used as a fallback rung only, never on the first pass.
  static String? _ftsExpr(String s, {bool or = false, bool expand = false}) {
    final phrases = _queryPhrases(s);
    // Terms come from the query WITHOUT its quoted spans, so phrase words
    // aren't also AND-ed loosely.
    final terms = _queryTerms(s.replaceAll(RegExp(r'"[^"]*"'), ' '));
    final neg = _negTerms(s);
    final positives = <String>[
      for (final p in phrases) '"$p"',
      for (final t in terms)
        () {
          final exp = expand
              ? (kSynonymExpansions[t] ?? const <String>[])
              : const <String>[];
          if (or || exp.isEmpty) return '"$t"*';
          return '("$t"* OR ${exp.map((e) => '"$e"*').join(' OR ')})';
        }(),
    ];
    if (positives.isEmpty) return null;
    return _applyNeg(positives.join(or ? ' OR ' : ' AND '), neg);
  }

  /// Cheap stable content fingerprint (matches the old in-memory hash shape).
  static int _hash(String content) {
    final b = utf8.encode(content);
    var h = b.length;
    final step = (b.length ~/ 64).clamp(1, b.isEmpty ? 1 : b.length);
    for (var i = 0; i < b.length; i += step) {
      h = (h * 31 + b[i]) & 0x7fffffff;
    }
    return h;
  }

  static Relic _toRelic(Row j) => Relic(
    uid: j['uid'] as String,
    createdAt: j['created_at'] as int,
    updatedAt: j['updated_at'] as int,
    kind: kindFromStr(j['kind'] as String? ?? 'string'),
    source: sourceFromStr(j['source'] as String? ?? 'clipboard'),
    promoted: (j['promoted'] as int? ?? 0) != 0,
    byteSize: j['byte_size'] as int? ?? 0,
    device: j['device'] as String?,
    mime: j['mime'] as String?,
    filename: j['filename'] as String?,
    blobKey: j['blob_key'] as String?,
    tags: _jsonList(j['tags']),
    userTags: _jsonList(j['user_tags']),
    title: j['title'] as String?,
    note: j['note'] as String?,
    content: j['content'] as String?,
    preview: j['preview'] as String?,
    attachments: Attachment.listFrom(j['attachments']),
  );

  static List<String> _jsonList(Object? v) {
    if (v is! String || v.isEmpty) return const [];
    try {
      return (jsonDecode(v) as List).cast<String>();
    } catch (_) {
      return const [];
    }
  }
}

/// One row of the open-vocabulary tag vocabulary: an emitted tag string, the
/// representative it snapped onto, how often it was emitted, and its embedding.
class TagVocabRow {
  final String tag;
  final String canonical;
  final int count;
  final List<double> vec;
  const TagVocabRow({
    required this.tag,
    required this.canonical,
    required this.count,
    required this.vec,
  });

  bool get isRepresentative => tag == canonical;

  /// The wire shape `sift tags bound` accepts as a `vocabulary` entry.
  Map<String, dynamic> toJson() => {'tag': tag, 'count': count, 'vec': vec};
}
