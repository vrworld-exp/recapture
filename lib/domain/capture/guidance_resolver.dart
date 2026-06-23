// lib/domain/capture/guidance_resolver.dart
//
// Pure Dart — NO Flutter/Riverpod imports. The single brain that decides "what
// should the user be told right now" for Level A, resolving the live signals into
// exactly ONE instruction + arrow via a fixed, total priority order:
//
//   complete (terminal) > tilt > stability > direction > capture
//
// Exactly one branch wins per tick, so the HUD never shows conflicting cues. This
// is a PURE function of [GuidanceInputs] — no I/O, no provider reads — so it is
// exhaustively unit-testable; the dwell/anti-thrash + provider wiring live in the
// application layer (guidance_engine.dart).
//
// Stable [CaptureInstruction.id]s ('complete'|'tilt'|'stability'|'direction'|
// 'capture'|'capture-next') keep the banner from re-animating while the same
// logical instruction persists.
//
// SENSOR-UNAVAILABLE: the tilt + stability branches are skipped when sensors are
// unusable (their values can't be trusted), so the user is never stranded on an
// impossible "Tilt"/"Hold steady" cue — the flow falls through to direction/
// capture (mirrors CaptureReadiness's fail-open rule). A separate "guidance
// unavailable" note is the parent's job, not this banner.
import '../entities/capture_instruction.dart';
import '../entities/capture_readiness.dart' show CaptureMode;
import '../entities/direction_hint.dart';
import '../entities/tilt_target.dart' show TiltState;
import '../../application/capture/stability_provider.dart' show Stability;
import 'guidance_inputs.dart';
import 'guidance_output.dart';

/// Below this gap (degrees) the user is treated as effectively at the target, so
/// "move" guidance doesn't nag near the position; together with the dwell this
/// absorbs flicker at the direction↔capture boundary. Tunable (could be config).
const double kDirectionThresholdDeg = 12;

GuidanceOutput resolveGuidance(GuidanceInputs i) {
  // 0) Terminal: whole ring captured.
  if (i.ring.allCaptured) {
    return _banner(
        'complete', 'All angles captured', InstructionSeverity.info);
  }

  // 1) TILT (highest) — only trustworthy when sensors work.
  if (i.sensorSupported && i.tilt != TiltState.inBand) {
    // aboveBand = aimed too high → tilt down; belowBand → tilt up.
    final message = i.tilt == TiltState.aboveBand ? 'Tilt down' : 'Tilt up';
    return _banner('tilt', message, InstructionSeverity.warning);
  }

  // 2) STABILITY.
  if (i.sensorSupported && i.stability == Stability.unstable) {
    return _banner('stability', 'Hold steady', InstructionSeverity.warning);
  }

  // 3) DIRECTION — guide toward the next uncaptured position (arrow shown).
  if (!i.ring.atTargetPosition && i.ring.angularGapDeg > kDirectionThresholdDeg) {
    final message = i.ring.toNext == RingDirection.clockwise
        ? 'Move right around the object'
        : 'Move left around the object';
    return GuidanceOutput(
      instruction: CaptureInstruction(
        id: 'direction',
        message: message,
        severity: InstructionSeverity.info,
      ),
      direction: DirectionHint(
        visible: true,
        direction: i.ring.toNext,
        urgency: (i.ring.angularGapDeg / 180).clamp(0.0, 1.0),
      ),
    );
  }

  // 4) CAPTURE (lowest) — at position, in band, stable.
  if (i.ring.currentPositionCaptured) {
    return _banner('capture-next', 'Move to the next position',
        InstructionSeverity.info);
  }
  final message =
      i.mode == CaptureMode.manual ? 'Tap to capture' : 'Capturing…';
  return _banner('capture', message, InstructionSeverity.info);
}

/// A banner-only output (arrow hidden) — every non-direction branch.
GuidanceOutput _banner(String id, String message, InstructionSeverity severity) =>
    GuidanceOutput(
      instruction:
          CaptureInstruction(id: id, message: message, severity: severity),
      direction: DirectionHint.hidden,
    );
