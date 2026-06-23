// lib/domain/entities/direction_hint.dart
//
// Pure Dart — NO Flutter imports. The movement-direction decision the Level A
// HUD's direction arrow renders: which way to ring the object to reach the next
// uncaptured position, and whether that guidance is currently relevant.
//
// This is a DISPLAY contract only. Computing the shorter arc to the next ring
// position (from yaw + ring progress) and deciding relevance is a SEPARATE
// resolver concern, not this model — the arrow overlay trusts [visible].
//
// Convention: [RingDirection.clockwise] is defined from the USER's viewpoint
// looking at their screen while ringing the object. The resolver and this
// overlay must share this one convention; it needs on-device calibration so the
// arrow never points the long way around (see the overlay's notes).

/// Which way to move around the object, from the user's on-screen viewpoint.
enum RingDirection { clockwise, counterclockwise }

/// A direction-guidance decision for the arrow overlay.
class DirectionHint {
  const DirectionHint({
    required this.visible,
    this.direction = RingDirection.clockwise,
    this.urgency = 0.5,
  });

  /// Whether movement guidance is currently relevant (decided upstream). The
  /// arrow is hidden unless this is true.
  final bool visible;

  /// The direction to move (rendered only while [visible]).
  final RingDirection direction;

  /// Optional intensity in [0, 1] (0 = barely, 1 = go now). Drives a capped
  /// size/colour escalation; out-of-range/NaN is clamped by the overlay.
  final double urgency;

  /// The default hidden state — nothing to show.
  static const DirectionHint hidden = DirectionHint(visible: false);

  @override
  bool operator ==(Object other) =>
      other is DirectionHint &&
      other.visible == visible &&
      other.direction == direction &&
      other.urgency == urgency;

  @override
  int get hashCode => Object.hash(visible, direction, urgency);
}
