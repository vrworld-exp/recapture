// lib/domain/capture/ring_coverage_engine.dart
//
// Pure Dart — NO Flutter/native imports. The eye-ring guided-capture engine: it
// consumes smoothed yaw and produces ring coverage state (which segment the user
// is in, and which segments have been captured). It owns the angular math +
// coverage for ONE ring. It renders nothing and triggers no capture — the HUD
// and the capture trigger are separate tasks that consume this state.
//
// LEVEL-AGNOSTIC: although first written for Level A (the Eye Ring), this engine
// carries NO Level-A assumption — `yawStart` and `segmentCount` are arguments to
// [start], there is no hardcoded count, and there is no static/shared mutable
// state (RingMath is stateless pure functions). So it is the SAME engine reused
// per level: instantiate one [RingCoverageEngine] per ring (A/B/C) and each is a
// fully independent state machine. See [LevelSegmentMachine], which bundles one
// instance with that level's band + fill state behind a uniform interface.
//
// UNIT CONVENTION: DEGREES throughout, matching the rest of the capture-logic
// layer (PitchBand.minDegrees, CapturePitchGuide, TiltTarget). Feed
// `SmoothedOrientation.yawDegrees` (the source's `.yaw` is radians — use the
// degrees getter). Do NOT mix units.
//
// CORE RULE: ring position is `(currentYaw − yawStart)` NORMALIZED into [0, 360)
// — wraparound-safe — NOT a shortest-path ±180° delta (which can't represent a
// full circle). ASSIGNMENT (where the user is) is kept distinct from COVERAGE
// (what has been captured): being in a segment does not cover it; only
// [markCurrentCovered]/[markCovered] (called on a successful capture) does.

import 'dart:collection';

import '../entities/ring_coverage.dart';
import 'segment_capture_decision.dart';

/// Direction of travel around the ring between the two most recent yaw samples.
/// [forward] = the assigned index increases (the ring's clockwise convention,
/// segment 0 at start increasing with normalized position); [backward] = it
/// decreases; [idle] = movement below the noise dead-band.
enum RingTurn { idle, forward, backward }

/// Stateless angular helpers — pure functions, trivially unit-testable
/// independent of the engine's state.
abstract final class RingMath {
  /// Normalizes [degrees] into [0, 360), wraparound-safe across the ±180°/0–360°
  /// boundary. (Dart's `%` already yields a non-negative result for a positive
  /// divisor; the extra add/mod makes the intent explicit and robust.)
  static double normalizeDegrees(double degrees) =>
      ((degrees % 360.0) + 360.0) % 360.0;

  /// Shortest-path signed delta from [from] to [to] in (-180, 180]. Used ONLY
  /// for direction/velocity sign — never for ring position.
  static double signedDeltaDegrees(double from, double to) {
    final d = (to - from) % 360.0;
    return ((d + 540.0) % 360.0) - 180.0;
  }

  /// Angular size of one segment, in degrees. Guards `segmentCount >= 1`.
  static double segmentSizeDegrees(int segmentCount) =>
      360.0 / (segmentCount < 1 ? 1 : segmentCount);

  /// Assigns a [normalized] position (expected [0, 360)) to a segment index in
  /// [0, segmentCount). Boundary inclusivity: a position exactly on a boundary
  /// belongs to the HIGHER segment (`floor`), e.g. with size 30° exactly 30°
  /// is segment 1. Floating-point `normalized == 360.0` is clamped to the last
  /// segment so the index never escapes the range.
  static int assignSegment(double normalized, int segmentCount) {
    final count = segmentCount < 1 ? 1 : segmentCount;
    final size = 360.0 / count;
    var idx = (normalized / size).floor();
    if (idx < 0) idx = 0;
    if (idx >= count) idx = count - 1;
    return idx;
  }

  /// Wraparound-aware distance, in segment-steps, between segments [a] and [b]
  /// around a ring of [segmentCount] (the fewer of the two ways round). 0 when
  /// equal; never larger than `segmentCount ~/ 2`. Indices are taken modulo the
  /// count so stale/out-of-range values can't escape the ring.
  static int segmentDistance(int a, int b, int segmentCount) {
    final n = segmentCount < 1 ? 1 : segmentCount;
    final raw = (((a - b) % n) + n) % n;
    return raw <= n - raw ? raw : n - raw;
  }

