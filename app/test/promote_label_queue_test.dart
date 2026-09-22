import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/models/relic.dart';

/// Labeling only runs for promoted text, but the enrich worker only picks up
/// rows *below* the ML level. An item enriched while it sat in the stream is
/// already at that level, so promoting it has to drop `enrich_level` or it can
/// never be labeled — no amount of waiting helps. Photos always did this; text
/// did not, which is the bug these tests pin.
Relic _relic({
  required Kind kind,
  bool promoted = true,
  String? title,
  String? filename,
  String content = 'some captured text',
}) => Relic(
  uid: 'u1',
  createdAt: 1785000000,
  updatedAt: 1785000000,
  kind: kind,
  source: Source.clipboard,
  promoted: promoted,
  byteSize: 42,
  title: title,
  filename: filename,
  content: content,
);

void main() {
  test('promoting text re-queues it so the labeler can reach it', () {
    expect(
      shouldRequeueForLabel(
        _relic(kind: Kind.string),
        describeItems: true,
        bulk: false,
      ),
      isTrue,
    );
  });

  test('promoting a title-less photo still re-queues', () {
    expect(
      shouldRequeueForLabel(
        _relic(kind: Kind.photo),
        describeItems: true,
        bulk: false,
      ),
      isTrue,
    );
  });

  test('an item that already has a title is left alone', () {
    for (final kind in [Kind.string, Kind.photo]) {
      expect(
        shouldRequeueForLabel(
          _relic(kind: kind, title: 'EIN Number'),
          describeItems: true,
          bulk: false,
        ),
        isFalse,
        reason: '$kind with a title must not be re-labeled over',
      );
    }
  });

  test('a photo still named after its file is re-queued', () {
    // The phone names a shared photo after its file at capture time. That is
    // a placeholder, not a name the user chose, so it must not hold the photo
    // back from a real description.
    expect(
      shouldRequeueForLabel(
        _relic(kind: Kind.photo, title: 'IMG_4821.jpg', filename: 'IMG_4821.jpg'),
        describeItems: true,
        bulk: false,
      ),
      isTrue,
    );
    expect(
      shouldRequeueForLabel(
        _relic(kind: Kind.photo, title: 'Shared image'),
        describeItems: true,
        bulk: false,
      ),
      isTrue,
    );
  });

  test('a photo named from its own text is re-queued too', () {
    expect(
      shouldRequeueForLabel(
        _relic(
          kind: Kind.photo,
          title: 'Blue Bottle Coffee',
          content: 'Blue Bottle Coffee\nOrder #4821\nTotal \$6.50',
        ),
        describeItems: true,
        bulk: false,
      ),
      isTrue,
    );
  });

  test('nothing is re-queued while item descriptions are switched off', () {
    expect(
      shouldRequeueForLabel(
        _relic(kind: Kind.string),
        describeItems: false,
        bulk: false,
      ),
      isFalse,
    );
  });

  test('an unpromoted item is never re-queued', () {
    expect(
      shouldRequeueForLabel(
        _relic(kind: Kind.string, promoted: false),
        describeItems: true,
        bulk: false,
      ),
      isFalse,
    );
  });

  /// "Save everything to Vault" would otherwise re-queue the whole vault for
  /// generative labeling — the backfill we explicitly chose not to run.
  test('the bulk vault sweep does not re-queue text', () {
    expect(
      shouldRequeueForLabel(
        _relic(kind: Kind.string),
        describeItems: true,
        bulk: true,
      ),
      isFalse,
    );
  });

  test('the bulk sweep still re-queues photos, as it always has', () {
    expect(
      shouldRequeueForLabel(
        _relic(kind: Kind.photo),
        describeItems: true,
        bulk: true,
      ),
      isTrue,
    );
  });

  _titleTests();
  _scopeTests();

  test('file relics are not re-queued; nothing labels them', () {
    expect(
      shouldRequeueForLabel(
        _relic(kind: Kind.file),
        describeItems: true,
        bulk: false,
      ),
      isFalse,
    );
  });
}

