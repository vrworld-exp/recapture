// test/projects/project_photo_upload_test.dart
//
// The client half of the artist photo-upload feature:
//   • the extracted magic-byte sniffer (and the avatar picker still using it);
//   • the picker's per-file type / size / count rules;
//   • BytesPartByteSource range reads;
//   • Project.fromMap / toMap round-tripping `source`;
//   • the UploadSessionSpec key↔file pairing, including the fatal mismatch;
//   • the ProjectPhotosNotifier state machine, failure branches included;
//   • the PER-PHOTO status the upload-progress screen renders, derived from the
//     engine's aggregate feed (the engine's own sequential-file contract is
//     pinned separately, in test/upload/chunked_upload_manager_test.dart).
//
// Hermetic: no network, no platform channel, no filesystem.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:recapture/application/projects/project_photos_notifier.dart';
import 'package:recapture/application/upload/bytes_part_byte_source.dart';
import 'package:recapture/application/upload/photo_set_upload_flow.dart';
import 'package:recapture/application/upload/resilient_upload_runner.dart';
import 'package:recapture/application/upload/upload_progress_provider.dart';
import 'package:recapture/data/repositories/projects_repository.dart';
import 'package:recapture/domain/upload/upload_session_spec.dart';
import 'package:recapture/data/datasources/project_photo_picker.dart';
import 'package:recapture/data/repositories/project_photos_repository.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/create_project_options.dart';
import 'package:recapture/domain/entities/project_source.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/utils/image_content_type.dart';

// ── Fixtures ─────────────────────────────────────────────────────────────────

Uint8List _jpeg([int trailing = 32]) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.filled(trailing, 0)]);

Uint8List _png([int trailing = 32]) => Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(trailing, 0)]);

Uint8List _webp() => Uint8List.fromList([
      0x52, 0x49, 0x46, 0x46, // RIFF
      0x00, 0x00, 0x00, 0x00, // size
      0x57, 0x45, 0x42, 0x50, // WEBP
      0x56, 0x50, 0x38, 0x20,
    ]);

Uint8List _gif() => Uint8List.fromList(
    [0x47, 0x49, 0x46, 0x38, 0x39, 0x61, ...List.filled(16, 0)]);

