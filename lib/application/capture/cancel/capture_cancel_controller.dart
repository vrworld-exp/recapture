// lib/application/capture/cancel/capture_cancel_controller.dart
//
// The seam the "Cancel → Keep as Draft" flow signals for the two DATA operations
// that back the confirmation's outcomes: persisting the session as a resumable
// draft (Keep as Draft) and deleting the in-progress session/captures (Discard).
// It uses ONLY existing save/cleanup APIs — it introduces no new persistence
// schema and owns no upload mechanics.
//
// Like the upload controller/progress seams, this is an interface with a real
// default plus a no-op stand-in, so widget tests inject a fake that records the
// calls and can simulate a save FAILURE (the fail-safe path: stay put, no data
// loss). The flow reads it through [captureCancelControllerProvider].
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/local/active_session_box.dart';
import '../../../domain/entities/active_session.dart';
import '../../../domain/entities/project_status.dart';
import '../../projects/project_capture_cleanup.dart';
import '../../projects/projects_notifier.dart';
import '../session/capture_session_store.dart';

/// The DATA operations behind the cancel confirmation. Pure control surface — no
/// UI, no navigation, no analytics (the flow owns those).
abstract interface class CaptureCancelController {
  /// The in-progress project this cancel targets, or null when none is resolvable
  /// (app restart / deep-link / unavailable store). Best-effort — never throws.
  Future<String?> activeProjectId();

  /// Persist the session as a resumable DRAFT. Retains every captured frame and
  /// per-level state — this NEVER deletes. Returns true on a successful save;
  /// false when the save failed (the caller then stays put and surfaces an error
  /// rather than leaving, so failing to save never silently drops the project).
  Future<bool> keepAsDraft(String projectId);

  /// Delete the in-progress session/captures — the ONLY deletion path. Clears the
  /// resumable session snapshots + the local captured frames + the active-session
  /// marker via the existing cleanup APIs. Best-effort per resource; a partial
  /// failure never throws (a missed purge is reclaimable by the orphan sweep).
  Future<void> discard(String projectId);
}

/// No-op stand-in (mirrors [NoUploadController]): resolves no project and treats
/// a draft save as a trivial success. Never deletes. Used where the flow is wired
/// but no real persistence is available.
class NoCaptureCancelController implements CaptureCancelController {
  const NoCaptureCancelController();

  @override
  Future<String?> activeProjectId() async => null;

  @override
  Future<bool> keepAsDraft(String projectId) async => true;

  @override
  Future<void> discard(String projectId) async {}
}

/// Default controller backed by the repo's existing gateways:
///   • Keep as Draft — re-affirms the resumable [ActiveSession] (the durable,
///     fallible save point) and reflects the project as a [ProjectStatus.draft]
///     in the live list. The captured frames themselves already persist on-device
///     from capture; this path adds nothing to delete and removes nothing.
///   • Discard — [CaptureSessionStore.clearProject] (per-level snapshots) +
///     [ProjectCaptureCleanup.purgeProjectCaptureData] (native frames) + clears
///     the active-session marker.
class DefaultCaptureCancelController implements CaptureCancelController {
  DefaultCaptureCancelController(
    this._ref, {
    ActiveSessionBox? sessionBox,
    CaptureSessionStore? sessionStore,
  })  : _sessionBox = sessionBox ?? ActiveSessionBox(),
        _sessionStore = sessionStore ?? CaptureSessionStore();

  final Ref _ref;
  final ActiveSessionBox _sessionBox;
  final CaptureSessionStore _sessionStore;

  /// The opaque step marker stored on the re-affirmed draft session (a free-form
  /// string per [ActiveSession.step]; not a route import — keeps layering clean).
  static const String _draftStep = 'capture_summary';

  @override
  Future<String?> activeProjectId() async {
    try {
      return (await _sessionBox.read())?.projectId;
    } catch (_) {
      return null; // no resumable session / unavailable store → nothing to target
    }
  }

  @override
  Future<bool> keepAsDraft(String projectId) async {
    try {
      // Durable save (the fallible point): re-affirm the resumable session so the
      // project can be reopened later. Throws on an IO/storage error → false.
      await _sessionBox.save(ActiveSession(
        projectId: projectId,
        step: _draftStep,
        updatedAt: DateTime.now(),
      ));
      // Reflect it as a resumable Draft in the live projects list. Best-effort:
      // a no-op when the list is not loaded (never blocks the successful save).
      _ref
          .read(projectsProvider.notifier)
          .updateStatus(projectId, ProjectStatus.draft);
      return true;
    } catch (_) {
      return false; // save failed — the flow keeps the user + data in place
    }
  }

  @override
  Future<void> discard(String projectId) async {
    // Per-level resumable snapshots.
    try {
      await _sessionStore.clearProject(projectId);
    } catch (_) {/* best-effort */}
    // Native captured frames/sidecars (already best-effort + platform-guarded).
    await _ref
        .read(projectCaptureCleanupProvider)
        .purgeProjectCaptureData(projectId);
    // The resumable-session marker so a re-entry does not resurrect it.
    try {
      await _sessionBox.clear();
    } catch (_) {/* best-effort */}
  }
}

/// The active cancel controller. Override to inject a fake in tests; the flow
/// always signals through this provider.
final captureCancelControllerProvider = Provider<CaptureCancelController>(
  DefaultCaptureCancelController.new,
);
