// lib/presentation/screens/capture/level_complete_screen.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/analytics/capture_analytics.dart';
import '../../../application/capture/analytics/capture_level_events.dart';
import '../../../application/capture/analytics/capture_level_session.dart';
import '../../../application/capture/capture_flow_variant_provider.dart';
import '../../../application/config/config_notifier.dart';
import '../../../domain/entities/capture_config.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';

/// Generic per-level completion interstitial (Levels B & C; Screen 6B-Complete is
/// the Level B instance). A parameterized recap once a level's capture pass meets
/// its gate, with the next actions — "[nextLabel]" (advance) and "Review
/// [levelName]" (this level's review grid). The last level passes a finish-style
/// [nextLabel]/[nextRoute] (e.g. "Continue" → the summary) instead of a next level.
///
/// Presentational + intent: it renders the supplied stats and navigates via
/// [nextRoute]/[reviewRoute]. Parity with the rich Level A completion screen: it
/// emits the canonical level-tagged `capture_level_completed` once per session
/// completion (the ONLY emitter of that funnel event for B/C) and guards a rapid
/// double-tap so each CTA dispatches a single navigation.
class LevelCompleteScreen extends ConsumerStatefulWidget {
  const LevelCompleteScreen({
    super.key,
    required this.levelLabel,
    required this.levelName,
    required this.photosAccepted,
    required this.coveragePercent,
    required this.warningsCount,
    required this.nextRoute,
    required this.nextLabel,
    required this.reviewRoute,
  });

  final String levelLabel;
  final String levelName;
  final int photosAccepted;
  final int coveragePercent;
  final int warningsCount;
  final String nextRoute;
  final String nextLabel;
  final String reviewRoute;

  @override
  ConsumerState<LevelCompleteScreen> createState() =>
      _LevelCompleteScreenState();
}

class _LevelCompleteScreenState extends ConsumerState<LevelCompleteScreen> {
  /// Photos-accepted denominator shown in the recap ("X / N") AND reported as
  /// `target` in the completion analytics — one place so the two never disagree.
  /// N is this level's effective ring segment count (config × flow variant),
  /// through the same [effectiveSegmentsFor] resolver the flow uses.
  int get _displayTarget => effectiveSegmentsFor(
        ref.read(captureConfigProvider),
        ref.read(captureFlowVariantProvider),
        pitchBandIdForLevel(_level),
      );

  /// One-shot guard so a rapid double-tap on either CTA fires a single nav.
  bool _dispatched = false;

  static String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  CaptureLevel get _level => captureLevelFromLabel(widget.levelLabel);

  @override
  void initState() {
    super.initState();
    // Canonical lifecycle event — once per session completion, level-tagged. The
    // session (started by the capture screen) supplies the shared session_id +
    // duration; the provider's latch stops a re-visit from double-emitting. For
    // B/C this is the ONLY emitter of capture_level_completed (the Level A screen
    // covers level A), so without it the funnel has no completed event past A.
    final claim =
        ref.read(captureLevelSessionProvider.notifier).claimCompletion();
    if (claim.shouldEmit) {
      final session = claim.session;
      CaptureAnalytics.log(CaptureLevelCompleted(
        level: _level,
        projectId: session?.projectId ?? '',
        sessionId: session?.sessionId ?? '',
        accepted: widget.photosAccepted,
        target: _displayTarget,
        // This screen surfaces warnings, not rejects; rejected isn't tracked here
        // (the stats are placeholders until real per-level aggregation lands).
        rejected: 0,
        coveragePct: widget.coveragePercent.clamp(0, 100),
        durationSeconds: session?.durationSecondsUntil(DateTime.now()) ?? 0,
        deviceType: _deviceType,
      ));
    }
  }

  /// Logs the CTA [action] (level-tagged) then runs [nav] — once. A second rapid
  /// tap (on either CTA) is swallowed so navigation fires a single time.
  void _dispatch(String action, VoidCallback nav) {
    if (_dispatched) return;
    _dispatched = true;
    Analytics.logEvent(AnalyticsEvents.levelCompleteAction, {
      'action': action,
      'level': _level.code,
      'device_type': _deviceType,
    });
    nav();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle,
                  size: 48,
                  color: AppColors.success,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Level ${widget.levelLabel} complete',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.xxl),
              AppCard(
                child: Column(
                  children: [
                    _StatRow(
                      label: 'Photos accepted',
                      value: '${widget.photosAccepted} / $_displayTarget',
                      valueColor: AppColors.textPrimary,
                    ),
                    const _GoldDivider(),
                    _StatRow(
                      label: 'Coverage',
                      value: '${widget.coveragePercent}%',
                      valueColor: widget.coveragePercent > 80
                          ? AppColors.success
                          : AppColors.warning,
                    ),
                    const _GoldDivider(),
                    _StatRow(
                      label: 'Warnings',
                      value: '${widget.warningsCount}',
                      valueColor: widget.warningsCount > 0
                          ? AppColors.warning
                          : AppColors.success,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
              AppButton(
                label: widget.nextLabel,
                onPressed: () =>
                    _dispatch('start_next', () => context.go(widget.nextRoute)),
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton.secondary(
                label: 'Review ${widget.levelName}',
                onPressed: () =>
                    _dispatch('review', () => context.push(widget.reviewRoute)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textSecondary),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: valueColor,
                ),
          ),
        ],
      ),
    );
  }
}

class _GoldDivider extends StatelessWidget {
  const _GoldDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: AppColors.royalGold.withValues(alpha: 0.3),
    );
  }
}
