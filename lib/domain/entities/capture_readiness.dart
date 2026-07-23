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

enum CaptureMode { guided, manual }

/// Why the shutter is currently blocked (guided mode only). [capturing] and
/// [sensorUnavailable] are not returned by [CaptureReadiness.primaryBlockReason]
/// — capturing is the button's own in-flight state, and sensor-unavailable fails
/// open rather than blocking.
enum BlockReason { outOfBand, unstable, notPlaced, sensorUnavailable, capturing }

class CaptureReadiness {
  const CaptureReadiness({
    required this.mode,
    this.inBand = false,
    this.stable = false,
    this.placed = true,
    this.sensorSupported = true,
    this.hardGate = false,
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

  /// Manual mode: always allowed. Guided mode: require all gates — but if sensors
  /// are unavailable, allow (fail-open), UNLESS [hardGate] is set, in which case
  /// the gates are enforced regardless (a sensor-less device then cannot capture).
  bool get canCapture {
    if (mode == CaptureMode.manual) return true;
    if (!sensorSupported && !hardGate) return true; // fail-open (full mode)
    return inBand && stable && placed;
  }

  /// The single reason the shutter is blocked, or null if it can capture. Order:
  /// placement, then band, then stability.
  BlockReason? get primaryBlockReason {
    if (canCapture) return null;
    if (!placed) return BlockReason.notPlaced;
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
      other.hardGate == hardGate;

  @override
  int get hashCode =>
      Object.hash(mode, inBand, stable, placed, sensorSupported, hardGate);
}
