// lib/presentation/widgets/catalog/analytics_chart.dart
//
// The dashboard's timeseries chart — one bar per UTC day, drawn by hand.
//
// NO CHARTING PACKAGE. What this surface needs is a bar per day, a baseline, a
// peak label and a way to read one day's exact number; a `CustomPainter` does
// all of that in one file, and every charting package in reach brings a
// rendering model, a theme system and a web story to keep working (AGENTS.md:
// no new dependency without justification). If this ever grows stacked series,
// zooming or a second axis, that is the moment to revisit it — not before.
//
// EVERY SIZE COMES FROM THE CONSTRAINTS. The chart is asked to be legible from
// a 360 px phone to a 1600 px browser window, which rules out fixed pixel
// geometry: the bar width, the gutter, the label cadence and the height are all
// derived from the width it is given. Ninety bars across 360 px are two pixels
// wide and that is FINE — the shape is the information at that size, and the
// exact number is one tap away.
//
// HOVER *AND* TAP, NOT ONE OR THE OTHER. A pointer that hovers gets a tooltip;
// a finger gets the same tooltip on tap and can drag along the series to scrub
// it. Both paths set the same `_active` index, so there is one inspection
// behaviour with two ways in — and neither is chosen by asking `kIsWeb`, which
// would give a touchscreen laptop the wrong one.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/entities/catalog_analytics.dart';
import 'analytics_format.dart';

/// Shortest the plot area is allowed to get. Below this the bars stop reading
/// as a trend and start reading as noise.
const double kAnalyticsChartMinHeight = 150;

/// Tallest it grows on a wide window — a 1600 px browser does not want a
/// 640 px-tall bar chart, it wants a wide one.
const double kAnalyticsChartMaxHeight = 260;

class AnalyticsChart extends StatefulWidget {
  const AnalyticsChart({
    super.key,
    required this.points,
    required this.series,
  });

  /// Already gap-filled and ascending, as Mirage returned it. Not re-sorted
  /// here — see [AnalyticsTimeseries.points].
  final List<AnalyticsPoint> points;

  final AnalyticsSeries series;

  @override
  State<AnalyticsChart> createState() => _AnalyticsChartState();
}

class _AnalyticsChartState extends State<AnalyticsChart> {
  /// The day being inspected, or null when nothing is.
  int? _active;

  /// The geometry of the last paint, so a pointer position can be turned into
  /// a day index without the painter and the hit-testing disagreeing about
  /// where the bars are.
  _ChartGeometry? _geometry;

  @override
  void didUpdateWidget(AnalyticsChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new range or a new series means the index points at a different day.
    // Clearing beats keeping it: a tooltip that survives a range switch is
    // reporting a number that is no longer on screen.
    if (oldWidget.points != widget.points || oldWidget.series != widget.series) {
      _active = null;
    }
  }

  void _inspectAt(Offset local) {
    final geometry = _geometry;
    if (geometry == null || widget.points.isEmpty) return;
    final index = geometry.indexAt(local.dx, widget.points.length);
    if (index != _active) setState(() => _active = index);
  }

