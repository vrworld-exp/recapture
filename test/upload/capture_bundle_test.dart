// test/upload/capture_bundle_test.dart
//
// Pure unit tests for the bundle layout helpers + deterministic planner.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/upload/capture_bundle.dart';

BundleSourceImage _src(String path, {int? seg, int ts = 0, bool warned = false}) =>
    BundleSourceImage(
      sourcePath: path,
      captureTimestampNs: ts,
      segmentIndex: seg,
      warned: warned,
    );

void main() {
  group('layout helpers', () {
    test('names are zero-padded, ring-prefixed, deterministic', () {
      expect(bundleImageFileName('EYE', 1), 'eye_0001.jpg');
      expect(bundleImageFileName('TOP', 7), 'top_0007.jpg');
      expect(bundleImageFileName('LOW', 12), 'low_0012.jpg');
    });

    test('relative paths use the images/{RING}/ layout', () {
      expect(bundleImageDir('EYE'), 'images/EYE');
      expect(bundleImageRelPath('TOP', 'top_0001.jpg'), 'images/TOP/top_0001.jpg');
    });
  });

  group('planBundleImages mapping + determinism', () {
    test('maps A→EYE, B→TOP, C→LOW and orders levels A→B→C', () {
      final plan = planBundleImages([
        BundleLevelSources(levelCode: 'C', levelId: 'low', images: [_src('/s/c1.jpg')]),
        BundleLevelSources(levelCode: 'A', levelId: 'mid', images: [_src('/s/a1.jpg')]),
        BundleLevelSources(levelCode: 'B', levelId: 'high', images: [_src('/s/b1.jpg')]),
      ]);

      expect(plan.map((p) => p.ringName).toList(), ['EYE', 'TOP', 'LOW']);
      expect(plan.map((p) => p.relPath).toList(), [
        'images/EYE/eye_0001.jpg',
        'images/TOP/top_0001.jpg',
        'images/LOW/low_0001.jpg',
      ]);
    });

    test('within a level, orders by segment then timestamp; numbers 1..N', () {
      final plan = planBundleImages([
        BundleLevelSources(levelCode: 'A', levelId: 'mid', images: [
          _src('/s/late.jpg', seg: 5, ts: 200),
          _src('/s/early.jpg', seg: 1, ts: 100),
          _src('/s/mid.jpg', seg: 5, ts: 50),
        ]),
      ]);
      expect(plan.map((p) => p.sourcePath).toList(),
          ['/s/early.jpg', '/s/mid.jpg', '/s/late.jpg']);
      expect(plan.map((p) => p.fileName).toList(),
          ['eye_0001.jpg', 'eye_0002.jpg', 'eye_0003.jpg']);
    });

    test('null segment sorts after numbered segments', () {
      final plan = planBundleImages([
        BundleLevelSources(levelCode: 'A', levelId: 'mid', images: [
          _src('/s/none.jpg', seg: null, ts: 1),
          _src('/s/s0.jpg', seg: 0, ts: 9),
        ]),
      ]);
      expect(plan.map((p) => p.sourcePath).toList(), ['/s/s0.jpg', '/s/none.jpg']);
    });

    test('same input → identical plan (deterministic)', () {
      List<BundleLevelSources> input() => [
            BundleLevelSources(levelCode: 'A', levelId: 'mid', images: [
              _src('/s/a2.jpg', seg: 2, ts: 20),
              _src('/s/a1.jpg', seg: 1, ts: 10),
            ]),
          ];
      final a = planBundleImages(input());
      final b = planBundleImages(input().reversed.toList());
      expect(a.map((p) => p.relPath).toList(), b.map((p) => p.relPath).toList());
      expect(a.map((p) => p.sourcePath).toList(), b.map((p) => p.sourcePath).toList());
    });

    test('warned flag carried through', () {
      final plan = planBundleImages([
        BundleLevelSources(levelCode: 'A', levelId: 'mid', images: [
          _src('/s/w.jpg', seg: 0, warned: true),
        ]),
      ]);
      expect(plan.single.warned, isTrue);
    });

    test('empty level yields no images', () {
      final plan = planBundleImages([
        const BundleLevelSources(levelCode: 'A', levelId: 'mid', images: []),
      ]);
      expect(plan, isEmpty);
    });
  });

  group('failure reasons', () {
    test('wire names are stable', () {
      expect(BundlePackFailureReason.missingSourceFile.wireName, 'missing_source_file');
      expect(BundlePackFailureReason.integrityMismatch.wireName, 'integrity_mismatch');
      expect(BundlePackFailureReason.cancelled.wireName, 'cancelled');
    });
  });
}
