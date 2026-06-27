// lib/application/capture/progression/level_progression.dart
//
// The PURE core of the multi-level guided-capture progression (A → B → C). It is
// the single source of truth for "where are we in the flow": the ordered level
// sequence, per-level completion (composed from the existing completion gate), the
// no-forward-skip advance rule, backward review access, and overall completion.
//
// PURITY: no Flutter / Hive / IO / async. It composes the existing per-level
// pieces (it does NOT reimplement coverage or the gate): each level's completeness
// is decided by [evaluateLevelA] (the SegmentCoverage-fed 80%-coverage + min-count
// gate). Every transform returns a NEW immutable snapshot, so it is trivially
// unit-testable; the Hive store and the Riverpod controller are thin adapters
// around this core.
//
// IDENTITY: a level is keyed by its [levelId] — the `PitchBand.id` string
// ("mid"/"high"/"low"), the SAME key the ledger registry and capture-session store
// use, so progression, persistence, and per-level state never disagree on which
// level is which. (The display code "A"/"B"/"C" is carried alongside for the UI.)
import '../../../domain/capture/level_completion.dart';

/// One level's progression state — the gate inputs for its completeness, plus its
/// identity. The full per-segment coverage (for mid-level resume) lives in the
/// CaptureSessionStore snapshot; this carries the [filledCount]/[acceptedCount]
/// the completion gate needs, so overall progression survives a restart without
/// reloading every session blob.
class LevelProgressState {
  const LevelProgressState({
    required this.levelId,
    required this.levelCode,
    required this.segmentCount,
    this.filledCount = 0,
    this.acceptedCount = 0,
    this.minAcceptedCount = 1,
    this.minCoveragePct = kDefaultMinCoveragePct,
    this.firedMilestones = const <int>{},
  });

  /// The `PitchBand.id` ("mid"/"high"/"low") — the canonical per-level key.
  final String levelId;

  /// Display code "A"/"B"/"C" (UI/analytics; never the storage key).
  final String levelCode;

  /// Ring positions (N) for this level — from the level config (object-size map).
  final int segmentCount;

  /// Filled segments so far (from the level's SegmentCoverage.filledCount).
  final int filledCount;

  /// Accepted photos so far (from the level's ledger — ACCEPT + WARN-kept).
  final int acceptedCount;

  /// Minimum accepted photos required by the completion gate.
  final int minAcceptedCount;

  /// Coverage threshold (percent) the completion gate applies.
  final double minCoveragePct;

  /// The `coverage_milestone`s ({25,50,75,100}) already fired for this level —
  /// persisted with the level's state so a RESUME of a partially-covered level
  /// does NOT re-fire milestones it already crossed (the coverage-analytics
  /// observer seeds itself from this; see [CoverageAnalyticsTracker.seedLevel]).
  /// Empty on a fresh level start. Analytics-only — NOT a completion input.
  final Set<int> firedMilestones;

  /// The composed completion decision for this level (delegates to the shared
  /// [evaluateLevelA] gate — NOT reimplemented here).
  LevelCompletion get completion => evaluateLevelA(
        filledCount: filledCount,
        segmentCount: segmentCount,
        acceptedCount: acceptedCount,
        minAcceptedCount: minAcceptedCount,
        minCoveragePct: minCoveragePct,
      );

  /// True once this level meets its gate (80% coverage + min accepted count).
  bool get isComplete => completion.isComplete;

  LevelProgressState copyWith({
    int? segmentCount,
    int? filledCount,
    int? acceptedCount,
    int? minAcceptedCount,
    double? minCoveragePct,
    Set<int>? firedMilestones,
  }) =>
      LevelProgressState(
        levelId: levelId,
        levelCode: levelCode,
        segmentCount: segmentCount ?? this.segmentCount,
        filledCount: filledCount ?? this.filledCount,
        acceptedCount: acceptedCount ?? this.acceptedCount,
        minAcceptedCount: minAcceptedCount ?? this.minAcceptedCount,
        minCoveragePct: minCoveragePct ?? this.minCoveragePct,
        firedMilestones: firedMilestones ?? this.firedMilestones,
      );

  @override
  bool operator ==(Object other) =>
      other is LevelProgressState &&
      other.levelId == levelId &&
      other.levelCode == levelCode &&
      other.segmentCount == segmentCount &&
      other.filledCount == filledCount &&
      other.acceptedCount == acceptedCount &&
      other.minAcceptedCount == minAcceptedCount &&
      other.minCoveragePct == minCoveragePct &&
      _intSetEquals(other.firedMilestones, firedMilestones);

  @override
  int get hashCode => Object.hash(
      levelId,
      levelCode,
      segmentCount,
      filledCount,
      acceptedCount,
      minAcceptedCount,
      minCoveragePct,
      // Order-independent set hash so equal sets hash equally.
      Object.hashAllUnordered(firedMilestones));

  @override
  String toString() => 'LevelProgressState($levelCode/$levelId, '
      'filled: $filledCount/$segmentCount, accepted: $acceptedCount, '
      'complete: $isComplete)';
}

