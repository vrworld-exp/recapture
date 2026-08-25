// lib/domain/entities/level_a_summary.dart
//
// Pure Dart — NO Flutter imports. The recap the Level A completion screen shows
// once the eye-ring meets its target/coverage threshold: accepted vs target,
// coverage %, optional rejected count, and a few representative thumbnails. This
// is a DISPLAY model — the parent assembles it from the SAME progress/coverage
// source the in-capture progress meter + ring map used, so the numbers can never
// contradict the in-capture values.

import 'capture_thumbnail.dart';

class LevelASummary {
  const LevelASummary({
    required this.accepted,
    required this.target,
    required this.coveragePct,
    this.rejected = 0,
    this.highlights = const [],
  });

  /// Captures that passed quality (== the ring map's filledCount).
  final int accepted;

  /// N — target ring positions (== the ring map's segmentCount).
  final int target;

  /// Overall coverage 0..100 (same value the progress meter showed).
  final double coveragePct;

  /// Shots discarded this session (optional context).
  final int rejected;

  /// A few representative thumbnails for the montage (e.g. up to 6).
  final List<CaptureThumbnail> highlights;

  /// coveragePct/100 clamped to [0, 1] (guards out-of-range coverage).
  double get coverageFraction => (coveragePct / 100).clamp(0.0, 1.0);

  /// accepted/target in [0, 1]; 0 when target<=0. Over-capture clamps to 1.
  double get acceptedFraction =>
      target <= 0 ? 0.0 : (accepted / target).clamp(0.0, 1.0);

  @override
  bool operator ==(Object other) =>
      other is LevelASummary &&
      other.accepted == accepted &&
      other.target == target &&
      other.coveragePct == coveragePct &&
      other.rejected == rejected &&
      _listEquals(other.highlights, highlights);

  @override
  int get hashCode => Object.hash(
        accepted,
        target,
        coveragePct,
        rejected,
        Object.hashAll(highlights),
      );
}

bool _listEquals(List<CaptureThumbnail> a, List<CaptureThumbnail> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
