// test/capture/level_a_summary_test.dart
//
// Pure unit tests for the completion summary model: fraction getters (clamped,
// div-by-zero guarded, over-capture) and value equality.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_thumbnail.dart';
import 'package:recapture/domain/entities/level_a_summary.dart';

void main() {
  test('coverageFraction clamps to [0,1]', () {
    expect(
      const LevelASummary(accepted: 0, target: 10, coveragePct: 68)
          .coverageFraction,
      closeTo(0.68, 1e-9),
    );
    expect(
      const LevelASummary(accepted: 0, target: 10, coveragePct: 150)
          .coverageFraction,
      1.0,
    );
    expect(
      const LevelASummary(accepted: 0, target: 10, coveragePct: -5)
          .coverageFraction,
      0.0,
    );
  });

  test('acceptedFraction: normal, zero-target, over-capture', () {
    expect(
      const LevelASummary(accepted: 6, target: 12, coveragePct: 50)
          .acceptedFraction,
      closeTo(0.5, 1e-9),
    );
    expect(
      const LevelASummary(accepted: 5, target: 0, coveragePct: 0)
          .acceptedFraction,
      0.0,
    );
    expect(
      const LevelASummary(accepted: 14, target: 12, coveragePct: 100)
          .acceptedFraction,
      1.0,
    );
  });

  test('value equality (incl. highlights)', () {
    final t = CaptureThumbnail(
      id: 'a',
      filePath: '/a.jpg',
      capturedAt: DateTime(2026),
    );
    final a = LevelASummary(
      accepted: 12,
      target: 12,
      coveragePct: 90,
      highlights: [t],
    );
    final b = LevelASummary(
      accepted: 12,
      target: 12,
      coveragePct: 90,
      highlights: [t],
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(
      a == const LevelASummary(accepted: 12, target: 12, coveragePct: 90),
      isFalse,
    );
  });
}
