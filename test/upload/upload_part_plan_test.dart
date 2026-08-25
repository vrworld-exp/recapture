// test/upload/upload_part_plan_test.dart
//
// Pure unit tests for the S3 chunking math + ETag/backoff helpers.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/upload/upload_part_plan.dart';

void main() {
  group('planFileParts — S3 rules', () {
    test('file smaller than 5 MiB → single (final) part of its size', () {
      final parts = planFileParts(1024);
      expect(parts.length, 1);
      expect(parts.single.partNumber, 1);
      expect(parts.single.offset, 0);
      expect(parts.single.length, 1024);
    });

    test('exactly one chunk → single part', () {
      final parts = planFileParts(kDefaultChunkSize);
      expect(parts.length, 1);
      expect(parts.single.length, kDefaultChunkSize);
    });

    test('non-final parts are full chunk size; final part is the remainder', () {
      final size = kDefaultChunkSize * 2 + 123;
      final parts = planFileParts(size);
      expect(parts.length, 3);
      expect(parts[0].length, kDefaultChunkSize);
      expect(parts[1].length, kDefaultChunkSize);
      expect(parts[2].length, 123); // final, smaller — allowed
      // Offsets are contiguous and cover the whole file.
      expect(parts[0].offset, 0);
      expect(parts[1].offset, kDefaultChunkSize);
      expect(parts[2].offset, kDefaultChunkSize * 2);
      expect(parts.last.endOffset, size);
      // 1-based, ascending part numbers.
      expect(parts.map((p) => p.partNumber).toList(), [1, 2, 3]);
    });

    test('chunkSize below the 5 MiB floor is raised to the floor', () {
      final parts = planFileParts(kS3MinPartSize * 2, chunkSize: 1024);
      expect(parts.length, 2);
      expect(parts[0].length, kS3MinPartSize);
      expect(parts[1].length, kS3MinPartSize);
    });

    test('scales chunk size up so part count never exceeds 10,000', () {
      // At the 5 MiB floor this would be ~10,486 parts; must scale up to <= 10,000.
      final size = kS3MinPartSize * 10486;
      final parts = planFileParts(size, chunkSize: kS3MinPartSize);
      expect(parts.length, lessThanOrEqualTo(kS3MaxParts));
      // Every non-final part is still >= the floor.
      for (var i = 0; i < parts.length - 1; i++) {
        expect(parts[i].length, greaterThanOrEqualTo(kS3MinPartSize));
      }
      expect(parts.last.endOffset, size);
    });

    test('at exactly 10,000 parts, no scaling needed', () {
      final size = kS3MinPartSize * kS3MaxParts;
      final parts = planFileParts(size, chunkSize: kS3MinPartSize);
      expect(parts.length, kS3MaxParts);
    });

    test('zero / negative size → empty plan (caller skips)', () {
      expect(planFileParts(0), isEmpty);
      expect(planFileParts(-5), isEmpty);
    });
  });

  group('normalizeETag', () {
    test('strips surrounding quotes and whitespace', () {
      expect(normalizeETag('"abc123"'), 'abc123');
      expect(normalizeETag('  "d4e5" '), 'd4e5');
      expect(normalizeETag('nak'), 'nak');
      expect(normalizeETag(r'"a\"b"'), 'ab');
    });
  });

  group('backoffDelay', () {
    test('first attempt is the base; grows exponentially; caps', () {
      const base = Duration(milliseconds: 500);
      const cap = Duration(seconds: 4);
      expect(backoffDelay(1, base: base, maxDelay: cap), base);
      expect(backoffDelay(2, base: base, maxDelay: cap),
          const Duration(milliseconds: 1000));
      expect(backoffDelay(3, base: base, maxDelay: cap),
          const Duration(milliseconds: 2000));
      // 4th would be 4000ms == cap; 5th clamps to cap.
      expect(backoffDelay(5, base: base, maxDelay: cap), cap);
      // Pathological attempt count does not overflow.
      expect(backoffDelay(1000, base: base, maxDelay: cap), cap);
    });
  });
}