void main() {
  // ── The extracted sniffer ──────────────────────────────────────────────────
  group('sniffImageContentType', () {
    test('reads the type from MAGIC BYTES, not from a name', () {
      expect(sniffImageContentType(_jpeg()), kContentTypeJpeg);
      expect(sniffImageContentType(_png()), kContentTypePng);
    });

    test('WebP is OFF by default — the avatar path keeps its exact behaviour', () {
      expect(sniffImageContentType(_webp()), isNull);
      expect(sniffImageContentType(_webp(), allowWebp: true), kContentTypeWebp);
    });

    test('rejects anything else, and never guesses', () {
      expect(sniffImageContentType(_gif(), allowWebp: true), isNull);
      expect(sniffImageContentType(Uint8List(0)), isNull);
      expect(sniffImageContentType(Uint8List.fromList([0xFF, 0xD8])), isNull);
    });

    test('a RIFF container that is NOT WebP is refused (a WAV is not an image)', () {
      final wav = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, //
        0x00, 0x00, 0x00, 0x00,
        0x57, 0x41, 0x56, 0x45, // 'WAVE'
        0x00, 0x00, 0x00, 0x00,
      ]);
      expect(sniffImageContentType(wav, allowWebp: true), isNull);
    });
  });

  // ── The picker ─────────────────────────────────────────────────────────────
  group('ImagePickerProjectPhotoSource', () {
    test('accepts JPEG / PNG / WebP and reports each sniffed type', () async {
      final picker = ImagePickerProjectPhotoSource(_FakeBackend([
        _file('a.jpg', _jpeg()),
        _file('b.png', _png()),
        _file('c.webp', _webp()),
      ]));

      final set = await picker.pickPhotos();

      expect(set.accepted.map((p) => p.contentType), [
        kContentTypeJpeg,
        kContentTypePng,
        kContentTypeWebp,
      ]);
      expect(set.rejected, isEmpty);
    });

    test('drops an unsupported type WITH a reason — never silently', () async {
      final picker = ImagePickerProjectPhotoSource(_FakeBackend([
        _file('good.jpg', _jpeg()),
        _file('nope.gif', _gif()),
      ]));

      final set = await picker.pickPhotos();

      expect(set.accepted, hasLength(1));
      expect(set.rejected.single.name, 'nope.gif');
      expect(set.rejected.single.reason, PhotoRejectionReason.unsupportedType);
    });

    test('enforces the per-file byte cap at pick time', () async {
      final picker = ImagePickerProjectPhotoSource(_FakeBackend([
        _file('huge.jpg', _jpeg(), size: kProjectPhotoMaxBytes + 1),
        _file('ok.jpg', _jpeg()),
      ]));

      final set = await picker.pickPhotos();

      expect(set.accepted, hasLength(1));
      expect(set.rejected.single.reason, PhotoRejectionReason.tooLarge);
    });

    test('caps the TOTAL count across repeated picks, not per pick', () async {
      final picker = ImagePickerProjectPhotoSource(_FakeBackend([
        _file('x.jpg', _jpeg()),
        _file('y.jpg', _jpeg()),
      ]));

      // One slot left in the whole set.
      final set = await picker.pickPhotos(alreadyPicked: kProjectPhotoMaxCount - 1);

      expect(set.accepted, hasLength(1));
      expect(set.rejected.single.reason, PhotoRejectionReason.overCount);
    });

    test('a cancelled pick is an empty set, not an error', () async {
      final picker = ImagePickerProjectPhotoSource(_FakeBackend(const []));
      expect((await picker.pickPhotos()).isEmpty, isTrue);
    });
  });

  // ── The web byte source ────────────────────────────────────────────────────
  group('BytesPartByteSource', () {
    final bytes = Uint8List.fromList(List.generate(100, (i) => i));
    final source = BytesPartByteSource({'h': bytes});

    Future<List<int>> read(int offset, int length) async {
      final chunks = await source.read('h', offset, length).toList();
      return chunks.expand((c) => c).toList();
    }

    test('reports the size', () => expect(source.fileSize('h'), 100));

    test('first part', () async {
      expect(await read(0, 40), bytes.sublist(0, 40));
    });

    test('last, SHORT part', () async {
      expect(await read(80, 20), bytes.sublist(80, 100));
    });

    test('a single-part file is the whole thing', () async {
      expect(await read(0, 100), bytes);
    });

    test('a range past the end CLAMPS rather than throwing mid-upload', () async {
      expect(await read(90, 50), bytes.sublist(90));
    });

    test('an unknown handle is an empty stream, matching FilePartByteSource', () async {
      expect(source.fileSize('missing'), 0);
      expect(await source.read('missing', 0, 10).toList(), isEmpty);
    });
  });

  // ── The entity ─────────────────────────────────────────────────────────────
  group('Project.source', () {
    test('absent → capture (an older API or an older cache row)', () {
      final p = Project.fromMap({'id': '1', 'name': 'A', 'status': 'draft'});
      expect(p.source, ProjectSource.capture);
      expect(p.isUploadProject, isFalse);
    });

    test('an unknown value → capture, never a crash', () {
      final p = Project.fromMap(
          {'id': '1', 'name': 'A', 'status': 'draft', 'source': 'martian'});
      expect(p.source, ProjectSource.capture);
    });

    test('round-trips through toMap — a cached upload project stays one', () {
      final original = Project(
        id: '1',
        name: 'Uploaded',
        status: ProjectStatus.draft,
        updatedAt: DateTime.utc(2026, 8, 24),
        source: ProjectSource.upload,
      );

      final restored = Project.fromMap(original.toMap());

      expect(restored.source, ProjectSource.upload);
      expect(restored.isUploadProject, isTrue);
    });

    test('parses the wire value', () {
      final p = Project.fromMap(
          {'id': '1', 'name': 'A', 'status': 'draft', 'source': 'upload'});
      expect(p.source, ProjectSource.upload);
    });
  });

  // ── The pairing rule ───────────────────────────────────────────────────────
  group('key <-> file pairing', () {
    test('pairs BY INDEX, in the order the files were listed', () async {
      final container = _containerWith(
        picker: _StubPicker([
          _photo('/a.jpg', 10),
          _photo('/b.png', 20),
          _photo('/c.jpg', 30),
        ]),
        repo: _StubPhotosRepo(),
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.pickPhotos();
      final project = await notifier.upload(name: 'Set');

      expect(project, isNotNull);
      final repo = container.read(projectPhotosRepositoryProvider) as _StubPhotosRepo;
      // The engine received each picked file against the key at the SAME index.
      expect(repo.sessionSizes, [10, 20, 30]);
      expect(repo.sessionTypes, [
        kContentTypeJpeg,
        kContentTypePng,
        kContentTypeJpeg,
      ]);
    });

    test('a length mismatch is FATAL - never a silently shuffled set', () async {
      final container = _containerWith(
        picker: _StubPicker([
          _photo('/a.jpg', 10),
          _photo('/b.jpg', 20),
          _photo('/c.jpg', 30),
        ]),
        // Returns TWO keys for THREE files. Continuing would upload photo 3's
        // bytes to photo 2's key: a set that looks fine and is wrong.
        repo: _StubPhotosRepo(slotCount: 2),
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.pickPhotos();

      await expectLater(
        notifier.upload(name: 'Set'),
        throwsA(isA<PhotoKeyPairingError>()),
      );
    });
  });

  // ── The state machine ──────────────────────────────────────────────────────
  group('ProjectPhotosNotifier', () {
    test('idle → picking → idle, collecting the picked set', () async {
      final container = _containerWith(
        picker: _StubPicker([_photo('/a.jpg', 1), _photo('/b.jpg', 2)]),
        repo: _StubPhotosRepo(),
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      expect(container.read(projectPhotosProvider).phase, PhotoUploadPhase.idle);

      await notifier.pickPhotos();

      final state = container.read(projectPhotosProvider);
      expect(state.phase, PhotoUploadPhase.idle);
      expect(state.picked, hasLength(2));
      // Two is below the minimum, so the CTA stays disabled.
      expect(state.canUpload, isFalse);
    });

    test('canUpload only once the MINIMUM is reached', () async {
      final container = _containerWith(
        picker: _StubPicker(List.generate(kProjectPhotoMinCount, (i) => _photo('/$i.jpg', 1))),
        repo: _StubPhotosRepo(),
      );
      addTearDown(container.dispose);

      await container.read(projectPhotosProvider.notifier).pickPhotos();
      expect(container.read(projectPhotosProvider).canUpload, isTrue);
    });

    test('removePicked drops one and re-disables the CTA', () async {
      final container = _containerWith(
        picker: _StubPicker(List.generate(3, (i) => _photo('/$i.jpg', 1))),
        repo: _StubPhotosRepo(),
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.pickPhotos();
      notifier.removePicked(0);

      expect(container.read(projectPhotosProvider).picked, hasLength(2));
      expect(container.read(projectPhotosProvider).canUpload, isFalse);
    });

    test('OFFLINE refuses with a plain sentence and creates NOTHING', () async {
      final repo = _StubPhotosRepo();
      final container = _containerWith(
        picker: _StubPicker(List.generate(3, (i) => _photo('/$i.jpg', 1))),
        repo: repo,
        online: false,
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.pickPhotos();
      final project = await notifier.upload(name: 'Set');

      expect(project, isNull);
      final state = container.read(projectPhotosProvider);
      expect(state.phase, PhotoUploadPhase.failed);
      expect(state.message, contains('online'));
      // The upload path must never enqueue a project onto the offline outbox —
      // step 2 needs the REAL server id, and a temp local id would 404.
      expect(repo.sessionsOpened, 0);
    });

    test('a session failure surfaces the mapped reason and stops', () async {
      final container = _containerWith(
        picker: _StubPicker(List.generate(3, (i) => _photo('/$i.jpg', 1))),
        repo: _StubPhotosRepo(
          sessionError: const PhotoUploadException(PhotoUploadFailure.forbidden),
        ),
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.pickPhotos();
      expect(await notifier.upload(name: 'Set'), isNull);

      final state = container.read(projectPhotosProvider);
      expect(state.phase, PhotoUploadPhase.failed);
      expect(state.failure, PhotoUploadFailure.forbidden);
      // The project still exists — an abandoned upload leaves a DRAFT, by design.
      expect(state.project, isNotNull);
    });

    test('a commit failure keeps the project and reports the reason', () async {
      final container = _containerWith(
        picker: _StubPicker(List.generate(3, (i) => _photo('/$i.jpg', 1))),
        repo: _StubPhotosRepo(
          commitError: const PhotoUploadException(PhotoUploadFailure.photoTooLarge),
        ),
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.pickPhotos();
      expect(await notifier.upload(name: 'Set'), isNull);

      final state = container.read(projectPhotosProvider);
      expect(state.failure, PhotoUploadFailure.photoTooLarge);
      expect(state.project, isNotNull);
      expect(state.jobId, isNotNull);
    });

    test('selection is bounded at 4 — an over-cap tap is a NO-OP', () async {
      final container = _containerWith(picker: _StubPicker(const []), repo: _StubPhotosRepo());
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.refreshPhotos('p1');

      for (var i = 1; i <= 5; i++) {
        notifier.toggleSelection('uploads/photo_000$i.jpg');
      }

      final state = container.read(projectPhotosProvider);
      expect(state.selectedKeys, hasLength(kMaxSelectedPhotos));
      expect(state.selectedKeys, isNot(contains('uploads/photo_0005.jpg')));
      expect(state.canGenerate, isTrue);
    });

    test('canGenerate is false below the minimum selection', () async {
      final container = _containerWith(picker: _StubPicker(const []), repo: _StubPhotosRepo());
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.refreshPhotos('p1');
      notifier.toggleSelection('uploads/photo_0001.jpg');
      notifier.toggleSelection('uploads/photo_0002.jpg');

      expect(container.read(projectPhotosProvider).canGenerate, isFalse);
    });

    test('toggling twice deselects', () async {
      final container = _containerWith(picker: _StubPicker(const []), repo: _StubPhotosRepo());
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.refreshPhotos('p1');
      notifier.toggleSelection('uploads/photo_0001.jpg');
      notifier.toggleSelection('uploads/photo_0001.jpg');

      expect(container.read(projectPhotosProvider).selectedKeys, isEmpty);
    });

    test('a refused generation returns to ready with a message, not a crash', () async {
      final container = _containerWith(
        picker: _StubPicker(const []),
        repo: _StubPhotosRepo(
          generateError: const PhotoUploadException(
            PhotoUploadFailure.rateLimited,
            'Too many model generation requests.',
          ),
        ),
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.refreshPhotos('p1');
      for (var i = 1; i <= 3; i++) {
        notifier.toggleSelection('uploads/photo_000$i.jpg');
      }

      expect(await notifier.generate('p1'), isNull);
      final state = container.read(projectPhotosProvider);
      expect(state.phase, PhotoUploadPhase.ready);
      expect(state.failure, PhotoUploadFailure.rateLimited);
      expect(state.message, 'Too many model generation requests.');
    });

    test('a deleted photo drops out of the selection on refresh', () async {
      final repo = _StubPhotosRepo();
      final container = _containerWith(picker: _StubPicker(const []), repo: repo);
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.refreshPhotos('p1');
      notifier.toggleSelection('uploads/photo_0001.jpg');
      notifier.toggleSelection('uploads/photo_0002.jpg');

      repo.photoKeys = ['uploads/photo_0002.jpg'];
      await notifier.deletePhoto('p1', 'uploads/photo_0001.jpg');

      expect(container.read(projectPhotosProvider).selectedKeys,
          {'uploads/photo_0002.jpg'});
    });
  });

  // ── Per-photo status (what the upload-progress screen renders) ─────────────
  group('per-photo transfer status', () {
    test('walks queued to uploading to uploaded, one photo at a time', () async {
      final engine = _ProgressingEngine([100, 200, 300]);
      final container = _containerWith(
        picker: _StubPicker([
          _photo('/a.jpg', 100),
          _photo('/b.jpg', 200),
          _photo('/c.jpg', 300),
        ]),
        repo: _StubPhotosRepo(),
        engine: engine,
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.pickPhotos();

      // Before a byte moves, everything is waiting.
      final start = container.read(projectPhotosProvider);
      expect(
        [for (var i = 0; i < 3; i++) start.statusForPhoto(i)],
        List.filled(3, PhotoTransferStatus.queued),
      );

      // Every mid-transfer frame, as the screen would have seen it.
      final frames = <List<PhotoTransferStatus>>[];
      engine.onFrame = () {
        final s = container.read(projectPhotosProvider);
        frames.add([for (var i = 0; i < 3; i++) s.statusForPhoto(i)]);
      };

      await notifier.upload(name: 'Set');

      for (final row in frames) {
        // Exactly one photo is ever in flight.
        expect(
          row.where((s) => s == PhotoTransferStatus.uploading).length,
          lessThanOrEqualTo(1),
          reason: 'two photos claimed to be in flight at once: \$row',
        );
        // And it is always the FIRST unfinished one — never a photo sitting
        // behind a queued one, which is what a concurrent engine would show.
        final firstUnfinished =
            row.indexWhere((s) => s != PhotoTransferStatus.uploaded);
        // -1 means the whole set is done — nothing left to order.
        if (firstUnfinished < 0) continue;
        for (var i = 0; i < row.length; i++) {
          if (i < firstUnfinished) {
            expect(row[i], PhotoTransferStatus.uploaded, reason: 'row: \$row');
          } else if (i > firstUnfinished) {
            expect(row[i], PhotoTransferStatus.queued, reason: 'row: \$row');
          }
        }
      }

      // The mid-file frames are what prove `uploading` is reachable at all.
      expect(
        frames.map((r) => r[0]).toList(),
        containsAllInOrder([
          PhotoTransferStatus.uploading,
          PhotoTransferStatus.uploaded,
        ]),
      );
      expect(frames.any((r) => r[1] == PhotoTransferStatus.uploading), isTrue);
      expect(frames.any((r) => r[2] == PhotoTransferStatus.uploading), isTrue);

      // Committed: every photo reads uploaded, whatever the last frame said.
      final done = container.read(projectPhotosProvider);
      expect(done.phase, PhotoUploadPhase.completed);
      expect(
        [for (var i = 0; i < 3; i++) done.statusForPhoto(i)],
        List.filled(3, PhotoTransferStatus.uploaded),
      );
    });

    test('the in-flight photo reports its OWN bytes, not the running total',
        () async {
      final engine = _ProgressingEngine([100, 200, 300]);
      final container = _containerWith(
        picker: _StubPicker([
          _photo('/a.jpg', 100),
          _photo('/b.jpg', 200),
          _photo('/c.jpg', 300),
        ]),
        repo: _StubPhotosRepo(),
        engine: engine,
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.pickPhotos();

      // (bytes for the photo in flight, that photo's size) per frame.
      final own = <({int bytes, int size})>[];
      engine.onFrame = () {
        final s = container.read(projectPhotosProvider);
        if (s.uploadedFiles < s.picked.length) {
          own.add((
            bytes: s.activePhotoBytesUploaded,
            size: s.picked[s.uploadedFiles].size,
          ));
        }
      };
      await notifier.upload(name: 'Set');

      // Photo 2's mid frame sits at 200/600 for the SET but 100/200 for itself
      // — subtracting the finished photos is the whole point.
      expect(own.map((f) => f.bytes), contains(100));
      // And a row can never render past 100%: every reading stays inside the
      // photo it belongs to.
      expect(own.every((f) => f.bytes >= 0 && f.bytes <= f.size), isTrue);
    });

    test('a failure marks the photo that was in flight, not the whole set',
        () async {
      final container = _containerWith(
        picker: _StubPicker([
          _photo('/a.jpg', 10),
          _photo('/b.jpg', 20),
          _photo('/c.jpg', 30),
        ]),
        repo: _StubPhotosRepo(
          sessionError: const PhotoUploadException(
            PhotoUploadFailure.offline,
            'You are offline.',
          ),
        ),
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.pickPhotos();
      await notifier.upload(name: 'Set');

      final state = container.read(projectPhotosProvider);
      expect(state.phase, PhotoUploadPhase.failed);
      // Nothing had finalized, so the FIRST photo carries the failure and the
      // rest stay queued — no blanket red over a set that never moved.
      expect(state.statusForPhoto(0), PhotoTransferStatus.failed);
      expect(state.statusForPhoto(1), PhotoTransferStatus.queued);
      expect(state.statusForPhoto(2), PhotoTransferStatus.queued);
    });

    test('an out-of-range index is queued, never a range error', () {
      const empty = ProjectPhotosState();
      expect(empty.statusForPhoto(0), PhotoTransferStatus.queued);
      expect(empty.statusForPhoto(-1), PhotoTransferStatus.queued);
      expect(empty.activePhotoBytesUploaded, 0);
    });
  });

  // ── Where a finished upload leaves the state ──────────────────────────────
  group('upload completion', () {
    test('lands on completed WITHOUT loading the grid', () async {
      final repo = _StubPhotosRepo();
      final container = _containerWith(
        picker: _StubPicker([
          _photo('/a.jpg', 10),
          _photo('/b.jpg', 20),
          _photo('/c.jpg', 30),
        ]),
        repo: repo,
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectPhotosProvider.notifier);
      await notifier.pickPhotos();
      final project = await notifier.upload(name: 'Set');

      expect(project, isNotNull);
      final state = container.read(projectPhotosProvider);
      // `completed`, not `ready`: the artist is not routed to the grid, so a
      // set of presigned thumbnails nobody renders would be a round trip spent
      // on nothing — and a hiccup fetching them would flip a SUCCEEDED upload
      // to failed.
      expect(state.phase, PhotoUploadPhase.completed);
      expect(state.isUploadComplete, isTrue);
      expect(repo.listCalls, 0);
      // The bar reads full on the success screen.
      expect(state.uploadedFiles, 3);
      expect(state.progress, 1.0);
    });
  });
}

// ── Doubles ──────────────────────────────────────────────────────────────────

/// A container wired with fake I/O at every seam the notifier touches: the
/// picker, the photos repository, and the upload FLOW (whose engine is faked,
/// so the real step-3 pairing logic still runs but no bytes move).
ProviderContainer _containerWith({
  required ProjectPhotoPicker picker,
  required _StubPhotosRepo repo,
  bool online = true,
  PhotoSetUploadEngine? engine,
}) {
  final projects = _StubProjectsRepo();
  late final ProviderContainer container;
  container = ProviderContainer(
    overrides: [
      projectPhotoPickerProvider.overrideWithValue(picker),
      projectPhotosRepositoryProvider.overrideWithValue(repo),
      projectsRepositoryProvider.overrideWithValue(projects),
      photoSetUploadFlowFactoryProvider.overrideWithValue(
        () => PhotoSetUploadFlow(
          projects: projects,
          photos: repo,
          isOnline: () => online,
          engineFor: (jobId, bytes) => engine ?? _FakeEngine(),
        ),
      ),
    ],
  );
  // projectPhotosProvider is autoDispose, so without a listener it is collected
  // the moment a test awaits — which an upload does, repeatedly. In the app the
  // Create form stays mounted under the progress screen and holds exactly this
  // subscription; the container has to do the same or it tests a torn-down
  // notifier.
  container.listen(projectPhotosProvider, (_, __) {});
  return container;
}

/// Records the spec the flow handed it, then reports success without moving a
/// byte. Everything above it — the create, the session, the key pairing, the
/// commit — is the REAL code path.
class _FakeEngine implements PhotoSetUploadEngine {
  UploadSessionSpec? received;

  @override
  UploadProgressSource get progress => const NoUploadProgressSource();

  @override
  Future<ResilientUploadOutcome> run(UploadSessionSpec spec) async {
    received = spec;
    return const ResilientUploadOutcome(
      status: ResilientUploadStatus.succeeded,
      attemptsUsed: 1,
    );
  }

  @override
  void cancel() {}
}

/// Reports progress the way the real engine does — file by file, in spec order,
/// counting a file only once it FINALIZES — so the per-photo derivation is
/// exercised against the shape the engine actually emits.
class _ProgressingEngine implements PhotoSetUploadEngine {
  _ProgressingEngine(this.sizes);

  final List<int> sizes;
  final _controller = StreamController<UploadProgress>.broadcast();

  /// Fires after each frame has been delivered, so a test can observe what the
  /// screen would have rendered MID-transfer rather than only the end state.
  void Function()? onFrame;

  @override
  UploadProgressSource get progress => _StreamSource(_controller.stream);

  @override
  Future<ResilientUploadOutcome> run(UploadSessionSpec spec) async {
    final total = sizes.fold<int>(0, (a, b) => a + b);
    var bytes = 0;
    for (var i = 0; i < sizes.length; i++) {
      final half = sizes[i] ~/ 2;
      // Half of file i, then the rest: the mid-file frame is what makes
      // "index == filesUploaded is the one in flight" observable at all.
      for (final (part, finalized) in [(half, false), (sizes[i] - half, true)]) {
        bytes += part;
        _controller.add(UploadProgress(
          status: UploadStatus.inProgress,
          bytesUploaded: bytes,
          totalBytes: total,
          filesUploaded: finalized ? i + 1 : i,
          totalFiles: sizes.length,
        ));
        await _drain();
        onFrame?.call();
      }
    }
    return const ResilientUploadOutcome(
      status: ResilientUploadStatus.succeeded,
      attemptsUsed: 1,
    );
  }

  @override
  void cancel() {}
}

class _StreamSource implements UploadProgressSource {
  const _StreamSource(this._stream);
  final Stream<UploadProgress> _stream;

  @override
  Stream<UploadProgress> watch() => _stream;
}

/// Lets the notifier's progress subscription deliver before the next frame.
Future<void> _drain() async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Only `create` matters here; every other member would be a compile-time
/// obligation with no behaviour, so noSuchMethod carries them.
class _StubProjectsRepo implements ProjectsRepository {
  int creates = 0;

  @override
  Future<Project> create({
    required String name,
    ObjectSize? size,
    CaptureMode? mode,
    String? category,
    ProjectSource source = ProjectSource.capture,
  }) async {
    creates++;
    return Project(
      id: 'p1',
      name: name,
      status: ProjectStatus.draft,
      updatedAt: DateTime.utc(2026, 8, 24),
      source: source,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

XFile _file(String name, Uint8List bytes, {int? size}) =>
    _FakeXFile(name, bytes, size ?? bytes.length);

class _FakeXFile implements XFile {
  _FakeXFile(this._name, this._bytes, this._size);

  final String _name;
  final Uint8List _bytes;
  final int _size;

  @override
  String get name => _name;

  @override
  String get path => '/fake/$_name';

  @override
  Future<int> length() async => _size;

  @override
  Future<Uint8List> readAsBytes() async => _bytes;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBackend implements ProjectPhotoPickerBackend {
  const _FakeBackend(this.files);
  final List<XFile> files;

  @override
  Future<List<XFile>> pickMulti() async => files;
}

PickedProjectPhoto _photo(String path, int size) => PickedProjectPhoto(
      name: path.split('/').last,
      path: path,
      size: size,
      contentType: path.endsWith('.png') ? kContentTypePng : kContentTypeJpeg,
    );

class _StubPicker implements ProjectPhotoPicker {
  _StubPicker(this.photos);
  final List<PickedProjectPhoto> photos;

  @override
  Future<PickedPhotoSet> pickPhotos({int alreadyPicked = 0}) async =>
      PickedPhotoSet(accepted: photos, rejected: const []);
}

class _StubPhotosRepo implements ProjectPhotosRepository {
  _StubPhotosRepo({
    this.slotCount,
    this.sessionError,
    this.commitError,
    this.generateError,
  });

  /// Number of slots to return — defaults to one per requested file.
  final int? slotCount;
  final PhotoUploadException? sessionError;
  final PhotoUploadException? commitError;
  final PhotoUploadException? generateError;

  int sessionsOpened = 0;
  List<int> sessionSizes = const [];
  List<String> sessionTypes = const [];
  List<String> photoKeys = const [
    'uploads/photo_0001.jpg',
    'uploads/photo_0002.jpg',
    'uploads/photo_0003.jpg',
    'uploads/photo_0004.jpg',
    'uploads/photo_0005.jpg',
  ];

  @override
  Future<PhotoUploadSession> openSession({
    required String projectId,
    required List<({String contentType, int size})> files,
    String? idempotencyKey,
  }) async {
    sessionsOpened++;
    if (sessionError != null) throw sessionError!;
    sessionSizes = [for (final f in files) f.size];
    sessionTypes = [for (final f in files) f.contentType];
    final count = slotCount ?? files.length;
    return PhotoUploadSession(
      jobId: 'job1',
      keyPrefix: 'dev/set_p1/job1/',
      slots: [
        for (var i = 1; i <= count; i++)
          PhotoUploadSlot(key: 'dev/set_p1/job1/uploads/photo_000$i.jpg'),
      ],
    );
  }

  @override
  Future<int> commit({required String projectId, required String jobId}) async {
    if (commitError != null) throw commitError!;
    return sessionSizes.length;
  }

  /// Counted so a test can assert the grid is NOT fetched by a finished
  /// upload — the round trip that was deliberately removed.
  int listCalls = 0;

  @override
  Future<List<ProjectPhoto>> listPhotos(String projectId) async {
    listCalls++;
    return [
      for (final key in photoKeys)
        ProjectPhoto(key: key, url: 'https://s3/$key?sig=x', size: 1),
    ];
  }

  @override
  Future<void> deletePhotos({
    required String projectId,
    required List<String> keys,
  }) async {}

  @override
  Future<String> generateModel({
    required String projectId,
    required List<String> keys,
    String? idempotencyKey,
  }) async {
    if (generateError != null) throw generateError!;
    return 'model1';
  }
}
