// lib/application/upload/photo_set_upload_flow.dart
//
// Orchestrates an artist's photo-set upload end to end:
//
//   1. POST /projects                     (source: upload, name)           → id
//   2. POST /projects/:id/photos/session  ({files:[{contentType,size}]})   → jobId + keys
//   3. build an UploadSessionSpec         (picked file  x  server key, BY INDEX)
//   4. ResilientUploadRunner over ChunkedUploadManager
//        → JobsMultipartUploadApi(jobId) → DioS3PartClient  → S3
//   5. POST /projects/:id/photos/commit   ({jobId})
//
// ── THIN BY CONSTRUCTION ────────────────────────────────────────────────────
// This is NOT a second upload engine. It touches neither
// `capture_bundle_packer.dart` nor `capture_manifest_assembler.dart`, and it
// deliberately does not import `upload_flow.dart` — that orchestrator is the
// one genuinely capture-shaped layer (it packs a bundle and assembles a
// manifest, neither of which exists here). Everything below step 3 is the
// EXISTING engine, unchanged, with its own retry, resume and progress.
//
// ── ONLINE ONLY, ON PURPOSE ─────────────────────────────────────────────────
// Step 2 needs the REAL server project id. `ProjectsNotifier.create` falls back
// to an optimistic TEMPORARY local id when offline and enqueues the create on
// the durable offline outbox — which would give this flow a project id that
// does not exist server-side, producing a 404 or, worse, a key prefix built
// from a fake id. So the create here goes through the repository DIRECTLY and
// refuses when the connectivity abstraction reports offline.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/project_photo_picker.dart';
import '../../data/local/upload_progress_box.dart';
import '../../data/repositories/project_photos_repository.dart';
import '../../data/repositories/projects_repository.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_source.dart';
import '../../domain/upload/upload_session_spec.dart';
import '../../platform/connectivity_watcher.dart';
import '../connectivity/connectivity_providers.dart';
import 'chunked_upload_manager.dart';
import 'bytes_part_byte_source.dart';
import 'jobs_multipart_upload_api.dart';
import 'multipart_upload_api.dart';
import 'resilient_upload_runner.dart';
import 'upload_auth_session.dart';
import 'upload_progress_provider.dart';

/// How the whole flow ended.
enum PhotoSetUploadStatus { succeeded, failed, cancelled }

class PhotoSetUploadResult {
  const PhotoSetUploadResult({
    required this.status,
    this.project,
    this.jobId,
    this.photoCount = 0,
    this.failure,
    this.message,
  });

  final PhotoSetUploadStatus status;

  /// The project that was created. Non-null once step 1 succeeded, EVEN on a
  /// later failure — an abandoned upload leaves a real DRAFT project with no
  /// photos, exactly what an abandoned capture leaves today, and the caller
  /// needs its id to let the artist retry into the same project.
  final Project? project;

  final String? jobId;
  final int photoCount;
  final PhotoUploadFailure? failure;

  /// One owner-safe sentence. The server's own when it sent one we trust.
  final String? message;

  bool get isSuccess => status == PhotoSetUploadStatus.succeeded;
}

/// Raised when the session response and the picked set disagree in length.
///
/// Loud rather than lenient ON PURPOSE: the two are paired BY INDEX (the
/// server returns its keys in request order), so a length mismatch would
/// silently upload photo N's bytes to photo M's key — a set that looks fine and
/// is wrong. There is no safe way to continue.
class PhotoKeyPairingError extends StateError {
  PhotoKeyPairingError(int expected, int actual)
      : super('photo session returned $actual keys for $expected files');
}

/// The engine half of the flow, injectable so the flow is testable with fakes.
abstract interface class PhotoSetUploadEngine {
  UploadProgressSource get progress;
  Future<ResilientUploadOutcome> run(UploadSessionSpec spec);
  void cancel();
}

class PhotoSetUploadFlow {
  PhotoSetUploadFlow({
    required ProjectsRepository projects,
    required ProjectPhotosRepository photos,
    required bool Function() isOnline,
    required PhotoSetUploadEngine Function(
      String jobId,
      Map<String, Uint8List> bytesByHandle,
    ) engineFor,
  })  : _projects = projects,
        _photos = photos,
        _isOnline = isOnline,
        _engineFor = engineFor;

  final ProjectsRepository _projects;
  final ProjectPhotosRepository _photos;
  final bool Function() _isOnline;
  /// Builds the engine for one session. Takes the bytes map THIS flow just
  /// built (empty on native, where the engine streams off disk) — the flow
  /// mints the handles, so nothing else can populate it correctly.
  final PhotoSetUploadEngine Function(
    String jobId,
    Map<String, Uint8List> bytesByHandle,
  ) _engineFor;

  PhotoSetUploadEngine? _engine;

  /// The live engine's progress stream, once step 4 has started. Null before
  /// then — the caller renders "preparing…" until it appears.
  UploadProgressSource? get progress => _engine?.progress;

