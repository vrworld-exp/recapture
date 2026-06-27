// lib/presentation/screens/capture/level_intro_content.dart
import 'package:flutter/material.dart';

import '../../../app/routes/app_router.dart';
import '../../../utils/analytics.dart';

/// Per-level content for the shared guided-capture intro ([LevelIntroScaffold]).
/// All display copy, the illustration, the default capture route, and the
/// analytics event names live HERE — so the intro widget carries no level-
/// specific literals and Levels B and C differ only by the config they are built
/// with (the "one shared widget, config-driven difference" contract).
@immutable
class LevelIntroContent {
  const LevelIntroContent({
    required this.introId,
    required this.appBarTitle,
    required this.activeLevel,
    required this.headline,
    required this.supportingLine,
    required this.rules,
    required this.illustrationIcon,
    required this.illustrationSemanticLabel,
    required this.defaultNextRoute,
    required this.viewedEvent,
    required this.dismissedEvent,
  });

  /// Stable persistence + analytics key (e.g. 'level_b').
  final String introId;

  /// App-bar title, e.g. "Level C: Low Ring".
  final String appBarTitle;

  /// 'A' | 'B' | 'C' — drives the progress indicator's highlighted step.
  final String activeLevel;

  /// The primary instruction headline (e.g. "Lower phone, tilt slightly up").
  final String headline;

  /// One-line "why" under the headline.
  final String supportingLine;

  /// The capture-rule checklist shown under the instruction.
  final List<String> rules;

  /// Placeholder illustration glyph. It is a framework [Icon] (no external/Lottie
  /// asset), so it can never reach a broken-asset state — the missing-asset edge
  /// degrades to this neutral glyph rather than a red error screen.
  final IconData illustrationIcon;

  /// Screen-reader description of the (decorative) illustration.
  final String illustrationSemanticLabel;

  /// Capture route the CTA replaces into by default.
  final String defaultNextRoute;

  /// Per-level granular analytics event names (mirroring Level A/B).
  final String viewedEvent;
  final String dismissedEvent;
}

/// Level B (Top Ring) intro content — the exact copy/illustration/analytics the
/// standalone Level B intro shipped with, now sourced from config.
const LevelIntroContent kLevelBIntroContent = LevelIntroContent(
  introId: 'level_b',
  appBarTitle: 'Level B: Top Ring',
  activeLevel: 'B',
  headline: 'Tilt down more to show top',
  supportingLine: 'Angle the camera downward as you circle so the top '
      'surface of the object comes into view.',
  rules: [
    'Keep the same circular motion around the object',
    'Aim down so the top surface stays in frame',
    'Let each position settle before it captures',
  ],
  illustrationIcon: Icons.screen_rotation_alt,
  illustrationSemanticLabel:
      'Illustration: tilt the camera downward to show the top.',
  defaultNextRoute: AppRoutes.levelBCapture,
  viewedEvent: AnalyticsEvents.levelBIntroViewed,
  dismissedEvent: AnalyticsEvents.levelBIntroDismissed,
);

// TODO(assets): Level C phone-position illustration — replace the placeholder
// glyph (assets/capture/level_c_tilt_up.json, once it exists) behind an error-
// safe builder so a missing asset degrades to a neutral box, not a red error
// screen. Do NOT reuse the Level B asset.
/// Level C (Low Ring) intro content — the lower-angle pass ("lower phone, tilt
/// slightly up"). Distinct illustration glyph from Level B.
const LevelIntroContent kLevelCIntroContent = LevelIntroContent(
  introId: 'level_c',
  appBarTitle: 'Level C: Low Ring',
  activeLevel: 'C',
  headline: 'Lower phone, tilt slightly up',
  supportingLine: 'Bring the phone lower and angle it up so the base and '
      'underside of the object stay in frame.',
  rules: [
    'Keep the same circular motion around the object',
    'Angle up so the base and underside stay in frame',
    'Let each position settle before it captures',
  ],
  illustrationIcon: Icons.keyboard_double_arrow_up,
  illustrationSemanticLabel:
      'Illustration: lower the phone and tilt it up to show the base.',
  defaultNextRoute: AppRoutes.levelCCapture,
  viewedEvent: AnalyticsEvents.levelCIntroViewed,
  dismissedEvent: AnalyticsEvents.levelCIntroDismissed,
);