  /// The member of [candidates] nearest to [origin] by wraparound-aware
  /// [segmentDistance], searching outward from [origin]. Tie policy: at equal
  /// distance the FORWARD (index-increasing, the ring's clockwise convention)
  /// candidate wins; this is deterministic and matches the engine's sweep
  /// direction. Returns null if [candidates] is empty. Shared by the engine's
  /// [RingCoverageEngine.nearestUncovered] and the segment-fill state model so
  /// both agree on "nearest" — no duplicated distance math.
  static int? nearestInSet(int origin, Set<int> candidates, int segmentCount) {
    if (candidates.isEmpty) return null;
    final n = segmentCount < 1 ? 1 : segmentCount;
    final from = ((origin % n) + n) % n;
    for (var step = 0; step < n; step++) {
      final fwd = (from + step) % n; // forward checked first → forward ties win
      if (candidates.contains(fwd)) return fwd;
      final bwd = ((from - step) % n + n) % n;
      if (candidates.contains(bwd)) return bwd;
    }
    return null;
  }
}

/// Drives Level A (Eye Ring) guided capture from smoothed yaw. Mutable but
/// deterministic and synchronous — no UI, async, or platform calls.
class RingCoverageEngine {
  /// [boundaryHysteresisDeg] (optional, default 0 = off) adds a Schmitt
  /// dead-band so residual yaw noise at a segment boundary doesn't flicker the
  /// assignment between adjacent segments; a clear move (multiple segments, or
  /// past the boundary by more than the dead-band) still switches immediately.
  RingCoverageEngine({double boundaryHysteresisDeg = 0})
      : _hysteresis = boundaryHysteresisDeg < 0 ? 0 : boundaryHysteresisDeg;

  final double _hysteresis;

  double? _yawStart;
  int _segmentCount = 1;
  List<bool> _covered = const [];

  double _normalizedDelta = 0;
  int _currentSegment = 0;
  double? _lastRawYaw;
  RingTurn _lastTurn = RingTurn.idle;

  /// Movement below this (degrees of shortest-path change) is treated as noise
  /// for direction purposes — keeps [lastTurn] from chattering when held still.
  static const double _directionDeadbandDeg = 0.5;

  // ── lifecycle ──────────────────────────────────────────────────────────────

  /// Baselines the ring: [yawStart] (degrees) becomes segment 0's start and the
  /// ring is divided into [segmentCount] (guarded `>= 1`) equal segments. Clears
  /// any prior coverage.
  void start(double yawStart, int segmentCount) {
    _yawStart = yawStart;
    _segmentCount = segmentCount < 1 ? 1 : segmentCount;
    _covered = List<bool>.filled(_segmentCount, false);
    _normalizedDelta = 0;
    _currentSegment = 0;
    _lastRawYaw = yawStart;
    _lastTurn = RingTurn.idle;
  }

  /// Moves the angular origin to [newYawStart] WITHOUT clearing coverage and
  /// WITHOUT changing [segmentCount]. Policy: coverage is index-based and is
  /// preserved as-is; only the yaw→segment mapping origin moves. The current
  /// segment is recomputed from the last yaw against the new origin. A no-op if
  /// the ring was never started (use [start] first).
  void rebaseline(double newYawStart) {
    if (!started) return;
    _yawStart = newYawStart;
    final last = _lastRawYaw;
    if (last != null) {
      _normalizedDelta = RingMath.normalizeDegrees(last - newYawStart);
      _currentSegment = RingMath.assignSegment(_normalizedDelta, _segmentCount);
    } else {
      _normalizedDelta = 0;
      _currentSegment = 0;
    }
    _lastTurn = RingTurn.idle;
  }

  /// Clears all state back to "not started".
  void reset() {
    _yawStart = null;
    _segmentCount = 1;
    _covered = const [];
    _normalizedDelta = 0;
    _currentSegment = 0;
    _lastRawYaw = null;
    _lastTurn = RingTurn.idle;
  }

  // ── updates ──────────────────────────────────────────────────────────────

  /// Feeds a new yaw reading (degrees). Returns the assigned segment index, or
  /// null if the ring has not been started (the update is ignored). Computes the
  /// wraparound-safe normalized position and updates direction.
  int? updateYaw(double currentYaw) {
    final start = _yawStart;
    if (start == null) return null;

    _normalizedDelta = RingMath.normalizeDegrees(currentYaw - start);

    // Direction from the shortest-path change in RAW yaw between samples.
    final last = _lastRawYaw;
    if (last != null) {
      final d = RingMath.signedDeltaDegrees(last, currentYaw);
      if (d.abs() >= _directionDeadbandDeg) {
        _lastTurn = d > 0 ? RingTurn.forward : RingTurn.backward;
      }
    }
    _lastRawYaw = currentYaw;

    _currentSegment = _resolveSegment(_normalizedDelta);
    return _currentSegment;
  }

