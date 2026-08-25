// lib/presentation/widgets/direction_arrow_overlay.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../domain/entities/direction_hint.dart';

/// Base diameter of the curved ring arrow, in logical pixels.
const double _kBaseArrowSize = 64;

/// Urgency at/above which the arrow escalates to Mirage Red (used sparingly).
const double _kHighUrgency = 0.75;

/// Clamp urgency into [0, 1]; NaN → neutral 0.5 (no overflow downstream).
double _safeUrgency(double u) => u.isNaN ? 0.5 : u.clamp(0.0, 1.0);

/// Resolved arrow colour for an [urgency]: neutral Royal Gold by default, Mirage
/// Red only at high urgency. Pure + testable.
Color directionArrowColor(double urgency) =>
    _safeUrgency(urgency) >= _kHighUrgency
        ? AppColors.mirageRed
        : AppColors.royalGold;

/// Resolved size multiplier for an [urgency] — a small, capped intensity bump
/// (1.0 .. 1.18) so the arrow never balloons. Pure + testable.
double directionArrowScale(double urgency) => 1.0 + 0.18 * _safeUrgency(urgency);

/// Level A direction arrow: a curved clockwise/counterclockwise indicator that
/// tells the user which way to ring the object to reach the next uncaptured
/// position. It renders a supplied [DirectionHint] — it does NOT compute ring
/// progress, yaw, or which arc is shorter.
///
/// Hidden by default; fades/scales in only when [DirectionHint.visible] is true.
/// Visibility toggles are debounced so the arrow doesn't blink near the relevance
/// threshold. A direction reversal mirrors a single glyph (a smooth horizontal
/// flip — never a both-arrows state). Optional [DirectionHint.urgency] nudges
/// colour/size within capped bounds. Guidance-only and hit-test transparent.
class DirectionArrowOverlay extends StatefulWidget {
  const DirectionArrowOverlay({
    super.key,
    required this.hint,
    this.debounceWindow = const Duration(milliseconds: 150),
  });

  final DirectionHint hint;

  /// Debounce applied to visibility flips (both directions) to stop blinking.
  final Duration debounceWindow;

  @override
  State<DirectionArrowOverlay> createState() => _DirectionArrowOverlayState();
}

