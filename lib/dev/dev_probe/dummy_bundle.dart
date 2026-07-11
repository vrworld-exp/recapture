// lib/dev/dev_probe/dummy_bundle.dart
//
// Pure in-memory generator for the upload smoke test's dummy capture bundle.
// Mirrors the `with_bottom` capture-variant contract the backend enforces:
// 12 photos per ring on EYE/TOP/LOW (36 images) + capture_manifest.json = 37
// files exactly. No IO, no Flutter — unit-testable as plain Dart.
import 'dart:convert';
import 'dart:typed_data';

/// Local mirror of the `with_bottom` variant contract (the backend's
/// captureVariants table). The generator derives every count from this table;
/// a unit test pins 36 + 1 = 37.
const List<String> kSmokeRings = ['EYE', 'TOP', 'LOW'];
const int kSmokePhotosPerRing = 12;
const String kSmokeFlowVariant = 'with_bottom';

/// Total files the bundle must contain: the variant's images + the manifest.
final int kSmokeExpectedFilesCount =
    kSmokeRings.length * kSmokePhotosPerRing + 1;

/// One in-memory file of the dummy bundle, addressed by its full S3 key.
class BundleFile {
  const BundleFile({required this.key, required this.bytes});

  final String key;
  final Uint8List bytes;
}

/// The generated bundle: 36 image blobs + the manifest, keys already under
/// the job's plan prefix.
class DummyBundle {
  const DummyBundle({required this.files});

  final List<BundleFile> files;

  BundleFile get manifest => files.last;
  int get totalBytes => files.fold(0, (sum, f) => sum + f.bytes.length);
}

/// Builds the full dummy bundle for one upload plan.
///
/// Image keys follow the canonical bundle layout the backend's containment
/// check enforces: `{keyPrefix}images/{RING}/{ring}_0001.jpg` …; the manifest
/// goes to the plan's own [manifestKey]. Each image is a small (~2–8 KB) blob
/// framed by the JPEG SOI marker (FF D8 FF E0) and EOI (FF D9); the manifest
/// satisfies the backend's manifestValidationService rules for `with_bottom`.
DummyBundle buildDummyBundle({
  required String keyPrefix,
  required String manifestKey,
}) {
  final files = <BundleFile>[];
  final photos = <Map<String, String>>[];

  for (var ringIndex = 0; ringIndex < kSmokeRings.length; ringIndex++) {
    final ring = kSmokeRings[ringIndex];
    for (var i = 1; i <= kSmokePhotosPerRing; i++) {
      final name = '${ring.toLowerCase()}_${i.toString().padLeft(4, '0')}';
      files.add(BundleFile(
        key: '${keyPrefix}images/$ring/$name.jpg',
        bytes: _dummyJpegBytes(ringIndex * kSmokePhotosPerRing + i),
      ));
      photos.add({'photoId': name, 'ringName': ring});
    }
  }

  final manifest = <String, Object>{
    'flowVariant': kSmokeFlowVariant,
    'summary': {'totalPhotos': photos.length, 'warningsCount': 0},
    'photos': photos,
  };
  files.add(BundleFile(
    key: manifestKey,
    bytes: Uint8List.fromList(utf8.encode(jsonEncode(manifest))),
  ));

  return DummyBundle(files: files);
}

/// A deterministic pseudo-JPEG: SOI/APP0 marker prefix, LCG filler sized
/// 2–8 KB varying by [seed], EOI suffix. Not decodable as an image — the
/// backend only verifies presence/counts, not pixel content.
Uint8List _dummyJpegBytes(int seed) {
  final size = 2048 + (seed * 731) % 6144; // 2 KB ≤ size < 8 KB
  final bytes = Uint8List(size);
  bytes[0] = 0xFF; // SOI
  bytes[1] = 0xD8;
  bytes[2] = 0xFF; // APP0
  bytes[3] = 0xE0;
  var state = seed + 0x9E3779B9;
  for (var i = 4; i < size - 2; i++) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    bytes[i] = state & 0xFF;
  }
  bytes[size - 2] = 0xFF; // EOI
  bytes[size - 1] = 0xD9;
  return bytes;
}
