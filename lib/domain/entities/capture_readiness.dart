// lib/domain/entities/capture_readiness.dart
//
// Pure Dart — NO Flutter imports. Whether the Level A shutter may fire, assembled
// by the PARENT from the tilt (inBand), stability (stable), and placement (placed)
// inputs. The shutter button consumes this; it does NOT subscribe to sensors.
//
// Safety rule: sensor-unavailable must NEVER hard-block. In guided mode with no
// usable sensors we fail OPEN (allow capture) so the user is never locked out —
// the parent surfaces a "guidance unavailable" note separately.

enum CaptureMode { guided, manual }

/// Why the shutter is currently blocked (guided mode only, except
/// [alreadyCaptured] which blocks in every mode). [capturing] and
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
    this.alreadyCaptured = false,
  });

  final CaptureMode mode;
  final bool inBand;
  final bool stable;

  /// Optional placement gate; true when placement is not required.
  final bool placed;

  /// Whether the motion sensors that drive [inBand]/[stable] are usable. When
  /// false, gating is bypassed (fail-open).
  final bool sensorSupported;

  /// The ring segment the camera currently points at ALREADY holds an accepted
  /// shot, so another shot here would add nothing — the user must turn to an
  /// unfilled segment. Used by the one-shot-per-segment flows (Meshy).
  ///
  /// The parent sets this true ONLY when the current segment is definitively
  /// known AND filled; an unknown segment (sensors warming up / unavailable)
  /// must resolve to false, never true. That rule is what makes blocking on it
  /// safe even though every other gate here fails open.
  final bool alreadyCaptured;

  /// Manual mode: always allowed. Guided mode: require all gates — but if sensors
  /// are unavailable, allow (never lock the user out).
  ///
  /// [alreadyCaptured] is the ONE hard block, checked before both fail-open
  /// returns: it is not a "we can't tell" state (those fail open by design) but a
  /// positively-known duplicate, and the user always has a way out — turn.
  bool get canCapture {
    if (alreadyCaptured) return false;
    if (mode == CaptureMode.manual) return true;
    if (!sensorSupported) return true; // fail-open
    return inBand && stable && placed;
  }

  /// The single reason the shutter is blocked, or null if it can capture. Order:
  /// placement, already-captured, band, stability. Already-captured outranks
  /// tilt/stability because at a finished segment "turn to the next angle" is the
  /// only useful instruction — tilt/steadiness advice there is noise.
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
      other.alreadyCaptured == alreadyCaptured;

  @override
  int get hashCode => Object.hash(
        mode,
        inBand,
        stable,
        placed,
        sensorSupported,
        alreadyCaptured,
      );
}
