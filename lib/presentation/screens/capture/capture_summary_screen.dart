// lib/presentation/screens/capture/capture_summary_screen.dart
//
// Capture Summary — shown after the multi-level guided capture (A/B/C) and the
// entry point to the upload pipeline. READ-ONLY over capture data: one card per
// configured level (iterating CaptureLevel.values, never hardcoded) showing the
// level's accepted/min frame count, ring coverage %, a per-level warning
// indicator, its completeness, and — when short — the shortfall that names what to
// fix. Below the cards, a collapsible list aggregates every warning raised.
//
// Three actions:
//   • Upload (PRIMARY) — kicks off the upload pipeline for the captured set.
//     Warn-then-allow: if any level is below its completion criteria the user
//     confirms first, then proceeds (issues are surfaced either way).
//   • Fix Issues — routes to the level needing the MOST work (greatest shortfall,
//     from the SAME completion validator the gate uses), to capture more. Hidden
//     when every level is complete.
//   • Save for later — exits to the project list; the session is resumable.
//
// Completeness + shortfall are read from the per-level summary (which composes the
// shared `evaluateLevelA` validator over the live ledger) — this screen recomputes
// no coverage and owns no sequencing or upload mechanics.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/analytics/capture_level_events.dart';
import '../../../application/capture/analytics/capture_level_session.dart';
import '../../../application/capture/capture_summary_provider.dart';
import '../../../application/capture/completion_gate_provider.dart';
import '../../../application/capture/review_grid_items_provider.dart';
import '../../../application/capture/upload_gate_provider.dart';
import '../../../application/connectivity/connectivity_providers.dart';
import '../../../domain/capture/capture_cancel.dart';
import '../../../domain/capture/level_completion.dart';
import '../../../domain/capture/upload_gate.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import 'capture_cancel_flow.dart';

/// The review grid route for a level (per-card review entry).
String _reviewRouteForLevel(CaptureLevel level) => switch (level) {
      CaptureLevel.a => AppRoutes.levelAReview,
      CaptureLevel.b => AppRoutes.levelBReview,
      CaptureLevel.c => AppRoutes.levelCReview,
    };

/// The capture route for a level — the Fix Issues target (more capture).
String _captureRouteForLevel(CaptureLevel level) => switch (level) {
      CaptureLevel.a => AppRoutes.levelACapture,
      CaptureLevel.b => AppRoutes.levelBCapture,
      CaptureLevel.c => AppRoutes.levelCCapture,
    };

class CaptureSummaryScreen extends ConsumerStatefulWidget {
  const CaptureSummaryScreen({super.key});

  @override
  ConsumerState<CaptureSummaryScreen> createState() =>
      _CaptureSummaryScreenState();
}

