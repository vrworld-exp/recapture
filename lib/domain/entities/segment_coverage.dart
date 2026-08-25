// lib/domain/entities/segment_coverage.dart
//
// Pure Dart — NO Flutter/native imports. The single source of truth for eye-ring
// coverage STATE: per-segment fill counts, the derived gaps (missing), and the
// next segment to guide the user to (current target). It is the layer between
// the ring coverage engine (which owns the angular math: yaw → current segment,
// wraparound-aware distance) and the guided-capture HUD (which renders).
//
// DIVISION OF LABOR
//   - The ring engine (ring_coverage_engine.dart / RingMath) owns segment
//     indexing, segmentCount, and wraparound-aware distance. This model CONSUMES
//     that math (RingMath.nearestInSet) — it never reimplements it.
//   - THIS model owns fill/target/missing state derived from capture events
//     (recordCapture) and the user's current position (updatePosition).
//
// KEY INVARIANTS
//   - `missingSegments` and `currentTarget` are DERIVED from `fillCounts` (+
//     position + config) on every read — never stored independently, so the
//     three can't drift out of sync.
//   - A segment is filled ONLY by `recordCapture` (a capture event). Position
//     updates re-aim the target but never fill anything (assignment ≠ coverage —
//     the same rule the engine enforces).
//   - `filled[i]` ⇔ `fillCounts[i] >= fillThreshold` (configurable, default 1),
//     so "filled" can mean "has K captures", not just "touched once". Overfill
//     is idempotent w.r.t. `filled`.
//
// IMMUTABLE + PURE: every transform (recordCapture / updatePosition / reset /
// reconfigure) returns a NEW snapshot; every derivation is a pure function of the
// stored state. This keeps the core trivially unit-testable; the reactive layer
// (SegmentCoverageNotifier) is a thin wrapper over these transforms.

import '../capture/ring_coverage_engine.dart' show RingMath;
import 'ring_coverage.dart';

class SegmentCoverage {
  /// Internal canonical constructor. [fillCounts] must already be the right
  /// length and non-negative, and [position] in range — use [SegmentCoverage.of]
  /// / the transforms, which guard, rather than calling this directly.
  const SegmentCoverage._({
    required this.segmentCount,
    required this.fillThreshold,
    required List<int> fillCounts,
    required this.position,
  }) : _fillCounts = fillCounts;

  /// Builds a guarded snapshot. [segmentCount] is clamped `>= 1` and
  /// [fillThreshold] `>= 1`. [fillCounts], when supplied, is normalized to length
  /// [segmentCount] (truncated/zero-padded) with negatives clamped to 0.
  /// [position] is taken modulo the (guarded) segment count.
  factory SegmentCoverage.of({
    required int segmentCount,
    int fillThreshold = 1,
    List<int>? fillCounts,
    int position = 0,
  }) {
    final n = segmentCount < 1 ? 1 : segmentCount;
    final k = fillThreshold < 1 ? 1 : fillThreshold;
    final counts = List<int>.generate(n, (i) {
      final v = (fillCounts != null && i < fillCounts.length) ? fillCounts[i] : 0;
      return v < 0 ? 0 : v;
    }, growable: false);
    return SegmentCoverage._(
      segmentCount: n,
      fillThreshold: k,
      fillCounts: counts,
      position: ((position % n) + n) % n,
    );
  }

  /// A fresh, fully-empty ring.
  factory SegmentCoverage.initial({
    required int segmentCount,
    int fillThreshold = 1,
    int position = 0,
  }) =>
      SegmentCoverage.of(
        segmentCount: segmentCount,
        fillThreshold: fillThreshold,
        position: position,
      );

  /// N — total positions around the ring (matches the engine's segmentCount and
  /// [RingCoverage.segmentCount]). Always `>= 1`.
  final int segmentCount;

  /// Captures required before a segment counts as filled. Always `>= 1`.
  final int fillThreshold;

  /// The user's current segment (from the ring engine). Drives nearest-missing
  /// target selection only; never fills a segment.
  final int position;

  final List<int> _fillCounts;

  /// Per-segment capture counts (read-only copy; length == [segmentCount]).
  List<int> get fillCounts => List<int>.unmodifiable(_fillCounts);

  bool _inRange(int i) => i >= 0 && i < segmentCount;

  // ── derived state (pure functions of fillCounts + position + config) ────────

  /// `filled[i]` ⇔ segment i has reached the threshold.
  List<bool> get filled => [
        for (final c in _fillCounts) c >= fillThreshold,
      ];

  /// Indices below the threshold, ascending. Empty iff complete.
  List<int> get missingSegments => [
        for (var i = 0; i < segmentCount; i++)
          if (_fillCounts[i] < fillThreshold) i,
      ];

  /// Number of filled segments.
  int get filledCount {
    var n = 0;
    for (final c in _fillCounts) {
      if (c >= fillThreshold) n++;
    }
    return n;
  }

  /// Coverage in [0, 1] — filled / total.
  double get progress => (filledCount / segmentCount).clamp(0.0, 1.0);

