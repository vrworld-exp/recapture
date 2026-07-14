// lib/presentation/screens/capture/level_review_grid_screen.dart
//
// The in-flow review screen for a guided-capture level — Screen 7A (Eye Ring),
// 7B (Top Ring), and 7C (Bottom Ring) are ALL this one widget, parameterized by
// level. It feeds the shared, reusable [ReviewGridScreen] with the REAL captured
// frames for the level (from the per-level ledger via [reviewGridItemsProvider])
// and owns the flow concerns the reusable grid does not: which level/band, the
// forward route, and the level-tagged review analytics.
//
// This replaces the former placeholder `ReviewScreen` (static fake tiles) — A/B/C
// now share one rich grid showing actual frames + per-frame QC badges, so there is
// a SINGLE review-grid implementation across the flow.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../application/capture/analytics/capture_level_events.dart';
import '../../../application/capture/review_grid_items_provider.dart';
import '../../../domain/entities/retake_request.dart';
import '../../../utils/analytics.dart';
import 'review_grid_screen.dart';

/// Maps a [CaptureLevel] to its capture route — where a per-tile Retake navigates
/// (in retake mode, via a [RetakeRequest] passed as GoRouter `extra`).
String _captureRouteForLevel(CaptureLevel level) => switch (level) {
      CaptureLevel.a => AppRoutes.levelACapture,
      CaptureLevel.b => AppRoutes.levelBCapture,
      CaptureLevel.c => AppRoutes.levelCCapture,
    };

class LevelReviewGridScreen extends ConsumerWidget {
  const LevelReviewGridScreen({
    super.key,
    required this.levelLabel,
    required this.levelName,
    required this.nextRoute,
  });

  /// 'A' / 'B' / 'C' — drives the level taxonomy (band, analytics code).
  final String levelLabel;

  /// Human ring name shown in the title ("Eye Ring" / "Top Ring" / "Low Ring").
  final String levelName;

  /// Route the confirm CTA advances to (the level's completion screen).
  final String nextRoute;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final level = captureLevelFromLabel(levelLabel);
    final levelId = pitchBandIdForLevel(level);
    final items = ref.watch(reviewGridItemsProvider(levelId));

    return ReviewGridScreen(
      items: items,
      title: 'Review: $levelName',
      analyticsLevel: level.code,
      onConfirm: () {
        _logAction('proceed', level);
        context.go(nextRoute);
      },
      onBackToCapture: () {
        _logAction('back_to_capture', level);
        // Pop when the grid was pushed; the normal flow go()-navigates here
        // (nothing to pop), so fall back to the level's capture route.
        if (context.canPop()) {
          context.pop();
        } else {
          context.go(_captureRouteForLevel(level));
        }
      },
      // Per-tile Retake → re-shoot that ring position. Navigate to the level's
      // capture screen in retake mode (RetakeRequest via `extra`); an accepted
      // retake pops back here (returnToReviewAfter). The grid debounces taps and
      // only builds the request for tiles with a known ring position.
      onRetake: (request) {
        _logAction('retake', level, frameId: request.replacingCaptureId);
        context.push(_captureRouteForLevel(level), extra: request);
      },
    );
  }

  void _logAction(String action, CaptureLevel level, {String? frameId}) {
    Analytics.logEvent(AnalyticsEvents.reviewAction, {
      'action': action,
      'level': level.code,
      if (frameId != null) 'frame_id': frameId,
      'device_type':
          defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    });
  }
}
