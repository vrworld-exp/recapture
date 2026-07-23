// lib/presentation/screens/capture/level_a_complete_screen.dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/analytics/capture_analytics.dart';
import '../../../application/capture/analytics/capture_level_events.dart';
import '../../../application/capture/analytics/capture_level_session.dart';
import '../../../domain/entities/capture_thumbnail.dart';
import '../../../domain/entities/level_a_summary.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';

/// Level A (Eye Ring) completion screen: a restrained on-brand recap once the
/// eye-ring meets its target/coverage threshold, with the next actions —
/// "Start Level B" (primary), "Review" (secondary), and an optional "Done".
///
/// Presentational + intent only: it renders the supplied [LevelASummary] (whose
/// numbers come from the SAME source as the in-capture progress meter + ring map)
/// and emits [onStartLevelB] / [onReview] / [onDoneExit]. It computes nothing,
/// saves nothing, and navigates nowhere — the parent (route builder) does that.
///
/// A brief gold-check scale-in marks completion; reduce-motion makes it static.
/// CTAs are debounced so a rapid double-tap fires a single intent.
class LevelACompleteScreen extends ConsumerStatefulWidget {
  const LevelACompleteScreen({
    super.key,
    required this.summary,
    required this.onStartLevelB,
    required this.onReview,
    this.onDoneExit,
    this.startLevelBEnabled = true,
    this.nextLabel,
  });

  final LevelASummary summary;
  final VoidCallback onStartLevelB;
  final VoidCallback onReview;

  /// Optional "finish after Level A" path. Hidden when null.
  final VoidCallback? onDoneExit;

  /// When false, "Start Level B" is disabled with a note (Level B unavailable).
  final bool startLevelBEnabled;

  /// Primary-CTA label. Defaults to "Start Level B" (the full A→B→C flow); the
  /// single-ring Meshy flow passes "Continue" since Level A IS the whole capture
  /// and the CTA goes straight to the Summary.
  final String? nextLabel;

  @override
  ConsumerState<LevelACompleteScreen> createState() =>
      _LevelACompleteScreenState();
}

class _LevelACompleteScreenState extends ConsumerState<LevelACompleteScreen>
    with SingleTickerProviderStateMixin {
  /// Gold-check scale-in. Static under reduce-motion.
  late final AnimationController _celebrate;
  bool _celebrateStarted = false;

  /// One-shot guard so a rapid double-tap on any CTA fires a single intent.
  bool _dispatched = false;

  static String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  @override
  void initState() {
    super.initState();
    _celebrate = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    // Canonical lifecycle event — fired once per session completion. The session
    // (started by the capture screen) supplies the shared session_id + duration;
    // the completion latch in the provider prevents a re-visit of THIS completion
    // from double-emitting. A missing session (restart/deep-link) still emits once
    // with an empty session_id + 0 duration, never a missing/NaN field.
    final claim = ref.read(captureLevelSessionProvider.notifier).claimCompletion();
    if (claim.shouldEmit) {
      final s = widget.summary;
      final session = claim.session;
      CaptureAnalytics.log(CaptureLevelCompleted(
        level: CaptureLevel.a, // this is the Level A completion screen
        projectId: session?.projectId ?? '',
        sessionId: session?.sessionId ?? '',
        accepted: s.accepted,
        target: s.target,
        rejected: s.rejected,
        coveragePct: s.coveragePct.clamp(0.0, 100.0).round(),
        durationSeconds: session?.durationSecondsUntil(DateTime.now()) ?? 0,
        deviceType: _deviceType,
      ));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_celebrateStarted) return;
    _celebrateStarted = true;
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      _celebrate.value = 1; // static completion state
    } else {
      _celebrate.forward();
    }
  }

  @override
  void dispose() {
    _celebrate.dispose();
    super.dispose();
  }

  void _dispatch(String action, VoidCallback cb) {
    if (_dispatched) return;
    _dispatched = true;
    Analytics.logEvent(AnalyticsEvents.levelACompleteAction, {'action': action});
    cb();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.summary;

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.xl),
              _CompletionHeader(scale: _celebrate),
              const SizedBox(height: AppSpacing.xxl),
              _SummaryCard(summary: s),
              if (s.highlights.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.lg),
                _Montage(highlights: s.highlights),
              ],
              const SizedBox(height: AppSpacing.xxl),
              AppButton(
                label: widget.nextLabel ?? 'Start Level B',
                icon: Icons.arrow_forward,
                onPressed: widget.startLevelBEnabled
                    ? () => _dispatch('start_level_b', widget.onStartLevelB)
                    : null,
              ),
              if (!widget.startLevelBEnabled) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Level B is coming soon.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.textMuted),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              AppButton.secondary(
                label: 'Review',
                onPressed: () => _dispatch('review', widget.onReview),
              ),
              if (widget.onDoneExit != null) ...[
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: () => _dispatch('done_exit', widget.onDoneExit!),
                  child: Text(
                    'Done',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: AppColors.textSecondary),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }
}

