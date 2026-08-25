// lib/domain/capture/completion_gate.dart
//
// Pure Dart — NO Flutter/Riverpod/native imports. The SINGLE authoritative
// definition of "guided capture is done": the final completion gate that unlocks
// the Summary screen (6C-Complete). Both the router (whether the flow may reach
// Summary) and the Summary screen itself (Continue gating + per-card status) read
// THIS — the rule exists in exactly one place.
//
// RULE (config-driven, not hardcoded): a level is complete when its accepted
// frame count meets that level's configured minimum (`minAcceptedFrames`, from
// `CompletionThresholds` — defaultable/remote-overridable). The gate is unlocked
// iff EVERY configured level is complete. The level SET is supplied by the caller
// (iterating the config level list), never a hardcoded A/B/C or the number 3.
//
// FAIL SAFE: with no level data (empty input) there are zero accepted frames, so
// every level is incomplete and the gate stays LOCKED — missing/ambiguous state
// never unlocks. READ-ONLY: it derives a decision from counts; it mutates nothing.

/// One level's completion status within the gate — its identity, the accepted
/// count read live from the results store, the threshold applied, and the derived
/// completeness. Immutable.
class LevelCompletionStatus {
  const LevelCompletionStatus({
    required this.levelCode,
    required this.acceptedCount,
    required this.minAcceptedFrames,
  });

  /// Display/level code ("A"/"B"/"C") — the gate's per-level key + the
  /// `incomplete_levels` analytics token.
  final String levelCode;

  /// Accepted frames for this level (from the per-level ledger/results store).
  final int acceptedCount;

  /// The minimum accepted frames this level needs (config-driven, validated `>=1`).
  final int minAcceptedFrames;

  /// Complete iff the accepted count meets the level's threshold.
  bool get isComplete => acceptedCount >= minAcceptedFrames;

  @override
  bool operator ==(Object other) =>
      other is LevelCompletionStatus &&
      other.levelCode == levelCode &&
      other.acceptedCount == acceptedCount &&
      other.minAcceptedFrames == minAcceptedFrames;

  @override
  int get hashCode => Object.hash(levelCode, acceptedCount, minAcceptedFrames);

  @override
  String toString() => 'LevelCompletionStatus($levelCode, '
      '$acceptedCount/$minAcceptedFrames, complete: $isComplete)';
}

/// The evaluated final completion gate over all configured levels. Immutable;
/// derived purely from the per-level statuses.
class SummaryGate {
  const SummaryGate(this.levels);

  /// Per-level statuses in configured order.
  final List<LevelCompletionStatus> levels;

  /// The gate: unlocked iff there is at least one level AND every level is
  /// complete. Empty input ⇒ locked (fail safe).
  bool get isUnlocked => levels.isNotEmpty && levels.every((l) => l.isComplete);

  /// Alias for [isUnlocked] in `areAllLevelsComplete()` terms.
  bool get areAllLevelsComplete => isUnlocked;

  /// The codes of levels still below their threshold, in order (for the blocked
  /// analytics + "what remains" messaging). Empty when unlocked.
  List<String> get incompleteLevelCodes =>
      [for (final l in levels) if (!l.isComplete) l.levelCode];

  /// `incompleteLevelCodes` as the analytics wire string (e.g. "C" or "B,C").
  String get incompleteLevelsLabel => incompleteLevelCodes.join(',');

  int get levelsTotal => levels.length;

  int get levelsComplete => levels.where((l) => l.isComplete).length;

  /// Whether [levelCode] is complete (false for an unknown code — fail safe).
  bool isLevelComplete(String levelCode) {
    for (final l in levels) {
      if (l.levelCode == levelCode) return l.isComplete;
    }
    return false;
  }

  @override
  String toString() =>
      'SummaryGate(unlocked: $isUnlocked, $levelsComplete/$levelsTotal, '
      'incomplete: $incompleteLevelsLabel)';
}

/// Builds the gate from per-level [statuses]. A thin constructor wrapper kept as a
/// named function so call sites read as an evaluation step.
SummaryGate evaluateSummaryGate(List<LevelCompletionStatus> statuses) =>
    SummaryGate(List<LevelCompletionStatus>.unmodifiable(statuses));
