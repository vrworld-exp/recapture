// lib/domain/entities/ring_coverage.dart
//
// Pure Dart — NO Flutter imports. The 360° eye-ring coverage the Level A ring
// map renders: how many segments (N, from CaptureConfig), which are captured,
// and which is the current/next target. This is a DISPLAY model — computing
// which segments are filled and which is the target (from device yaw vs the N
// target angles) is a SEPARATE resolver concern, not this model.
//
// Convention: segment 0 is at 12 o'clock and index increases clockwise — this
// must match the ring-progress resolver and the direction arrow so positions map
// to real-world angles (calibrate on-device).
//
// All accessors are defensive: out-of-range filled/target indices are ignored
// (never crash, never NaN), so a stale resolver value can't break the HUD.

/// Per-segment render state. [filled] takes precedence over [target].
enum SegmentState { missing, target, filled }

class RingCoverage {
  const RingCoverage({
    required this.segmentCount,
    this.filledIndices = const {},
    this.targetIndex,
  });

  /// N — total positions around the ring (from the Level A band's `segments`).
  final int segmentCount;

  /// Captured segment indices (expected 0..N-1; out-of-range entries ignored).
  final Set<int> filledIndices;

  /// The current/next segment to capture, or null. Ignored if out-of-range or
  /// already filled.
  final int? targetIndex;

  bool _inRange(int i) => i >= 0 && i < segmentCount;

  /// The render state of segment [i]. Filled wins over target; an out-of-range
  /// or already-filled target never highlights. Out-of-range [i] → missing.
  SegmentState stateOf(int i) {
    if (!_inRange(i)) return SegmentState.missing;
    if (filledIndices.contains(i)) return SegmentState.filled;
    if (i == effectiveTarget) return SegmentState.target;
    return SegmentState.missing;
  }

  /// Captured count, counting only in-range indices (stale entries ignored).
  int get filledCount => filledIndices.where(_inRange).length;

  /// Capture progress in [0, 1]; 0 when there are no segments (no div-by-zero).
  double get progress =>
      segmentCount <= 0 ? 0 : (filledCount / segmentCount).clamp(0.0, 1.0);

  /// True once every segment is captured (and there is at least one).
  bool get isComplete => segmentCount > 0 && filledCount >= segmentCount;

  /// The target to highlight, or null if absent / out-of-range / already filled.
  int? get effectiveTarget {
    final t = targetIndex;
    if (t == null || !_inRange(t) || filledIndices.contains(t)) return null;
    return t;
  }

  @override
  bool operator ==(Object other) =>
      other is RingCoverage &&
      other.segmentCount == segmentCount &&
      other.targetIndex == targetIndex &&
      _setEquals(other.filledIndices, filledIndices);

  @override
  int get hashCode => Object.hash(
        segmentCount,
        targetIndex,
        Object.hashAllUnordered(filledIndices),
      );
}

bool _setEquals(Set<int> a, Set<int> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final e in a) {
    if (!b.contains(e)) return false;
  }
  return true;
}
