/// Network deadlines.
///
/// Dart's `http` package sets no timeout at all, so a request falls through to
/// the OS TCP timeout — tens of seconds on Android, and unbounded on a captive
/// portal that accepts the connection and then never answers. That is what made
/// the mobile launch screen hang: the boot path awaited a token refresh and a
/// full sync with no deadline, so "no usable network" looked identical to "slow
/// network" and the user just stared at the logo.
///
/// Every call now carries one of these. Timing out is not an error case here —
/// it lands in the same `catch` that already handles offline, so the app falls
/// back to local data instead of waiting.
library;

/// Interactive calls that must never hold up the UI: token refresh, keyparams,
/// account, the delta pull, outbox flush. Short on purpose — if the server
/// hasn't answered in this long, the cached vault is the better answer.
const Duration kNetTimeout = Duration(seconds: 10);

/// Blob download / upload, where the size isn't known up front. Relics run to
/// 100 MB (maxItemBytes) and this deadline covers the whole body, not just the
/// connect, so it has to tolerate a big file on a slow link. Still bounded: a
/// stalled transfer eventually gives up rather than pinning a spinner forever.
const Duration kBlobTimeout = Duration(minutes: 10);

/// A deadline scaled to how many bytes have to cross the wire.
///
/// Use this when the payload size IS known. A one-line snippet and a 90 MB
/// video both go through the same code path, and giving the snippet the video's
/// deadline means an offline user watches a spinner for ten minutes. Small
/// payloads get [kNetTimeout]; larger ones get roughly ten seconds of slack per
/// 100 KB, capped at [kBlobTimeout].
Duration netTimeoutForBytes(int bytes) {
  if (bytes <= 256 * 1024) return kNetTimeout;
  final d = Duration(seconds: 10 + (bytes / (100 * 1024)).ceil());
  return d > kBlobTimeout ? kBlobTimeout : d;
}