/// Gold check (scale-in) over a "Level A complete" headline.
class _CompletionHeader extends StatelessWidget {
  const _CompletionHeader({required this.scale});

  final Animation<double> scale;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ScaleTransition(
          scale: CurvedAnimation(parent: scale, curve: Curves.easeOutBack),
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.royalGold.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_circle,
                size: 48, color: AppColors.royalGold),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Level A complete',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ],
    );
  }
}

/// The recap card: accepted/target, coverage % (+ a thin bar), and a rejected
/// row when there were discards.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final LevelASummary summary;

  @override
  Widget build(BuildContext context) {
    final coveragePct = summary.coveragePct.clamp(0.0, 100.0).round();
    final coverageColor =
        coveragePct >= 80 ? AppColors.success : AppColors.warning;

    return AppCard(
      child: Column(
        children: [
          _StatRow(
            label: 'Photos accepted',
            value: '${summary.accepted}/${summary.target}',
            valueColor: AppColors.textPrimary,
          ),
          const _GoldDivider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StatRow(
                  label: 'Coverage',
                  value: '$coveragePct%',
                  valueColor: coverageColor,
                  dense: true,
                ),
                const SizedBox(height: AppSpacing.sm),
                _CoverageBar(
                    fraction: summary.coverageFraction, color: coverageColor),
              ],
            ),
          ),
          if (summary.rejected > 0) ...[
            const _GoldDivider(),
            _StatRow(
              label: 'Discarded',
              value: '${summary.rejected}',
              valueColor: AppColors.warning,
            ),
          ],
        ],
      ),
    );
  }
}

class _CoverageBar extends StatelessWidget {
  const _CoverageBar({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: AppColors.surface2)),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fraction.clamp(0.0, 1.0),
              child: ColoredBox(color: color),
            ),
          ],
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
    this.dense = false,
  });

  final String label;
  final String value;
  final Color valueColor;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 0 : AppSpacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textSecondary),
          ),
          Text(
            value,
            style: theme.textTheme.bodyLarge
                ?.copyWith(fontWeight: FontWeight.bold, color: valueColor),
          ),
        ],
      ),
    );
  }
}

class _GoldDivider extends StatelessWidget {
  const _GoldDivider();

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: AppColors.royalGold.withValues(alpha: 0.3));
}

/// A small wrap-grid of representative thumbnails. Each tile downscale-decodes
/// (cacheWidth matched to the tile's pixel size) so a full-res photo never
/// decodes for a small tile — mirrors the thumbnail strip. Missing/corrupt files
/// fall back to a neutral tile; loading shows a neutral surface.
class _Montage extends StatelessWidget {
  const _Montage({required this.highlights});

  final List<CaptureThumbnail> highlights;

  static const int _maxTiles = 6;
  static const double _tile = 64;

  @override
  Widget build(BuildContext context) {
    final tiles = highlights.take(_maxTiles).toList();
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [for (final t in tiles) _MontageTile(thumbnail: t, size: _tile)],
    );
  }
}

class _MontageTile extends StatelessWidget {
  const _MontageTile({required this.thumbnail, required this.size});

  final CaptureThumbnail thumbnail;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cachePx = (size * dpr).round();

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.file(
          File(thumbnail.filePath),
          fit: BoxFit.cover,
          cacheWidth: cachePx,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSync) =>
              frame == null ? _surface() : child,
          errorBuilder: (context, _, __) => _surface(
            child: const Icon(Icons.broken_image_outlined,
                size: 20, color: AppColors.textMuted),
          ),
        ),
      ),
    );
  }

  Widget _surface({Widget? child}) => SizedBox(
        width: size,
        height: size,
        child: ColoredBox(
          color: AppColors.surface2,
          child: Center(child: child),
        ),
      );
}
