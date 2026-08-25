// lib/domain/capture/level_segment_machine.dart
//
// Pure Dart — NO Flutter/Riverpod/native imports. ONE per-level instance of the
// SAME guided-capture engine Level A uses — instantiated independently for
// Levels A, B and C. It is a thin BUNDLE, not a new engine: it composes the
// existing, already level-agnostic pieces
//
//   - [RingCoverageEngine] — the angular state machine (per-level `yawStart`
//     baseline + `segmentCount` + wraparound-safe yaw→segment assignment +
//     direction). It owns NO Level-A assumption: every level-specific is a
//     constructor argument.
//   - [SegmentCoverage] — the threshold-aware fill state (the SINGLE source of
//     truth for `filled[]`/fill counts/`missingSegments`/`currentTarget`/
//     completion), exactly as the live Level A flow treats it.
//
// PER-LEVEL INDEPENDENCE: each machine owns its OWN engine + coverage + band +
// `segmentCount` + `yawStart`. Nothing is static or shared, so filling Level B's
// segments cannot touch Level C's (or A's): the instances are isolated, and B
// may be complete while C is not-started. Construct one per level (see
// `levelSegmentMachinesFromConfig`) and the level progression controller
// composes them via this uniform interface — it never reaches inside.
//
// DIVISION OF LABOUR (the repo's existing contract, reused verbatim):
//   - The ring engine owns angular math (yaw → currentSegment, direction).
//   - [SegmentCoverage] owns fill (a segment is filled ONLY by a capture, never
//     by position). Overlap is decided by [evaluateSegmentCapture] against that
//     fill — assignment ≠ coverage, the same rule both pieces already enforce.
//
// PURE + DETERMINISTIC: no UI/async/IO. Mutable per-instance state, but every
// step is a synchronous function of its inputs — trivially unit-testable.
import '../entities/capture_config.dart' show PitchBand;
import '../entities/ring_coverage.dart' show RingCoverage;
import '../entities/segment_coverage.dart';
import 'ring_coverage_engine.dart';
import 'segment_capture_decision.dart';

/// A single level's segment state machine — an independent instance of the same
/// engine for Level A, B or C. Identity ([levelId]/[levelCode]) + band context +
/// its own `segmentCount`, `yawStart`, and coverage; isolated from every other
/// level's instance.
class LevelSegmentMachine {
  /// Builds a level's machine. [segmentCount] defaults to the [band]'s `segments`
  /// (the per-level count — Top/Bottom rings can differ from the Eye Ring), is
  /// guarded `>= 1`, and is fixed for the machine's life. [fillThreshold]
  /// (captures required before a segment counts as filled) and
  /// [boundaryHysteresisDeg] (anti-flicker dead-band at segment edges) carry the
  /// engine's own defaults. The machine starts NOT-baselined — call [begin] when
  /// this ring's capture begins so `yawStart` is THIS level's start heading.
  LevelSegmentMachine({
    required this.levelId,
    required this.levelCode,
    required this.band,
    int? segmentCount,
    int fillThreshold = 1,
    double boundaryHysteresisDeg = 0,
  })  : segmentCount = (segmentCount ?? band.segments) < 1
            ? 1
            : (segmentCount ?? band.segments),
        _ring = RingCoverageEngine(boundaryHysteresisDeg: boundaryHysteresisDeg) {
    _coverage = SegmentCoverage.initial(
      segmentCount: this.segmentCount,
      fillThreshold: fillThreshold < 1 ? 1 : fillThreshold,
    );
  }

  /// The `PitchBand.id` ("mid"/"high"/"low") — the canonical per-level key shared
  /// with the ledger, session store, and progression core.
  final String levelId;

  /// Display code "A"/"B"/"C" (UI/analytics only; never the storage key).
  final String levelCode;

  /// This level's pitch band (degrees + the band's own segment count) — the
  /// per-level context Top Ring (+high) / Bottom Ring (low) carry.
  final PitchBand band;

  /// N for THIS level (may differ from other levels). Guarded `>= 1`, fixed.
  final int segmentCount;

  /// The angular engine — owns this level's `yawStart` + position. Per-instance.
  final RingCoverageEngine _ring;

  /// The fill state — the single source of truth for filled/missing/target/
  /// completion. Per-instance; replaced (never aliased) on every transform.
  late SegmentCoverage _coverage;

  // ── lifecycle ──────────────────────────────────────────────────────────────

  /// Re-baselines this ring at [yawStart] (degrees) when ITS capture begins — the
  /// user orbits each ring fresh, so each level establishes its own origin
  /// (segment 0's start). Does NOT clear fill (a re-begin after partial capture
  /// keeps coverage; only the angular origin moves). Position resets to 0.
  void begin(double yawStart) => _ring.start(yawStart, segmentCount);

