// lib/presentation/widgets/progress_meter.dart
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/capture_progress.dart';

/// Level A textual progress meter: a compact top-centre chip reading
/// "Accepted: X/N • Coverage: P%" with an optional thin coverage bar. It
/// complements the visual ring coverage map with precise numbers.
///
/// It RENDERS a supplied [CaptureProgress] — it does not count captures, judge
/// acceptance, or compute coverage (those are the parent's job, and must derive
/// from the same source the ring map reads so the numbers always agree). The
/// accepted count ticks and the bar fills smoothly on change; identical
/// re-emits don't re-animate and reduce-motion makes every update instant.
///
/// Display-only and hit-test transparent. Self-positions in the top-centre slot,
/// safe-area aware and clear of the top bar, ring map, shutter, and other HUD
/// elements.
class ProgressMeter extends StatefulWidget {
  const ProgressMeter({
    super.key,
    required this.progress,
    this.showBar = true,
  });

  final CaptureProgress progress;

  /// Whether to render the thin coverage bar under the text line.
  final bool showBar;

  @override
  State<ProgressMeter> createState() => _ProgressMeterState();
}

class _ProgressMeterState extends State<ProgressMeter> {
  /// Tick/fill durations — short and cheap; the chip is isolated so animation
  /// never repaints the rest of the HUD.
  static const Duration _countTick = Duration(milliseconds: 400);
  static const Duration _barFill = Duration(milliseconds: 300);

  /// Once complete, latch so the chip doesn't flash "Complete" on/off as values
  /// jitter around the threshold. Only unlatches if coverage drops a clear
  /// margin below the threshold (hysteresis).
  static const double _completeHysteresisPct = 3;

  /// First-frame values so the meter doesn't animate up from 0 on screen entry.
  late final int _initialAccepted = widget.progress.accepted;
  late final double _initialCoverage = widget.progress.coveragePct;

  bool _latchedComplete = false;

  @override
  void initState() {
    super.initState();
    _latchedComplete = widget.progress.isComplete;
  }

  @override
  void didUpdateWidget(ProgressMeter oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateLatch();
  }

  /// Sticky completion: latch on once complete, unlatch only when coverage falls
  /// a clear margin below the threshold so the state never flickers.
  void _updateLatch() {
    final p = widget.progress;
    final next = p.isComplete ||
        (_latchedComplete &&
            p.target > 0 &&
            p.coveragePct >= p.completeAtPct - _completeHysteresisPct);
    if (next != _latchedComplete) {
      setState(() => _latchedComplete = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final theme = Theme.of(context);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: IgnorePointer(
          child: Padding(
            // Clear the CaptureTopBar (back / level indicator / help / settings)
            // that sits at the very top within the same SafeArea.
            padding: const EdgeInsets.only(top: 72),
            child: Center(
              child: RepaintBoundary(
                child: ConstrainedBox(
                  // Keep the chip from spanning the full width on large screens.
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      // Subtle scrim chip for legibility over a busy preview.
                      color: AppColors.bgPrimary.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                      border: _latchedComplete
                          ? Border.all(
                              color: AppColors.royalGold.withValues(alpha: 0.7),
                            )
                          : null,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildTextLine(theme, reduceMotion),
                        if (widget.showBar) ...[
                          const SizedBox(height: AppSpacing.xs),
                          _buildBar(reduceMotion),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextLine(ThemeData theme, bool reduceMotion) {
    final p = widget.progress;
    final baseStyle = theme.textTheme.labelMedium?.copyWith(
      color: AppColors.textPrimary,
      fontWeight: FontWeight.w600,
    );

    final line = reduceMotion
        ? Text(
            _format(p.accepted, p.target, p.coveragePct),
            key: const ValueKey('progress_meter_text'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: baseStyle,
          )
        // Nest two implicit tweens so the accepted count ticks (11→12) and the
        // coverage % counts up. TweenAnimationBuilder only animates when `end`
        // actually changes, so identical re-emits don't re-trigger.
        : TweenAnimationBuilder<int>(
            tween: IntTween(begin: _initialAccepted, end: p.accepted),
            duration: _countTick,
            curve: Curves.easeOut,
            builder: (context, animAccepted, _) {
              return TweenAnimationBuilder<double>(
                tween: Tween<double>(
                  begin: _initialCoverage,
                  end: p.coveragePct,
                ),
                duration: _countTick,
                curve: Curves.easeOut,
                builder: (context, animCoverage, __) {
                  return Text(
                    _format(animAccepted, p.target, animCoverage),
                    key: const ValueKey('progress_meter_text'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: baseStyle,
                  );
                },
              );
            },
          );

    if (!_latchedComplete) return line;

    // Complete emphasis — subtle gold check + "Complete", never loud.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: line),
        const SizedBox(width: AppSpacing.sm),
        const Icon(Icons.check_circle,
            size: 16, color: AppColors.royalGold),
        const SizedBox(width: AppSpacing.xs),
        Text(
          'Complete',
          style: baseStyle?.copyWith(color: AppColors.royalGold),
        ),
      ],
    );
  }

  Widget _buildBar(bool reduceMotion) {
    // The bar tracks coverage — the completion criterion — so it agrees with the
    // "Complete" state. Fraction is already clamped to [0, 1].
    final fraction = widget.progress.coverageFraction;
    final fillColor =
        _latchedComplete ? AppColors.royalGold : AppColors.success;

    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        width: 200,
        height: 4,
        child: Stack(
          children: [
            // Muted track.
            const Positioned.fill(
              child: ColoredBox(color: AppColors.disabled),
            ),
            // Animated fill (instant under reduce-motion).
            Align(
              alignment: Alignment.centerLeft,
              child: reduceMotion
                  ? FractionallySizedBox(
                      widthFactor: fraction,
                      child: ColoredBox(color: fillColor),
                    )
                  : TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: fraction, end: fraction),
                      duration: _barFill,
                      curve: Curves.easeOut,
                      builder: (context, value, _) => FractionallySizedBox(
                        widthFactor: value.clamp(0.0, 1.0),
                        child: ColoredBox(color: fillColor),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// "Accepted: X/N • Coverage: P%" with coverage clamped to 0..100. Raw accepted
  /// shows over-capture honestly (e.g. "38/36").
  String _format(int accepted, int target, double coveragePct) {
    final pct = coveragePct.clamp(0.0, 100.0).round();
    return 'Accepted: $accepted/$target • Coverage: $pct%';
  }
}
