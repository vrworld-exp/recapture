// test/dev_probe/dummy_bundle_test.dart
//
// Pins the dummy-bundle generator to the `with_bottom` variant contract the
// backend enforces at finalize: exactly 49 files (48 images + manifest),
// 16 per ring across EYE/TOP/LOW, JPEG SOI/EOI framing, keys contained under
// the given plan prefix, and a manifest that round-trips with matching counts.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/dev/dev_probe/dummy_bundle.dart';

void main() {
  const keyPrefix = 'development/user1/proj1/job1/';
  const manifestKey = '${keyPrefix}capture_manifest.json';

  DummyBundle build() =>
      buildDummyBundle(keyPrefix: keyPrefix, manifestKey: manifestKey);

  test('exactly 49 entries: 48 images + 1 manifest', () {
    final bundle = build();
    expect(kSmokeExpectedFilesCount, 49);
    expect(bundle.files, hasLength(49));
    expect(bundle.manifest.key, manifestKey);
    expect(
      bundle.files.where((f) => f.key.endsWith('.jpg')),
      hasLength(48),
    );
  });

  test('16 images per ring across EYE/TOP/LOW, canonical names', () {
    final bundle = build();
    for (final ring in ['EYE', 'TOP', 'LOW']) {
      final ringFiles = bundle.files
          .where((f) => f.key.startsWith('${keyPrefix}images/$ring/'))
          .toList();
      expect(ringFiles, hasLength(16), reason: 'ring $ring');
      for (var i = 1; i <= 16; i++) {
        final name =
            '${ring.toLowerCase()}_${i.toString().padLeft(4, '0')}.jpg';
        expect(
          ringFiles.any((f) => f.key == '${keyPrefix}images/$ring/$name'),
          isTrue,
          reason: 'missing $name',
        );
      }
    }
  });

  test('every image blob starts FF D8 (SOI) and ends FF D9 (EOI), 2–8 KB', () {
    final bundle = build();
    for (final file in bundle.files.where((f) => f.key.endsWith('.jpg'))) {
      final b = file.bytes;
      expect(b[0], 0xFF, reason: file.key);
      expect(b[1], 0xD8, reason: file.key);
      expect(b[2], 0xFF, reason: file.key);
      expect(b[3], 0xE0, reason: file.key);
      expect(b[b.length - 2], 0xFF, reason: file.key);
      expect(b[b.length - 1], 0xD9, reason: file.key);
      expect(b.length, greaterThanOrEqualTo(2048), reason: file.key);
      expect(b.length, lessThan(8192), reason: file.key);
    }
  });

  test('every key sits under the given prefix', () {
    final bundle = build();
    for (final file in bundle.files) {
      expect(file.key, startsWith(keyPrefix));
    }
  });

  test('manifest JSON round-trips and matches the counts', () {
    final bundle = build();
    final manifest =
        jsonDecode(utf8.decode(bundle.manifest.bytes)) as Map<String, dynamic>;

    expect(manifest['flowVariant'], kSmokeFlowVariant);
    final summary = manifest['summary'] as Map<String, dynamic>;
    expect(summary['totalPhotos'], 48);
    expect(summary['warningsCount'], 0);

    final photos = (manifest['photos'] as List).cast<Map<String, dynamic>>();
    expect(photos, hasLength(48));
    for (final ring in ['EYE', 'TOP', 'LOW']) {
      expect(
        photos.where((p) => p['ringName'] == ring),
        hasLength(16),
        reason: 'ring $ring',
      );
    }
    // Every photo has a non-empty photoId, all unique.
    final ids = photos.map((p) => p['photoId'] as String).toSet();
    expect(ids, hasLength(48));
    expect(ids.every((id) => id.isNotEmpty), isTrue);
  });

  test('totalBytes sums every file', () {
    final bundle = build();
    expect(
      bundle.totalBytes,
      bundle.files.fold<int>(0, (sum, f) => sum + f.bytes.length),
    );
  });
}
