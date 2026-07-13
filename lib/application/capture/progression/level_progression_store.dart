// lib/application/capture/progression/level_progression_store.dart
//
// Hive gateway for the multi-level progression, keyed by `projectId`. Follows the
// repo's box convention (see CaptureSessionStore): a `Box<String>` of JSON,
// opened via [openStringBoxSafely] (corruption + schema-version safe), NO Hive
// TypeAdapters. One entry per project. [load] returns null on absent OR
// corrupt/unparseable data — never throws, so a bad blob means "start fresh".
//
// What it persists: `currentLevelIndex` + the per-level completion SUMMARY
// (levelId/code/segmentCount/filledCount/acceptedCount + gate config). This is the
// sequencing/overall-completion layer; the full per-segment fill counts for
// mid-level resume live in [CaptureSessionStore] (keyed by projectId::levelId).
import 'dart:convert';

import 'package:hive/hive.dart';

import '../../../data/local/box_names.dart';
import '../../../data/local/hive_init.dart';
import '../../../domain/capture/capture_flow_variant.dart';
import '../../../domain/capture/coverage_milestones.dart';
import 'level_progression.dart';

/// Centralised JSON keys so encode/decode can't drift via a typo.
abstract final class LevelProgressionKeys {
  LevelProgressionKeys._();

  static const currentLevelIndex = 'current_level_index';
  static const levels = 'levels';
  static const savedAtMs = 'saved_at_ms';

  // LevelProgressState
  static const levelId = 'level_id';
  static const levelCode = 'level_code';
  static const segmentCount = 'segment_count';
  static const filledCount = 'filled_count';
  static const acceptedCount = 'accepted_count';
  static const minAcceptedCount = 'min_accepted_count';
  static const minCoveragePct = 'min_coverage_pct';
  static const firedMilestones = 'fired_milestones';
}

/// Thrown by [LevelProgressionCodec.fromJson] on structurally invalid data; the
/// store catches it and treats the blob as absent (start fresh).
class LevelProgressionParseException implements Exception {
  const LevelProgressionParseException(this.message);
  final String message;
  @override
  String toString() => 'LevelProgressionParseException: $message';
}

/// Pure JSON <-> [LevelProgression] mapping (no IO).
abstract final class LevelProgressionCodec {
  LevelProgressionCodec._();

  static Map<String, Object?> toJson(LevelProgression p, {required int savedAtMs}) =>
      {
        LevelProgressionKeys.currentLevelIndex: p.currentLevelIndex,
        LevelProgressionKeys.savedAtMs: savedAtMs,
        LevelProgressionKeys.levels: [
          for (final l in p.levels)
            {
              LevelProgressionKeys.levelId: l.levelId,
              LevelProgressionKeys.levelCode: l.levelCode,
              LevelProgressionKeys.segmentCount: l.segmentCount,
              LevelProgressionKeys.filledCount: l.filledCount,
              LevelProgressionKeys.acceptedCount: l.acceptedCount,
              LevelProgressionKeys.minAcceptedCount: l.minAcceptedCount,
              LevelProgressionKeys.minCoveragePct: l.minCoveragePct,
              // Sorted for a stable, diff-friendly blob.
              LevelProgressionKeys.firedMilestones: (l.firedMilestones.toList()
                ..sort()),
            },
        ],
      };

  static LevelProgression fromJson(Map<dynamic, dynamic> json) {
    final rawLevels = json[LevelProgressionKeys.levels];
    if (rawLevels is! List || rawLevels.isEmpty) {
      throw const LevelProgressionParseException('missing/empty levels');
    }
    final levels = <LevelProgressState>[];
    for (final raw in rawLevels) {
      if (raw is! Map) {
        throw const LevelProgressionParseException('level is not a map');
      }
      final levelId = raw[LevelProgressionKeys.levelId];
      if (levelId is! String || levelId.isEmpty) {
        throw const LevelProgressionParseException('level missing level_id');
      }
      levels.add(LevelProgressState(
        levelId: levelId,
        levelCode: raw[LevelProgressionKeys.levelCode] is String
            ? raw[LevelProgressionKeys.levelCode] as String
            : levelId,
        segmentCount: _asInt(raw[LevelProgressionKeys.segmentCount], 1),
        filledCount: _asInt(raw[LevelProgressionKeys.filledCount], 0),
        acceptedCount: _asInt(raw[LevelProgressionKeys.acceptedCount], 0),
        minAcceptedCount: _asInt(raw[LevelProgressionKeys.minAcceptedCount], 1),
        minCoveragePct: _asDouble(raw[LevelProgressionKeys.minCoveragePct], 80),
        firedMilestones: _asMilestoneSet(raw[LevelProgressionKeys.firedMilestones]),
      ));
    }
    final idx = _asInt(json[LevelProgressionKeys.currentLevelIndex], 0);
    // LevelProgression.of clamps a stale/out-of-range index defensively.
    return LevelProgression.of(levels, currentLevelIndex: idx);
  }

