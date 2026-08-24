// lib/application/projects/project_photos_notifier.dart
//
// State for the artist photo-upload flow and the photo grid that follows it.
//
// PURE STATE. Every network call goes through [ProjectPhotosRepository] or
// [PhotoSetUploadFlow]; no Dio type and no response envelope appears here
// (AGENTS.md: notifiers hold state and call repositories).
//
// The machine:
//
//   idle → picking → creating → uploading(progress) → committing → completed
//                                    ↘ failed(reason) ↗
//
// `completed` is TERMINAL for one upload run: every photo is on S3 and the
// project is real. It is deliberately NOT `ready` — the artist is not sent to
// the grid when an upload finishes (see PhotoUploadProgressScreen), so the
// screen that owns the run needs a state that means "this transfer is done"
// without also claiming a grid has been loaded.
//
// `ready` is where the grid lives: it holds the uploaded set, the artist's
// 3–4 selection, and the Generate action. It is reached by [refreshPhotos],
// which the photo screen calls when the artist opens the project later.
//
// ── PER-PHOTO STATUS ────────────────────────────────────────────────────────
// [ProjectPhotosState.statusForPhoto] resolves one photo's live status from the
// engine's AGGREGATE `filesUploaded` count. That derivation is sound ONLY
// because [ChunkedUploadManager.start] walks `spec.files` STRICTLY
// SEQUENTIALLY, in order, incrementing the count as each file finalizes — so
// index < count is done, index == count is the one in flight, and the rest are
// queued. Pinned by a test; if files ever upload concurrently, that test fails
// rather than this screen quietly lying about which photo is moving.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/project_photo_picker.dart';
import '../../data/repositories/project_photos_repository.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/upload_progress.dart';
import '../upload/photo_set_upload_flow.dart';

/// Fewest / most photos one generation may be built from. Mirrors the
/// backend's MIN_SELECTED_PHOTOS / MAX_SELECTED_PHOTOS — hand-synced.
const int kMinSelectedPhotos = 3;
const int kMaxSelectedPhotos = 4;

enum PhotoUploadPhase {
  idle,
  picking,
  creating,
  uploading,
  committing,

  /// Terminal for ONE upload run: every photo committed, project created.
  completed,
  ready,
  generating,
  failed,
}

/// One photo's live transfer status, as the progress screen renders it.
enum PhotoTransferStatus { queued, uploading, uploaded, failed }

@immutable
class ProjectPhotosState {
  const ProjectPhotosState({
    this.phase = PhotoUploadPhase.idle,
    this.picked = const [],
    this.rejected = const [],
    this.photos = const [],
    this.selectedKeys = const {},
    this.project,
    this.jobId,
    this.uploadedBytes = 0,
    this.totalBytes = 0,
    this.uploadedFiles = 0,
    this.message,
    this.failure,
    this.generatedModelId,
  });

  final PhotoUploadPhase phase;

  /// What the artist picked, in the order they will upload. The set's order.
  final List<PickedProjectPhoto> picked;

  /// Files dropped at pick time, each with its own reason — never silent.
  final List<RejectedProjectPhoto> rejected;

  /// The committed set, as the grid renders it (presigned thumbnails).
  final List<ProjectPhoto> photos;

  /// The artist's hand-picked generation selection (job-relative keys).
  final Set<String> selectedKeys;

  final Project? project;
  final String? jobId;

  final int uploadedBytes;
  final int totalBytes;

  /// Photos the engine has FINALIZED, straight off its progress feed. Because
  /// files upload in order this doubles as a cursor: `picked[uploadedFiles]` is
  /// the photo currently moving. See the file header.
  final int uploadedFiles;

  /// One owner-safe sentence for the current phase. Never a code.
  final String? message;
  final PhotoUploadFailure? failure;

  /// Set once a generation has been accepted.
  final String? generatedModelId;

  bool get canUpload =>
      picked.length >= kProjectPhotoMinCount && phase == PhotoUploadPhase.idle;

