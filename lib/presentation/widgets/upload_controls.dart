// lib/presentation/widgets/upload_controls.dart
//
// The state-dependent Pause / Resume / Cancel buttons for an in-progress upload.
// They SIGNAL the upload pipeline (via [uploadControllerProvider]) and REFLECT its
// state (driven by the [status] passed in from the screen's single watch of the
// progress feed, so the buttons and the progress display always show ONE
// consistent state). The pipeline owns the actual mechanics — this widget performs
// no transfer, networking, or persistence work.
//
// Buttons by state:
//   • uploading → Pause + Cancel
//   • paused    → Resume + Cancel
//   • idle / completed / failed / cancelled → nothing (the screen handles those:
//     completion advances, failure shows the failed view, cancel/idle exit).
//
// Guards (signal-and-reflect only): the handlers re-check [status] before
// signalling (wrong-state taps — e.g. Resume while uploading — are ignored), and
// an in-flight latch blocks rapid double-taps until the observed [status] actually
// changes (so a double-pause or double-cancel signals once). Cancel additionally
// confirms first (retain-semantics wording) and guards against opening a second
// confirmation. The pipeline's control API is also idempotent, so a slipped-through
// duplicate is still a safe no-op.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_spacing.dart';
import '../../application/upload/upload_controller.dart';
import '../../domain/entities/upload_progress.dart';
import '../../utils/analytics.dart';
import 'app_button.dart';
import 'upload_cancel_confirmation.dart';

class UploadControls extends ConsumerStatefulWidget {
  const UploadControls({
    super.key,
    required this.status,
    required this.sessionId,
  });

  /// The current pipeline upload state, driven by the screen's watch of the
  /// progress feed. The buttons render and guard against THIS value, keeping them
  /// in sync with the progress display.
  final UploadStatus status;

  /// The opaque capture funnel session id, for the control analytics.
  final String sessionId;

  @override
  ConsumerState<UploadControls> createState() => _UploadControlsState();
}

class _UploadControlsState extends ConsumerState<UploadControls> {
  /// Set after a control is signalled; blocks further taps until the observed
  /// [UploadControls.status] changes (the pipeline reflected the signal). Prevents
  /// rapid double-pause / double-resume / double-cancel.
  bool _inFlight = false;

  /// True while the Cancel confirmation is open — prevents stacking a second one.
  bool _confirming = false;

  static String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  @override
  void didUpdateWidget(covariant UploadControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The pipeline reflected our signal (or moved on its own) → re-arm the taps.
    if (oldWidget.status != widget.status) {
      _inFlight = false;
    }
  }

  UploadController get _controller => ref.read(uploadControllerProvider);

  void _logControl(String event, [Map<String, Object?> extra = const {}]) {
    Analytics.logEvent(event, {
      'session_id': widget.sessionId,
      'phase': 'upload',
      ...extra,
      'device_type': _deviceType,
    });
  }

  void _onPause() {
    // Wrong-state / double-tap guards: only an in-progress, not-already-signalled
    // upload can be paused.
    if (_inFlight || widget.status != UploadStatus.inProgress) return;
    setState(() => _inFlight = true);
    _controller.pause();
    _logControl(AnalyticsEvents.uploadPaused);
  }

  void _onResume() {
    // Only a paused upload can be resumed (continues from the durable queue —
    // completed photos are not re-uploaded; the pipeline owns that).
    if (_inFlight || widget.status != UploadStatus.paused) return;
    setState(() => _inFlight = true);
    _controller.resume();
    _logControl(AnalyticsEvents.uploadResumed);
  }

  Future<void> _onCancel() async {
    // Cancel applies while uploading OR paused. Guard re-taps and a second dialog.
    final from = widget.status;
    if (_inFlight ||
        _confirming ||
        (from != UploadStatus.inProgress && from != UploadStatus.paused)) {
      return;
    }
    setState(() => _confirming = true);
    final bool confirmed;
    try {
      confirmed = await showUploadCancelConfirmation(context);
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (!confirmed || !mounted) return; // dismissed → no abort, data untouched

    // Re-check after the async gap: the pipeline may have completed/failed while
    // the dialog was open. Only signal if still cancellable.
    if (widget.status != UploadStatus.inProgress &&
        widget.status != UploadStatus.paused) {
      return;
    }
    setState(() => _inFlight = true);
    _controller.cancel(); // aborts the TRANSFER; local captured data is retained
    _logControl(AnalyticsEvents.uploadCancelled, {
      'from_state':
          from == UploadStatus.paused ? 'paused' : 'uploading',
    });
  }

  @override
  Widget build(BuildContext context) {
    final cancelButton = AppButton.secondary(
      key: const Key('upload_cancel'),
      label: 'Cancel',
      icon: Icons.close,
      onPressed: _inFlight ? null : _onCancel,
    );

    switch (widget.status) {
      case UploadStatus.inProgress:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppButton.secondary(
              key: const Key('upload_pause'),
              label: 'Pause',
              icon: Icons.pause,
              onPressed: _inFlight ? null : _onPause,
            ),
            const SizedBox(height: AppSpacing.sm),
            cancelButton,
          ],
        );
      case UploadStatus.paused:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppButton(
              key: const Key('upload_resume'),
              label: 'Resume',
              icon: Icons.play_arrow,
              onPressed: _inFlight ? null : _onResume,
            ),
            const SizedBox(height: AppSpacing.sm),
            cancelButton,
          ],
        );
      case UploadStatus.idle:
      case UploadStatus.completed:
      case UploadStatus.failed:
      case UploadStatus.cancelled:
        // No transfer controls in these states — the screen owns the outcome.
        return const SizedBox.shrink();
    }
  }
}
