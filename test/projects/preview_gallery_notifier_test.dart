// test/projects/preview_gallery_notifier_test.dart
//
// Preview gallery state: build parses the export map into a typed manifest;
// deletePhoto soft-deletes via the repo and drops the tile LOCALLY without
// re-fetching the (rate-limited) manifest; a delete failure rethrows and leaves
// the list intact. Hermetic: scripted fake repository.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/application/projects/preview_gallery_notifier.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'repo_fake_defaults.dart';

class _FakeRepo
    with
        FakeModelGenerationDefaults,
        FakeAdminDeleteDefaults,
        FakeAutoGenerationDefaults
    implements LiveProjectsRepository {
  Map<String, dynamic> exportResult = const {};
  LiveProjectsException? exportFail;
  int exportCalls = 0;

  final List<List<String>> deleteCalls = [];
  LiveProjectsException? deleteFail;
  PreviewDeleteResult deleteResult =
      const PreviewDeleteResult(deleted: [], missing: []);

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async =>
      const LiveProjectsPage(items: [], nextCursor: null);

  @override
  Future<Map<String, dynamic>> export(String projectId) async {
    exportCalls++;
    final fail = exportFail;
    if (fail != null) throw fail;
    return exportResult;
  }

  @override
  Future<PreviewDeleteResult> deletePhotos(
      String projectId, List<String> keys) async {
    deleteCalls.add(keys);
    final fail = deleteFail;
    if (fail != null) throw fail;
    return deleteResult;
  }
}

Map<String, dynamic> _manifest(List<String> keys) => {
      'projectId': 'p1',
      'jobId': 'j1',
      'generatedAt': '2026-07-15T12:00:00.000Z',
      'expiresAt': '2026-07-15T13:00:00.000Z',
      'fileCount': keys.length,
      'expectedFileCount': keys.length,
      'files': [
        for (final k in keys)
          {'key': k, 'url': 'https://signed/$k', 'size': 100},
      ],
    };

void main() {
  late _FakeRepo repo;
  late ProviderContainer container;

  setUp(() {
    repo = _FakeRepo();
    container = ProviderContainer(overrides: [
      liveProjectsRepositoryProvider.overrideWithValue(repo),
    ]);
  });

  tearDown(() => container.dispose());

  test('build parses the export map into a typed manifest', () async {
    repo.exportResult = _manifest(['images/EYE/a.jpg', 'images/EYE/b.jpg']);

    final manifest = await container.read(previewGalleryProvider('p1').future);

    expect(manifest.files.map((f) => f.key),
        ['images/EYE/a.jpg', 'images/EYE/b.jpg']);
    expect(manifest.files.first.url, 'https://signed/images/EYE/a.jpg');
    expect(manifest.fileCount, 2);
    expect(manifest.expiresAt, DateTime.utc(2026, 7, 15, 13));
    expect(repo.exportCalls, 1);
  });

  test('deletePhoto soft-deletes, drops the tile locally, and does NOT re-fetch',
      () async {
    repo.exportResult = _manifest(['images/EYE/a.jpg', 'images/EYE/b.jpg']);
    repo.deleteResult =
        const PreviewDeleteResult(deleted: ['images/EYE/a.jpg'], missing: []);

    final manifest = await container.read(previewGalleryProvider('p1').future);
    final target = manifest.files.first;

    await container
        .read(previewGalleryProvider('p1').notifier)
        .deletePhoto(target);

    final after = container.read(previewGalleryProvider('p1')).value!;
    expect(after.files.map((f) => f.key), ['images/EYE/b.jpg']);
    expect(after.fileCount, 1);
    // The repo was asked to delete exactly the one key…
    expect(repo.deleteCalls, [
      ['images/EYE/a.jpg']
    ]);
    // …and the manifest was NOT re-requested (still the single build fetch).
    expect(repo.exportCalls, 1);
  });

  test('freshPhotoFor returns the same photo (no re-fetch) when url is valid',
      () async {
    repo.exportResult = _manifest(['images/EYE/a.jpg']);
    final manifest = await container.read(previewGalleryProvider('p1').future);
    final photo = manifest.files.first;

    final fresh = await container
        .read(previewGalleryProvider('p1').notifier)
        .freshPhotoFor(photo, now: () => DateTime.utc(2026, 7, 15, 12));

    expect(fresh.url, photo.url);
    // Well before expiry (13:00Z) → no token spent.
    expect(repo.exportCalls, 1);
  });

  test('freshPhotoFor re-fetches an expired manifest and returns the fresh url',
      () async {
    repo.exportResult = _manifest(['images/EYE/a.jpg']);
    final manifest = await container.read(previewGalleryProvider('p1').future);
    final photo = manifest.files.first;
    expect(repo.exportCalls, 1);

    // Simulate the server re-presigning: same key, a new url on the next fetch.
    repo.exportResult = {
      ..._manifest(['images/EYE/a.jpg']),
      'files': [
        {'key': 'images/EYE/a.jpg', 'url': 'https://signed/fresh', 'size': 100},
      ],
    };

    final fresh = await container
        .read(previewGalleryProvider('p1').notifier)
        // Past the manifest's 13:00Z expiry → must refresh.
        .freshPhotoFor(photo, now: () => DateTime.utc(2026, 7, 15, 14));

    expect(fresh.key, 'images/EYE/a.jpg');
    expect(fresh.url, 'https://signed/fresh');
    expect(repo.exportCalls, 2);
  });

  test('deletePhoto failure rethrows and leaves the list intact', () async {
    repo.exportResult = _manifest(['images/EYE/a.jpg']);
    repo.deleteFail =
        const LiveProjectsException(LiveProjectsFailure.forbidden);

    final manifest = await container.read(previewGalleryProvider('p1').future);

    await expectLater(
      container
          .read(previewGalleryProvider('p1').notifier)
          .deletePhoto(manifest.files.first),
      throwsA(isA<LiveProjectsException>().having(
          (e) => e.failure, 'failure', LiveProjectsFailure.forbidden)),
    );

    final after = container.read(previewGalleryProvider('p1')).value!;
    expect(after.files.map((f) => f.key), ['images/EYE/a.jpg'],
        reason: 'tile stays put on failure');
  });
}
