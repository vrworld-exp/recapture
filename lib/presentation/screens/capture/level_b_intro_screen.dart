// lib/presentation/screens/capture/level_b_intro_screen.dart
import 'package:flutter/material.dart';

import '../../../app/routes/app_router.dart';
import '../../../data/local/level_intro_box.dart';
import 'level_intro_content.dart';
import 'level_intro_scaffold.dart';

/// Whether a user who checked "Don't show again" is auto-skipped straight to
/// capture on the next entry. Mirrors the Level A intro gate — auto-skip only
/// ever applies to users who explicitly opted out. Flip to `false` to always
/// show the intro.
const bool kLevelBIntroAutoSkipEnabled = true;

/// Screen 5B — Level B (Top Ring) intro. A thin binding of [LevelIntroScaffold]
/// (the shared B/C intro widget) to the Level B config [kLevelBIntroContent]:
/// the rule "Tilt down more to show top", the guided-sequence progress, and a
/// "Begin" CTA into Level B capture. All layout/behaviour lives in the shared
/// scaffold; only the config differs from Level C.
class LevelBIntroScreen extends StatelessWidget {
  const LevelBIntroScreen({
    super.key,
    this.nextRoute = AppRoutes.levelBCapture,
    this.store,
    this.autoSkipEnabled = kLevelBIntroAutoSkipEnabled,
    this.onProceed,
  });

  /// Capture route the CTA replaces into. Overridable for tests.
  final String nextRoute;

  /// Persistence for the "seen"/"don't show again" flags. Injectable for tests.
  final LevelIntroStore? store;

  /// Gate for auto-skipping opted-out users (see [kLevelBIntroAutoSkipEnabled]).
  final bool autoSkipEnabled;

  /// Navigation override for tests. When null, uses `context.go(nextRoute)`.
  final VoidCallback? onProceed;

  @override
  Widget build(BuildContext context) {
    return LevelIntroScaffold(
      content: kLevelBIntroContent,
      nextRoute: nextRoute,
      store: store,
      autoSkipEnabled: autoSkipEnabled,
      onProceed: onProceed,
    );
  }
}