  void _clear() {
    if (_active != null) setState(() => _active = null);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final labelStyle = textTheme.bodySmall?.copyWith(
          color: AppColors.textMuted,
          fontSize: 11,
        ) ??
        const TextStyle(color: AppColors.textMuted, fontSize: 11);

    final values = [
      for (final point in widget.points) widget.series.valueOf(point),
    ];
    final peak = values.isEmpty ? 0 : values.reduce(math.max);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Proportional, then clamped: a phone gets a chart tall enough to read
        // and a wide window gets a wide one rather than a billboard.
        final height = (width * 0.38)
            .clamp(kAnalyticsChartMinHeight, kAnalyticsChartMaxHeight)
            .toDouble();

        final geometry = _ChartGeometry.compute(
          context: context,
          width: width,
          height: height,
          count: widget.points.length,
          peak: peak,
          labelStyle: labelStyle,
          points: widget.points,
        );
        _geometry = geometry;

        final active = _active;
        final activePoint = active != null && active < widget.points.length
            ? widget.points[active]
            : null;

        return Semantics(
          // The whole chart as one sentence, because a screen reader cannot
          // usefully walk ninety bars. The peak is the thing a business asks
          // this chart for.
          label: _semanticsLabel(context, peak),
          child: MouseRegion(
            // Web hover. Harmless on touch, where no pointer ever hovers.
            onHover: (event) => _inspectAt(event.localPosition),
            onExit: (_) => _clear(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Touch inspection, and a drag that scrubs along the series —
              // the only way to read individual days when ninety of them share
              // a phone's width.
              onTapDown: (details) => _inspectAt(details.localPosition),
              onTapUp: (_) => _clear(),
              onTapCancel: _clear,
              onHorizontalDragStart: (details) =>
                  _inspectAt(details.localPosition),
              onHorizontalDragUpdate: (details) =>
                  _inspectAt(details.localPosition),
              onHorizontalDragEnd: (_) => _clear(),
              onHorizontalDragCancel: _clear,
              child: SizedBox(
                width: width,
                height: height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _AnalyticsChartPainter(
                          points: widget.points,
                          series: widget.series,
                          geometry: geometry,
                          activeIndex: active,
                        ),
                      ),
                    ),
                    if (activePoint != null)
                      _ChartTooltip(
                        point: activePoint,
                        series: widget.series,
                        geometry: geometry,
                        index: active!,
                        count: widget.points.length,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _semanticsLabel(BuildContext context, int peak) {
    final first = widget.points.isEmpty ? null : widget.points.first.day;
    final last = widget.points.isEmpty ? null : widget.points.last.day;
    final span = first == null || last == null
        ? ''
        : ' from ${analyticsShortDay(context, first)} '
            'to ${analyticsShortDay(context, last)}';
    return '${widget.series.label} per day$span. '
        'Highest day: ${analyticsExact(context, peak)}.';
  }
}

/// Where the bars, the baseline and the labels sit for one paint.
///
/// Computed ONCE per layout and shared by the painter and the hit-testing, so a
/// tooltip can never name a day the pointer is not over.
@immutable
class _ChartGeometry {
  const _ChartGeometry({
    required this.width,
    required this.height,
    required this.gutter,
    required this.plotBottom,
    required this.peak,
    required this.labelStyle,
    required this.slot,
    required this.barWidth,
    required this.dayLabels,
    required this.valueLabels,
  });

  final double width;
  final double height;

  /// Left strip holding the value labels. Derived from the width of the widest
  /// label actually painted, so a chart topping out at 12 does not reserve the
  /// room a 1.2M chart needs.
  final double gutter;

  /// Baseline y — above the day labels along the bottom.
  final double plotBottom;

  /// The largest value in the series, and therefore the top gridline. Never
  /// below 1: a window in which nothing happened must still draw an axis, not
  /// divide by zero.
  final int peak;

  final TextStyle labelStyle;

  /// Horizontal space per day, and the bar drawn inside it.
  final double slot;
  final double barWidth;

  /// Labels PRE-FORMATTED at layout time, keyed by day index and by value.
  ///
  /// `MaterialLocalizations` needs a `BuildContext` and a `CustomPainter` has
  /// none — formatting here rather than reaching for a global is what keeps the
  /// axis locale-aware instead of quietly English.
  final Map<int, String> dayLabels;
  final Map<int, String> valueLabels;

  double get plotWidth => width - gutter;

  /// Top of the plot area. A little headroom so the tallest bar does not touch
  /// the top gridline's label.
  double get plotTop => 6;

  double xCenter(int index) => gutter + slot * index + slot / 2;

  double yFor(int value) {
    final fraction = peak <= 0 ? 0.0 : value / peak;
    return plotBottom - (plotBottom - plotTop) * fraction;
  }

  /// Which day a pointer at [dx] is over. Clamped rather than nullable — a
  /// pointer inside the chart but left of the first bar is inspecting the first
  /// day, which is what it looks like it is doing.
  int indexAt(double dx, int count) {
    if (count <= 0) return 0;
    final offset = (dx - gutter) / slot;
    return offset.floor().clamp(0, count - 1);
  }

  /// The day indices that get a label: first, middle and last.
  ///
  /// The same cadence at every width, so the chart does not change character
  /// as a browser window is dragged — and never more, because ninety dates
  /// across 360 px is an ink blot.
  static List<int> labelledDays(int count) {
    if (count <= 0) return const [];
    if (count < 3) return [0, count - 1];
    return [0, count ~/ 2, count - 1];
  }

  /// The values the gridlines are drawn at: floor, middle, peak.
  static List<int> gridValues(int peak) =>
      [0, (peak * 0.5).round(), peak];

  static _ChartGeometry compute({
    required BuildContext context,
    required double width,
    required double height,
    required int count,
    required int peak,
    required TextStyle labelStyle,
    required List<AnalyticsPoint> points,
  }) {
    final safePeak = math.max(peak, 1);

    // Reserve exactly the width the top label needs.
    final probe = TextPainter(
      text: TextSpan(
        text: analyticsCompact(context, safePeak),
        style: labelStyle,
      ),
      textDirection: Directionality.of(context),
    )..layout();
    final gutter = math.min(probe.width + AppSpacing.sm, width / 3);

    // Room for the day labels under the baseline.
    final dayLabelHeight = (labelStyle.fontSize ?? 11) + AppSpacing.sm;
    final plotBottom = math.max(height - dayLabelHeight, 1.0);

    final slot = count <= 0 ? width : (width - gutter) / count;
    // A visible bar even at ninety days on a phone, and a gap that scales with
    // the slot rather than a fixed pixel value that would swallow a 2 px bar.
    final barWidth = math.max(1.0, slot * (slot > 6 ? 0.66 : 0.85));

    return _ChartGeometry(
      dayLabels: {
        for (final index in labelledDays(count).toSet())
          if (index < points.length)
            index: switch (points[index].day) {
              final DateTime day => analyticsShortDay(context, day),
              // A date the server sent in a shape we could not parse still
              // gets a label — its own string, rather than a gap in the axis.
              null => points[index].date,
            },
      },
      valueLabels: {
        for (final value in gridValues(safePeak))
          value: analyticsCompact(context, value),
      },
      width: width,
      height: height,
      gutter: gutter,
      plotBottom: plotBottom,
      peak: safePeak,
      labelStyle: labelStyle,
      slot: slot,
      barWidth: barWidth,
    );
  }
}

class _AnalyticsChartPainter extends CustomPainter {
  _AnalyticsChartPainter({
    required this.points,
    required this.series,
    required this.geometry,
    required this.activeIndex,
  });

  final List<AnalyticsPoint> points;
  final AnalyticsSeries series;
  final _ChartGeometry geometry;
  final int? activeIndex;

  @override
  void paint(Canvas canvas, Size size) {
    _paintGridlines(canvas);
    _paintBars(canvas);
    _paintDayLabels(canvas);
  }

  void _paintGridlines(Canvas canvas) {
    final line = Paint()
      ..color = AppColors.textMuted.withValues(alpha: 0.16)
      ..strokeWidth = 1;

    // Three lines — floor, middle, peak. More would be chartjunk at 150 px
    // tall, and fewer would leave the middle of the plot unscaled.
    for (final value in _ChartGeometry.gridValues(geometry.peak)) {
      final y = geometry.yFor(value);
      canvas.drawLine(
        Offset(geometry.gutter, y),
        Offset(geometry.width, y),
        line,
      );
      _paintText(
        canvas,
        _compactLabel(value),
        Offset(0, y - (geometry.labelStyle.fontSize ?? 11)),
        maxWidth: geometry.gutter - AppSpacing.xs,
      );
    }
  }

  void _paintBars(Canvas canvas) {
    if (points.isEmpty) return;

    final bar = Paint()..color = AppColors.royalGold.withValues(alpha: 0.55);
    final activeBar = Paint()..color = AppColors.goldGlow;
    final radius = Radius.circular(math.min(2, geometry.barWidth / 2));

    for (var i = 0; i < points.length; i++) {
      final value = series.valueOf(points[i]);
      final top = geometry.yFor(value);
      final center = geometry.xCenter(i);
      final left = center - geometry.barWidth / 2;

      // A zero day still gets a hairline. Otherwise a quiet stretch reads as
      // missing data rather than as zero, and those are different facts.
      final height = math.max(geometry.plotBottom - top, value > 0 ? 1.5 : 1.0);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, geometry.plotBottom - height, geometry.barWidth,
              height),
          radius,
        ),
        i == activeIndex ? activeBar : bar,
      );
    }
  }

  void _paintDayLabels(Canvas canvas) {
    if (points.isEmpty) return;

    for (final index in _ChartGeometry.labelledDays(points.length).toSet()) {
      final label = geometry.dayLabels[index];
      if (label == null) continue;
      final x = geometry.xCenter(index);
      _paintText(
        canvas,
        label,
        Offset(x, geometry.plotBottom + AppSpacing.xs),
        centerOn: x,
        maxWidth: geometry.width,
      );
    }
  }

  String _compactLabel(int value) => geometry.valueLabels[value] ?? '$value';

  void _paintText(
    Canvas canvas,
    String text,
    Offset offset, {
    double? centerOn,
    required double maxWidth,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: geometry.labelStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: maxWidth);

    final dx = centerOn == null
        ? offset.dx
        : (centerOn - painter.width / 2)
            .clamp(0.0, math.max(0.0, geometry.width - painter.width))
            .toDouble();
    painter.paint(canvas, Offset(dx, offset.dy));
  }

  @override
  bool shouldRepaint(_AnalyticsChartPainter old) =>
      old.points != points ||
      old.series != series ||
      old.activeIndex != activeIndex ||
      old.geometry != geometry;
}

/// The hovered / tapped day, as a small card above the bar.
class _ChartTooltip extends StatelessWidget {
  const _ChartTooltip({
    required this.point,
    required this.series,
    required this.geometry,
    required this.index,
    required this.count,
  });

  final AnalyticsPoint point;
  final AnalyticsSeries series;
  final _ChartGeometry geometry;
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final day = point.day;
    final value = series.valueOf(point);

    // Anchored to the bar, then pulled back inside the chart at both edges —
    // a tooltip clipped by the right edge is one the last day cannot be read
    // through, and the last day is the one people look at.
    const tooltipWidth = 148.0;
    final left = (geometry.xCenter(index) - tooltipWidth / 2)
        .clamp(0.0, math.max(0.0, geometry.width - tooltipWidth))
        .toDouble();

    return Positioned(
      left: left,
      top: math.max(0.0, geometry.yFor(value) - 54),
      width: tooltipWidth,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(AppRadius.xs),
            border: Border.all(
              color: AppColors.royalGold.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                day == null ? point.date : analyticsShortDay(context, day),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textMuted),
              ),
              // THE EXACT NUMBER, always — the tiles abbreviate, and this is
              // where the abbreviation is paid back.
              Text(
                '${analyticsExact(context, value)} ${series.label.toLowerCase()}',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