  bool get canGenerate =>
      selectedKeys.length >= kMinSelectedPhotos &&
      selectedKeys.length <= kMaxSelectedPhotos &&
      phase == PhotoUploadPhase.ready;

  bool get isBusy => switch (phase) {
        PhotoUploadPhase.picking ||
        PhotoUploadPhase.creating ||
        PhotoUploadPhase.uploading ||
        PhotoUploadPhase.committing ||
        PhotoUploadPhase.generating =>
          true,
        _ => false,
      };

  double get progress =>
      totalBytes <= 0 ? 0 : (uploadedBytes / totalBytes).clamp(0.0, 1.0);

  /// True once an upload run has finished successfully.
  bool get isUploadComplete => phase == PhotoUploadPhase.completed;

  /// One picked photo's live transfer status.
  ///
  /// Derived from [uploadedFiles], which is only a valid per-photo cursor
  /// because the engine uploads files sequentially in order — see the file
  /// header. An out-of-range index is [PhotoTransferStatus.queued] rather than
  /// a throw: this drives a list builder, and a range error there would take
  /// down the screen mid-upload.
  PhotoTransferStatus statusForPhoto(int index) {
    if (index < 0 || index >= picked.length) return PhotoTransferStatus.queued;
    // Commit succeeded, so every photo is on S3 regardless of what the last
    // progress frame said.
    if (phase == PhotoUploadPhase.completed ||
        phase == PhotoUploadPhase.committing) {
      return PhotoTransferStatus.uploaded;
    }
    if (index < uploadedFiles) return PhotoTransferStatus.uploaded;
    if (index > uploadedFiles) return PhotoTransferStatus.queued;
    // index == uploadedFiles — the photo the engine is on.
    return switch (phase) {
      PhotoUploadPhase.uploading => PhotoTransferStatus.uploading,
      PhotoUploadPhase.failed => PhotoTransferStatus.failed,
      _ => PhotoTransferStatus.queued,
    };
  }

  /// Bytes confirmed for the photo currently in flight, so its own row shows a
  /// real percentage rather than an indeterminate spinner. Clamped to the
  /// photo's size — the engine's byte count is monotonic but the subtraction
  /// crosses two frames, so a transient over-report must not render >100%.
  int get activePhotoBytesUploaded {
    if (uploadedFiles < 0 || uploadedFiles >= picked.length) return 0;
    final done = picked
        .take(uploadedFiles)
        .fold<int>(0, (sum, p) => sum + p.size);
    return (uploadedBytes - done).clamp(0, picked[uploadedFiles].size);
  }

  ProjectPhotosState copyWith({
    PhotoUploadPhase? phase,
    List<PickedProjectPhoto>? picked,
    List<RejectedProjectPhoto>? rejected,
    List<ProjectPhoto>? photos,
    Set<String>? selectedKeys,
    Project? project,
    String? jobId,
    int? uploadedBytes,
    int? totalBytes,
    int? uploadedFiles,
    String? message,
    PhotoUploadFailure? failure,
    String? generatedModelId,
    bool clearMessage = false,
  }) {
    return ProjectPhotosState(
      phase: phase ?? this.phase,
      picked: picked ?? this.picked,
      rejected: rejected ?? this.rejected,
      photos: photos ?? this.photos,
      selectedKeys: selectedKeys ?? this.selectedKeys,
      project: project ?? this.project,
      jobId: jobId ?? this.jobId,
      uploadedBytes: uploadedBytes ?? this.uploadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      uploadedFiles: uploadedFiles ?? this.uploadedFiles,
      message: clearMessage ? null : (message ?? this.message),
      failure: clearMessage ? null : (failure ?? this.failure),
      generatedModelId: generatedModelId ?? this.generatedModelId,
    );
  }
}

class ProjectPhotosNotifier extends StateNotifier<ProjectPhotosState> {
  ProjectPhotosNotifier(this._ref) : super(const ProjectPhotosState());

  final Ref _ref;
  PhotoSetUploadFlow? _flow;