  /// Cancels an in-flight transfer. Reaches the RUNNER (not the manager
  /// directly), so a cancel landing during a between-attempts backoff is not
  /// lost. Local files are retained.
  void cancel() => _engine?.cancel();

  /// Runs the whole flow. Never throws for an expected business case: every
  /// outcome comes back as a [PhotoSetUploadResult] with one owner-safe
  /// sentence, because this drives a full screen rather than a control-flow
  /// decision.
  ///
  /// [existingProject] skips step 1 — used when the artist is retrying into a
  /// project a previous attempt already created (see [PhotoSetUploadResult.project]).
  /// [onEngineReady] fires the instant step 4's engine exists, handing over its
  /// progress feed. A callback rather than a pollable getter because
  /// [UploadProgressSource] is a STREAM contract — the caller subscribes to the
  /// engine's existing feed instead of a second progress shape being invented
  /// for this feature.
  /// [onCommitting] fires when every part is on S3 and step 5 begins, so the
  /// progress screen can say "finishing up" instead of showing a full bar and
  /// an idle-looking pause while the commit round-trips.
  Future<PhotoSetUploadResult> run({
    required String name,
    required List<PickedProjectPhoto> photos,
    Project? existingProject,
    void Function(UploadProgressSource progress)? onEngineReady,
    void Function()? onCommitting,
  }) async {
    if (!_isOnline()) {
      return const PhotoSetUploadResult(
        status: PhotoSetUploadStatus.failed,
        failure: PhotoUploadFailure.offline,
        message: 'You need to be online to upload photos.',
      );
    }

    // ── 1. The project. Straight to the repository: NOT through
    // ProjectsNotifier.create, whose offline branch would hand back a temporary
    // local id (see the file header).
    Project project;
    if (existingProject != null) {
      project = existingProject;
    } else {
      try {
        project = await _projects.create(
          name: name,
          source: ProjectSource.upload,
        );
      } catch (error) {
        return _failed(error, null);
      }
    }

    // ── 2. The session. The server assigns every key; we send no file names.
    PhotoUploadSession session;
    try {
      session = await _photos.openSession(
        projectId: project.id,
        files: [
          for (final photo in photos)
            (contentType: photo.contentType, size: photo.size),
        ],
        idempotencyKey: _randomUuidV4(),
      );
    } catch (error) {
      return _failed(error, project);
    }

    // ── 3. Pair picked file with server key BY INDEX. The session's `files`
    // array is in request order by contract; a length mismatch is fatal.
    if (session.slots.length != photos.length) {
      throw PhotoKeyPairingError(photos.length, session.slots.length);
    }

    final bytesByHandle = <String, Uint8List>{};
    final specFiles = <UploadFileSpec>[];
    for (var i = 0; i < photos.length; i++) {
      final photo = photos[i];
      final key = session.slots[i].key;
      // Native: the real device path — the engine streams each part's range off
      // disk, so 48 photos never sit in RAM. Web: no path exists, so a
      // synthetic handle addresses the bytes held by BytesPartByteSource. The
      // handle is engine-internal and never reaches S3 or a key.
      final handle = photo.path ?? 'photo:$i:$key';
      if (photo.bytes != null) bytesByHandle[handle] = photo.bytes!;
      specFiles.add(UploadFileSpec(path: handle, key: key, size: photo.size));
    }

    // ── 4. The EXISTING engine.
    final engine = _engineFor(session.jobId, bytesByHandle);
    _engine = engine;
    onEngineReady?.call(engine.progress);
    final outcome = await engine.run(
      UploadSessionSpec(sessionId: session.jobId, files: specFiles),
    );

    if (outcome.status == ResilientUploadStatus.cancelled) {
      return PhotoSetUploadResult(
        status: PhotoSetUploadStatus.cancelled,
        project: project,
        jobId: session.jobId,
      );
    }
    if (outcome.status != ResilientUploadStatus.succeeded) {
      return PhotoSetUploadResult(
        status: PhotoSetUploadStatus.failed,
        project: project,
        jobId: session.jobId,
        failure: PhotoUploadFailure.unknown,
        message: 'The upload could not finish. Please try again.',
      );
    }

    // ── 5. Commit. This is what makes the set real: the server verifies each
    // object's size against its own ceiling and flips the job to UPLOADED.
    onCommitting?.call();
    try {
      final count = await _photos.commit(
        projectId: project.id,
        jobId: session.jobId,
      );
      return PhotoSetUploadResult(
        status: PhotoSetUploadStatus.succeeded,
        project: project,
        jobId: session.jobId,
        photoCount: count,
      );
    } catch (error) {
      return _failed(error, project, jobId: session.jobId);
    }
  }

  PhotoSetUploadResult _failed(Object error, Project? project, {String? jobId}) {
    final failure = error is PhotoUploadException
        ? error.failure
        : PhotoUploadFailure.unknown;
    final message = error is PhotoUploadException ? error.message : null;
    return PhotoSetUploadResult(
      status: PhotoSetUploadStatus.failed,
      project: project,
      jobId: jobId,
      failure: failure,
      message: message ?? photoUploadFallbackMessage(failure),
    );
  }
}

