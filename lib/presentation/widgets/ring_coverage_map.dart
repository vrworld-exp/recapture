// lib/presentation/widgets/ring_coverage_map.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/ring_coverage.dart';

/// Level A (Eye Ring) coverage map: a compact segmented donut in the lower-left
/// corner showing, at a glance, how much of the 360° eye-level circle is
/// captured. Each segment is coloured by [RingCoverage.stateOf] — filled
/// (captured), target (current/next, emphasised), missing (uncaptured) — with a
/// compact "X/N" readout in the centre.
///
/// It RENDERS a supplied [RingCoverage]; it does not compute yaw, fills, or the
/// target. Newly-filled segments animate in and the target segment pulses;
/// reduce-motion makes both instant. Guidance-only and hit-test transparent; the
/// ring's repaint is isolated (a [RepaintBoundary] + a painter `repaint`
/// listenable) so animation never repaints the rest of the HUD.
class RingCoverageMap extends StatefulWidget {
  const RingCoverageMap({
    super.key,
    required this.coverage,
    this.diameter = 76,
  });

  final RingCoverage coverage;
  final double diameter;

  @override
  State<RingCoverageMap> createState() => _RingCoverageMapState();
}

class _RingCoverageMapState extends State<RingCoverageMap>
    with TickerProviderStateMixin {
  /// Pulses the target segment.
  late final AnimationController _pulse;

  /// Drives the missing→filled ramp for [_animatingFill] segments (one-shot).
  late final AnimationController _fill;

  /// Segments newly filled since the last update (animate from missing→filled).
  Set<int> _animatingFill = const {};

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _fill = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addStatusListener((s) {
        if (s == AnimationStatus.completed && mounted) {
          setState(() => _animatingFill = const {});
        }
      });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse(); // reduce-motion (MediaQuery) available here
  }

  @override
  void didUpdateWidget(RingCoverageMap oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Detect freshly captured segments to animate (in-range only).
    final before = oldWidget.coverage.filledIndices;
    final newlyFilled = widget.coverage.filledIndices
        .where((i) => i >= 0 && i < widget.coverage.segmentCount)
        .where((i) => !before.contains(i))
        .toSet();
    if (newlyFilled.isNotEmpty) {
      final reduceMotion =
          MediaQuery.maybeOf(context)?.disableAnimations ?? false;
      _animatingFill = newlyFilled;
      if (reduceMotion) {
        _animatingFill = const {}; // instant: skip the ramp
      } else {
        _fill.forward(from: 0);
      }
    }

    if (oldWidget.coverage.effectiveTarget != widget.coverage.effectiveTarget) {
      _syncPulse();
    }
  }

  /// Pulses only when there is a target and motion is allowed.
  void _syncPulse() {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final shouldPulse =
        widget.coverage.effectiveTarget != null && !reduceMotion;
    if (shouldPulse) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else if (_pulse.isAnimating || _pulse.value != 0) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coverage = widget.coverage;

    // Nothing to show without segments (config not loaded / N=0) — no NaN, no
    // empty circle artifact.
    if (coverage.segmentCount <= 0) return const SizedBox.shrink();

    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return Positioned(
      left: AppSpacing.lg,
      bottom: 120,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: SizedBox(
            width: widget.diameter,
            height: widget.diameter,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: Size.square(widget.diameter),
                  painter: _RingPainter(
                    coverage: coverage,
                    pulse: _pulse,
                    fill: _fill,
                    animatingFill: _animatingFill,
                    reduceMotion: reduceMotion,
                  ),
                ),
                // Centre readout — outside the painter so it does not repaint per
                // animation frame.
                Text(
                  '${coverage.filledCount}/${coverage.segmentCount}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: coverage.isComplete
                            ? AppColors.success
                            : AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.coverage,
    required this.pulse,
    required this.fill,
    required this.animatingFill,
    required this.reduceMotion,
  }) : super(repaint: Listenable.merge([pulse, fill]));

  final RingCoverage coverage;
  final Animation<double> pulse;
  final Animation<double> fill;
  final Set<int> animatingFill;
  final bool reduceMotion;

  static const Color _filled = AppColors.success;
  static const Color _target = AppColors.mirageRed;
  static const Color _missing = AppColors.disabled;

  @override
  void paint(Canvas canvas, Size size) {
    final n = coverage.segmentCount;
    if (n <= 0) return;

    final center = size.center(Offset.zero);
    final thickness = size.shortestSide * 0.16;
    final radius = (size.shortestSide - thickness) / 2 - 1;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Deep-black backing disc for legibility over a busy preview.
    canvas.drawCircle(
      center,
      size.shortestSide / 2,
      Paint()..color = AppColors.bgPrimary.withValues(alpha: 0.55),
    );

    final seg = (2 * math.pi) / n;
    // Gap scales with segment size so it stays proportional at large N.
    final gap = (seg * 0.18).clamp(0.0, 0.12);
    final fillT = reduceMotion ? 1.0 : fill.value;
    final pulseT = reduceMotion ? 0.0 : pulse.value;

    for (var i = 0; i < n; i++) {
      final state = coverage.stateOf(i);
      final start = -math.pi / 2 + i * seg + gap / 2;
      final sweep = seg - gap;

      Color color;
      var width = thickness;
      switch (state) {
        case SegmentState.filled:
          color = animatingFill.contains(i)
              ? Color.lerp(_missing, _filled, fillT)!
              : _filled;
          if (animatingFill.contains(i)) {
            width = thickness * (0.7 + 0.3 * fillT);
          }
        case SegmentState.target:
          color = _target;
        case SegmentState.missing:
          color = _missing;
      }

      // Target pulse: a soft wider glow behind the segment.
      if (state == SegmentState.target && pulseT > 0) {
        canvas.drawArc(
          rect,
          start,
          sweep,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = thickness + 6 * pulseT
            ..strokeCap = StrokeCap.round
            ..color = _target.withValues(alpha: 0.35 * (1 - pulseT)),
        );
      }

      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.coverage != coverage ||
      old.animatingFill != animatingFill ||
      old.reduceMotion != reduceMotion;
}
