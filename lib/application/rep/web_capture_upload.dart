// lib/application/rep/web_capture_upload.dart
//
// Turning six in-memory browser photos into a QUEUED job, over the SAME
// pipeline the phone uses.
//
// ── IT REUSES THE ENGINE, IT DOES NOT COPY IT ───────────────────────────────
// `POST /projects` → `POST /jobs` → per-file presigned multipart →
// `POST /jobs/:id/finalize` is exactly `upload_flow.dart`'s sequence, run
// through the same `ChunkedUploadManager`, the same `JobsMultipartUploadApi`
// and the same `DioUploadJobsBackend`. A second upload implementation is the
// thing this file exists to avoid: retry, part sizing, ETag handling and the
// finalize contract are subtle, already correct, and already tested.
//
// ONE seam does the whole job — [ChunkedUploadManager] takes its
// `PartByteSource` by injection, and the only reason the phone's is
// disk-backed is that its photos are on disk. Ours are in memory, so
// [_MemoryPartByteSource] answers from a map and nothing else changes.
//
// ── WHY THE UPLOAD IS `meshy`, NOT `full` ───────────────────────────────────
// Not a downgrade chosen for the browser's sake — it is the mode that already
// describes this capture. `CaptureMode.meshy` is defined as "ONE ring of 6,
// shutter only" (capture_mode.dart), which is the browser flow exactly: six
// manual shots around a single eye ring. `full` would claim 48 photos across
// three rings and be a lie in the manifest.
//
// The one rule of meshy this flow CANNOT honour is the hard tilt gate. On a
// phone that gate is enforced even when the sensors are missing, on the
// argument that a sensor-less device "cannot meet the guarantee" and should be
// locked out. A browser is permanently in that state, so the gate is replaced
// by INSTRUCTION on the capture screen rather than enforcement here. The
// manifest tells the truth about it: every orientation and quality field is
// null, because nothing measured them.
//
// ── WHAT NULL POSES MEAN DOWNSTREAM ─────────────────────────────────────────
// `ManifestPhoto` already declares blurScore / meanLuminance / yawDegrees /
// pitchDegrees as NULLABLE, and the manifest doc's own words are that "a null
// pose stays a reserved null" — so this is a shape the format anticipated, not
// one bent to fit. `POST /jobs/:id/finalize` verifies only that the manifest
// object exists and that the uploaded object count matches; it does not read
// poses. Meshy's model selector picks the best 4 of the 6 from the images
// themselves.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/config/config_notifier.dart';
import '../../application/upload/chunked_upload_manager.dart';
import '../../application/upload/jobs_multipart_upload_api.dart';
import '../../application/upload/multipart_upload_api.dart';
import '../../application/upload/upload_auth_session.dart';
import '../../application/upload/upload_jobs_backend.dart';
import '../../domain/upload/capture_manifest.dart';
import '../../domain/upload/upload_session_spec.dart';

/// One photo the browser produced, with the ring position the screen asked for.
class WebCapturePhoto {
  const WebCapturePhoto({required this.segmentIndex, required this.bytes});

  /// 0..5 — which of the six eye-ring positions the rep was asked to stand at.
  ///
  /// ASKED FOR, NOT MEASURED. Nothing verifies the rep actually moved; there is
  /// no yaw sensor to verify it with. It is recorded because the ORDER still
  /// carries real information (the shots are a sequence around the dish), and
  /// an index the reconstruction can ignore is better than one it cannot see.
  final int segmentIndex;

  final Uint8List bytes;
}

/// What the caller gets back once the job is queued.
class WebCaptureUploadResult {
  const WebCaptureUploadResult({required this.projectId, required this.jobId});

  final String projectId;
  final String jobId;
}

/// A [PartByteSource] over bytes already in memory.
///
/// `path` here is a KEY, not a filename — the engine only ever passes it back
/// to us, so a stable synthetic string is all it has to be. The disk-backed
/// implementation returns 0 for a missing file rather than throwing, and this
/// one matches that so the engine's accounting behaves identically.
class _MemoryPartByteSource implements PartByteSource {
  const _MemoryPartByteSource(this._files);

  final Map<String, Uint8List> _files;

  @override
  int fileSize(String path) => _files[path]?.length ?? 0;

  @override
  Stream<List<int>> read(String path, int offset, int length) {
    final bytes = _files[path];
    if (bytes == null) return const Stream<List<int>>.empty();
    final end = (offset + length).clamp(0, bytes.length);
    if (offset >= end) return const Stream<List<int>>.empty();
    // One chunk: a part is a few MB at most and it is already resident, so
    // splitting it further would add copies without saving a byte of peak
    // memory.
    return Stream<List<int>>.value(
      Uint8List.sublistView(bytes, offset, end),
    );
  }
}

/// Uploads [photos] as a new project + queued job, and resolves once the
/// backend reports QUEUED.
///
/// AN INTERFACE, mirroring [UploadJobsBackend] next door and for the same
/// reason: the screen that drives this cannot run in a VM test against a real
/// Dio, and a concrete class would have made the six-shot flow assertable only
/// in a browser. Tests substitute a recorder; production gets [DioWebCaptureUploader].
abstract interface class WebCaptureUploader {
  /// Throws whatever the underlying Dio / engine throws; the calling screen
  /// maps it to its own words, the same way every other rep screen does.
  Future<WebCaptureUploadResult> upload({
    required String projectName,
    required List<WebCapturePhoto> photos,
    void Function(int sent, int total)? onProgress,
  });
}