class _CaptureSummaryScreenState extends ConsumerState<CaptureSummaryScreen>
    with CaptureCancelFlow<CaptureSummaryScreen> {
  /// The cancel flow leaves from the Summary step (no upload runs here).
  @override
  CaptureCancelPhase get cancelPhase => CaptureCancelPhase.captureSummary;

  @override
  String get cancelSessionId => _sessionId;

  /// Single-flight guard: once any action begins navigating (including through the
  /// async below-min confirm), no other action can double-kickoff or double-nav.
  /// Re-armed only when the below-min confirm is cancelled.
  bool _navigating = false;

  /// Whether the warnings list is expanded — children are built only when true.
  bool _warningsExpanded = false;

  /// Debounced offline state driving the banner + the Upload CTA block. Debounced
  /// (not read raw) so rapid connectivity flapping doesn't flicker the banner.
  /// Starts false — [isOnlineProvider] defaults ONLINE before the status resolves,
  /// so no false "offline" flashes on entry.
  bool _offline = false;
  Timer? _connectivityDebounce;

  static String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// The opaque funnel session id, or '' when no session was observed (app
  /// restart / deep-link) — the same accepted edge the rest of the funnel uses.
  String get _sessionId =>
      ref.read(captureLevelSessionProvider)?.sessionId ?? '';

  @override
  void initState() {
    super.initState();
    // Once per entry (never on rebuild). Totals + completeness are read from the
    // same read-only summary the screen renders.
    final summaries = ref.read(captureSummaryProvider);
    final totalAccepted =
        summaries.fold<int>(0, (sum, s) => sum + s.frameCount);
    final totalWarnings =
        summaries.fold<int>(0, (sum, s) => sum + s.warningCount);
    final complete = summaries.where((s) => s.isComplete).length;
    Analytics.logEvent(AnalyticsEvents.captureSummaryViewed, {
      'phase': 'guided_capture',
      'session_id': _sessionId,
      'levels_complete': complete,
      'levels_total': summaries.length,
      'total_accepted_frames': totalAccepted,
      'total_warning_count': totalWarnings,
      'any_level_below_min': !allLevelsComplete(summaries),
      'device_type': _deviceType,
    });

    // Hard upload gate: if the control is shown disabled on entry, that is a
    // blocked view — report it once (the not-eligible→eligible pass milestone is
    // handled reactively in build).
    final uploadGate = ref.read(uploadGateProvider);
    if (!uploadGate.eligible) {
      ref
          .read(uploadGateAnalyticsProvider.notifier)
          .logBlocked(uploadGate, sessionId: _sessionId);
    }

    // Observe the CENTRALIZED connectivity source live (never a one-shot check).
    // fireImmediately seeds from the current status (online by default → no false
    // flash); each change is debounced before it flips the banner/CTA.
    ref.listenManual<bool>(
      isOnlineProvider,
      (_, online) => _onOnlineChanged(online),
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _connectivityDebounce?.cancel();
    super.dispose();
  }

  /// Debounces a connectivity change (coalescing rapid flapping to the settled
  /// value) before flipping [_offline]. Fires the banner-shown analytics ONLY on a
  /// genuine hidden→shown (online→offline) edge, never per rebuild.
  void _onOnlineChanged(bool online) {
    _connectivityDebounce?.cancel();
    _connectivityDebounce =
        Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final offline = !online;
      if (offline == _offline) return; // settled on the same state → no-op
      setState(() => _offline = offline);
      if (offline) {
        Analytics.logEvent(AnalyticsEvents.captureSummaryOfflineBannerShown, {
          'session_id': _sessionId,
          'phase': 'guided_capture',
          'device_type': _deviceType,
        });
      }
    });
  }

  /// Recompute the summary from the (possibly re-captured) ledger after a Review
  /// round-trip: the per-level item providers are kept alive by this screen's
  /// watch, so force them — and the aggregate — to recompute.
  void _refreshAfterReview() {
    for (final level in CaptureLevel.values) {
      ref.invalidate(reviewGridItemsProvider(pitchBandIdForLevel(level)));
    }
    ref.invalidate(captureSummaryProvider);
    ref.invalidate(uploadGateProvider);
  }

  /// Upload (primary) — kicks off the upload pipeline. HARD-GATE ENFORCED: the
  /// handler re-checks the absolute-minimum gate before starting, so a stale UI
  /// state can never bypass it. Above the floor but below soft completion →
  /// warn-then-allow confirm; complete → straight through.
  Future<void> _onUpload({
    required bool anyBelowMin,
    required String incompleteLabel,
  }) async {
    if (_navigating) return;

    // Offline block: uploading is impossible without connectivity, so never
    // navigate into a guaranteed-to-fail upload. The CTA allows the tap (so the
    // user gets a clear reason) then blocks + logs. Does NOT latch [_navigating] —
    // the user can proceed the moment they reconnect.
    if (_offline) {
      _showOfflineBlocked();
      Analytics.logEvent(AnalyticsEvents.captureSummaryProceedBlockedOffline, {
        'session_id': _sessionId,
        'phase': 'guided_capture',
        'device_type': _deviceType,
      });
      return;
    }

    // Hard gate (re-evaluated live) — refuse even if invoked while disabled.
    final gate = ref.read(uploadGateProvider);
    if (!gate.eligible) {
      ref
          .read(uploadGateAnalyticsProvider.notifier)
          .logBlocked(gate, sessionId: _sessionId);
      return; // do NOT latch / navigate
    }

    _navigating = true; // blocks double-tap through the await
    if (anyBelowMin) {
      final proceed = await _confirmBelowMin(incompleteLabel);
      if (!proceed) {
        if (mounted) setState(() => _navigating = false); // re-arm for a retry
        return;
      }
    }
    // Final defense: re-check after the await (a delete during the confirm could
    // have dropped a level below the floor).
    if (!ref.read(uploadGateProvider).eligible) {
      ref.read(uploadGateAnalyticsProvider.notifier).logBlocked(
            ref.read(uploadGateProvider),
            sessionId: _sessionId,
          );
      if (mounted) setState(() => _navigating = false);
      return;
    }
    Analytics.logEvent(AnalyticsEvents.captureSummaryProceedToUpload, {
      'phase': 'guided_capture',
      'session_id': _sessionId,
      'any_level_below_min': anyBelowMin,
      'device_type': _deviceType,
    });
    Analytics.logEvent(AnalyticsEvents.uploadInitiated, {
      'session_id': _sessionId,
      'phase': 'upload',
      'device_type': _deviceType,
    });
    if (!mounted) return;
    context.go(AppRoutes.uploading);
  }

  /// Routes to [target]'s capture to add shots — the Fix Issues CTA (most-work
  /// level) and the hard-gate remedy rows (a specific short level) share this.
  /// [target] is null only when there is nothing to fix (action not shown).
  void _onFixIssues(CaptureLevel? target) {
    if (_navigating || target == null) return;
    _navigating = true;
    Analytics.logEvent(AnalyticsEvents.captureSummaryAction, {
      'phase': 'guided_capture',
      'session_id': _sessionId,
      'action': 'fix_issues',
      'target_level': target.code,
      'device_type': _deviceType,
    });
    context.go(_captureRouteForLevel(target));
  }

  /// Save for later — exits to the project list. The captured session is persisted
  /// by the capture flow (CaptureSessionStore) and resumable; this screen owns no
  /// new persistence — it exits cleanly.
  void _onSaveForLater() {
    if (_navigating) return;
    _navigating = true;
    Analytics.logEvent(AnalyticsEvents.captureSummaryAction, {
      'phase': 'guided_capture',
      'session_id': _sessionId,
      'action': 'save_for_later',
      'device_type': _deviceType,
    });
    context.go(AppRoutes.projects);
  }

  /// Surfaces the offline block with the app's standard SnackBar pattern.
  void _showOfflineBlocked() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const Key('summary_offline_snack'),
        backgroundColor: AppColors.warning,
        content: const Text("You're offline — reconnect to upload."),
      ),
    );
  }

  /// Confirms uploading while one or more levels are short of completion. Returns
  /// true to proceed, false to stay. Dismiss == cancel.
  Future<bool> _confirmBelowMin(String incompleteLabel) async {
    final plural = incompleteLabel.contains(',');
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('below_min_dialog'),
        backgroundColor: AppColors.surface1,
        title: const Text('Some levels are incomplete'),
        content: Text(
          'Level${plural ? 's' : ''} $incompleteLabel ${plural ? "haven't" : "hasn't"} '
          'reached the recommended coverage. You can upload anyway, but the model '
          'quality may be lower — or Fix Issues to capture more first.',
        ),
        actions: [
          TextButton(
            key: const Key('below_min_cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep capturing'),
          ),
          TextButton(
            key: const Key('below_min_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Upload anyway'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Per-card review entry. Routes to the review grid and refreshes on return.
  /// (Review does not latch [_navigating] — it returns here.)
  Future<void> _onReview(CaptureLevel level) async {
    Analytics.logEvent(AnalyticsEvents.captureSummaryAction, {
      'phase': 'guided_capture',
      'session_id': _sessionId,
      'action': 'review',
      'level': level.code,
      'device_type': _deviceType,
    });
    await context.push(_reviewRouteForLevel(level));
    if (mounted) _refreshAfterReview();
  }

  void _onWarningsExpanded(bool expanded, int warningCount) {
    setState(() => _warningsExpanded = expanded);
    if (expanded) {
      Analytics.logEvent(AnalyticsEvents.captureSummaryWarningsExpanded, {
        'phase': 'guided_capture',
        'session_id': _sessionId,
        'warning_count': warningCount,
        'device_type': _deviceType,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final summaries = ref.watch(captureSummaryProvider);
    // Keep the count-only completion gate's funnel-end milestone firing as before
    // (it is the session-complete funnel, separate from this screen's coverage-aware
    // display/actions).
    final gate = ref.watch(completionGateProvider);
    ref
        .read(summaryGateAnalyticsProvider.notifier)
        .syncUnlockMilestone(gate, sessionId: _sessionId);

    // The HARD upload floor — drives whether Upload is enabled at all.
    final uploadGate = ref.watch(uploadGateProvider);
    ref
        .read(uploadGateAnalyticsProvider.notifier)
        .syncPassedMilestone(uploadGate, sessionId: _sessionId);

    final overallComplete = allLevelsComplete(summaries);
    final mostWork = mostWorkLevel(summaries);
    final incompleteLabel =
        [for (final s in summaries) if (!s.isComplete) s.level.code].join(',');
    final totalPhotos = summaries.fold<int>(0, (sum, s) => sum + s.frameCount);
    final allWarnings = [for (final s in summaries) ...s.warnings];

    // Per-level upload deficit (0 when the level meets its absolute minimum) —
    // keyed by level code so cards can flag the hard-blocked level.
    final uploadDeficits = {
      for (final l in uploadGate.shortLevels) l.levelCode: l.deficit,
    };

    return PopScope(
      key: const Key('summary_cancel_popscope'),
      // System/hardware back must route through the cancel confirmation, never a
      // silent exit that could bypass Keep-as-Draft or lose data.
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
          title: Text('Capture summary',
              style: Theme.of(context).textTheme.titleLarge),
        ),
        body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    overallComplete
                        ? 'All levels complete — ready to upload.'
                        : 'Review each level, then upload or fix issues.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Total photos: $totalPhotos',
                    key: const Key('summary_total_photos'),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  for (final s in summaries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: _LevelSummaryCard(
                        summary: s,
                        uploadDeficit: uploadDeficits[s.level.code] ?? 0,
                        onReview: () => _onReview(s.level),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.lg),
                  _WarningsSection(
                    warnings: allWarnings,
                    expanded: _warningsExpanded,
                    onExpansionChanged: (e) =>
                        _onWarningsExpanded(e, allWarnings.length),
                  ),
                ],
              ),
            ),
          ),
          // Offline banner — pinned just above the Upload CTA (the action it
          // gates), so it's always visible without obscuring the scrolling cards
          // or warnings list. Renders nothing when online (no reserved space).
          if (_offline) const _OfflineBanner(),
          _BottomBar(
            uploadEligible: uploadGate.eligible,
            shortLevels: uploadGate.shortLevels,
            anyLevelBelowMin: !overallComplete,
            showFixIssues: mostWork != null,
            onUpload: () => _onUpload(
              anyBelowMin: !overallComplete,
              incompleteLabel: incompleteLabel,
            ),
            onFixShortLevel: (code) =>
                _onFixIssues(captureLevelFromLabel(code)),
            onFixIssues: () => _onFixIssues(mostWork),
            onSaveForLater: _onSaveForLater,
            onCancel: startCaptureCancelFlow,
          ),
        ],
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.uploadEligible,
    required this.shortLevels,
    required this.anyLevelBelowMin,
    required this.showFixIssues,
    required this.onUpload,
    required this.onFixShortLevel,
    required this.onFixIssues,
    required this.onSaveForLater,
    required this.onCancel,
  });

  /// Hard upload gate: false → Upload is disabled (any level below its absolute
  /// minimum accepted shots).
  final bool uploadEligible;

  /// The levels below their absolute minimum (the disabled-state messaging).
  final List<UploadLevelStatus> shortLevels;

  /// Soft: some level is below completion (coverage/count) but ABOVE the hard
  /// floor — Upload stays enabled (warn-then-allow).
  final bool anyLevelBelowMin;
  final bool showFixIssues;
  final VoidCallback onUpload;

  /// Remedy: navigate to a specific short level's capture (by level code).
  final ValueChanged<String> onFixShortLevel;
  final VoidCallback onFixIssues;
  final VoidCallback onSaveForLater;

  /// Opens the safe-leave confirmation (Keep as Draft / Discard / Keep editing).
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    // The disabled-Upload reason (also the screen-reader label) — never silent.
    final disabledReason = uploadEligible
        ? null
        : 'Upload disabled — add more shots to '
            '${shortLevels.map((l) => 'Level ${l.levelCode}').join(', ')}.';
    return Material(
      color: AppColors.bgPrimary,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!uploadEligible)
                _UploadGateNotice(
                  shortLevels: shortLevels,
                  onFixShortLevel: onFixShortLevel,
                )
              else if (anyLevelBelowMin)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Text(
                    'Some levels are incomplete — you can still upload.',
                    key: const Key('below_min_notice'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.warning),
                  ),
                ),
              // PRIMARY CTA — disabled (null onPressed) by the hard gate; the
              // reason is exposed visually (notice) and to a11y (Semantics).
              Semantics(
                button: true,
                enabled: uploadEligible,
                label: disabledReason,
                child: AppButton(
                  key: const Key('summary_upload'),
                  label: 'Upload',
                  icon: Icons.cloud_upload_outlined,
                  onPressed: uploadEligible ? onUpload : null,
                ),
              ),
              if (showFixIssues) ...[
                const SizedBox(height: AppSpacing.sm),
                AppButton.secondary(
                  key: const Key('summary_fix_issues'),
                  label: 'Fix Issues',
                  onPressed: onFixIssues,
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              AppButton.secondary(
                key: const Key('summary_save'),
                label: 'Save for later',
                onPressed: onSaveForLater,
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton.secondary(
                key: const Key('summary_cancel'),
                label: 'Cancel',
                icon: Icons.close,
                onPressed: onCancel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The hard-gate disabled-state message: names each short level with its
/// accepted/required counts + deficit, and offers a tap-through remedy to that
/// level's capture. Scroll-safe — a long list wraps without overflow.
class _UploadGateNotice extends StatelessWidget {
  const _UploadGateNotice({
    required this.shortLevels,
    required this.onFixShortLevel,
  });

  final List<UploadLevelStatus> shortLevels;
  final ValueChanged<String> onFixShortLevel;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.sm);
    return Container(
      key: const Key('upload_gate_notice'),
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: radius,
        border: Border.all(color: AppColors.error.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.block, color: AppColors.error, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Add more shots before uploading',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.error,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          for (final l in shortLevels)
            InkWell(
              key: Key('upload_remedy_${l.levelCode}'),
              onTap: () => onFixShortLevel(l.levelCode),
              borderRadius: BorderRadius.circular(AppRadius.xs),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Level ${l.levelCode}: ${l.accepted}/${l.required} '
                        '— needs ${l.deficit} more',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppColors.textSecondary),
                      ),
                    ),
                    const Icon(Icons.chevron_right,
                        size: 18, color: AppColors.textMuted),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The connectivity-offline banner — reuses the screen's established notice idiom
/// (bordered [AppColors.surface1] container + icon + text, design tokens only,
/// like [_UploadGateNotice]). Amber (a recoverable warning), distinct from the red
/// hard-gate. Shown only while offline; the parent renders nothing when online.
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Container(
        key: const Key('summary_offline_banner'),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.6)),
        ),
        child: Row(
          children: [
            const Icon(Icons.wifi_off, color: AppColors.warning, size: 18),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                "You're offline. Reconnect to upload your capture.",
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.warning,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LevelSummaryCard extends StatelessWidget {
  const _LevelSummaryCard({
    required this.summary,
    required this.uploadDeficit,
    required this.onReview,
  });

  final LevelCaptureSummary summary;

  /// How many more accepted shots this level needs to clear the HARD upload floor
  /// (0 when it meets the absolute minimum). When > 0 the card flags it in error
  /// styling (distinct from the amber soft-shortfall hint).
  final int uploadDeficit;
  final VoidCallback onReview;

  /// "Need 3 more segments • 2 more photos" — the surfaced shortfall, or null
  /// when the level is complete.
  static String? _shortfallHint(LevelCompletion c) {
    if (c.isComplete) return null;
    final parts = <String>[];
    if (c.segmentsShort > 0) {
      parts.add('${c.segmentsShort} more segment${c.segmentsShort == 1 ? '' : 's'}');
    }
    if (c.photosShort > 0) {
      parts.add('${c.photosShort} more photo${c.photosShort == 1 ? '' : 's'}');
    }
    return parts.isEmpty ? 'Incomplete' : 'Need ${parts.join(' • ')}';
  }

  @override
  Widget build(BuildContext context) {
    final complete = summary.isComplete;
    final coverage = summary.coveragePct;
    final coverageText = coverage == null ? '—' : '$coverage%';
    final hint = _shortfallHint(summary.completion);
    return AppCard(
      onTap: onReview,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Thumb(path: summary.thumbnailPath),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Level ${summary.level.code} • ${summary.name}',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    _Stat(
                      label: 'Frames',
                      value: '${summary.frameCount} / ${summary.minRequired}',
                      valueColor:
                          complete ? AppColors.textPrimary : AppColors.warning,
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    _Stat(label: 'Coverage', value: coverageText),
                  ],
                ),
                // Hard-floor block takes precedence over the soft shortfall hint.
                if (uploadDeficit > 0) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Below upload minimum — add $uploadDeficit more',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                            color: AppColors.error, fontWeight: FontWeight.w600),
                  ),
                ] else if (hint != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    hint,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.warning),
                  ),
                ],
                const SizedBox(height: AppSpacing.xs),
                _WarningIndicator(count: summary.warningCount),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _StatusChip(complete: complete),
        ],
      ),
    );
  }
}

