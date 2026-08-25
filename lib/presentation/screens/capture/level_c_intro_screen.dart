// lib/presentation/screens/capture/level_c_intro_screen.dart
import 'package:flutter/material.dart';

import '../../../app/routes/app_router.dart';
import '../../../data/local/level_intro_box.dart';
import 'level_intro_content.dart';
import 'level_intro_scaffold.dart';

/// Whether a user who checked "Don't show again" is auto-skipped straight to
/// capture on the next entry (see [LevelBIntroScreen]'s equivalent gate).
const bool kLevelCIntroAutoSkipEnabled = true;

/// Screen 5C — Level C (Low Ring) intro. A thin binding of [LevelIntroScaffold]
/// (the SAME shared widget Level B uses) to the Level C config
/// [kLevelCIntroContent]: the rule "Lower phone, tilt slightly up", the guided-
/// sequence progress (on Level C), and a "Begin" CTA into Level C capture. No
/// layout is duplicated from Level B — only the config differs.
class LevelCIntroScreen extends StatelessWidget {
  const LevelCIntroScreen({
    super.key,
    this.nextRoute = AppRoutes.levelCCapture,
    this.store,
    this.autoSkipEnabled = kLevelCIntroAutoSkipEnabled,
    this.onProceed,
  });

  /// Capture route the CTA replaces into. Overridable for tests.
  final String nextRoute;

  /// Persistence for the "seen"/"don't show again" flags. Injectable for tests.
  final LevelIntroStore? store;

  /// Gate for auto-skipping opted-out users (see [kLevelCIntroAutoSkipEnabled]).
  final bool autoSkipEnabled;

  /// Navigation override for tests. When null, uses `context.go(nextRoute)`.
  final VoidCallback? onProceed;

  @override
  Widget build(BuildContext context) {
    return LevelIntroScaffold(
      content: kLevelCIntroContent,
      nextRoute: nextRoute,
      store: store,
      autoSkipEnabled: autoSkipEnabled,
      onProceed: onProceed,
    );
  }
}
