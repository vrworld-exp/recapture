// lib/application/upload/upload_controller.dart
//
// The CONTROL seam the upload-control buttons (Pause / Resume / Cancel) signal —
// the write counterpart of the read-only [UploadProgressSource]. The buttons
// SIGNAL these intents; the real upload pipeline OWNS the mechanics (suspending an
// in-flight item, resuming from the durable/outbox queue without re-uploading
// completed photos, aborting a transfer while RETAINING the local captured data).
//
// Like the progress source, this is a pure interface. The pipeline is wired:
// while an upload flow is ACTIVE, [uploadControllerProvider] delegates to the
// flow's live control surface (reaching the real engine — pause/resume the
// transfer, cancel aborts the multipart upload while RETAINING local files);
// when idle it falls back to the no-op. Tests override it with a fake that
// records the signals. The button widget never performs any transfer work
// itself — it signals + reflects.
//
// All three signals MUST be idempotent at the implementation: a double-pause, a
// double-cancel, or a wrong-state signal is a safe no-op. The UI also guards
// against those (state-dependent buttons + an in-flight latch), but the pipeline
// is the final authority, so it must not assume the UI's guards are perfect.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'upload_flow.dart';

/// The control intents the buttons signal to the upload pipeline. Pure interface —
/// no UI, no IO, no transfer mechanics here.
abstract class UploadController {
  /// Suspend the upload. The pipeline finishes/suspends the in-flight item and
  /// preserves progress; completed photos stay completed. No-op if not running.
  void pause();

  /// Continue from the durable queue. Completed photos are NOT re-uploaded. No-op
  /// if not paused.
  void resume();

  /// Abort the TRANSFER (not a delete) — the local captured photos/sidecars are
  /// retained and remain re-uploadable. No-op if there is nothing to cancel.
  void cancel();
}

/// Idle-state controller (no upload flow running): every signal is a safe
/// no-op. Also the override point for tests.
class NoUploadController implements UploadController {
  const NoUploadController();

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  void cancel() {}
}

/// The active upload controller: the LIVE flow's control surface when one
/// exists, else the idle no-op. Tests override this directly (unchanged); the
/// buttons always signal through this provider.
final uploadControllerProvider = Provider<UploadController>(
  (ref) => ref.watch(uploadFlowProvider) ?? const NoUploadController(),
);