/// A small labelled metric ("Frames 3 / 1", "Coverage 30%").
class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: AppColors.textMuted);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: muted),
        Text(
          value,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: valueColor ?? AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }
}

/// Per-level warning indicator: muted "No warnings" or an amber count.
class _WarningIndicator extends StatelessWidget {
  const _WarningIndicator({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count == 0) {
      return Text(
        'No warnings',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: AppColors.textMuted),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.warning_amber_rounded,
            size: 16, color: AppColors.warning),
        const SizedBox(width: AppSpacing.xs),
        Text(
          '$count warning${count == 1 ? '' : 's'}',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.warning, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// Status pill: complete (check) vs incomplete (alert), using design tokens only.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.complete});

  final bool complete;

  @override
  Widget build(BuildContext context) {
    final color = complete ? AppColors.success : AppColors.warning;
    final label = complete ? 'Complete' : 'Incomplete';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(complete ? Icons.check_circle : Icons.error_outline,
              color: color, size: 18),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// The aggregated, collapsible warnings list (collapsed by default). With zero
/// warnings it shows a clear "no warnings" state instead of an empty expandable.
/// Children are built only while expanded, so a long list costs nothing collapsed.
class _WarningsSection extends StatelessWidget {
  const _WarningsSection({
    required this.warnings,
    required this.expanded,
    required this.onExpansionChanged,
  });

  final List<CaptureWarning> warnings;
  final bool expanded;
  final ValueChanged<bool> onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    if (warnings.isEmpty) {
      return AppCard(
        key: const Key('no_warnings'),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: AppColors.success, size: 18),
            const SizedBox(width: AppSpacing.sm),
            Text(
              'No warnings during capture',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    final radius = BorderRadius.circular(AppRadius.sm);
    final shape = RoundedRectangleBorder(borderRadius: radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: radius,
        border: Border.all(
          color: AppColors.disabled.withValues(alpha: 0.4),
          width: 0.5,
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: ExpansionTile(
          key: const Key('warnings_expansion'),
          initiallyExpanded: expanded,
          onExpansionChanged: onExpansionChanged,
          shape: shape,
          collapsedShape: shape,
          iconColor: AppColors.textPrimary,
          collapsedIconColor: AppColors.textSecondary,
          leading: const Icon(Icons.warning_amber_rounded,
              color: AppColors.warning),
          title: Text(
            '${warnings.length} warning${warnings.length == 1 ? '' : 's'}',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: AppColors.textPrimary),
          ),
          childrenPadding: const EdgeInsets.only(
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            bottom: AppSpacing.sm,
          ),
          children: expanded
              ? [for (final w in warnings) _WarningRow(warning: w)]
              : const [],
        ),
      ),
    );
  }
}

class _WarningRow extends StatelessWidget {
  const _WarningRow({required this.warning});

  final CaptureWarning warning;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.circle, size: 6, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.sm),
          Text(
            'Level ${warning.level.code}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              warning.message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Square representative thumbnail, downscale-decoded (same mechanism as the
/// review grid). A missing path or a decode failure degrades to a neutral
/// placeholder — never a crash.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.path});

  final String? path;

  static const double _size = 56;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.xs);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(color: AppColors.surface2, borderRadius: radius),
      child: const Center(
        child: Icon(Icons.photo_outlined,
            size: 22, color: AppColors.textMuted),
      ),
    );

    return SizedBox(
      width: _size,
      height: _size,
      child: path == null
          ? placeholder
          : ClipRRect(
              borderRadius: radius,
              child: Image.file(
                File(path!),
                fit: BoxFit.cover,
                cacheWidth: (_size * dpr).round(),
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => placeholder,
              ),
            ),
    );
  }
}