  /// Applies optional boundary hysteresis. Keeps the current segment while the
  /// position stays within its interval expanded by the dead-band on both sides
  /// (wrap-aware); otherwise re-assigns by `floor`. A multi-segment jump leaves
  /// the band and switches immediately.
  int _resolveSegment(double normalized) {
    final raw = RingMath.assignSegment(normalized, _segmentCount);
    if (_hysteresis <= 0) return raw;

    final size = RingMath.segmentSizeDegrees(_segmentCount);
    // A dead-band wider than a segment would never let assignment change — clamp
    // so it can't fully swallow the segment.
    final h = _hysteresis >= size ? size * 0.5 : _hysteresis;

    // Position relative to the CURRENT segment's start, in [0, 360).
    final rel = RingMath.normalizeDegrees(normalized - _currentSegment * size);
    // Inside the current segment ([0, size)) or within h past either edge
    // (upper: [size, size+h]; lower wraps to [360-h, 360)).
    final keep = rel <= size + h || rel >= 360.0 - h;
    return keep ? _currentSegment : raw;
  }

  // ── coverage ──────────────────────────────────────────────────────────────

  /// Marks the current segment covered (idempotent). Call on a successful
  /// capture in the current segment. No-op if not started.
  void markCurrentCovered() => markCovered(_currentSegment);

  /// Marks [index] covered (idempotent). Out-of-range / not-started → no-op.
  void markCovered(int index) {
    if (!started || index < 0 || index >= _covered.length) return;
    _covered[index] = true;
  }

  /// Clears coverage for [index] (idempotent) — the retake primitive: a UI
  /// retake flow uncovers a segment so a fresh capture there is allowed again.
  /// Out-of-range / not-started → no-op.
  void markUncovered(int index) {
    if (!started || index < 0 || index >= _covered.length) return;
    _covered[index] = false;
  }

  /// Overlap enforcement: the typed decision for a capture attempt at the
  /// CURRENT segment — [RejectAlreadyFilled] if it is already covered, else
  /// [ProceedCapture]. A pure READ (does NOT mark anything; call
  /// [markCurrentCovered] only after the capture is accepted downstream). Feed
  /// the latest yaw via [updateYaw] first so `currentSegment` is up to date; not
  /// started → an empty ring, so it proceeds at segment 0.
  SegmentCaptureDecision evaluateCapture() => evaluateSegmentCapture(
        segmentIndex: _currentSegment,
        isFilled: _currentSegment >= 0 &&
            _currentSegment < _covered.length &&
            _covered[_currentSegment],
      );

  // ── reads ──────────────────────────────────────────────────────────────

  bool get started => _yawStart != null;

  double? get yawStart => _yawStart;

  int get segmentCount => _segmentCount;

  /// Current normalized position in [0, 360). 0 when not started.
  double get normalizedDelta => _normalizedDelta;

  /// The segment the user is currently in. 0 when not started.
  int get currentSegment => _currentSegment;

  /// Direction of the most recent movement (noise dead-banded).
  RingTurn get lastTurn => _lastTurn;

  /// Per-segment covered flags (read-only view).
  List<bool> get covered => UnmodifiableListView(_covered);

  int get coveredCount => _covered.where((c) => c).length;

  List<int> get coveredSegments => [
        for (var i = 0; i < _covered.length; i++)
          if (_covered[i]) i,
      ];

  List<int> get uncoveredSegments => [
        for (var i = 0; i < _covered.length; i++)
          if (!_covered[i]) i,
      ];

  /// Coverage in [0, 1]; 0 when not started / no segments.
  double get progress =>
      _covered.isEmpty ? 0 : coveredCount / _covered.length;

  /// True once every segment is covered (and there is at least one).
  bool get isComplete => _covered.isNotEmpty && coveredCount == _covered.length;

  /// The uncovered segment nearest (fewest segment-steps around the ring) to
  /// [from] (defaults to the current segment), for "turn to the next gap"
  /// guidance. Null when all are covered / not started. Ties prefer the forward
  /// (index-increasing) direction.
  int? nearestUncovered({int? from}) {
    if (_covered.isEmpty) return null;
    return RingMath.nearestInSet(
      from ?? _currentSegment,
      uncoveredSegments.toSet(),
      _covered.length,
    );
  }

  /// Bridges to the [RingCoverage] DISPLAY model the ring-map HUD renders, so the
  /// map and this engine share one source of truth. [targetIndex] defaults to
  /// [nearestUncovered] (the segment to guide the user toward).
  RingCoverage toRingCoverage({int? targetIndex}) => RingCoverage(
        segmentCount: _segmentCount,
        filledIndices: coveredSegments.toSet(),
        targetIndex: targetIndex ?? nearestUncovered(),
      );
}
