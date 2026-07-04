// lib/presentation/screens/capture/uploading_screen.dart
//
// Screen 9 — Uploading. A PURE OBSERVER of the upload pipeline's progress feed
// (uploadProgressProvider): a DETERMINATE progress bar bound to real bytes
// transferred, a "files uploaded / total" + "MB uploaded / total MB" counter, and
// a static Wi-Fi advisory. It performs NO upload, networking, file IO, or retry
// logic and NEVER animates/simulates progress — the bar reflects the stream only.
//
// Terminal states: completion advances to Processing; failure (stream error or a
// failed status) surfaces a clear state with Retry/Back rather than a frozen bar.
// All byte→MB display goes through the shared formatter; all fraction/counter math
// is guarded in [UploadProgress] (no divide-by-zero / NaN / >100%).
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/analytics/capture_level_session.dart';
import '../../../application/upload/upload_controller.dart';
import '../../../application/upload/upload_progress_provider.dart';
import '../../../domain/capture/capture_cancel.dart';
import '../../../domain/entities/upload_progress.dart';
import '../../../domain/upload/upload_failure.dart';
import '../../../utils/analytics.dart';
import '../../../utils/byte_format.dart';
import '../../widgets/upload_controls.dart';
import 'capture_cancel_flow.dart';

class UploadingScreen extends ConsumerStatefulWidget {
  const UploadingScreen({super.key});

  @override
  ConsumerState<UploadingScreen> createState() => _UploadingScreenState();
}

