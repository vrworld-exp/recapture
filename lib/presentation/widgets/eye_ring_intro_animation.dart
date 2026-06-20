// lib/presentation/widgets/eye_ring_intro_animation.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// Instructional Level A (Eye Ring) animation: a camera dot orbiting a centered
/// subject at eye level, demonstrating the "walk a circle around the object"
/// motion the user is about to perform.
///
/// Drawn entirely with a [CustomPainter] — there is no external animation asset
/// or library, so it cannot show a broken-asset state and loads instantly even
/// on low-end devices. The loop repaints only on the controller tick.
///
/// Accessibility / performance contract:
///   - Honors reduce-motion ([MediaQueryData.disableAnimations]): when enabled,
///     renders a single static keyframe (with a direction arrow) instead of the
///     loop, and never starts the controller.
///   - Pauses the loop when the app is backgrounded and resumes on return; the
///     framework additionally mutes the ticker for off-stage routes, so pushing
///     another screen on top stops the work too. The controller is disposed with
///     the widget — no background CPU/battery drain.
class EyeRingIntroAnimation extends StatefulWidget {
  const EyeRingIntroAnimation({
    super.key,
    required this.segments,
    this.loopDuration = const Duration(seconds: 4),
    this.semanticLabel =
        'Animation: the camera moves in a circle at eye level around the object.',
  });

  /// Number of capture positions to mark around the ring (from the eye-ring
  /// band's `segments`). Clamped to a sane visual range before drawing.
  final int segments;

  /// One full revolution duration. Spec target is 3–5s.
  final Duration loopDuration;

  /// Screen-reader description of the (decorative) animation.
  final String semanticLabel;

  @override
  State<EyeRingIntroAnimation> createState() => _EyeRingIntroAnimationState();
}

class _EyeRingIntroAnimationState extends State<EyeRingIntroAnimation>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: widget.loopDuration);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery (reduce-motion) is available here and re-runs if it changes.
    _syncPlayback();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.resumed) {
      _syncPlayback();
    } else if (_controller.isAnimating) {
      _controller.stop(); // pause on background — no drain
    }
  }

  /// Starts/stops the loop to match the current reduce-motion setting.
  void _syncPlayback() {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      if (_controller.isAnimating) _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // Visual clamp: too few ticks reads as noise, too many as a solid ring.
    final segments = widget.segments.clamp(3, 60);

    return Semantics(
      label: widget.semanticLabel,
      image: true,
      child: AspectRatio(
        aspectRatio: 1,
        child: reduceMotion
            ? CustomPaint(
                painter: _EyeRingPainter(
                  progress: 0,
                  segments: segments,
                  showDirectionArrow: true,
                ),
              )
            : AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  painter: _EyeRingPainter(
                    progress: _controller.value,
                    segments: segments,
                    showDirectionArrow: false,
                  ),
                ),
              ),
      ),
    );
  }
}

class _EyeRingPainter extends CustomPainter {
  _EyeRingPainter({
    required this.progress,
    required this.segments,
    required this.showDirectionArrow,
  });

  /// 0..1 position of the camera dot around the ring.
  final double progress;
  final int segments;

  /// Static keyframe (reduce-motion) draws a motion-direction chevron.
  final bool showDirectionArrow;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 * 0.62;

    // Orbit path.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = AppColors.royalGold.withValues(alpha: 0.35),
    );

    // Segment ticks (one per capture position).
    final tickPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = AppColors.royalGold.withValues(alpha: 0.5);
    for (var i = 0; i < segments; i++) {
      final a = (i / segments) * 2 * math.pi - math.pi / 2;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(center + dir * (radius - 6), center + dir * (radius + 6),
          tickPaint);
    }

    // Centered subject (the object being captured).
    final objRect = Rect.fromCenter(
      center: center,
      width: radius * 0.72,
      height: radius * 0.72,
    );
    final rrect = RRect.fromRectAndRadius(objRect, const Radius.circular(10));
    canvas.drawRRect(rrect, Paint()..color = AppColors.surface2);
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = AppColors.royalGold.withValues(alpha: 0.7),
    );

    final angle = progress * 2 * math.pi - math.pi / 2;

    // Trailing arc behind the dot — conveys direction of travel.
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      angle - math.pi / 3,
      math.pi / 3,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = AppColors.mirageRed.withValues(alpha: 0.45),
    );

    // Camera dot (current capture position) with a soft glow.
    final dotPos = center + Offset(math.cos(angle), math.sin(angle)) * radius;
    canvas.drawCircle(
        dotPos, 11, Paint()..color = AppColors.redGlow.withValues(alpha: 0.35));
    canvas.drawCircle(dotPos, 6.5, Paint()..color = AppColors.mirageRed);

    if (showDirectionArrow) {
      _drawDirectionChevron(canvas, center, radius);
    }
  }

  /// A small clockwise chevron at the top of the ring, shown only on the static
  /// (reduce-motion) keyframe so direction is still communicated without motion.
  void _drawDirectionChevron(Canvas canvas, Offset center, double radius) {
    final top = center + const Offset(0, 0) + Offset(0, -radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = AppColors.mirageRed;
    final path = Path()
      ..moveTo(top.dx + 8, top.dy - 7)
      ..lineTo(top.dx + 16, top.dy)
      ..lineTo(top.dx + 8, top.dy + 7);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _EyeRingPainter old) =>
      old.progress != progress ||
      old.segments != segments ||
      old.showDirectionArrow != showDirectionArrow;
}
