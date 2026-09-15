// lib/presentation/widgets/catalog/analytics_sparkline.dart
//
// The twelve-point line beside a KPI tile.
//
// CONTEXT, NOT A CHART. No axes, no labels, no hit-testing: it exists so a
// tile reading "36" also says "and it has been flat for a week" at a glance.
// The exact day-by-day numbers live in the traffic chart below the tiles,
// which is where a reader who wants them is sent. Hand-drawn for the same
// reason `analytics_chart.dart` is — a polyline and a dot do not justify a
// charting dependency (AGENTS.md: no new dependency without justification).
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';

/// How many trailing days a sparkline shows. Twelve is enough to read a shape
/// and few enough that a 96 px line does not turn into noise.
const int kSparklinePoints = 12;

class AnalyticsSparkline extends StatelessWidget {
  const AnalyticsSparkline({
    super.key,
    required this.values,
    required this.color,
    this.width = 96,
    this.height = 28,
  });

  /// Oldest first. Anything beyond the last [kSparklinePoints] is dropped.
  final List<int> values;
  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final recent = values.length > kSparklinePoints
        ? values.sublist(values.length - kSparklinePoints)
        : values;

    // Two points make a line; one makes nothing worth drawing.
    if (recent.length < 2) return SizedBox(width: width, height: height);

    return ExcludeSemantics(
      child: CustomPaint(
        size: Size(width, height),
        painter: _SparklinePainter(values: recent, color: color),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({required this.values, required this.color});

  final List<int> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Never divide by zero on a flat-zero window: a line along the baseline
    // is the truthful drawing of "nothing happened".
    final max = values.fold<int>(1, (m, v) => v > m ? v : m);
    final step = size.width / (values.length - 1);
    const inset = 3.0;

    Offset at(int index) {
      final x = index * step;
      final y = size.height -
          inset -
          (values[index] / max) * (size.height - inset * 2);
      return Offset(x, y);
    }

    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    // The current day gets the accent; the surface-coloured ring keeps the
    // dot legible where it sits on the line.
    final last = at(values.length - 1);
    canvas.drawCircle(last, 3.5, Paint()..color = AppColors.surface1);
    canvas.drawCircle(last, 2.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) =>
      oldDelegate.color != color || !_sameValues(oldDelegate.values, values);

  static bool _sameValues(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