/// The second half of the same bug: even once a promoted text item is
/// re-queued, the generated title has to actually be stored. That write used to
/// sit inside a `kind != string` branch, so it was unreachable for exactly the
/// text the labeler had just been taught to handle.
void _titleTests() {
  test('a generated title becomes the headline for untitled text', () {
    expect(
      titleAfterLabel(
        kind: Kind.string,
        current: null,
        caption: 'PostgreSQL connection pool configuration',
      ),
      'PostgreSQL connection pool configuration',
    );
  });

  test('and for untitled photos, as before', () {
    expect(
      titleAfterLabel(kind: Kind.photo, current: '', caption: 'a rocky beach'),
      'a rocky beach',
    );
  });

  test('a title the user already set is never overwritten', () {
    expect(
      titleAfterLabel(
        kind: Kind.string,
        current: 'EIN Number',
        caption: 'Employer identification number',
      ),
      'EIN Number',
    );
  });

  test('files keep their filename, never a generated headline', () {
    expect(
      titleAfterLabel(kind: Kind.file, current: null, caption: 'Relic icon'),
      isNull,
    );
  });

  test('an empty or missing caption leaves the title untouched', () {
    expect(titleAfterLabel(kind: Kind.string, current: null, caption: null), isNull);
    expect(titleAfterLabel(kind: Kind.string, current: null, caption: '   '), isNull);
  });

  test('a phone-shared photo gives up its filename for a real name', () {
    expect(
      titleAfterLabel(
        kind: Kind.photo,
        current: 'IMG_4821.jpg',
        caption: 'Blue Bottle Coffee',
        filename: 'IMG_4821.jpg',
      ),
      'Blue Bottle Coffee',
    );
    expect(
      titleAfterLabel(
        kind: Kind.photo,
        current: 'Shared image',
        caption: 'Blue Bottle Coffee',
      ),
      'Blue Bottle Coffee',
    );
  });

  test('a photo named from its OCR text still takes a description', () {
    // The OCR name is the app's, not the user's: when the labeler later has a
    // better one, it lands.
    expect(
      titleAfterLabel(
        kind: Kind.photo,
        current: 'Blue Bottle Coffee',
        caption: 'a coffee shop receipt',
        content: 'Blue Bottle Coffee\nOrder #4821',
      ),
      'a coffee shop receipt',
    );
  });

  test('a name the user gave a photo outranks both', () {
    expect(
      titleAfterLabel(
        kind: Kind.photo,
        current: 'Receipt for the client dinner',
        caption: 'Blue Bottle Coffee',
        filename: 'IMG_4821.jpg',
        content: 'Blue Bottle Coffee\nOrder #4821',
      ),
      'Receipt for the client dinner',
    );
  });

  test('a file keeps its filename even when it matches', () {
    expect(
      titleAfterLabel(
        kind: Kind.file,
        current: 'invoice.pdf',
        caption: 'Kessler Roofing invoice',
        filename: 'invoice.pdf',
      ),
      'invoice.pdf',
    );
  });
}

/// The vault-only rule for text, and the setting that widens it.
void _scopeTests() {
  test('vault text is labeled by default', () {
    expect(
      shouldLabelText(
        describeItems: true,
        describeEverything: false,
        promoted: true,
      ),
      isTrue,
    );
  });

  test('unsaved history text is skipped by default', () {
    expect(
      shouldLabelText(
        describeItems: true,
        describeEverything: false,
        promoted: false,
      ),
      isFalse,
    );
  });

  test('the scope setting opts unsaved history in', () {
    expect(
      shouldLabelText(
        describeItems: true,
        describeEverything: true,
        promoted: false,
      ),
      isTrue,
    );
  });

  test('the scope setting cannot switch labeling on by itself', () {
    for (final promoted in [true, false]) {
      expect(
        shouldLabelText(
          describeItems: false,
          describeEverything: true,
          promoted: promoted,
        ),
        isFalse,
        reason: 'the master toggle stays the master toggle',
      );
    }
  });
}
