// lib/platform/capture_ports/capture_storage_port.dart
//
// PORT: "where do captured frames live, and how much space are they using".
//
// Native talks to the app-scoped capture tree
// (`/recapture/{projectId}/{jobId}/images/{level}/`) over the
// `capture_storage` MethodChannel. Web talks to an IndexedDB database with the
// SAME hierarchy encoded in each key (capture_ports/web_capture_store.dart).
//
// The whole native surface is here — usage accounting, incomplete-job listing,
// scoped deletion and the active-job delete guard — because the project
// deletion cleanup hook depends on all of it, and a web build that answered
// "0 bytes, nothing to delete" would silently leak every capture a user ever
// took in that browser.
//
// Four members are additive and exist because a browser has no ambient session
// the way CameraX does: [setActiveScope], [setJobActive], [markJobComplete] and
// [readFrameBytes]. On native the first three are no-ops (the native manager
// derives all of it itself) and [readFrameBytes] reads the real file.
import 'dart:typed_data';

import 'capture_storage_models.dart';

export 'capture_storage_models.dart';

/// Capture-storage accounting and lifecycle.
abstract interface class CaptureStoragePort {
  /// Usable bytes for capture data (a volume's free space natively; the
  /// remaining `navigator.storage.estimate()` quota on web).
  Future<int> freeSpaceBytes();

  /// Frame count + bytes for a project, a job, or a level.
  Future<StorageUsage> usage(String projectId, {String? jobId, String? level});

  Future<List<String>> listProjects();

  Future<List<String>> listJobs(String projectId);

  /// Jobs interrupted mid-capture (resumable or cleanable).
  Future<List<IncompleteJob>> listIncompleteJobs();

  Future<StorageDeleteResult> deleteLevel(
    String projectId,
    String jobId,
    String level, {
    bool force,
  });

  Future<StorageDeleteResult> deleteJob(
    String projectId,
    String jobId, {
    bool force,
  });

  Future<StorageDeleteResult> deleteProject(String projectId, {bool force});

  Future<PurgeResult> purgeProjectCaptureData(String projectId, {bool force});

  Future<SweepResult> sweepOrphanedCaptureData(
    List<String> knownProjectIds, {
    bool force,
  });

  /// Tells the storage layer which project/job/level the NEXT captured frames
  /// belong to. A no-op natively (CameraX writes into the session directory the
  /// native manager already owns); on web it is what gives an IndexedDB key its
  /// `{projectId}/{jobId}/{level}/` prefix, and therefore what makes scoped
  /// usage and the project-deletion purge work at all.
  void setActiveScope({
    required String projectId,
    required String jobId,
    required String level,
  });

  /// Marks a job as actively capturing. The delete guard reads this — a job
  /// left active is what makes a delete return `active_job`. No-op natively.
  Future<void> setJobActive(
    String projectId,
    String jobId, {
    required bool active,
  });

  /// Records that a job's manifest was finalized, so it stops being reported as
  /// incomplete. No-op natively (the native side writes the manifest marker).
  Future<void> markJobComplete(String projectId, String jobId);

  /// Resolves a `CapturedFrame.path` to its bytes — a real file read natively,
  /// an IndexedDB lookup on web. Null when the frame is gone.
  Future<Uint8List?> readFrameBytes(String path);
}
