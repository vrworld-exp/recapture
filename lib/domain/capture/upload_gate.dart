// lib/domain/capture/upload_gate.dart
//
// Pure Dart — NO Flutter/Riverpod/native imports. The HARD upload gate: the
// absolute floor that decides whether the captured set may be uploaded AT ALL.
// A level is uploadable iff BOTH
//   1. its accepted-shot count meets that level's config-driven ABSOLUTE
//      MINIMUM (UploadMinShots), AND
//   2. its ring COVERAGE meets the level-completion floor — filled segments
//      >= ceil(minCoveragePct% × segmentCount). The backend rejects a job
//      whose per-ring image count sits below that same floor
//      (minimumPerRing in recapture-api's captureVariants.ts), and the bundle
//      packer stages at most one image per filled segment — so a level below
//      coverage would produce a bundle POST /jobs 400s on. The gate keeps
//      that unreachable.
// The gate is eligible iff EVERY configured level meets both.
//
// This is DISTINCT from the soft completion gate (completion_gate.dart): that one
// answers "is the level done / Summary unlocked?"; THIS one answers "is there
// enough raw data that the pipeline (and the backend's count range) will accept
// it?" — a separate threshold, evaluated independently. The level SET is
// supplied by the caller (iterating the config level list), never hardcoded.
//
// FAIL SAFE: with no level data (empty input) the gate is NOT eligible — unknown /
// missing state must never enable upload. READ-ONLY: derives a decision from
// counts; mutates nothing. Comparisons are INCLUSIVE (== required passes).

/// One level's standing against the hard upload floor.
class UploadLevelStatus {
  const UploadLevelStatus({
    required this.levelCode,
    required this.accepted,
    required this.required,
    this.filled = 0,
    this.requiredFilled = 0,
  });

  /// Display/level code ("A"/"B"/"C") — the per-level key + the `short_levels`
  /// analytics token.
  final String levelCode;

  /// Accepted shots for this level (from the per-level ledger/results store).
  final int accepted;

  /// The absolute minimum accepted shots this level needs (config-driven, `>=1`).
  final int required;

  /// DISTINCT ring segments the accepted shots cover (the ledger analogue of
  /// `SegmentCoverage.filledCount`).
  final int filled;

  /// The coverage floor: filled segments needed for the level to be uploadable
  /// (`requiredSegmentsFor(minCoveragePct, segmentCount)` — the same floor the
  /// backend enforces per ring). 0 = no coverage requirement (legacy callers).
  final int requiredFilled;

  /// Meets the floor iff the shot count AND the ring coverage both reach their
  /// minimums (inclusive).
  bool get meetsMinimum => accepted >= required && filled >= requiredFilled;

  /// Accepted shots still missing against [required] — 0 when met.
  int get shotsShort => accepted >= required ? 0 : required - accepted;

  /// Filled segments still missing against [requiredFilled] — 0 when met.
  int get segmentsShort =>
      filled >= requiredFilled ? 0 : requiredFilled - filled;

  /// How many more accepted shots are needed to satisfy BOTH floors — one new
  /// shot fills at most one new segment, so this is the larger shortfall.
  int get deficit =>
      shotsShort > segmentsShort ? shotsShort : segmentsShort;

  @override
  bool operator ==(Object other) =>
      other is UploadLevelStatus &&
      other.levelCode == levelCode &&
      other.accepted == accepted &&
      other.required == required &&
      other.filled == filled &&
      other.requiredFilled == requiredFilled;

  @override
  int get hashCode =>
      Object.hash(levelCode, accepted, required, filled, requiredFilled);

  @override
  String toString() => 'UploadLevelStatus($levelCode, $accepted/$required, '
      'coverage: $filled/$requiredFilled, '
      'meets: $meetsMinimum, deficit: $deficit)';
}

/// The evaluated hard upload gate over all configured levels. Immutable; derived
/// purely from the per-level statuses.
class UploadGate {
  const UploadGate(this.levels);

  /// Per-level statuses in configured order.
  final List<UploadLevelStatus> levels;

  /// Eligible iff there is at least one level AND every level meets its floor.
  /// Empty input ⇒ NOT eligible (fail safe).
  bool get eligible =>
      levels.isNotEmpty && levels.every((l) => l.meetsMinimum);

  /// The levels below their floor, in order (for the disabled-state messaging +
  /// the `short_levels` analytics). Empty when eligible.
  List<UploadLevelStatus> get shortLevels =>
      [for (final l in levels) if (!l.meetsMinimum) l];

  /// `shortLevels` codes as the analytics wire string (e.g. "B" or "B,C").
  String get shortLevelsLabel => shortLevels.map((l) => l.levelCode).join(',');

  /// Sum of per-level deficits — the `total_deficit` analytics value.
  int get totalDeficit =>
      shortLevels.fold(0, (sum, l) => sum + l.deficit);

  @override
  String toString() =>
      'UploadGate(eligible: $eligible, short: $shortLevelsLabel, '
      'totalDeficit: $totalDeficit)';
}

/// Builds the gate from per-level [statuses]. A thin constructor wrapper kept as a
/// named function so call sites read as an evaluation step.
UploadGate evaluateUploadGate(List<UploadLevelStatus> statuses) =>
    UploadGate(List<UploadLevelStatus>.unmodifiable(statuses));
