// lib/domain/entities/capture_readiness.dart
//
// Pure Dart — NO Flutter imports. Whether the Level A shutter may fire, assembled
// by the PARENT from the tilt (inBand), stability (stable), and placement (placed)
// inputs. The shutter button consumes this; it does NOT subscribe to sensors.
//
// Safety rule (DEFAULT, full mode): sensor-unavailable must NEVER hard-block. In
// guided mode with no usable sensors we fail OPEN (allow capture) so the user is
// never locked out — the parent surfaces a "guidance unavailable" note.
//
// HARD-GATE EXCEPTION (Meshy mode): a Meshy shot MUST land in the eye→top window
// or it is worthless to the model, so [hardGate] disables the fail-open — a shot
// outside the band is blocked even when sensors are unavailable. On a device that
// does not stream tilt this means the Meshy shutter stays blocked ("adjust tilt")
// rather than taking an unguided shot; that is the intended behaviour, not a bug
// (a sensor-less device cannot satisfy Meshy's guarantee). Full mode is untouched.
//
// ALREADY-CAPTURED (Meshy mode): the one gate that NEVER fails open. A second
// shot into a wedge that already holds one adds nothing the model can use, so it
// is refused whatever the sensors are doing — see [CaptureReadiness.alreadyCaptured].
// The PARENT decides when it applies (Meshy, live segment known and in range, no
// retake targeted); this type only enforces what it is told.

enum CaptureMode { guided, manual }

/// Why the shutter is currently blocked (guided mode only). [capturing] and
/// [sensorUnavailable] are not returned by [CaptureReadiness.primaryBlockReason]
/// — capturing is the button's own in-flight state, and sensor-unavailable fails
/// open rather than blocking.
enum BlockReason {
  outOfBand,
  unstable,
  notPlaced,
  alreadyCaptured,
  sensorUnavailable,
  capturing,
}

class CaptureReadiness {
  const CaptureReadiness({
    required this.mode,
    this.inBand = false,
    this.stable = false,
    this.placed = true,
    this.sensorSupported = true,
    this.hardGate = false,
    this.alreadyCaptured = false,
  });

  final CaptureMode mode;
  final bool inBand;
  final bool stable;

  /// Optional placement gate; true when placement is not required.
  final bool placed;

  /// Whether the motion sensors that drive [inBand]/[stable] are usable. When
  /// false, gating is normally bypassed (fail-open) — UNLESS [hardGate].
  final bool sensorSupported;

  /// When true (Meshy mode), the tilt band is ENFORCED even without usable
  /// sensors: the fail-open is disabled, so a shot outside the band is blocked
  /// rather than silently taken. See the HARD-GATE EXCEPTION note above. False
  /// (the default) preserves full mode's fail-open exactly.
  final bool hardGate;

  /// The wedge the camera currently points at ALREADY holds a capture, and this
  /// mode allows exactly one per wedge (Meshy). Default false — every existing
  /// construction site keeps today's behaviour.
  ///
  /// Unlike every other gate this one is absolute: it is checked before the
  /// manual-mode allowance AND before the sensor fail-open, because a duplicate
  /// shot is worthless to the model no matter how the shutter was reached. The
  /// parent supplies it only from state it can actually read (a known, in-range
  /// live segment), so "unknown" arrives here as false — the fail-open lives at
  /// the call site, not in this rule.
  final bool alreadyCaptured;

  /// Already-captured: never allowed (see [alreadyCaptured]). Otherwise manual
  /// mode is always allowed, and guided mode requires all gates — but if sensors
  /// are unavailable, allow (fail-open), UNLESS [hardGate] is set, in which case
  /// the gates are enforced regardless (a sensor-less device then cannot capture).
  bool get canCapture {
    if (alreadyCaptured) return false; // the one gate that never fails open
    if (mode == CaptureMode.manual) return true;
    if (!sensorSupported && !hardGate) return true; // fail-open (full mode)
    return inBand && stable && placed;
  }

  /// The single reason the shutter is blocked, or null if it can capture. Order:
  /// placement, then already-captured, then band, then stability. Already-captured
  /// outranks band/stability because "turn to the next section" is the action that
  /// resolves it — telling the user to steady a shot they cannot take would be a
  /// dead end.
  BlockReason? get primaryBlockReason {
    if (canCapture) return null;
    if (!placed) return BlockReason.notPlaced;
    if (alreadyCaptured) return BlockReason.alreadyCaptured;
    if (!inBand) return BlockReason.outOfBand;
    if (!stable) return BlockReason.unstable;
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is CaptureReadiness &&
      other.mode == mode &&
      other.inBand == inBand &&
      other.stable == stable &&
      other.placed == placed &&
      other.sensorSupported == sensorSupported &&
      other.hardGate == hardGate &&
      other.alreadyCaptured == alreadyCaptured;

  @override
  int get hashCode => Object.hash(
        mode,
        inBand,
        stable,
        placed,
        sensorSupported,
        hardGate,
        alreadyCaptured,
      );
}
