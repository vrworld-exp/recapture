// lib/application/capture/capture_summary_provider.dart
//
// Aggregates the per-level capture results for the terminal Capture Summary
// (Screen 8 / 6C-Complete). It iterates the flow variant's ACTIVE levels
// (captureFlowVariantProvider.levels — NEVER a hardcoded 3-tuple, so a 2-ring
// session shows no Level C row) and reads each level's REAL captured frames from the
// ledger via [reviewGridItemsProvider] — the SAME source the review grids render —
// so counts, the representative thumbnail, coverage, and the warnings raised all
// come from actual capture data, not placeholders. READ-ONLY: it derives display
// data from the ledger + config; it never recomputes acceptance or coverage rules.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/capture/level_completion.dart';
import '../../domain/entities/capture_config.dart';
import '../../domain/entities/capture_evaluation.dart';
import '../config/config_notifier.dart';
import 'analytics/capture_level_events.dart';
import 'capture_flow_variant_provider.dart';
import 'capture_mode_provider.dart';
import 'ledger/level_capture_ledger_registry_provider.dart';
import 'ledger/warned_photo_record.dart';
import 'review_grid_items_provider.dart';

/// Display ring name for a guided-capture level (Eye / Top / Low Ring). Keyed off
/// [CaptureLevel] so the level LIST stays config-driven (CaptureLevel.values) while
/// the human label lives in one place.
String guidedCaptureLevelName(CaptureLevel level) => switch (level) {
      CaptureLevel.a => 'Eye Ring',
      CaptureLevel.b => 'Top Ring',
      CaptureLevel.c => 'Low Ring',
    };

/// A human-readable label for a warning raised during capture, with the level it
/// came from — the unit the aggregated, collapsible warnings list renders. The
/// only warnings currently recorded are exposure warnings (WarnedPhotoRecord);
/// the message is derived from the exposure band so the list reads in plain words.
@immutable
class CaptureWarning {
  const CaptureWarning({required this.level, required this.message});

  /// The level this warning was raised on (drives the per-warning level tag).
  final CaptureLevel level;

  /// Human-readable description (e.g. "Underexposed — frame too dark").
  final String message;

  @override
  bool operator ==(Object other) =>
      other is CaptureWarning && other.level == level && other.message == message;

  @override
  int get hashCode => Object.hash(level, message);
}

/// Plain-words message for an exposure warning record. Underexposure and
/// overexposure are mutually exclusive at evaluation time; the final fallback
/// guards a degenerate record so the UI never shows a blank line.
String _warningMessage(WarnedPhotoRecord w) {
  if (w.isUnderexposed) return 'Underexposed — frame too dark';
  if (w.isOverexposed) return 'Overexposed — frame too bright';
  return 'Exposure warning';
}

/// One level's capture result, as shown on a summary card.
@immutable
class LevelCaptureSummary {
  const LevelCaptureSummary({
    required this.level,
    required this.name,
    required this.frameCount,
    required this.warnedCount,
    required this.minRequired,
    required this.coveragePct,
    required this.completion,
    required this.warnings,
    required this.thumbnailPath,
  });

  final CaptureLevel level;

  /// Ring name ("Eye Ring" / "Top Ring" / "Low Ring").
  final String name;

  /// Captured (accepted) frames for the level.
  final int frameCount;

  /// Of [frameCount], how many carry an exposure warning (accepted-and-warned).
  /// Distinct from [warningCount], which counts ALL warnings raised (a warning
  /// can be raised on a frame that was not ultimately kept).
  final int warnedCount;

  /// Minimum accepted frames this level needs (the count criterion's threshold).
  /// Always `>= 1`.
  final int minRequired;

  /// Ring coverage 0..100 for the level (filled segments / segment count), or
  /// `null` when the level's segment count is unavailable (degenerate config) —
  /// the card then renders a placeholder instead of a misleading 0% / NaN.
  final int? coveragePct;

  /// The composed per-level completion decision (the SAME validator the gate
  /// uses: 80%-coverage AND min-accepted-count), evaluated from the live ledger +
  /// config — it carries `isComplete` plus the per-criterion shortfall
  /// (`segmentsShort` / `photosShort`) that ranks Fix Issues. NOT recomputed
  /// anywhere else: this is the screen's single completeness/shortfall source.
  final LevelCompletion completion;

