// test/upload/file_checksum_test.dart
//
// Streaming MD5 helper: known reference vectors, empty input, streaming==whole,
// real-file digest, and missing-file → throws (never a blank digest).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/upload/file_checksum.dart';

Stream<List<int>> _chunks(List<int> bytes, int size) async* {
  for (var i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size);
  }
}

void main() {
  group('md5HexOfStream — reference vectors (lowercase hex)', () {
    test('empty input → canonical empty MD5', () async {
      expect(await md5HexOfStream(const Stream.empty()),
          'd41d8cd98f00b204e9800998ecf8427e');
    });

    test('"abc" matches the reference MD5', () async {
      expect(await md5HexOfStream(Stream.value(utf8.encode('abc'))),
          '900150983cd24fb0d6963f7d28e17f72');
    });

    test('classic pangram matches the reference MD5', () async {
      final s = utf8.encode('The quick brown fox jumps over the lazy dog');
      expect(await md5HexOfStream(Stream.value(s)),
          '9e107d9d372bb6826bd81d3542a419d6');
    });

    test('chunked stream yields the SAME digest as one buffer (streaming works)',
        () async {
      final bytes = List<int>.generate(1024 * 1024 + 7, (i) => i % 251);
      final streamed = await md5HexOfStream(_chunks(bytes, 64 * 1024));
      final whole = md5.convert(bytes).toString();
      expect(streamed, whole);
    });

    test('encoding is 32 lowercase hex chars', () async {
      final digest = await md5HexOfStream(Stream.value(utf8.encode('x')));
      expect(digest, matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });

  group('StreamingMd5Checksum (real file)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('md5_'));
    tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

    test('hashes a real file to the reference value', () async {
      final f = File('${tmp.path}/a.jpg')..writeAsBytesSync(utf8.encode('abc'));
      expect(await const StreamingMd5Checksum().md5Hex(f.path),
          '900150983cd24fb0d6963f7d28e17f72');
    });

    test('zero-byte file → canonical empty MD5 (not an error)', () async {
      final f = File('${tmp.path}/empty.jpg')..writeAsBytesSync(const []);
      expect(await const StreamingMd5Checksum().md5Hex(f.path),
          'd41d8cd98f00b204e9800998ecf8427e');
    });

    test('missing file throws (never a blank digest)', () async {
      expect(
        () => const StreamingMd5Checksum().md5Hex('${tmp.path}/nope.jpg'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
