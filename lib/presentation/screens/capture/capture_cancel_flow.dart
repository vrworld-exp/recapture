// lib/presentation/screens/capture/capture_cancel_flow.dart
//
// The shared "Cancel → Keep as Draft" orchestration mixed into the Capture Summary
// and Uploading screens. It owns the sequence the brief specifies:
//
//   1. (Upload step only) abort any in-flight transfer cleanly + idempotently.
//   2. Show the confirmation (`capture_cancel_opened`).
//   3. Keep as Draft  → persist a draft; leave ONLY on a successful save, else
//      stay + surface an error (no data loss, no `capture_cancel_kept_draft`).
//   4. Discard        → delete the session/captures (the ONLY deletion path), leave.
//   5. Keep editing   → dismiss, unchanged (`capture_cancel_dismissed`).
//
// A single in-flight latch guards against double invocation (double-tap Cancel,
// system-back-while-open) so only one confirmation / save / discard / navigation
// ever occurs. Leaving uses `context.go(projects)`, which replaces the stack so
// back cannot re-enter the capture flow.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../application/capture/cancel/capture_cancel_controller.dart';
import '../../../domain/capture/capture_cancel.dart';
import '../../../utils/analytics.dart';
import '../../widgets/capture_cancel_confirmation.dart';

/// Mixed into a screen's [ConsumerState]. The host supplies the phase + session id
/// and, on the upload step, the in-progress signal + a clean abort.
mixin CaptureCancelFlow<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// Single-flight guard across the whole flow (open → confirm → act → navigate).
  /// Re-armed only when the flow ends WITHOUT leaving (Keep editing, or a failed
  /// draft save) so the user can try again.
  bool _cancelInFlight = false;

  static String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// Which step this screen is — carried as the analytics `phase`.
  CaptureCancelPhase get cancelPhase;

  /// The opaque funnel session id for the cancel analytics.
  String get cancelSessionId;

  /// Whether an upload is in progress right now (default false — the Summary step
  /// never has one). The upload screen overrides this from its live progress.
  bool get uploadInProgress => false;

  /// Whether a cancel flow currently owns the leave decision. The upload screen
  /// reads this to suppress its own cancelled→exit auto-navigation while the
  /// confirmation is open, so the confirmation (not the auto-nav) resolves the exit.
  @protected
  bool get cancelFlowActive => _cancelInFlight;

  /// Aborts the in-flight transfer (upload step only). Must be idempotent — the
  /// flow may call it while the pipeline is already stopping. Default: no-op.
  @protected
  void abortUploadForCancel() {}

  /// Entry point — wired to the Cancel control AND system/hardware back. Runs the
  /// full sequence; a re-entry while one is active is ignored (single confirmation).
  Future<void> startCaptureCancelFlow() async {
    if (_cancelInFlight) return;
    _cancelInFlight = true;

    // Abort any in-flight upload FIRST so no orphaned transfer outlives the prompt.
    final wasUploading = uploadInProgress;
    if (wasUploading) abortUploadForCancel();

    Analytics.logEvent(AnalyticsEvents.captureCancelOpened, {
      'session_id': cancelSessionId,
      'phase': cancelPhase.wireName,
      'upload_in_progress': wasUploading,
      'device_type': _deviceType,
    });

    final choice = await showCaptureCancelConfirmation(context);
    if (!mounted) {
      _cancelInFlight = false;
      return;
    }

    switch (choice) {
      case CaptureCancelChoice.keepEditing:
        _logOutcome(AnalyticsEvents.captureCancelDismissed);
        _cancelInFlight = false; // stayed — allow cancelling again later
      case CaptureCancelChoice.keepDraft:
        await _keepAsDraft();
      case CaptureCancelChoice.discard:
        await _discard();
    }
  }

  Future<void> _keepAsDraft() async {
    final controller = ref.read(captureCancelControllerProvider);
    final projectId = await controller.activeProjectId();
    if (!mounted) {
      _cancelInFlight = false;
      return;
    }
    // With a project to persist, the save must SUCCEED before we leave. Without
    // one (empty/near-empty session — nothing captured to a project) there is
    // nothing to lose, so leaving directly is safe.
    final saved = projectId == null || await controller.keepAsDraft(projectId);
    if (!mounted) {
      _cancelInFlight = false;
      return;
    }
    if (!saved) {
      // Fail-safe: stay, surface the error, allow retry. No data lost, and the
      // kept-draft success event does NOT fire (the project did not leave).
      _showSaveError();
      _cancelInFlight = false;
      return;
    }
    _logOutcome(AnalyticsEvents.captureCancelKeptDraft);
    _leaveFlow();
  }

  Future<void> _discard() async {
    final controller = ref.read(captureCancelControllerProvider);
    final projectId = await controller.activeProjectId();
    if (!mounted) {
      _cancelInFlight = false;
      return;
    }
    if (projectId != null) {
      await controller.discard(projectId);
      if (!mounted) {
        _cancelInFlight = false;
        return;
      }
    }
    _logOutcome(AnalyticsEvents.captureCancelDiscarded);
    _leaveFlow();
  }

  /// Leaves to the projects list, replacing the stack so back cannot re-enter the
  /// capture flow. `_cancelInFlight` stays latched — the screen is gone, and the
  /// latch blocks any duplicate navigation queued behind this one.
  void _leaveFlow() => context.go(AppRoutes.projects);

  void _logOutcome(String event) {
    Analytics.logEvent(event, {
      'session_id': cancelSessionId,
      'phase': cancelPhase.wireName,
      'device_type': _deviceType,
    });
  }

  void _showSaveError() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const Key('cancel_save_error'),
        backgroundColor: AppColors.error,
        content: const Text(
          "Couldn't save your draft. Your photos are safe — please try again.",
        ),
      ),
    );
  }
}