/// Production engine: the SAME [ChunkedUploadManager] + [ResilientUploadRunner]
/// pair the capture flow builds, differing only in the byte source.
///
/// ── WHY IT LISTENS TO CONNECTIVITY ──────────────────────────────────────────
/// The manager's `isOnline` gate AUTO-PAUSES rather than burning retries into a
/// dead network: a worker that finds the network gone parks on the pause gate.
/// Only [UploadController.resume] reopens that gate. The CAPTURE flow has two
/// things that call it — the on-screen upload controls and the offline queue's
/// `autoResumeQueued` — but this flow has NEITHER: the photo progress screen
/// offers only Cancel. Without the subscription below, airplane mode mid-upload
/// parked every worker permanently and the transfer hung even after the network
/// came back. [onlineChanges] is the missing edge: it resumes on reconnect.
class RunnerPhotoSetUploadEngine implements PhotoSetUploadEngine {
  RunnerPhotoSetUploadEngine({
    required this.manager,
    required this.runner,
    Stream<bool>? onlineChanges,
  }) : _onlineChanges = onlineChanges;

  final ChunkedUploadManager manager;
  final ResilientUploadRunner runner;

  /// Online/offline edges for the life of ONE run. Null disables auto-resume
  /// (the manager then behaves exactly as it always has).
  final Stream<bool>? _onlineChanges;

  @override
  UploadProgressSource get progress => manager;

  @override
  Future<ResilientUploadOutcome> run(UploadSessionSpec spec) async {
    // Subscribed for the RUN, cancelled with it — no listener outlives the
    // transfer it was opened for.
    final sub = _onlineChanges?.listen((online) {
      // `resume` is a no-op unless the manager is actually paused, so a
      // spurious online event cannot disturb a healthy transfer.
      if (online) manager.resume();
    });
    try {
      return await runner.run(spec);
    } finally {
      await sub?.cancel();
    }
  }

  /// Through the RUNNER, so a cancel during a backoff wait is not lost.
  @override
  void cancel() => runner.cancel();
}

/// Builds the production flow.
///
/// The byte source is chosen per session from what the flow actually collected:
/// EMPTY on native, where every picked photo carries a real path and
/// `FilePartByteSource` re-reads each part's range off disk — which is exactly
/// why a 48-photo set is safe on a phone. Only web, where a picked file has no
/// path, populates the map and gets [BytesPartByteSource].
PhotoSetUploadFlow buildPhotoSetUploadFlow(
  Ref ref, {
  String deviceType = 'mobile',
}) {
  return PhotoSetUploadFlow(
    projects: ref.read(projectsRepositoryProvider),
    photos: ref.read(projectPhotosRepositoryProvider),
    isOnline: () => ref.read(isOnlineProvider),
    engineFor: (jobId, bytes) {
      final manager = ChunkedUploadManager(
        api: JobsMultipartUploadApi(
          dio: ref.read(uploadApiDioProvider),
          jobId: jobId,
        ),
        s3: DioS3PartClient(),
        byteSource: bytes.isEmpty
            ? const FilePartByteSource()
            : BytesPartByteSource(bytes),
        // The SAME durable store the capture flow uses. Without it the engine is
        // stateless, so every auto-retry re-initiated each file and re-sent every
        // part from zero — which is precisely what the runner's own idempotency
        // note promises does not happen. A dropped network on part 300 of a
        // 48-photo set must not cost the first 299.
        store: HiveUploadProgressStore(),
        // Connectivity gate: parts park (auto-pause) instead of burning retries
        // into a dead network. Paired with `onlineChanges` below, which is what
        // un-parks them — this flow has no upload controls to do it by hand.
        isOnline: () => ref.read(isOnlineProvider),
        deviceType: deviceType,
      );
      return RunnerPhotoSetUploadEngine(
        manager: manager,
        runner: ResilientUploadRunner(
          attempt: ManagerUploadAttempt(manager),
          deviceType: deviceType,
        ),
        onlineChanges: ref
            .read(connectivityWatcherProvider)
            .statusStream
            .map((s) => s == AppConnectivityStatus.online),
      );
    },
  );
}

/// Builds ONE flow per upload attempt.
///
/// A factory rather than a `Provider<PhotoSetUploadFlow>` because a flow holds
/// per-run state (the live engine it must be able to cancel), so a second
/// upload must not inherit the first one's. Overridden in tests to substitute a
/// fake engine — which is what keeps the pairing logic in step 3 testable
/// without a network.
final photoSetUploadFlowFactoryProvider = Provider<PhotoSetUploadFlow Function()>(
  (ref) => () => buildPhotoSetUploadFlow(ref),
);

/// RFC-4122 v4 UUID from a CSPRNG — the session's Idempotency-Key.
String _randomUuidV4() {
  final rng = Random.secure();
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = rng.nextInt(256);
  }
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
