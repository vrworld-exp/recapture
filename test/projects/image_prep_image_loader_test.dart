// test/projects/image_prep_image_loader_test.dart
//
// The Prepare-Images byte loader, which owns two things the crop depends on:
//
//   1. TRANSPORT FALLBACK — the presigned S3 URL first, then the API's
//      read-through proxy. Without the fallback the whole screen is dead on
//      the web build (the raw bucket serves no CORS, so the direct fetch can
//      never succeed) and dies on device once a presign expires.
//
//   2. MEASUREMENT — the display dimensions, decoded through dart:ui exactly
//      as Image.memory will. This is the fix for the crop landing in the wrong
//      place: the screen builds its AspectRatio from these, and a header-only
//      read reports them un-rotated for an EXIF-tagged capture, so the preview
//      was stretched and every normalized coordinate was measured against the
//      wrong shape.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:recapture/application/projects/image_prep_image_loader.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/preview_manifest.dart';

import 'repo_fake_defaults.dart';

/// Splices a minimal APP1/Exif Orientation segment into [jpeg] — img.encodeJpg
/// bakes an in-memory orientation and drops the tag, so it cannot make one.
Uint8List _withOrientationTag(Uint8List jpeg, int orientation) {
  const segment = [
    0xFF, 0xE1, 0x00, 0x22, //
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
    0x49, 0x49, 0x2A, 0x00, //
    0x08, 0x00, 0x00, 0x00, //
    0x01, 0x00, //
    0x12, 0x01, //
    0x03, 0x00, //
    0x01, 0x00, 0x00, 0x00, //
  ];
  return Uint8List.fromList([
    ...jpeg.sublist(0, 2),
    ...segment,
    orientation, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    ...jpeg.sublist(2),
  ]);
}

/// Stored 200×100, tagged "rotate 90° CW" → DISPLAYS as 100×200.
final Uint8List _portraitCapture = _withOrientationTag(
  Uint8List.fromList(
    img.encodeJpg(
      img.Image(width: 200, height: 100, numChannels: 3),
      quality: 100,
    ),
  ),
  6,
);

class _FakeRepo
    with
        FakeModelGenerationDefaults,
        FakeAutoGenerationDefaults,
        FakeAdminDeleteDefaults
    implements LiveProjectsRepository {
  _FakeRepo(this.bytes);

  final Uint8List bytes;
  final proxied = <(String, String)>[];

  @override
  Future<Uint8List> fetchPhotoBytes(String projectId, String key) async {
    proxied.add((projectId, key));
    return bytes;
  }

  @override
  Future<List<ModelImageUploadSlot>> requestModelImageUploads(
          String projectId, int count) async =>
      throw UnimplementedError('not used here');

  @override
  Future<void> uploadModelImage(
          ModelImageUploadSlot slot, Uint8List bytes) async =>
      throw UnimplementedError('not used here');

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async =>
      const LiveProjectsPage(items: [], nextCursor: null);

  @override
  Future<Map<String, dynamic>> export(String projectId) async => const {};

  @override
  Future<PreviewDeleteResult> deletePhotos(
          String projectId, List<String> keys) async =>
      const PreviewDeleteResult(deleted: [], missing: []);
}

/// A photo whose presigned URL cannot possibly resolve, forcing the fallback —
/// the web build's permanent state.
const _unreachable = PreviewPhoto(
  key: 'images/EYE/eye_0001.jpg',
  url: 'http://localhost:1/definitely-not-served',
  size: 1234,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('falls back to the API proxy when the presigned fetch fails', () async {
    final repo = _FakeRepo(_portraitCapture);
    final loaded =
        await DioPrepImageLoader(repo).load('proj-1', _unreachable);

    expect(repo.proxied, [('proj-1', 'images/EYE/eye_0001.jpg')]);
    expect(loaded.bytes, _portraitCapture);
  });

  test(
      'REGRESSION: reports DISPLAY dimensions for an EXIF-rotated capture, '
      'so the preview box matches the pixels the crop is measured against',
      () async {
    final loaded = await DioPrepImageLoader(_FakeRepo(_portraitCapture))
        .load('proj-1', _unreachable);

    expect(
      (loaded.width, loaded.height),
      (100, 200),
      reason: 'a header-only read reports the stored 200×100 here — the '
          'AspectRatio is then wrong and BoxFit.fill stretches the image to '
          'hide it, skewing every crop coordinate',
    );
  });

  test('propagates the failure when the proxy fails too', () async {
    final loader = DioPrepImageLoader(_FailingRepo());
    expect(
      () => loader.load('proj-1', _unreachable),
      throwsA(isA<LiveProjectsException>()),
    );
  });
}

class _FailingRepo extends _FakeRepo {
  _FailingRepo() : super(Uint8List(0));

  @override
  Future<Uint8List> fetchPhotoBytes(String projectId, String key) async =>
      throw const LiveProjectsException(LiveProjectsFailure.network);
}