  // ── Picking ────────────────────────────────────────────────────────────────

  Future<void> pickPhotos() async {
    if (state.isBusy) return;
    state = state.copyWith(phase: PhotoUploadPhase.picking, clearMessage: true);
    try {
      final result = await _ref
          .read(projectPhotoPickerProvider)
          .pickPhotos(alreadyPicked: state.picked.length);
      state = state.copyWith(
        phase: PhotoUploadPhase.idle,
        picked: [...state.picked, ...result.accepted],
        rejected: result.rejected,
      );
    } catch (_) {
      state = state.copyWith(
        phase: PhotoUploadPhase.idle,
        message: "We couldn't open your photos. Please try again.",
        failure: PhotoUploadFailure.unknown,
      );
    }
  }

  /// Removes one picked photo BEFORE the upload starts. After the upload,
  /// removal goes through [deletePhoto] (a server-side soft delete).
  void removePicked(int index) {
    if (index < 0 || index >= state.picked.length) return;
    final next = [...state.picked]..removeAt(index);
    state = state.copyWith(picked: next, rejected: const []);
  }

  // ── Upload ─────────────────────────────────────────────────────────────────

  /// Creates the project, uploads the set and commits it.
  ///
  /// Returns the created project on success so the caller can route with a real
  /// server id. On failure the project may STILL exist (a crash between create
  /// and commit leaves a DRAFT project with no photos, by design) — it is on
  /// [ProjectPhotosState.project] either way.
  Future<Project?> upload({required String name}) async {
    if (state.isBusy || state.picked.length < kProjectPhotoMinCount) return null;

    state = state.copyWith(
      phase: PhotoUploadPhase.creating,
      totalBytes: state.picked.fold<int>(0, (sum, p) => sum + p.size),
      uploadedBytes: 0,
      uploadedFiles: 0,
      clearMessage: true,
    );

    // Through the factory provider so a test can substitute a fake engine. The
    // flow owns the byte-source choice: it mints the handles, so only it can
    // pair them with bytes. Native never populates that map.
    final flow = _flow = _ref.read(photoSetUploadFlowFactoryProvider)();

    // Progress rides the engine's EXISTING UploadProgressSource — subscribed
    // the moment step 4 creates it, never a second progress shape.
    StreamSubscription<UploadProgress>? progressSub;

    try {
      final result = await flow.run(
        name: name,
        photos: state.picked,
        existingProject: state.project,
        onEngineReady: (source) {
          progressSub = source.watch().listen(_onProgress);
        },
        // Every part is on S3; the commit is the last round trip. Surfaced so
        // the screen shows "finishing up" rather than a full bar that appears
        // to have stalled.
        onCommitting: () {
          if (!mounted) return;
          state = state.copyWith(
            phase: PhotoUploadPhase.committing,
            uploadedFiles: state.picked.length,
            uploadedBytes: state.totalBytes,
          );
        },
      );

      if (result.isSuccess) {
        // TERMINAL, and deliberately NOT a refreshPhotos() call. The artist is
        // not routed to the grid when an upload finishes, so fetching a set of
        // presigned thumbnails nobody is about to render would be a round trip
        // spent on nothing — and a hiccup in that fetch would flip a SUCCEEDED
        // upload to `failed`. The photo screen loads the grid itself, with
        // fresh URLs, whenever the artist opens the project.
        state = state.copyWith(
          phase: PhotoUploadPhase.completed,
          project: result.project,
          jobId: result.jobId,
          uploadedFiles: state.picked.length,
          uploadedBytes: state.totalBytes,
        );
        return result.project;
      }

      state = state.copyWith(
        phase: result.status == PhotoSetUploadStatus.cancelled
            ? PhotoUploadPhase.idle
            : PhotoUploadPhase.failed,
        project: result.project,
        jobId: result.jobId,
        message: result.message,
        failure: result.failure,
      );
      return null;
    } finally {
      await progressSub?.cancel();
      _flow = null;
    }
  }