class _UploadingScreenState extends ConsumerState<UploadingScreen>
    with CaptureCancelFlow<UploadingScreen> {
  final DateTime _entryTime = DateTime.now();
  bool _startedLogged = false;
  bool _terminalLogged = false;
  int _lastFilesUploaded = 0;

  static String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  String get _sessionId =>
      ref.read(captureLevelSessionProvider)?.sessionId ?? '';

  // ── Cancel → Keep as Draft flow (leaving the upload step) ──────────────────
  @override
  CaptureCancelPhase get cancelPhase => CaptureCancelPhase.upload;

  @override
  String get cancelSessionId => _sessionId;

  /// An upload is "in progress" (and so must be aborted before the confirmation)
  /// while the pipeline reports transferring OR paused.
  @override
  bool get uploadInProgress {
    final p = ref.read(uploadProgressProvider).valueOrNull;
    return p != null && (p.isInProgress || p.isPaused);
  }

  /// Aborts the in-flight transfer via the pipeline's control seam (idempotent;
  /// safe to call twice / when nothing is running).
  @override
  void abortUploadForCancel() => ref.read(uploadControllerProvider).cancel();

  @override
  void initState() {
    super.initState();
    // Drive the once-only view/terminal analytics + forward navigation off the
    // progress stream itself (fireImmediately covers an already-present snapshot).
    // Side-effects run from the listener (outside build) so navigation is safe.
    ref.listenManual<AsyncValue<UploadProgress>>(
      uploadProgressProvider,
      (prev, next) => next.when(
        data: _react,
        error: (err, _) => _reactError(err),
        loading: () {},
      ),
      fireImmediately: true,
    );
  }

  void _react(UploadProgress p) {
    // Once per entry, on the first real snapshot (so totals are populated).
    if (!_startedLogged) {
      _startedLogged = true;
      Analytics.logEvent(AnalyticsEvents.uploadStartedView, {
        'session_id': _sessionId,
        'phase': 'upload',
        'total_files': p.totalFiles,
        'total_mb': bytesToMb(p.totalBytes),
        'device_type': _deviceType,
      });
    }
    _lastFilesUploaded = p.displayFilesUploaded;

    if (_terminalLogged) return;
    if (p.isComplete) {
      _terminalLogged = true;
      Analytics.logEvent(AnalyticsEvents.uploadCompleted, {
        'session_id': _sessionId,
        'phase': 'upload',
        'total_files': p.totalFiles,
        'total_mb': bytesToMb(p.totalBytes),
        'duration_ms': DateTime.now().difference(_entryTime).inMilliseconds,
        'device_type': _deviceType,
      });
      if (mounted) context.go(AppRoutes.processing);
    } else if (p.isFailed) {
      // A failed STATUS carries no exception object → classified as the safe
      // generic (unknown) on Screen 9F.
      _goToFailure(null);
    } else if (p.isCancelled) {
      // The transfer was aborted and the local captured data is retained. If a
      // Cancel→Keep-as-Draft flow triggered the abort, IT owns the exit decision
      // (Keep as Draft / Discard / Keep editing) — don't auto-navigate out from
      // under its confirmation. Otherwise (an UploadControls transfer-cancel) the
      // captured set can be re-uploaded later, so leave the upload screen.
      if (cancelFlowActive) return;
      _terminalLogged = true;
      if (mounted) context.go(AppRoutes.projects);
    }
  }

  /// Stream error → treat as an upload failure (surface, don't hang). The error
  /// OBJECT is classified for Screen 9F (its raw text is never rendered).
  void _reactError(Object error) {
    if (_terminalLogged) return;
    _goToFailure(error);
  }

  /// Logs the observation event, classifies the failure into a MAPPED category
  /// (logging the raw detail to diagnostics only — never to the UI), and hands off
  /// to Screen 9F. `go` replaces the route so a repeated failure never stacks.
  void _goToFailure(Object? error) {
    if (_terminalLogged) return;
    _terminalLogged = true;
    Analytics.logEvent(AnalyticsEvents.uploadFailedView, {
      'session_id': _sessionId,
      'phase': 'upload',
      'files_uploaded_at_failure': _lastFilesUploaded,
      'device_type': _deviceType,
    });
    // Diagnostics only (dev builds) — the raw error never reaches the screen.
    if (error != null) {
      debugPrint('[upload] failed: ${error.runtimeType}');
    }
    final category = classifyUploadFailure(error);
    if (mounted) context.go(AppRoutes.uploadFailed, extra: category);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(uploadProgressProvider);
    final progress = async.valueOrNull ?? UploadProgress.initial;

    return PopScope(
      key: const Key('upload_cancel_popscope'),
      // System/hardware back routes through the cancel confirmation (aborting any
      // in-flight transfer first) — never a silent exit past Keep-as-Draft.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) startCaptureCancelFlow();
      },
      child: Scaffold(
        backgroundColor: AppColors.bgPrimary,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          leading: IconButton(
            key: const Key('upload_leave'),
            icon: const Icon(Icons.close),
            tooltip: 'Cancel',
            onPressed: startCaptureCancelFlow,
          ),
          title:
              Text('Uploading', style: Theme.of(context).textTheme.titleLarge),
        ),
        // On failure the listener navigates to Screen 9F (this screen is replaced),
        // so the body only ever renders the progress view.
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: _ProgressView(progress: progress, sessionId: _sessionId),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressView extends StatelessWidget {
  const _ProgressView({required this.progress, required this.sessionId});

  final UploadProgress progress;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final pct = (progress.fraction * 100).round();
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_upload_outlined,
            size: 64, color: AppColors.mirageRed),
        const SizedBox(height: AppSpacing.xl),
        Text(
          progress.isPaused ? 'Upload paused' : 'Uploading your capture',
          style: textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xl),
        // Determinate — value is always the clamped, guarded fraction (0 before
        // totals are known); never an indeterminate spinner.
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            key: const Key('upload_progress_bar'),
            value: progress.fraction,
            color: AppColors.mirageRed,
            backgroundColor: AppColors.surface2,
            minHeight: 8,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '$pct%',
          key: const Key('upload_percent'),
          style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '${progress.displayFilesUploaded} / ${progress.totalFiles} files',
          key: const Key('upload_files_counter'),
          style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          formatMbProgress(progress.bytesUploaded, progress.totalBytes),
          key: const Key('upload_mb_counter'),
          style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xl),
        const _UploadHint(
          key: Key('upload_wifi_hint'),
          icon: Icons.wifi,
          message: 'Stay on Wi-Fi to avoid data charges',
        ),
        // iOS-only advisory: iOS throttles background networking, so keeping the
        // app foregrounded uploads faster. A secondary hint beside the Wi-Fi one;
        // renders NOTHING on Android/web (no reserved space, no layout shift).
        // Uses the file's established platform check (defaultTargetPlatform), web-
        // guarded so it never evaluates iOS on a non-mobile target.
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) ...[
          const SizedBox(height: AppSpacing.sm),
          const _UploadHint(
            key: Key('upload_keep_open_hint'),
            icon: Icons.stay_current_portrait,
            message: 'Keep app open to upload faster',
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        // State-dependent Pause / Resume / Cancel — signals the pipeline and
        // reflects its state (driven by the same progress snapshot rendered above,
        // so the controls and the bar stay in one consistent state).
        UploadControls(status: progress.status, sessionId: sessionId),
      ],
    );
  }
}

/// A secondary, non-blocking advisory row on the Uploading screen. Static /
/// display-only — it implements NO connectivity detection, cellular auto-pause,
/// lifecycle handling, or upload logic (separate concerns). Both the Wi-Fi hint
/// and the iOS keep-app-open hint render through this one presentation.
class _UploadHint extends StatelessWidget {
  const _UploadHint({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.disabled.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
