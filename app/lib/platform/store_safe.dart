import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// True when this build must carry no purchase or upgrade steering at all.
///
/// App Store Guideline 3.1.1 / 3.1.3(a): any button, label, or link that
/// points users toward an outside purchase is a rejection. Relic ships iOS
/// under 3.1.3(b) (multiplatform services): the app honours a tier bought
/// elsewhere, may state plan facts, and never says "upgrade", names paid
/// tiers, or links to a page that sells. Android (Play) and desktop keep the
/// relic.space upgrade guidance.
///
/// Gate every upgrade affordance on this, not on `Platform.isIOS` directly,
/// so the policy lives in one place and tests can flip it.
bool get storeSafeBuild => debugStoreSafeOverride ?? Platform.isIOS;

/// Test-only override so widget tests run on desktop can assert the
/// store-safe rendering. Reset to null in tearDown.
@visibleForTesting
bool? debugStoreSafeOverride;
