// test/projects/preview_gallery_notifier_test.dart
//
// Preview gallery state. The load-bearing property here is that BROWSING SPENDS
// NO EXPORT BUDGET: build and refresh go to the credential-free `/photos`
// listing, and the rate-limited export manifest is minted only when a download
// needs a real presigned url — then cached until it expires. The gallery used
// to draw thumbnails from that manifest, which is what made ten opens exhaust a
// cap meant for ten exports.
//
// Also covered: deletePhoto soft-deletes via the repo and drops the tile
// LOCALLY without re-listing; a delete failure rethrows and leaves the list
// intact. Hermetic: scripted fake repository.
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
        FakeAutoGenerationDefaults,
        FakeModelOptimizeDefaults,
        FakeOwnerModelListDefaults,
        FakeModelSubmissionDefaults
    implements LiveProjectsRepository {
  Map<String, dynamic> photosResult = const {};
  LiveProjectsException? photosFail;
  int photosCalls = 0;

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
  Future<Map<String, dynamic>> photos(String projectId) async {
    photosCalls++;
    final fail = photosFail;
    if (fail != null) throw fail;
    return photosResult;
  }

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

/// The credential-free `/photos` payload: keys + sizes, no urls, no expiry.
Map<String, dynamic> _photos(List<String> keys) => {
      'projectId': 'p1',
      'jobId': 'j1',
      'fileCount': keys.length,
      'expectedFileCount': keys.length,
      'files': [
        for (final k in keys) {'key': k, 'size': 100},
      ],
    };

/// The rate-limited `/export` payload: the same set, presigned.
Map<String, dynamic> _manifest(List<String> keys, {String prefix = 'signed'}) => {
      'projectId': 'p1',
      'jobId': 'j1',
      'generatedAt': '2026-07-15T12:00:00.000Z',
      'expiresAt': '2026-07-15T13:00:00.000Z',
      'fileCount': keys.length,
      'expectedFileCount': keys.length,
      'files': [
        for (final k in keys)
          {'key': k, 'url': 'https://$prefix/$k', 'size': 100},
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

  test('build lists the capture set and mints NO export urls', () async {
    repo.photosResult = _photos(['images/EYE/a.jpg', 'images/EYE/b.jpg']);

    final manifest = await container.read(previewGalleryProvider('p1').future);

    expect(manifest.files.map((f) => f.key),
        ['images/EYE/a.jpg', 'images/EYE/b.jpg']);
    expect(manifest.fileCount, 2);
    // A listed photo carries no credential and nothing expires.
    expect(manifest.files.every((f) => f.url == null), isTrue);
    expect(manifest.expiresAt, isNull);
    expect(repo.photosCalls, 1);
    expect(repo.exportCalls, 0, reason: 'opening the gallery is free');
  });

  test('refresh re-lists and still spends no export budget', () async {
    repo.photosResult = _photos(['images/EYE/a.jpg']);
    await container.read(previewGalleryProvider('p1').future);

    await container.read(previewGalleryProvider('p1').notifier).refresh();

    expect(repo.photosCalls, 2);
    expect(repo.exportCalls, 0, reason: 'pull-to-refresh is free');
  });

  test('deletePhoto soft-deletes, drops the tile locally, and does NOT re-list',
      () async {
    repo.photosResult = _photos(['images/EYE/a.jpg', 'images/EYE/b.jpg']);
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
    // …and nothing was re-requested (still the single build listing).
    expect(repo.photosCalls, 1);
    expect(repo.exportCalls, 0);
  });

  test('freshPhotoFor mints an export url for a listed photo', () async {
    repo.photosResult = _photos(['images/EYE/a.jpg']);
    repo.exportResult = _manifest(['images/EYE/a.jpg']);
    final manifest = await container.read(previewGalleryProvider('p1').future);
    final photo = manifest.files.first;
    expect(photo.url, isNull);

    final fresh = await container
        .read(previewGalleryProvider('p1').notifier)
        .freshPhotoFor(photo, now: () => DateTime.utc(2026, 7, 15, 12));

    expect(fresh.key, 'images/EYE/a.jpg');
    expect(fresh.url, 'https://signed/images/EYE/a.jpg');
    expect(repo.exportCalls, 1, reason: 'download is the only paying path');
  });

  test('freshPhotoFor reuses the cached manifest for a second download',
      () async {
    repo.photosResult = _photos(['images/EYE/a.jpg', 'images/EYE/b.jpg']);
    repo.exportResult = _manifest(['images/EYE/a.jpg', 'images/EYE/b.jpg']);
    final manifest = await container.read(previewGalleryProvider('p1').future);
    final notifier = container.read(previewGalleryProvider('p1').notifier);
    final at = DateTime.utc(2026, 7, 15, 12);

    await notifier.freshPhotoFor(manifest.files[0], now: () => at);
    final second = await notifier.freshPhotoFor(manifest.files[1], now: () => at);

    expect(second.url, 'https://signed/images/EYE/b.jpg');
    expect(repo.exportCalls, 1,
        reason: 'one manifest covers every photo until it expires');
  });

  test('freshPhotoFor re-mints once the cached urls expire', () async {
    repo.photosResult = _photos(['images/EYE/a.jpg']);
    repo.exportResult = _manifest(['images/EYE/a.jpg']);
    final manifest = await container.read(previewGalleryProvider('p1').future);
    final notifier = container.read(previewGalleryProvider('p1').notifier);
    final photo = manifest.files.first;

    await notifier.freshPhotoFor(photo, now: () => DateTime.utc(2026, 7, 15, 12));
    // Simulate the server re-presigning: same key, a new url on the next fetch.
    repo.exportResult = _manifest(['images/EYE/a.jpg'], prefix: 'resigned');

    final fresh = await notifier.freshPhotoFor(
      photo,
      // Past the manifest's 13:00Z expiry → must re-mint.
      now: () => DateTime.utc(2026, 7, 15, 14),
    );

    expect(fresh.url, 'https://resigned/images/EYE/a.jpg');
    expect(repo.exportCalls, 2);
  });

  test('freshPhotoFor returns the photo unchanged when its key has vanished',
      () async {
    repo.photosResult = _photos(['images/EYE/a.jpg']);
    // The export no longer lists the photo (deleted elsewhere since listing).
    repo.exportResult = _manifest(['images/EYE/other.jpg']);
    final manifest = await container.read(previewGalleryProvider('p1').future);

    final fresh = await container
        .read(previewGalleryProvider('p1').notifier)
        .freshPhotoFor(manifest.files.first,
            now: () => DateTime.utc(2026, 7, 15, 12));

    // Still url-less, so delivery fails loudly into mapped copy rather than
    // downloading somebody else's photo.
    expect(fresh.key, 'images/EYE/a.jpg');
    expect(fresh.url, isNull);
  });

  test('deletePhoto failure rethrows and leaves the list intact', () async {
    repo.photosResult = _photos(['images/EYE/a.jpg']);
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