  /// Moves the angular origin to [newYawStart] WITHOUT clearing fill or changing
  /// [segmentCount] — the engine's rebaseline primitive. No-op if not yet [begin]un.
  void rebaseline(double newYawStart) => _ring.rebaseline(newYawStart);

  /// Restores a saved per-segment [coverage] (mid-level resume). When its
  /// `segmentCount` differs from this level's it is reconfigured to fit (stale
  /// shape can't corrupt the ring). Optionally re-establishes the [yawStart]
  /// baseline so position resumes against this level's own heading.
  void restore(SegmentCoverage coverage, {double? yawStart}) {
    _coverage = coverage.segmentCount == segmentCount
        ? coverage
        : coverage.reconfigure(
            segmentCount: segmentCount,
            fillThreshold: coverage.fillThreshold,
          );
    if (yawStart != null) _ring.start(yawStart, segmentCount);
  }

  /// Clears fill and the angular baseline — back to "not started, empty ring".
  void reset() {
    _coverage = _coverage.reset();
    _ring.reset();
  }

  // ── updates ──────────────────────────────────────────────────────────────

  /// Feeds a new yaw reading (degrees). Returns the assigned segment index, or
  /// null if the ring has not been [begin]un (ignored). Re-aims the coverage
  /// target at the new position; fills nothing.
  int? updateYaw(double currentYaw) {
    final seg = _ring.updateYaw(currentYaw);
    if (seg != null) _coverage = _coverage.updatePosition(seg);
    return seg;
  }

  /// The overlap decision for a capture at the CURRENT segment — a pure READ
  /// against the fill source of truth (does NOT mark anything). Feed the latest
  /// yaw via [updateYaw] first so `currentSegment` is current.
  SegmentCaptureDecision evaluateCapture() => evaluateSegmentCapture(
        segmentIndex: currentSegment,
        isFilled: isFilledAt(currentSegment),
      );

  /// Records a capture in the CURRENT segment (call after a capture is accepted).
  /// Returns the new coverage snapshot.
  SegmentCoverage recordCaptureHere() => recordCapture(currentSegment);

  /// Records a capture in [segmentIndex]. Out-of-range → unchanged. Returns the
  /// new coverage snapshot.
  SegmentCoverage recordCapture(int segmentIndex) =>
      _coverage = _coverage.recordCapture(segmentIndex);

  /// Removes one capture from [segmentIndex] (a delete/retake). Returns whether
  /// the segment is now MISSING (dropped below the fill threshold) — the caller
  /// retargets guidance to the freed segment.
  bool removeCapture(int segmentIndex) {
    _coverage = _coverage.removeCapture(segmentIndex);
    return _coverage.missingSegments.contains(segmentIndex);
  }

  // ── reads (uniform interface the progression controller composes) ───────────

  /// True once this ring has been [begin]un (a `yawStart` is established).
  bool get started => _ring.started;

  /// This level's angular origin (segment 0's start), or null when not begun.
  double? get yawStart => _ring.yawStart;

  /// The segment the user currently points at (0 when not begun).
  int get currentSegment => _ring.currentSegment;

  /// Direction of the most recent movement (noise dead-banded).
  RingTurn get lastTurn => _ring.lastTurn;

  /// Per-segment filled flags (threshold-aware).
  List<bool> get filled => _coverage.filled;

  /// Per-segment capture counts.
  List<int> get fillCounts => _coverage.fillCounts;

  bool isFilledAt(int i) => i >= 0 && i < segmentCount && _coverage.filled[i];

  /// Segments still below the threshold, ascending.
  List<int> get missingSegments => _coverage.missingSegments;

  /// The nearest missing segment to guide the user toward, or null when complete.
  int? get currentTarget => _coverage.currentTarget;

  /// Number of filled segments.
  int get filledCount => _coverage.filledCount;

  /// Coverage in [0, 1].
  double get progress => _coverage.progress;

  /// True once every segment is filled.
  bool get isComplete => _coverage.isComplete;

  /// The live fill snapshot (for persistence / composition).
  SegmentCoverage get coverage => _coverage;

  /// Bridges to the [RingCoverage] DISPLAY model the ring-map HUD renders.
  RingCoverage toRingCoverage({int? targetIndex}) =>
      _coverage.toRingCoverage(targetIndex: targetIndex);

  @override
  String toString() => 'LevelSegmentMachine($levelCode/$levelId, '
      'n: $segmentCount, filled: $filledCount/$segmentCount, '
      'yawStart: $yawStart, complete: $isComplete)';
}