  static int _asInt(Object? v, int fallback) =>
      v is num ? v.toInt() : fallback;
  static double _asDouble(Object? v, double fallback) =>
      v is num ? v.toDouble() : fallback;

  /// Tolerant decode of the persisted fired-milestone list: only the canonical
  /// milestones survive (a corrupt/garbage entry is dropped, never a throw), so a
  /// bad blob can at worst lose a milestone (it re-fires once), never crash.
  static Set<int> _asMilestoneSet(Object? v) {
    if (v is! List) return const <int>{};
    return {
      for (final e in v)
        if (e is num && kCoverageMilestones.contains(e.toInt())) e.toInt(),
    };
  }
}

class LevelProgressionStore {
  LevelProgressionStore();

  Box<String>? _box;
  Future<Box<String>>? _opening;

  Future<Box<String>> _open() {
    final existing = _box;
    if (existing != null && existing.isOpen) return Future.value(existing);
    return _opening ??=
        openStringBoxSafely(BoxNames.captureProgression).then((box) {
      _box = box;
      _opening = null;
      return box;
    });
  }

  /// Persists [progression] for [projectId], overwriting any prior snapshot.
  /// [savedAtMs] defaults to now (injectable for deterministic tests).
  Future<void> save(
    String projectId,
    LevelProgression progression, {
    int? savedAtMs,
  }) async {
    final box = await _open();
    await box.put(
      projectId,
      jsonEncode(LevelProgressionCodec.toJson(
        progression,
        savedAtMs: savedAtMs ?? DateTime.now().millisecondsSinceEpoch,
      )),
    );
  }

  /// The progression for [projectId], or null when absent OR corrupt/unparseable
  /// (never throws — treat null as "start fresh").
  Future<LevelProgression?> load(String projectId) async {
    final box = await _open();
    final raw = box.get(projectId);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return LevelProgressionCodec.fromJson(decoded);
    } on FormatException {
      return null;
    } on LevelProgressionParseException {
      return null;
    }
  }

  /// Removes the snapshot for [projectId] (and its flow variant). No-op if absent.
  Future<void> clear(String projectId) async {
    final box = await _open();
    await box.delete(projectId);
    await box.delete(_variantKey(projectId));
  }

  // ── flow variant ───────────────────────────────────────────────────────────
  // The capture FLOW VARIANT for a project is project-scoped sequencing state,
  // so it lives in this box as a sibling key — ONE durable location (never
  // duplicated into the per-level session blobs, which could then disagree).

  /// The box key holding [projectId]'s flow-variant id.
  static String _variantKey(String projectId) => '$projectId::flow_variant';

  /// Persists the chosen flow [variant] for [projectId].
  Future<void> saveVariant(String projectId, CaptureFlowVariant variant) async {
    final box = await _open();
    await box.put(_variantKey(projectId), variant.id);
  }

  /// The persisted flow variant for [projectId]. Absent or unknown (every
  /// pre-variant project) → [CaptureFlowVariant.withBottom], the legacy 3-ring
  /// behavior. Never throws.
  Future<CaptureFlowVariant> loadVariant(String projectId) async =>
      await loadVariantOrNull(projectId) ?? CaptureFlowVariant.withBottom;

  /// The persisted flow variant for [projectId], or null when none was ever
  /// saved (or the stored id is unknown). Lets callers keep their own default
  /// for never-captured projects instead of the legacy 3-ring fallback.
  Future<CaptureFlowVariant?> loadVariantOrNull(String projectId) async {
    final box = await _open();
    final raw = box.get(_variantKey(projectId));
    return CaptureFlowVariant.tryFromId(raw is String ? raw : null);
  }
}