  void _onProgress(UploadProgress snapshot) {
    if (!mounted) return;
    // A late frame must not drag a finished run back into `uploading` — the
    // engine's stream replays its last snapshot to new subscribers, and commit
    // resolves after the final emission.
    if (state.phase == PhotoUploadPhase.completed ||
        state.phase == PhotoUploadPhase.committing) {
      return;
    }
    state = state.copyWith(
      phase: PhotoUploadPhase.uploading,
      uploadedBytes: snapshot.bytesUploaded,
      totalBytes:
          snapshot.totalBytes > 0 ? snapshot.totalBytes : state.totalBytes,
      uploadedFiles: snapshot.filesUploaded,
    );
  }

  /// Cancels an in-flight transfer. Local files are retained.
  void cancelUpload() => _flow?.cancel();

  // ── Grid ───────────────────────────────────────────────────────────────────

  /// Loads (or reloads) the project's uploaded set. Presigned URLs expire
  /// within the hour, so this is also the refresh a stale grid needs.
  Future<void> refreshPhotos(String projectId) async {
    try {
      final photos =
          await _ref.read(projectPhotosRepositoryProvider).listPhotos(projectId);
      state = state.copyWith(
        phase: PhotoUploadPhase.ready,
        photos: photos,
        // Drop any selection naming a photo that is no longer there.
        selectedKeys:
            state.selectedKeys.where((k) => photos.any((p) => p.key == k)).toSet(),
        clearMessage: true,
      );
    } on PhotoUploadException catch (error) {
      state = state.copyWith(
        phase: PhotoUploadPhase.failed,
        message: error.message ?? photoUploadFallbackMessage(error.failure),
        failure: error.failure,
      );
    }
  }

  /// Toggles one photo in the generation selection, capped at
  /// [kMaxSelectedPhotos]: a tap that would exceed the cap is a no-op, so the
  /// UI never has to show an error for it.
  void toggleSelection(String key) {
    final next = {...state.selectedKeys};
    if (!next.remove(key)) {
      if (next.length >= kMaxSelectedPhotos) return;
      next.add(key);
    }
    state = state.copyWith(selectedKeys: next);
  }

  /// Soft-deletes one photo out of the set (a move to `deleted/` server-side).
  Future<void> deletePhoto(String projectId, String key) async {
    if (state.isBusy) return;
    try {
      await _ref
          .read(projectPhotosRepositoryProvider)
          .deletePhotos(projectId: projectId, keys: [key]);
      await refreshPhotos(projectId);
    } on PhotoUploadException catch (error) {
      state = state.copyWith(
        message: error.message ?? photoUploadFallbackMessage(error.failure),
        failure: error.failure,
      );
    }
  }

  // ── Generate ───────────────────────────────────────────────────────────────

  /// Asks for a 3D model from the current selection. THIS is the step that
  /// spends credits — the server keeps its rate window and idempotency guard
  /// regardless of what this does.
  Future<String?> generate(String projectId) async {
    if (!state.canGenerate) return null;
    state = state.copyWith(phase: PhotoUploadPhase.generating, clearMessage: true);
    try {
      final modelId = await _ref.read(projectPhotosRepositoryProvider).generateModel(
            projectId: projectId,
            keys: state.selectedKeys.toList(),
          );
      state = state.copyWith(
        phase: PhotoUploadPhase.ready,
        generatedModelId: modelId,
      );
      return modelId;
    } on PhotoUploadException catch (error) {
      state = state.copyWith(
        phase: PhotoUploadPhase.ready,
        message: error.message ?? photoUploadFallbackMessage(error.failure),
        failure: error.failure,
      );
      return null;
    }
  }
}

/// One notifier per screen instance — the state is a screen's working set, not
/// app-wide truth, so it is deliberately auto-disposed.
final projectPhotosProvider =
    StateNotifierProvider.autoDispose<ProjectPhotosNotifier, ProjectPhotosState>(
  ProjectPhotosNotifier.new,
);