  /// True once every segment is filled.
  bool get isComplete => filledCount >= segmentCount;

  /// The next segment to guide the user to: the NEAREST missing segment by the
  /// engine's wraparound-aware distance from [position], minimizing how far the
  /// user must turn. Equidistant ties resolve FORWARD (index-increasing — the
  /// ring's clockwise sweep convention), via [RingMath.nearestInSet]. `null` iff
  /// [isComplete] (no missing segments).
  int? get currentTarget =>
      RingMath.nearestInSet(position, missingSegments.toSet(), segmentCount);

  /// Missing segments ordered by proximity to [from] (or [position]) — nearest
  /// first, forward ties before backward. For "queue of gaps" UIs. Empty when
  /// complete.
  List<int> missingByProximity({int? from}) {
    final origin = from ?? position;
    final remaining = missingSegments.toSet();
    final ordered = <int>[];
    while (remaining.isNotEmpty) {
      final next = RingMath.nearestInSet(origin, remaining, segmentCount);
      if (next == null) break;
      ordered.add(next);
      remaining.remove(next);
    }
    return ordered;
  }

  // ── transforms (return new snapshots; never mutate) ─────────────────────────

  /// Fills [segmentIndex] by one capture. Out-of-range index → unchanged (stale
  /// engine value can't corrupt state). Overfill is allowed (the count keeps
  /// climbing) but is idempotent w.r.t. `filled`. Typically [segmentIndex] is
  /// the engine's current segment at capture time.
  SegmentCoverage recordCapture(int segmentIndex) {
    if (!_inRange(segmentIndex)) return this;
    final next = List<int>.of(_fillCounts);
    next[segmentIndex] = next[segmentIndex] + 1;
    return SegmentCoverage._(
      segmentCount: segmentCount,
      fillThreshold: fillThreshold,
      fillCounts: next,
      position: position,
    );
  }

  /// Removes one capture from [segmentIndex] (decrements its fill count, clamped
  /// at 0) — the counterpart to [recordCapture], used when a photo is deleted. A
  /// segment can drop below [fillThreshold] and become MISSING again, so
  /// `missingSegments` / `currentTarget` / `progress` recompute accordingly.
  /// Out-of-range index, or a segment already at 0, → unchanged (a stale id or a
  /// double-delete can't push a count negative).
  SegmentCoverage removeCapture(int segmentIndex) {
    if (!_inRange(segmentIndex)) return this;
    if (_fillCounts[segmentIndex] == 0) return this;
    final next = List<int>.of(_fillCounts);
    next[segmentIndex] = next[segmentIndex] - 1;
    return SegmentCoverage._(
      segmentCount: segmentCount,
      fillThreshold: fillThreshold,
      fillCounts: next,
      position: position,
    );
  }

  /// Updates the user's current segment, re-aiming [currentTarget] at the new
  /// nearest missing segment. Fills NOTHING. Returns `this` unchanged when the
  /// (normalized) position is the same, so reactive consumers don't churn.
  SegmentCoverage updatePosition(int currentSegment) {
    final p = ((currentSegment % segmentCount) + segmentCount) % segmentCount;
    if (p == position) return this;
    return SegmentCoverage._(
      segmentCount: segmentCount,
      fillThreshold: fillThreshold,
      fillCounts: _fillCounts,
      position: p,
    );
  }

  /// Clears all fill counts (keeps [segmentCount]/[fillThreshold]); position
  /// resets to 0.
  SegmentCoverage reset() => SegmentCoverage.of(
        segmentCount: segmentCount,
        fillThreshold: fillThreshold,
      );

  /// Re-initializes for a new ring shape. All coverage is dropped (a different
  /// [segmentCount] makes old indices meaningless) and position resets to 0.
  SegmentCoverage reconfigure({required int segmentCount, int fillThreshold = 1}) =>
      SegmentCoverage.of(
        segmentCount: segmentCount,
        fillThreshold: fillThreshold,
      );

  /// Bridges to the [RingCoverage] DISPLAY model the ring-map HUD renders, so the
  /// map, this model, and the engine share one source of truth. [targetIndex]
  /// defaults to [currentTarget].
  RingCoverage toRingCoverage({int? targetIndex}) => RingCoverage(
        segmentCount: segmentCount,
        filledIndices: {
          for (var i = 0; i < segmentCount; i++)
            if (_fillCounts[i] >= fillThreshold) i,
        },
        targetIndex: targetIndex ?? currentTarget,
      );

  @override
  bool operator ==(Object other) =>
      other is SegmentCoverage &&
      other.segmentCount == segmentCount &&
      other.fillThreshold == fillThreshold &&
      other.position == position &&
      _listEquals(other._fillCounts, _fillCounts);

  @override
  int get hashCode => Object.hash(
        segmentCount,
        fillThreshold,
        position,
        Object.hashAll(_fillCounts),
      );

  @override
  String toString() =>
      'SegmentCoverage(n: $segmentCount, k: $fillThreshold, pos: $position, '
      'filled: $filledCount/$segmentCount, target: $currentTarget)';
}

bool _listEquals(List<int> a, List<int> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
