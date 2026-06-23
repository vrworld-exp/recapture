// lib/presentation/widgets/auto_capture_indicator.dart
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/auto_capture_state.dart';

/// Level A auto-capture pill: shows AUTO ON / AUTO OFF and toggles the mode via
/// [onToggle]. Presentational + intent only — it renders the supplied
/// [AutoCaptureState] and requests toggles; it does NOT run the capture loop or
/// persist anything (the parent owns mode + persistence).
///
/// When ON and a shot is imminent it shows an armed accent, plus a thin countdown
/// bar reflecting [AutoCaptureState.effectiveCountdown] (clamped 0..1). Armed /
/// countdown are ignored when OFF. Reduce-motion drops the animated countdown bar
/// and shows static armed styling. The repaint is isolated ([RepaintBoundary]) so
/// frequent countdown updates don't repaint the rest of the HUD.
class AutoCaptureIndicator extends StatelessWidget {
  const AutoCaptureIndicator({
    super.key,
    required this.state,
    required this.onToggle,
  });

  final AutoCaptureState state;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final on = state.isOn;
    final countdown = state.effectiveCountdown;
    final armed = state.effectiveArmed || countdown != null;

    final baseColor = on ? AppColors.success : AppColors.textMuted;
    final accent = armed ? AppColors.mirageRed : baseColor;
    final showBar = on && countdown != null && !reduceMotion;

    final pill = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgPrimary.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: accent.withValues(alpha: on ? 0.9 : 0.5),
          width: on ? 1.5 : 1,
        ),
      ),
      // IntrinsicWidth bounds the column to the row's width so the (stretched)
      // countdown bar spans the pill without forcing an infinite width.
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  on ? Icons.bolt : Icons.bolt_outlined,
                  size: 14,
                  color: accent,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  on ? 'AUTO ON' : 'AUTO OFF',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: on ? AppColors.textPrimary : AppColors.textMuted,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                ),
              ],
            ),
            if (showBar)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: _CountdownBar(value: countdown),
              ),
          ],
        ),
      ),
    );

    return RepaintBoundary(
      child: Semantics(
        button: true,
        toggled: on,
        label: on ? 'Auto capture on' : 'Auto capture off',
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: pill,
          ),
        ),
      ),
    );
  }
}

/// A thin imminent-shot progress bar (Mirage Red fill over a muted track).
/// [value] is already clamped to 0..1 by [AutoCaptureState.effectiveCountdown].
class _CountdownBar extends StatelessWidget {
  const _CountdownBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: Stack(
          children: [
            const Positioned.fill(
              child: ColoredBox(color: AppColors.surface2),
            ),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: value,
              child: const ColoredBox(color: AppColors.mirageRed),
            ),
          ],
        ),
      ),
    );
  }
}
