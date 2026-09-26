import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:in_app_review/in_app_review.dart';

/// Whether this build can ask the store for a rating: Android (Play) and iOS
/// (App Store) only. Desktop and web have no store review sheet, so the prompt
/// never runs there.
///
/// Gate on this, not on `Platform` directly, so tests can flip it.
bool get reviewPromptSupported =>
    debugReviewPromptOverride ??
    (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

/// Test-only override for [reviewPromptSupported]. Reset to null in tearDown.
@visibleForTesting
bool? debugReviewPromptOverride;

/// Where the counter and the one-time flag live.
abstract class ReviewPromptStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// The store's own rating sheet. Wrapped so the decision logic is testable
/// without the platform plugin.
abstract class StoreReviewer {
  Future<bool> isAvailable();
  Future<void> requestReview();
}

/// The same secure store the other phone prefs use. These keys are kept out of
/// the sign-out wipe on purpose: the count is about this phone, not about the
/// account signed in on it, and a prompt that already fired must stay fired.
class SecureReviewPromptStore implements ReviewPromptStore {
  const SecureReviewPromptStore();
  static const _s = FlutterSecureStorage();

  @override
  Future<String?> read(String key) async {
    try {
      return await _s.read(key: key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _s.write(key: key, value: value);
    } catch (_) {}
  }
}

/// Play In-App Review on Android, SKStoreReviewController on iOS.
class PluginStoreReviewer implements StoreReviewer {
  const PluginStoreReviewer();

  @override
  Future<bool> isAvailable() => InAppReview.instance.isAvailable();

  @override
  Future<void> requestReview() => InAppReview.instance.requestReview();
}

/// Asks for a store rating once, after the user's tenth capture on this phone.
///
/// A capture is a new item the user made here: a share into Relic, a Quick
/// Settings tile or Shortcut clipboard capture, or a typed note. The count
/// comes from [WorkerRepo.onUserCapture], which never fires for items synced
/// in from other devices, re-captures that only move an item to the top, Undo,
/// or the vault loading at launch.
///
/// The request is made at most once, ever. There is no custom "Do you like
/// Relic?" screen and no star count is suggested: the store draws its own
/// sheet, and may decide not to show it at all.
class ReviewPrompt {
  ReviewPrompt({
    ReviewPromptStore? store,
    StoreReviewer? reviewer,
    bool? enabled,
  })  : _store = store ?? const SecureReviewPromptStore(),
        _reviewer = reviewer ?? const PluginStoreReviewer(),
        _enabled = enabled ?? reviewPromptSupported;

  /// The capture the prompt waits for.
  static const threshold = 10;

  static const kCount = 'relic.review.captureCount';
  static const kPrompted = 'relic.review.prompted';

  final ReviewPromptStore _store;
  final StoreReviewer _reviewer;
  final bool _enabled;

  // Captures can land back to back (a share of several photos), and each one
  // reads then writes the count. Running them in order keeps every capture
  // counted and makes sure two of them can never both ask.
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() body) {
    final run = _tail.then((_) => body());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  /// Count one capture. True when the prompt is now due: the count has
  /// reached [threshold] and the prompt has never fired. Never throws.
  Future<bool> recordCapture() {
    if (!_enabled) return Future.value(false);
    return _serial(() async {
      try {
        if (await _store.read(kPrompted) == '1') return false;
        final count = (int.tryParse(await _store.read(kCount) ?? '') ?? 0) + 1;
        await _store.write(kCount, '$count');
        return count >= threshold;
      } catch (_) {
        return false;
      }
    });
  }

  /// Ask the store for a rating if the prompt is due and [calm] says nothing
  /// else is on screen. A moment that is not calm, or a store that is not
  /// available, leaves the prompt due, so the next capture tries again.
  /// True only when the request was actually made. Never throws.
  Future<bool> askIfDue({required bool Function() calm}) {
    if (!_enabled) return Future.value(false);
    return _serial(() async {
      try {
        if (await _store.read(kPrompted) == '1') return false;
        final count = int.tryParse(await _store.read(kCount) ?? '') ?? 0;
        if (count < threshold) return false;
        if (!calm()) return false;
        if (!await _reviewer.isAvailable()) return false;
        // Marked before the request, so a plugin that throws or hangs can
        // never lead to a second ask.
        await _store.write(kPrompted, '1');
        try {
          await _reviewer.requestReview();
        } catch (_) {}
        return true;
      } catch (_) {
        return false;
      }
    });
  }
}
