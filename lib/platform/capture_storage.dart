// lib/platform/capture_storage.dart
//
// Capture-storage entry point. Historically this file WAS the native
// MethodChannel wrapper for the app-scoped capture backbone
// (`/recapture/{projectId}/{jobId}/images/{level}/`); it is now the
// platform-agnostic face of [CaptureStoragePort]
// (capture_ports/capture_storage_port.dart), which resolves to:
//
//   • native → that same `capture_storage` channel, unchanged;
//   • web    → an IndexedDB database keyed by the SAME hierarchy
//     (capture_ports/web_capture_store.dart), so accounting (counts/bytes),
//     incomplete-job listing, scoped deletion and — critically — the P1
//     project-deletion cleanup hook all behave identically in a browser.
//
// Dart uses this for accounting, free-space checks, incomplete-job listing, and
// deletion. Frame path allocation + writing stay on the platform side (the
// native burst task, or the web still-capture port).
// Channel: com.mayasabhaxr.recapture/capture_storage

import 'package:flutter/services.dart';

import 'capture_ports/capture_storage_port.dart';
import 'capture_ports/capture_storage_port_stub.dart'
    if (dart.library.io) 'capture_ports/capture_storage_port_io.dart'
    if (dart.library.js_interop) 'capture_ports/capture_storage_port_web.dart';

export 'capture_ports/capture_storage_models.dart'
    show
        StorageUsage,
        IncompleteJob,
        StorageDeleteResult,
        PurgeResult,
        SweepResult;

/// Dart entry point to the capture storage manager.
class CaptureStorageClient {
  CaptureStorageClient([MethodChannel? channel])
      : _port = createCaptureStoragePort(channel);

  final CaptureStoragePort _port;

  /// Usable bytes for capture data (volume free space natively; the remaining
  /// `navigator.storage.estimate()` quota on web) — for pre-burst space checks.
  Future<int> freeSpaceBytes() => _port.freeSpaceBytes();

  /// Frame count + bytes for a project, a job (`jobId`), or a level (`jobId`+`level`).
  Future<StorageUsage> usage(
    String projectId, {
    String? jobId,
    String? level,
  }) =>
      _port.usage(projectId, jobId: jobId, level: level);

  Future<List<String>> listProjects() => _port.listProjects();

  Future<List<String>> listJobs(String projectId) => _port.listJobs(projectId);

  /// Jobs interrupted mid-capture (resumable or cleanable).
  Future<List<IncompleteJob>> listIncompleteJobs() =>
      _port.listIncompleteJobs();

  Future<StorageDeleteResult> deleteLevel(
    String projectId,
    String jobId,
    String level, {
    bool force = false,
  }) =>
      _port.deleteLevel(projectId, jobId, level, force: force);

  Future<StorageDeleteResult> deleteJob(
    String projectId,
    String jobId, {
    bool force = false,
  }) =>
      _port.deleteJob(projectId, jobId, force: force);

  /// Deletes a project's entire capture tree — the P1 project-deletion cleanup
  /// hook. Guarded against active jobs unless [force].
  Future<StorageDeleteResult> deleteProject(
    String projectId, {
    bool force = false,
  }) =>
      _port.deleteProject(projectId, force: force);

  /// Purges a project's entire local capture data — the project-deletion cleanup
  /// hook. Reconciled with P1's soft delete as purge-on-delete (Option A): a
  /// restored project recovers its server record but NOT these local capture
  /// images. Guarded against an active capture job (`refused`) unless [force];
  /// idempotent (`noop` when already gone); reports `partial` + the surviving
  /// paths if some files are locked (native only — IndexedDB has no per-file
  /// locking, so the web port never returns `partial`).
  Future<PurgeResult> purgeProjectCaptureData(
    String projectId, {
    bool force = false,
  }) =>
      _port.purgeProjectCaptureData(projectId, force: force);

  /// Optional orphan sweep: purges capture data for projects NOT in
  /// [knownProjectIds] (left behind by a project deleted while the app was off).
  /// Applies the same guards/policy as a single purge.
  Future<SweepResult> sweepOrphanedCaptureData(
    List<String> knownProjectIds, {
    bool force = false,
  }) =>
      _port.sweepOrphanedCaptureData(knownProjectIds, force: force);

  /// Declares which project/job/level the NEXT captured frames belong to.
  ///
  /// A no-op natively (CameraX writes into the session directory the native
  /// manager owns). On web it is what scopes each IndexedDB key, and therefore
  /// what makes usage accounting and the project purge correct — call it when a
  /// capture level session starts.
  void setActiveScope({
    required String projectId,
    required String jobId,
    required String level,
  }) =>
      _port.setActiveScope(
        projectId: projectId,
        jobId: jobId,
        level: level,
      );

  /// Marks a job as actively capturing — what makes a scoped delete return
  /// `active_job`. No-op natively.
  Future<void> setJobActive(
    String projectId,
    String jobId, {
    required bool active,
  }) =>
      _port.setJobActive(projectId, jobId, active: active);

  /// Records that a job's manifest was finalized (it stops being reported as
  /// incomplete). No-op natively.
  Future<void> markJobComplete(String projectId, String jobId) =>
      _port.markJobComplete(projectId, jobId);

  /// Resolves a `CapturedFrame.path` to its bytes — a file read natively, an
  /// IndexedDB lookup on web. Null when the frame is gone.
  Future<Uint8List?> readFrameBytes(String path) => _port.readFrameBytes(path);
}
