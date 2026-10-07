import 'dart:math';

/// Where a pull of `/relics` has got to, kept across sync passes.
///
/// A pull is one or two walks of pages under one `since`. The cursor a
/// device syncs from moves only once the whole pull is over, so nothing is
/// ever skipped, but that used to mean a pass that died on page twelve
/// started the next pass at page one. A phone whose radio could not fetch
/// one five-hundred-item page inside the timeout pulled the same eleven
/// pages again on every tick, and never got further. Jordan watched a phone
/// do that for ten minutes with nothing on screen.
///
/// This holds the page cursor, the highest `updated_at` seen and the page
/// size between passes. The next pass picks up on the page that failed, and
/// asks for a smaller one when the failure was the time it took.
class PullWalk {
  PullWalk({required this.since})
      : vaultOnly = since == 0,
        maxUpdatedAt = since;

  /// The `since` the pull was started under. A cursor that has moved on
  /// means a completed pull; the next one starts a fresh walk.
  final int since;

  /// Whether the current walk is the vault-only one that opens a cold pull.
  /// Those are what a person goes looking for first after a reconnect, so
  /// they come down ahead of everything else, newest first. The full walk
  /// that follows sees them again and skips them as not news.
  bool vaultOnly;

  /// The page cursor within the current walk, null at its first page.
  String? cursor;

  /// The highest `updated_at` seen so far, across both walks.
  int maxUpdatedAt;

  /// Items per page. Starts small, so the first page is on screen within a
  /// round trip, grows while pages come back quickly, and shrinks when one
  /// times out, since what a page costs is mostly its size.
  int pageSize = firstPage;

  /// Whether every walk has reached its last page.
  bool done = false;

  static const firstPage = 100;
  static const maxPage = 500; // the server clamps above this
  static const minPage = 25;

  /// A page back inside this is a sign the next one can be bigger.
  static const quick = Duration(seconds: 3);

  /// The query for the next page.
  Map<String, String> query() => {
        'since': '$since',
        'limit': '$pageSize',
        'order': 'desc',
        if (vaultOnly) 'promoted': '1',
        'cursor': ?cursor,
      };

  /// Note an `updated_at` from a page that landed.
  void saw(int updatedAt) {
    if (updatedAt > maxUpdatedAt) maxUpdatedAt = updatedAt;
  }

  /// A page landed after [took]. [next] is the server's cursor for the one
  /// after it, null at the end of a walk.
  void pageLanded(String? next, Duration took) {
    if (took < quick && pageSize < maxPage) {
      pageSize = min(pageSize * 2, maxPage);
    }
    if (next != null) {
      cursor = next;
      return;
    }
    if (vaultOnly) {
      vaultOnly = false;
      cursor = null;
      return;
    }
    done = true;
  }

  /// A page did not come back in time. The same page is asked for again on
  /// the next pass, smaller.
  void pageTimedOut() {
    pageSize = max(pageSize ~/ 4, minPage);
  }

  /// The cursor a completed pull leaves behind: a second short of the
  /// newest `updated_at`, so a row written in that same second is not
  /// skipped by the next pull.
  int get nextSince => maxUpdatedAt - 1;
}