/// The real one: the shared upload engine, driven from memory.
class DioWebCaptureUploader implements WebCaptureUploader {
  DioWebCaptureUploader(this._ref);

  final Ref _ref;

  @override
  Future<WebCaptureUploadResult> upload({
    required String projectName,
    required List<WebCapturePhoto> photos,
    void Function(int sent, int total)? onProgress,
  }) async {
    final dio = _ref.read(uploadApiDioProvider);
    final backend = DioUploadJobsBackend(dio);

    // `manual` is the PROJECT's mode (how shots are triggered) and is a
    // different axis from the JOB's capture mode below — guided/manual describes
    // the shutter, full/meshy describes how much of the object is covered.
    // Manual is literally true here: the rep taps for every frame.
    final projectId = await backend.createProject(
      name: projectName,
      size: 'medium',
      mode: 'manual',
    );

    // +1 for the manifest — the count finalize cross-checks against S3.
    final job = await backend.createJob(
      projectId: projectId,
      objectSize: 'medium',
      captureVariant: 'with_bottom',
      expectedFilesCount: photos.length + 1,
      idempotencyKey: 'web-$projectId-${photos.length}',
      captureMode: 'meshy',
    );

    // ── Lay the objects out under the job's prefix ──────────────────────────
    // `<keyPrefix>images/EYE/<n>.jpg`, mirroring the phone bundle's layout so
    // anything downstream that walks the prefix finds the same shape. The
    // server rejects any key that escapes keyPrefix, so this is not a free
    // choice.
    final files = <String, Uint8List>{};
    final specs = <UploadFileSpec>[];
    final manifestPhotos = <ManifestPhoto>[];

    for (var i = 0; i < photos.length; i++) {
      final photo = photos[i];
      final name = 'web_${i.toString().padLeft(2, '0')}';
      final relPath = 'images/EYE/$name.jpg';
      final sourceKey = 'mem://$relPath';

      files[sourceKey] = photo.bytes;
      specs.add(UploadFileSpec(
        path: sourceKey,
        key: '${job.keyPrefix}$relPath',
        size: photo.bytes.length,
      ));

      manifestPhotos.add(ManifestPhoto(
        photoId: name,
        levelCode: 'A',
        levelId: 'mid',
        imagePath: relPath,
        verdict: 'accepted',
        // The browser has no camera-aligned sensor clock, so this is wall time
        // in ns. It is used as an ORDERING key, and wall time orders these six
        // correctly; it is not claimed to be alignable with anything.
        captureTimestampNs:
            DateTime.now().microsecondsSinceEpoch * 1000 + i,
        segmentIndex: photo.segmentIndex,
        // Every one of these stays null on purpose — see the header. Writing a
        // zero would be indistinguishable from a measured zero.
      ));
    }

    final config = _ref.read(captureConfigProvider);
    final manifest = buildCaptureManifest(
      session: ManifestSession(
        projectId: projectId,
        jobId: job.jobId,
        captureSessionId: job.jobId,
        startedAtIso: DateTime.now().toUtc().toIso8601String(),
        completedAtIso: DateTime.now().toUtc().toIso8601String(),
      ),
      // "web" is not one of the platform strings the phone emits
      // ("android"/"ios"), and that is the point: a reader of this manifest
      // should be able to tell at a glance that no IMU existed.
      device: const ManifestDevice(platform: 'web'),
      config: config,
      levels: [
        ManifestLevel(
          levelCode: 'A',
          levelId: 'mid',
          segmentCount: photos.length,
          filledCount: photos.length,
          coveragePct: 100,
          complete: true,
        ),
      ],
      photos: manifestPhotos,
      captureModeId: 'meshy',
    );

    final manifestBytes =
        Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
    const manifestSourceKey = 'mem://capture_manifest.json';
    files[manifestSourceKey] = manifestBytes;
    specs.add(UploadFileSpec(
      path: manifestSourceKey,
      key: job.manifestKey,
      size: manifestBytes.length,
    ));

    // ── The transfer, on the shared engine ─────────────────────────────────
    final engine = ChunkedUploadManager(
      api: JobsMultipartUploadApi(dio: dio, jobId: job.jobId),
      s3: DioS3PartClient(Dio()),
      byteSource: _MemoryPartByteSource(files),
      deviceType: 'web',
    );

    final total = specs.fold<int>(0, (sum, s) => sum + s.size);
    final progressSub = onProgress == null
        ? null
        : engine.watch().listen(
            (p) => onProgress(p.bytesUploaded, total),
          );

    try {
      await engine.start(
        UploadSessionSpec(sessionId: job.jobId, files: specs),
      );
    } finally {
      await progressSub?.cancel();
    }

    // QUEUED is the only success. Anything else means the objects landed but
    // the job will never be processed, which must not read as a finished dish.
    final state = await backend.finalizeJob(
      jobId: job.jobId,
      reportedFilesCount: specs.length,
    );
    if (state.toUpperCase() != 'QUEUED') {
      throw StateError('finalize returned $state, expected QUEUED');
    }

    return WebCaptureUploadResult(projectId: projectId, jobId: job.jobId);
  }
}

final webCaptureUploaderProvider =
    Provider<WebCaptureUploader>(DioWebCaptureUploader.new);
