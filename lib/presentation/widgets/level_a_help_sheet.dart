// lib/presentation/widgets/level_a_help_sheet.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../application/capture/capture_flow_variant_provider.dart';
import '../../application/config/config_notifier.dart';
import '../../domain/entities/capture_config.dart';
import '../../utils/analytics.dart';
import 'capture_tip.dart';

/// Opens the Level A Help sheet: a modal bottom sheet of 5–7 quick capture tips.
///
/// Matches the existing tooltip-sheet styling (rounded top, drag handle, dark
/// surface, scrim barrier). Always dismissible (swipe / tap-outside / close
/// button); the returned future completes on dismissal so the caller can resume
/// auto-capture. The sheet does NOT manage capture state — the parent pauses
/// before this `await` and resumes after it returns.
///
/// [onReplayIntro] (optional) adds a "Replay intro" footer action; tapping it
/// dismisses the sheet and invokes the callback (the parent shows the intro).
Future<void> showLevelAHelpSheet(
  BuildContext context, {
  List<CaptureTip> tips = levelACaptureTips,
  VoidCallback? onReplayIntro,
}) {
  Analytics.logEvent(AnalyticsEvents.levelAHelpOpened, {
    'device_type':
        defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
  });

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true, // tips may exceed half height
    backgroundColor: AppColors.surface1,
    barrierColor: AppColors.scrim,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (_) => LevelAHelpSheet(tips: tips, onReplayIntro: onReplayIntro),
  );
}

/// The Help sheet content. Reads [captureConfigProvider] (always a valid value,
/// bundled default before remote loads) to resolve any `{n}` count in the tips.
class LevelAHelpSheet extends ConsumerWidget {
  const LevelAHelpSheet({
    super.key,
    this.tips = levelACaptureTips,
    this.onReplayIntro,
  });

  final List<CaptureTip> tips;
  final VoidCallback? onReplayIntro;

  void _logAction(String action) {
    Analytics.logEvent(AnalyticsEvents.levelAHelpAction, {'action': action});
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // The Eye Ring's effective count (config × flow variant) — the same
    // resolver the flow uses, so the tip copy always names the real target.
    final segments = effectiveSegmentsFor(
      ref.watch(captureConfigProvider),
      ref.watch(captureFlowVariantProvider),
      'mid',
    );
    // Cap at 70% of the screen so long content / large font scales scroll
    // internally instead of overflowing.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.7;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xs,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Capture tips', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () {
                      _logAction('close');
                      Navigator.of(context).pop();
                    },
                  ),
                ],
              ),
            ),
            // Scrollable tips.
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                itemCount: tips.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: AppSpacing.lg),
                itemBuilder: (_, i) => _TipRow(
                  tip: tips[i],
                  segments: segments,
                ),
              ),
            ),
            if (onReplayIntro != null) _buildFooter(context, theme),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () {
            _logAction('replay_intro');
            // Dismiss first so we never stack the intro on top of the sheet.
            Navigator.of(context).pop();
            onReplayIntro?.call();
          },
          icon: const Icon(Icons.replay, color: AppColors.royalGold, size: 20),
          label: Text(
            'Replay intro',
            style: theme.textTheme.labelLarge
                ?.copyWith(color: AppColors.royalGold),
          ),
        ),
      ),
    );
  }
}

/// One tip: a gold-accented icon badge + title (prominent) over a grey body.
class _TipRow extends StatelessWidget {
  const _TipRow({required this.tip, required this.segments});

  final CaptureTip tip;
  final int segments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.royalGold.withValues(alpha: 0.14),
            shape: BoxShape.circle,
          ),
          child: Icon(tip.icon, color: AppColors.royalGold, size: 22),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tip.title,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                tip.formattedBody(segments),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.textSecondary, height: 1.4),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
