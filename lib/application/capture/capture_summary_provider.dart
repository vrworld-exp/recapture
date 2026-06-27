// lib/application/capture/capture_summary_provider.dart
//
// Aggregates the per-level capture results for the terminal "Capture complete"
// summary (Screen 6C-Complete). It iterates the level config (CaptureLevel.values
// — NEVER a hardcoded 3-tuple) and reads each level's REAL captured frames from the
// ledger via [reviewGridItemsProvider] — the SAME source the review grids render —
// so counts, the representative thumbnail, and completeness all come from actual
// capture data, not placeholders.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/capture_evaluation.dart';
import 'analytics/capture_level_events.dart';
import 'review_grid_items_provider.dart';

/// Display ring name for a guided-capture level (Eye / Top / Low Ring). Keyed off
/// [CaptureLevel] so the level LIST stays config-driven (CaptureLevel.values) while
/// the human label lives in one place.
String guidedCaptureLevelName(CaptureLevel level) => switch (level) {
      CaptureLevel.a => 'Eye Ring',
      CaptureLevel.b => 'Top Ring',
      CaptureLevel.c => 'Low Ring',
    };

/// One level's capture result, as shown on a summary card.
@immutable
class LevelCaptureSummary {
  const LevelCaptureSummary({
    required this.level,
    required this.name,
    required this.frameCount,
    required this.warnedCount,
    required this.thumbnailPath,
  });

  final CaptureLevel level;

  /// Ring name ("Eye Ring" / "Top Ring" / "Low Ring").
  final String name;

  /// Captured (accepted) frames for the level.
  final int frameCount;

  /// Of [frameCount], how many carry an exposure warning.
  final int warnedCount;

  /// First captured frame's path — the representative card thumbnail. Null when
  /// the level has no captures (→ the card's placeholder).
  final String? thumbnailPath;

  // NOTE: completeness is NOT defined here. The single source of truth is the
  // final completion gate (completion_gate.dart / completionGateProvider), which
  // applies the config-driven per-level threshold. The summary screen reads the
  // gate for per-card status + Continue gating — this type is display data only.
}

/// Per-level summaries for the Capture complete screen, in level order. Built by
/// iterating [CaptureLevel.values] and reading the real captured set per level.
///
/// `autoDispose` so it recomputes a fresh snapshot each time the summary is shown
/// (e.g. after a Review round-trip that re-captured frames — the screen invalidates
/// the per-level item providers on return; this then reflects the new counts).
final captureSummaryProvider =
    Provider.autoDispose<List<LevelCaptureSummary>>((ref) {
  return [
    for (final level in CaptureLevel.values)
      () {
        final items =
            ref.watch(reviewGridItemsProvider(pitchBandIdForLevel(level)));
        final warned =
            items.where((i) => i.verdict == CaptureVerdict.warn).length;
        return LevelCaptureSummary(
          level: level,
          name: guidedCaptureLevelName(level),
          frameCount: items.length,
          warnedCount: warned,
          thumbnailPath: items.isEmpty ? null : items.first.filePath,
        );
      }(),
  ];
});
