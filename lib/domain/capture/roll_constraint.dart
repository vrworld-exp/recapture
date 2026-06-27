// lib/domain/capture/roll_constraint.dart
//
// Pure Dart — NO Flutter/Riverpod/native imports. The roll-constraint advisory
// rule: device ROLL (rotation about the camera's forward/viewing axis — the phone
// tilting left/right off level, distinct from pitch and yaw) is WARNED, never
// blocked, during Guided Capture. This owns ONLY the threshold decision (with
// hysteresis) — it raises/clears an advisory flag and nothing else. It does not
// touch frame acceptance, ring progress, bucketing, or completion: roll is
// purely advisory, so this rule is deliberately isolated from all capture logic.
//
// SYMMETRY: the decision is on |roll|, so a left tilt and a right tilt past the
// threshold warn identically regardless of the source's sign convention.
//
// HYSTERESIS: a single raise threshold would flicker the warning on/off when roll
// hovers near it. So the warning RAISES above [raiseThresholdDeg] and only CLEARS
// once roll falls back below the lower [releaseThresholdDeg]; between the two it
// HOLDS its current state. Both thresholds are named here (one source of truth) —
// no magic numbers at call sites.

/// The ±roll advisory thresholds (degrees from level) and the pure hysteretic
/// decision over them.
abstract final class RollConstraint {
  /// Raise the advisory when |roll| exceeds this (degrees from level).
  static const double raiseThresholdDeg = 15.0;

  /// Clear the advisory only once |roll| falls back below this — the lower edge
  /// of the hysteresis band, so a wobble around the raise threshold does not
  /// flicker the warning.
  static const double releaseThresholdDeg = 12.0;

  /// The next advisory-active state given the [active] previous state and the
  /// latest [rollDegrees] (signed; sign convention irrelevant — compared by
  /// magnitude). Hysteretic:
  ///
  ///   - |roll| > [raiseThresholdDeg]      → active (raise / stay raised)
  ///   - |roll| < [releaseThresholdDeg]    → inactive (clear / stay clear)
  ///   - in between                        → HOLD the previous [active]
  ///
  /// UNAVAILABLE DATA: a null / NaN / infinite [rollDegrees] (no valid pose) is
  /// treated as "unknown" — the previous state is HELD, so missing data never
  /// raises a false warning and never clears a real one mid-excursion.
  static bool nextActive({required bool active, required double? rollDegrees}) {
    if (rollDegrees == null || rollDegrees.isNaN || rollDegrees.isInfinite) {
      return active; // unknown → hold, never a false raise/clear
    }
    final magnitude = rollDegrees.abs();
    if (magnitude > raiseThresholdDeg) return true;
    if (magnitude < releaseThresholdDeg) return false;
    return active; // inside the hysteresis band → hold
  }
}