class _DirectionArrowOverlayState extends State<DirectionArrowOverlay>
    with SingleTickerProviderStateMixin {
  /// Debounced visibility actually rendered (vs. the latest on the widget).
  late bool _effectiveVisible;

  Timer? _debounceTimer;

  /// Drives the subtle looping motion hint (a low-amplitude rotational sweep in
  /// the indicated direction). Reused across show/hide; never piles up.
  late final AnimationController _nudge;

  static const Duration _fade = Duration(milliseconds: 220);
  static const Duration _flip = Duration(milliseconds: 260);
  static const double _nudgeAmplitude = 0.10; // radians (~5.7°), gentle

  @override
  void initState() {
    super.initState();
    _effectiveVisible = widget.hint.visible; // first mount: no debounce
    _nudge = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncNudge(); // reduce-motion (MediaQuery) available here
  }

  @override
  void didUpdateWidget(DirectionArrowOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.hint.visible != _effectiveVisible) {
      // Debounce the flip; restart on each change so rapid flapping settles to
      // the final value without blinking.
      _debounceTimer?.cancel();
      _debounceTimer = Timer(widget.debounceWindow, () {
        _debounceTimer = null;
        if (!mounted) return;
        setState(() => _effectiveVisible = widget.hint.visible);
        _syncNudge();
      });
    } else {
      // Settled back to the rendered value before the timer fired → cancel.
      _debounceTimer?.cancel();
      _debounceTimer = null;
      if (oldWidget.hint.urgency != widget.hint.urgency) _syncNudge();
    }
  }

  /// Loops the motion hint only while visible and motion is allowed; otherwise
  /// rests at 0 (a static arrow). Higher urgency sweeps a little faster (capped).
  void _syncNudge() {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final shouldNudge = _effectiveVisible && !reduceMotion;
    if (shouldNudge) {
      final u = _safeUrgency(widget.hint.urgency);
      _nudge.duration = Duration(milliseconds: (1100 - 300 * u).round());
      if (!_nudge.isAnimating) _nudge.repeat(reverse: true);
    } else if (_nudge.isAnimating || _nudge.value != 0) {
      _nudge
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _nudge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final hint = widget.hint;
    final urgency = _safeUrgency(hint.urgency);
    final sign = hint.direction == RingDirection.clockwise ? 1.0 : -1.0;
    final color = directionArrowColor(urgency);
    final visible = _effectiveVisible;

    // Upper-centre slot: below the top bar, above the placement box, clear of the
    // tilt meter (upper-right), the lower-left ring/stability cluster, the
    // instruction banner (lower third), and the bottom controls.
    return Positioned(
      top: MediaQuery.sizeOf(context).height * 0.14,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: AnimatedOpacity(
            opacity: visible ? 1.0 : 0.0,
            duration: reduceMotion ? Duration.zero : _fade,
            child: AnimatedScale(
              scale: visible ? directionArrowScale(urgency) : 0.85,
              duration: reduceMotion ? Duration.zero : _fade,
              curve: Curves.easeOutBack,
              // Smooth CW↔CCW: mirror a single canonical-clockwise glyph via an
              // animated horizontal flip (scaleX: +1 → −1). One glyph throughout —
              // there is never a both-arrows state.
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(end: sign),
                duration: reduceMotion ? Duration.zero : _flip,
                builder: (context, animSign, child) {
                  return AnimatedBuilder(
                    animation: _nudge,
                    builder: (context, child) {
                      final nudge = reduceMotion
                          ? 0.0
                          : (_nudge.value - 0.5) * 2 * _nudgeAmplitude * sign;
                      return Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..rotateZ(nudge)
                          ..scaleByDouble(animSign, 1.0, 1.0, 1.0),
                        child: child,
                      );
                    },
                    child: child,
                  );
                },
                child: SizedBox(
                  key: const ValueKey<String>('direction_arrow_glyph'),
                  width: _kBaseArrowSize,
                  height: _kBaseArrowSize,
                  child: CustomPaint(
                    painter: _RingArrowPainter(color: color),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws a canonical CLOCKWISE curved ring arrow (an arc most of the way around
/// a circle with an arrowhead at the leading end). Counterclockwise is produced
/// by the overlay mirroring this glyph horizontally — so only one chirality is
/// drawn here.
class _RingArrowPainter extends CustomPainter {
  _RingArrowPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide * 0.34;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.shortestSide * 0.08
      ..strokeCap = StrokeCap.round
      ..color = color;

    // Arc: start near the top, sweep ~270° clockwise (positive angle is CW in
    // Flutter's y-down canvas), leaving a gap where the arrowhead sits.
    const startAngle = -math.pi / 2 + 0.4;
    const sweepAngle = 1.5 * math.pi;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      stroke,
    );

    // Arrowhead at the leading (end) point, pointing along the clockwise tangent.
    const endAngle = startAngle + sweepAngle;
    final tip = center +
        Offset(math.cos(endAngle), math.sin(endAngle)) * radius;
    final tangent = Offset(-math.sin(endAngle), math.cos(endAngle)); // CW dir
    final head = size.shortestSide * 0.16;
    // Two barbs swept back from the tip around the tangent direction.
    final back = -tangent;
    Offset rotate(Offset v, double a) => Offset(
          v.dx * math.cos(a) - v.dy * math.sin(a),
          v.dx * math.sin(a) + v.dy * math.cos(a),
        );
    final barb1 = tip + rotate(back, 0.5) * head;
    final barb2 = tip + rotate(back, -0.5) * head;
    final headPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke.strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawLine(tip, barb1, headPaint);
    canvas.drawLine(tip, barb2, headPaint);
  }

  @override
  bool shouldRepaint(covariant _RingArrowPainter old) => old.color != color;
}
