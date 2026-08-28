// lib/domain/capture/guidance_inputs.dart
//
// Pure Dart — NO Flutter/Riverpod imports. The input model for the Level A
// instruction engine ([resolveGuidance]): the live capture signals the resolver
// prioritizes into a single HUD instruction + direction hint. The engine only
// PRIORITIZES — it does not compute tilt/stability/ring-progress (those are the
// upstream providers).
//
// Grounded on the repo's existing signal types: [TiltState] (tilt_target.dart),
// [Stability] (stability_provider.dart), [CaptureMode] + [RingDirection]
// (capture_readiness.dart / direction_hint.dart). [RingDirectionState] is the
// ONE new contract defined here: the ring-progress source (filled/target indices,
// shorter-arc direction, angular gap) is a separate Capture Logic task, so the
// engine consumes an injected [RingDirectionState] and is fully testable now.
import '../entities/capture_readiness.dart' show CaptureMode;
import '../entities/direction_hint.dart' show RingDirection;
import '../entities/tilt_target.dart' show TiltState;
import '../../application/capture/stability_provider.dart' show Stability;

/// Ring-progress snapshot the engine needs to decide direction vs capture. The
/// shorter-arc [toNext] and [angularGapDeg] are computed by the ring-progress
/// task (consistent with the ring engine's segment indexing); this is the
/// contract the engine reads.
class RingDirectionState {
  const RingDirectionState({
    required this.atTargetPosition,
    required this.currentPositionCaptured,
    required this.toNext,
    required this.angularGapDeg,
    required this.allCaptured,
  });

  /// The user is aligned with the current target segment (within the ring's
  /// own tolerance) — no "move" guidance needed.
  final bool atTargetPosition;

  /// The segment the user currently points at already holds an accepted capture.
  final bool currentPositionCaptured;

  /// Shorter-arc direction to the next uncaptured segment.
  final RingDirection toNext;

  /// Degrees to the next target (0 when at it). Drives arrow urgency + the
  /// direction-vs-capture threshold.
  final double angularGapDeg;

  /// The whole ring is captured (terminal state).
  final bool allCaptured;

  /// A neutral default for wiring before the ring-progress task lands: at an
  /// uncaptured target position, ring incomplete → the engine falls through to
  /// the capture branch.
  static const RingDirectionState pending = RingDirectionState(
    atTargetPosition: true,
    currentPositionCaptured: false,
    toNext: RingDirection.clockwise,
    angularGapDeg: 0,
    allCaptured: false,
  );

  @override
  bool operator ==(Object other) =>
      other is RingDirectionState &&
      other.atTargetPosition == atTargetPosition &&
      other.currentPositionCaptured == currentPositionCaptured &&
      other.toNext == toNext &&
      other.angularGapDeg == angularGapDeg &&
      other.allCaptured == allCaptured;

  @override
  int get hashCode => Object.hash(atTargetPosition, currentPositionCaptured,
      toNext, angularGapDeg, allCaptured);
}

/// The full signal snapshot for one resolve tick.
class GuidanceInputs {
  const GuidanceInputs({
    required this.sensorSupported,
    required this.tilt,
    required this.stability,
    required this.ring,
    required this.mode,
  });

  /// Whether the motion sensors driving [tilt]/[stability] are usable. When
  /// false, the resolver SKIPS the tilt/stability branches (never strands the
  /// user on an impossible cue).
  final bool sensorSupported;

  final TiltState tilt;
  final Stability stability;
  final RingDirectionState ring;

  /// guided (auto-capture) vs manual (tap) — selects the capture-branch message.
  final CaptureMode mode;

  @override
  bool operator ==(Object other) =>
      other is GuidanceInputs &&
      other.sensorSupported == sensorSupported &&
      other.tilt == tilt &&
      other.stability == stability &&
      other.ring == ring &&
      other.mode == mode;

  @override
  int get hashCode => Object.hash(sensorSupported, tilt, stability, ring, mode);
}
