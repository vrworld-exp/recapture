// lib/domain/capture/upload_gate.dart
//
// Pure Dart — NO Flutter/Riverpod/native imports. The HARD upload gate: the
// absolute floor that decides whether the captured set may be uploaded AT ALL.
// A level is uploadable iff its accepted-shot count meets that level's
// config-driven ABSOLUTE MINIMUM (UploadMinShots). The gate is eligible iff EVERY
// configured level meets its minimum.
//
// This is DISTINCT from the soft completion gate (completion_gate.dart): that one
// answers "is the level done / Summary unlocked?"; THIS one answers "is there
// enough raw data that the pipeline won't choke?" — a separate, never-higher
// threshold, evaluated independently. The level SET is supplied by the caller
// (iterating the config level list), never hardcoded.
//
// FAIL SAFE: with no level data (empty input) the gate is NOT eligible — unknown /
// missing state must never enable upload. READ-ONLY: derives a decision from
// counts; mutates nothing. Comparison is INCLUSIVE (accepted == required passes).

/// One level's standing against the hard upload floor.
class UploadLevelStatus {
  const UploadLevelStatus({
    required this.levelCode,
    required this.accepted,
    required this.required,
  });

  /// Display/level code ("A"/"B"/"C") — the per-level key + the `short_levels`
  /// analytics token.
  final String levelCode;

  /// Accepted shots for this level (from the per-level ledger/results store).
  final int accepted;

  /// The absolute minimum accepted shots this level needs (config-driven, `>=1`).
  final int required;

  /// Meets the floor iff accepted reaches the minimum (inclusive).
  bool get meetsMinimum => accepted >= required;

  /// How many more accepted shots are needed — 0 when the floor is met.
  int get deficit => meetsMinimum ? 0 : required - accepted;

  @override
  bool operator ==(Object other) =>
      other is UploadLevelStatus &&
      other.levelCode == levelCode &&
      other.accepted == accepted &&
      other.required == required;

  @override
  int get hashCode => Object.hash(levelCode, accepted, required);

  @override
  String toString() => 'UploadLevelStatus($levelCode, $accepted/$required, '
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