/// Immutable multi-level progression: the ordered levels + the frontier index
/// (the furthest level reached = the active capture level). The frontier only ever
/// moves FORWARD, and only through [advance] when the current level's gate passes
/// — there is no forward skip. Backward review of an earlier level is allowed and
/// never moves the frontier (see [canReview]).
class LevelProgression {
  const LevelProgression._(this.levels, this.currentLevelIndex);

  /// Builds a progression over [levels] (already in flow order A→B→C). Empty input
  /// is rejected (a flow always has ≥1 level). [currentLevelIndex] is clamped into
  /// range, so a corrupt/stale index can never throw.
  factory LevelProgression.of(
    List<LevelProgressState> levels, {
    int currentLevelIndex = 0,
  }) {
    assert(levels.isNotEmpty, 'a progression needs at least one level');
    final n = levels.length;
    final idx = currentLevelIndex < 0
        ? 0
        : (currentLevelIndex >= n ? n - 1 : currentLevelIndex);
    return LevelProgression._(List<LevelProgressState>.unmodifiable(levels), idx);
  }

  /// The levels in flow order (A→B→C). Unmodifiable.
  final List<LevelProgressState> levels;

  /// The frontier: index of the active (furthest-reached) level.
  final int currentLevelIndex;

  /// The active level's state.
  LevelProgressState get currentLevel => levels[currentLevelIndex];

  /// True when the frontier is the last level (no next to advance to).
  bool get isLastLevel => currentLevelIndex >= levels.length - 1;

  /// True when the CURRENT level's completion gate passes — the precondition for
  /// [advance]. (Defense in depth: even if the UI only offers advance when shown
  /// complete, [advance] re-checks this.)
  bool get canAdvance => currentLevel.isComplete;

  /// Overall completion = EVERY level's gate passes (not just the current). A prior
  /// level un-completed by review (a delete dropping it below the gate) makes this
  /// false until it is re-completed.
  bool get overallComplete => levels.every((l) => l.isComplete);

  /// Index of [levelId], or -1 if absent.
  int indexOfId(String levelId) =>
      levels.indexWhere((l) => l.levelId == levelId);

  /// The state for [levelId], or null if absent.
  LevelProgressState? stateForId(String levelId) {
    final i = indexOfId(levelId);
    return i < 0 ? null : levels[i];
  }

  /// Whether [levelIndex] may be reviewed: any level up to and INCLUDING the
  /// frontier (backward review is allowed). A level beyond the frontier cannot be
  /// reviewed — that would be a forward skip. Reviewing never moves the frontier.
  bool canReview(int levelIndex) =>
      levelIndex >= 0 && levelIndex <= currentLevelIndex;

  /// Whether the level identified by [levelId] may be reviewed (see [canReview]).
  bool canReviewId(String levelId) {
    final i = indexOfId(levelId);
    return i >= 0 && canReview(i);
  }

  /// No-forward-skip advance. Returns the advanced snapshot when the current level
  /// is complete and a next level exists; otherwise returns `this` unchanged (the
  /// caller treats an identical result as "rejected" — an incomplete level is never
  /// skipped, and the last level has nothing to advance to). [didAdvance] reports
  /// whether the frontier moved.
  LevelProgression advance() {
    if (!canAdvance || isLastLevel) return this;
    return LevelProgression._(levels, currentLevelIndex + 1);
  }

  /// Replaces [levelId]'s coverage/accepted counts (and optionally its
  /// segmentCount) — used as capture progresses, or when a review delete
  /// un-completes a level. The frontier is NOT changed (review/edit of any level,
  /// including a prior one, never regresses progression). Unknown [levelId] → `this`.
  LevelProgression updateLevel(
    String levelId, {
    int? filledCount,
    int? acceptedCount,
    int? segmentCount,
    Set<int>? firedMilestones,
  }) {
    final i = indexOfId(levelId);
    if (i < 0) return this;
    final next = List<LevelProgressState>.of(levels);
    next[i] = next[i].copyWith(
      filledCount: filledCount,
      acceptedCount: acceptedCount,
      segmentCount: segmentCount,
      firedMilestones: firedMilestones,
    );
    return LevelProgression._(
      List<LevelProgressState>.unmodifiable(next),
      currentLevelIndex,
    );
  }

  /// The first incomplete level's index, or -1 when all complete. Used to guide
  /// the user to what still needs work (e.g. after a prior level is un-completed).
  int get firstIncompleteIndex => levels.indexWhere((l) => !l.isComplete);

  @override
  bool operator ==(Object other) =>
      other is LevelProgression &&
      other.currentLevelIndex == currentLevelIndex &&
      _levelsEqual(other.levels, levels);

  @override
  int get hashCode =>
      Object.hash(currentLevelIndex, Object.hashAll(levels));

  @override
  String toString() => 'LevelProgression(current: $currentLevelIndex/'
      '${levels.length - 1} [${currentLevel.levelCode}], '
      'overallComplete: $overallComplete)';
}

/// Order-independent equality for the small fired-milestone sets.
bool _intSetEquals(Set<int> a, Set<int> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  return a.containsAll(b);
}

bool _levelsEqual(List<LevelProgressState> a, List<LevelProgressState> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
