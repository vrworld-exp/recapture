// lib/domain/entities/placement_box.dart
//
// Pure Dart — only `dart:ui` for geometry types (Rect/Offset), no Flutter
// framework / Riverpod imports. Defines the centre-frame placement guide in
// NORMALIZED capture-image coordinates (0..1), so it maps to a consistent region
// of the captured frame across device aspect ratios. Projection to screen pixels
// is the overlay's job (via PreviewGeometry); decision/detection logic lives
// elsewhere — this type only describes the region and tests containment.
import 'dart:ui' show Offset, Rect;

/// Quality of the object's placement within the guide. INJECTED into the overlay
/// by a parent (future detection/sensor logic) — never self-detected here.
enum PlacementStatus { idle, good, tooClose, tooFar, offCenter }

extension PlacementStatusX on PlacementStatus {
  /// True for the states that signal the user should adjust framing.
  bool get isWarning =>
      this == PlacementStatus.tooClose ||
      this == PlacementStatus.tooFar ||
      this == PlacementStatus.offCenter;
}

/// A centred framing guide expressed in normalized capture-image space.
///
/// Ratios are clamped to a valid range when realized as a [normalizedRect], so a
/// misconfigured ratio (e.g. > 1) can never produce a box larger than the frame
/// or an invalid rect.
class PlacementBox {
  const PlacementBox({this.widthRatio = 0.7, this.heightRatio = 0.7});

  /// Fraction of the frame WIDTH the box spans (clamped to (0, 1]).
  final double widthRatio;

  /// Fraction of the frame HEIGHT the box spans (clamped to (0, 1]).
  final double heightRatio;

  /// Smallest sensible box so a zero/negative ratio can't collapse it.
  static const double _minRatio = 0.05;

  double get _clampedWidth => _clampRatio(widthRatio);
  double get _clampedHeight => _clampRatio(heightRatio);

  static double _clampRatio(double r) {
    if (r.isNaN) return _minRatio;
    return r.clamp(_minRatio, 1.0);
  }

  /// The centred box as a normalized (0..1) rect, using clamped ratios. Always a
  /// valid rect contained within the unit square.
  Rect get normalizedRect => Rect.fromCenter(
        center: const Offset(0.5, 0.5),
        width: _clampedWidth,
        height: _clampedHeight,
      );

  /// Whether [objectNormalized] (a normalized 0..1 object bounding box) sits
  /// fully inside the guide. Render-only helper for later gating logic.
  bool containsNormalized(Rect objectNormalized) =>
      normalizedRect.contains(objectNormalized.topLeft) &&
      normalizedRect.contains(objectNormalized.bottomRight);

  PlacementBox copyWith({double? widthRatio, double? heightRatio}) =>
      PlacementBox(
        widthRatio: widthRatio ?? this.widthRatio,
        heightRatio: heightRatio ?? this.heightRatio,
      );

  @override
  bool operator ==(Object other) =>
      other is PlacementBox &&
      other.widthRatio == widthRatio &&
      other.heightRatio == heightRatio;

  @override
  int get hashCode => Object.hash(widthRatio, heightRatio);
}
