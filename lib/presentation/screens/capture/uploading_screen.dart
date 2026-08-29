// lib/presentation/screens/capture/uploading_screen.dart
//
// Screen 9 — Uploading. A PURE OBSERVER of the upload pipeline's feeds: the
// live STEP TIMELINE (uploadStepTimelineProvider — pack → create project →
// create job → transfer → finalize, smoke-card style with ✓/spinner/✗ rows and
// expandable detail) plus the byte/file progress stream (uploadProgressProvider)
// driving the transfer row's DETERMINATE bar and counters. It performs NO
// upload, networking, file IO, or retry logic and NEVER animates/simulates
// progress — every pixel reflects the streams only.
//
// Terminal states: completion advances to Processing; failure (stream error or a
// failed status) paints the failing step red and lands on Screen 9F (the terminal
// failure surface — mapped category only, never raw error text). Step `info`
// lines are prod-safe (counts/sizes); raw `devDetail` (ids, paths, exceptions)
// renders ONLY in non-production flavors (same gate as the Dev Tools section).
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
import '../../../application/capture/ledger/level_capture_ledger_registry_provider.dart';
import '../../../application/upload/upload_controller.dart';
import '../../../application/upload/upload_flow.dart';
import '../../../application/upload/upload_progress_provider.dart';
import '../../../domain/capture/capture_cancel.dart';
import '../../../domain/entities/upload_progress.dart';
import '../../../domain/upload/upload_failure.dart';
import '../../../domain/upload/upload_flow_steps.dart';
import '../../../utils/analytics.dart';
import '../../../utils/app_env.dart';
import '../../../utils/byte_format.dart';
import '../../widgets/step_checklist_row.dart';
import '../../widgets/upload_controls.dart';
import 'capture_cancel_flow.dart';
import '../../../utils/platform_name.dart';
import '../../../platform/upload_tab_guard_stub.dart'
    if (dart.library.js_interop) '../../../platform/upload_tab_guard_web.dart';

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

  /// Step rows the user expanded to inspect their detail.
  final Set<UploadFlowStepId> _expandedSteps = <UploadFlowStepId>{};

  static String get _deviceType => appPlatformName;

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
    // Web has no background upload (see upload_background_session.dart /
    // upload_foreground_service.dart, which correctly report unsupported for
    // kIsWeb), so closing the tab kills the transfer. Arm the browser's own
    // "Leave site?" confirmation for as long as this screen is up; it is
    // disarmed on dispose and on every terminal state below. A no-op natively.
    setUploadInFlight(true);
  }

  @override
  void dispose() {
    setUploadInFlight(false);
    super.dispose();
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
      setUploadInFlight(false);
      Analytics.logEvent(AnalyticsEvents.uploadCompletedView, {
        'session_id': _sessionId,
        'phase': 'upload',
        'total_files': p.totalFiles,
        'total_mb': bytesToMb(p.totalBytes),
        'duration_ms': DateTime.now().difference(_entryTime).inMilliseconds,
        'device_type': _deviceType,
      });
      // The captured set has been handed off — end the run so its frames stop
      // being "the captures under review". Without this the in-memory ledgers
      // outlive the upload and the NEXT capture's review grid/summary would
      // show this object's photos alongside the new ones.
      ref.read(levelCaptureLedgerRegistryProvider).endRun();
      // Carry the REMOTE project id the flow minted into the post-upload
      // screen. Re-deriving it there would read the local session's id, which
      // is a different id space — and the button it feeds spends money on
      // whatever project it names. Null (a flow that never created a project)
      // degrades that screen to "Back to Projects" with no button at all.
      if (mounted) {
        context.go(
          AppRoutes.processing,
          extra: ref.read(uploadFlowProvider)?.remoteProjectId,
        );
      }
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
      setUploadInFlight(false);
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
    setUploadInFlight(false);
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
    final timeline = ref.watch(uploadStepTimelineProvider).valueOrNull ??
        UploadFlowTimeline.initial();

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
              child: _ProgressView(
                progress: progress,
                timeline: timeline,
                sessionId: _sessionId,
                expandedSteps: _expandedSteps,
                onToggleStep: (id) => setState(() => _expandedSteps.contains(id)
                    ? _expandedSteps.remove(id)
                    : _expandedSteps.add(id)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressView extends StatelessWidget {
  const _ProgressView({
    required this.progress,
    required this.timeline,
    required this.sessionId,
    required this.expandedSteps,
    required this.onToggleStep,
  });

  final UploadProgress progress;
  final UploadFlowTimeline timeline;
  final String sessionId;
  final Set<UploadFlowStepId> expandedSteps;
  final ValueChanged<UploadFlowStepId> onToggleStep;

  static String _label(UploadFlowStepId id) => switch (id) {
        UploadFlowStepId.prepare => 'Preparing photos',
        UploadFlowStepId.createProject => 'Creating project',
        UploadFlowStepId.createJob => 'Registering upload',
        UploadFlowStepId.transfer => 'Uploading files',
        UploadFlowStepId.finalize => 'Verifying upload',
      };

  static StepRowStatus _rowStatus(UploadStepStatus s) => switch (s) {
        UploadStepStatus.pending => StepRowStatus.pending,
        UploadStepStatus.running => StepRowStatus.running,
        UploadStepStatus.done => StepRowStatus.done,
        UploadStepStatus.failed => StepRowStatus.failed,
        UploadStepStatus.cancelled => StepRowStatus.cancelled,
      };

  @override
  Widget build(BuildContext context) {
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
        _stepCard(context),
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
        // Web-only, and NOT an advisory: a browser has no background upload at
        // all, so closing the tab ends the transfer and the recovery is to
        // re-open and retry. Said plainly rather than implied.
        if (kIsWeb) ...[
          const SizedBox(height: AppSpacing.sm),
          const _UploadHint(
            key: Key('upload_keep_tab_open_hint'),
            icon: Icons.tab,
            message: 'Keep this tab open — closing it stops the upload',
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

  /// The smoke-card-style step checklist over the REAL flow: one row per
  /// timeline step, the live transfer bar/counters beneath the transfer row
  /// (bound to the byte/file stream — never simulated), and the success
  /// footer once every step is done.
  Widget _stepCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.disabled.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final step in timeline.steps) ...[
            StepChecklistRow(
              key: Key('upload_step_${step.id.name}'),
              status: _rowStatus(step.status),
              label: _rowLabel(step),
              trailing: _rowTrailing(context, step),
              expanded: expandedSteps.contains(step.id),
              onToggle: () => onToggleStep(step.id),
              detail: _stepDetail(context, step),
            ),
            if (step.id == UploadFlowStepId.transfer)
              _transferProgress(context),
          ],
          if (timeline.isAllDone) _summaryFooter(context),
        ],
      ),
    );
  }

  /// The transfer row carries its live file counter in the label; every other
  /// row uses the static friendly label.
  String _rowLabel(UploadFlowStepState step) {
    if (step.id == UploadFlowStepId.transfer && progress.totalFiles > 0) {
      return '${_label(step.id)} '
          '${progress.displayFilesUploaded}/${progress.totalFiles}';
    }
    return _label(step.id);
  }

  /// Paused badge on the transfer row (user pause or offline auto-park); a
  /// transient note ("Retrying…") while the runner is between attempts.
  Widget? _rowTrailing(BuildContext context, UploadFlowStepState step) {
    if (step.id != UploadFlowStepId.transfer) return null;
    final textTheme = Theme.of(context).textTheme;
    if (progress.isPaused && !step.isDone) {
      return Container(
        key: const Key('upload_transfer_paused_badge'),
        padding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Text(
          'Paused',
          style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
        ),
      );
    }
    if (step.isRunning && step.info != null) {
      return Text(
        step.info!,
        style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
      );
    }
    return null;
  }

  /// Expandable detail: the prod-safe [info] line plus — ONLY in non-prod
  /// flavors — the raw devDetail lines in monospace (ids/paths/exceptions
  /// never render in production; same gate as the Dev Tools section).
  Widget? _stepDetail(BuildContext context, UploadFlowStepState step) {
    final showDev = !kAppEnvironment.isProduction && step.devDetail.isNotEmpty;
    // The running transfer's info is a transient trailing note, not detail.
    final info = step.id == UploadFlowStepId.transfer && step.isRunning
        ? null
        : step.info;
    if (info == null && !showDev) return null;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      key: Key('upload_step_detail_${step.id.name}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (info != null)
          Text(
            info,
            style:
                textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
        if (showDev) ...[
          if (info != null) const SizedBox(height: AppSpacing.xs),
          Text(
            step.devDetail.join('\n'),
            style: textTheme.bodySmall?.copyWith(
              color: AppColors.textMuted,
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
        ],
      ],
    );
  }

  /// The live transfer block under the transfer row — the SAME determinate
  /// bar + counters as before (same keys, same guarded math), bound to the
  /// byte/file stream only.
  Widget _transferProgress(BuildContext context) {
    final pct = (progress.fraction * 100).round();
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      // Aligns with the row labels: 14px status icon + the sm gap.
      padding: const EdgeInsets.only(
          left: 14 + AppSpacing.sm, bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Determinate — value is always the clamped, guarded fraction (0
          // before totals are known); never an indeterminate spinner.
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              key: const Key('upload_progress_bar'),
              value: progress.fraction,
              color: AppColors.mirageRed,
              backgroundColor: AppColors.surface2,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Text(
                '$pct%',
                key: const Key('upload_percent'),
                style: textTheme.bodySmall
                    ?.copyWith(color: AppColors.textSecondary),
              ),
              const Spacer(),
              Text(
                '${progress.displayFilesUploaded} / ${progress.totalFiles} files',
                key: const Key('upload_files_counter'),
                style:
                    textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                formatMbProgress(progress.bytesUploaded, progress.totalBytes),
                key: const Key('upload_mb_counter'),
                style:
                    textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Success summary shown once every step is done (the flow navigates to
  /// Processing right after): `✓ N/N files · SIZE MB · DURATIONs`.
  Widget _summaryFooter(BuildContext context) {
    final started = timeline.firstStartedAt;
    final ended = timeline.lastEndedAt;
    final secs = started != null && ended != null
        ? (ended.difference(started).inMilliseconds / 1000).toStringAsFixed(1)
        : null;
    final files = progress.totalFiles;
    final text = '✓ $files/$files files · ${formatMb(progress.totalBytes)} MB'
        '${secs == null ? '' : ' · ${secs}s'}';
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Text(
        text,
        key: const Key('upload_summary_footer'),
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: AppColors.success),
        textAlign: TextAlign.center,
      ),
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