  /// Every warning raised during this level's capture, in record order — the
  /// per-level slice the aggregated warnings list flattens across levels.
  final List<CaptureWarning> warnings;

  /// First captured frame's path — the representative card thumbnail. Null when
  /// the level has no captures (→ the card's placeholder).
  final String? thumbnailPath;

  /// Number of warnings raised during this level's capture.
  int get warningCount => warnings.length;

  /// Whether the level meets BOTH completion criteria (coverage + count).
  bool get isComplete => completion.isComplete;

  /// Total "work remaining" to complete the level — segments short + photos short.
  /// 0 when complete. The metric Fix Issues ranks levels by ("most work").
  int get shortfall => completion.segmentsShort + completion.photosShort;
}

/// The level needing the MOST work — the greatest [LevelCaptureSummary.shortfall]
/// among the INCOMPLETE levels — or `null` when every level is complete (no issues
/// to fix). Ties resolve to the lowest level index: [summaries] is in flow order
/// (A→B→C) and the comparison is strict `>`, so the earliest level wins a tie.
CaptureLevel? mostWorkLevel(List<LevelCaptureSummary> summaries) {
  LevelCaptureSummary? worst;
  for (final s in summaries) {
    if (s.isComplete) continue;
    if (worst == null || s.shortfall > worst.shortfall) worst = s;
  }
  return worst?.level;
}

/// Whether every level is complete (coverage + count) — drives Upload's
/// warn-then-allow and whether Fix Issues is shown.
bool allLevelsComplete(List<LevelCaptureSummary> summaries) =>
    summaries.isNotEmpty && summaries.every((s) => s.isComplete);

/// Per-level summaries for the Capture Summary screen, in level order. Built by
/// iterating [CaptureLevel.values] and reading the real captured set per level.
///
/// `autoDispose` so it recomputes a fresh snapshot each time the summary is shown
/// (e.g. after a Review round-trip that re-captured/deleted frames — the screen
/// invalidates the per-level item providers on return; this then reflects the new
/// counts, coverage, and warnings).
final captureSummaryProvider =
    Provider.autoDispose<List<LevelCaptureSummary>>((ref) {
  final config = ref.watch(captureConfigProvider);
  final variant = ref.watch(captureFlowVariantProvider);
  final mode = ref.watch(captureModeProvider);
  final registry = ref.watch(levelCaptureLedgerRegistryProvider);
  final thresholds = config.completionThresholds;

  return [
    for (final level in activeCaptureLevels(variant, mode))
      () {
        final bandId = pitchBandIdForLevel(level);
        final items =
            ref.watch(reviewGridItemsProvider(bandId)); // live captured set
        final ledger = registry.ledgerFor(bandId);

        final warned =
            items.where((i) => i.verdict == CaptureVerdict.warn).length;

        // The SAME effective-N resolver the builders/machines use (always >= 1),
        // so the summary can never disagree with the flow on segment count.
        final segCount = effectiveSegmentsFor(config, variant, bandId, mode: mode);
        final filled = items
            .map((i) => i.ringIndex)
            .whereType<int>()
            .where((s) => s >= 0 && s < segCount)
            .toSet()
            .length;
        final minRequired = thresholds.minAcceptedFramesFor(level.code);
        // The SAME validator the gate uses (coverage AND count) — evaluated from
        // the live ledger; carries the shortfall that ranks Fix Issues.
        final completion = evaluateLevelA(
          filledCount: filled,
          segmentCount: segCount,
          acceptedCount: items.length,
          minAcceptedCount: minRequired,
          minCoveragePct: config.thresholds.minCoveragePct,
        );

        return LevelCaptureSummary(
          level: level,
          name: guidedCaptureLevelName(level),
          frameCount: items.length,
          warnedCount: warned,
          minRequired: minRequired,
          coveragePct: (completion.coverageRatio * 100).round().clamp(0, 100),
          completion: completion,
          warnings: [
            for (final w in ledger.warned)
              CaptureWarning(level: level, message: _warningMessage(w)),
          ],
          thumbnailPath: items.isEmpty ? null : items.first.filePath,
        );
      }(),
  ];
});
