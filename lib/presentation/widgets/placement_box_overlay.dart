// lib/presentation/widgets/placement_box_overlay.dart
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/placement_box.dart';
import '../../platform/camera/preview_geometry.dart';

/// Centre-frame placement guide drawn over the camera preview: a dimmed scrim
/// outside a centred box, corner brackets at the box edge, and helper text. The
/// box is defined in normalized capture-image space ([PlacementBox]) and
/// projected to screen via [PreviewGeometry], so it maps to a consistent region
/// of the captured frame across device aspect ratios.
///
/// Render-only: it draws the supplied [status] (colour + copy) and a gentle
/// pulse in the `good` state. It runs NO object detection and triggers NO
/// captures — a parent supplies [status]. Hit-test transparent, so it never
/// swallows taps meant for the capture chrome.
class PlacementBoxOverlay extends StatefulWidget {
  const PlacementBoxOverlay({
    super.key,
    required this.geometry,
    this.box = const PlacementBox(),
    this.status = PlacementStatus.idle,
    this.helperText,
  });

  /// The active screen↔image mapping. When not yet valid (camera initializing)
  /// the overlay renders nothing.
  final PreviewGeometry geometry;

  /// The guide region in normalized image space.
  final PlacementBox box;

  /// Injected placement quality (drives colour + copy). Defaults to idle.
  final PlacementStatus status;

  /// Optional copy override; defaults to status-derived text.
  final String? helperText;

  @override
  State<PlacementBoxOverlay> createState() => _PlacementBoxOverlayState();
}

class _PlacementBoxOverlayState extends State<PlacementBoxOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  /// Centralized helper copy — placeholder strings, easy to swap in a content
  /// pass. `tooClose` → move back; `tooFar` → move closer.
  static const Map<PlacementStatus, String> _copy = {
    PlacementStatus.idle: 'Place the object inside the box',
    PlacementStatus.good: 'Looks good — hold steady',
    PlacementStatus.tooClose: 'Move back',
    PlacementStatus.tooFar: 'Move closer',
    PlacementStatus.offCenter: 'Center the object',
  };

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse(); // MediaQuery (reduce-motion) available here.
  }

  @override
  void didUpdateWidget(PlacementBoxOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status ||
        oldWidget.geometry.isValid != widget.geometry.isValid) {
      _syncPulse();
    }
  }

  /// Pulses only in the `good` state, with a valid geometry, and when motion is
  /// allowed. Otherwise it rests at 0 (static brackets, no pulse ring).
  void _syncPulse() {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final shouldAnimate = widget.status == PlacementStatus.good &&
        widget.geometry.isValid &&
        !reduceMotion;
    if (shouldAnimate) {
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
    super.dispose();
  }

  Color _statusColor() => switch (widget.status) {
        PlacementStatus.idle => AppColors.textPrimary,
        PlacementStatus.good => AppColors.success,
        PlacementStatus.tooClose ||
        PlacementStatus.tooFar ||
        PlacementStatus.offCenter =>
          AppColors.mirageRed,
      };

  @override
  Widget build(BuildContext context) {
    final geometry = widget.geometry;
    // Camera still initializing / no resolution yet → render nothing (no NaN).
    if (!geometry.isValid) return const SizedBox.shrink();

    final nr = widget.box.normalizedRect;
    final boxRect = Rect.fromPoints(
      geometry.normalizedImageToScreen(nr.topLeft),
      geometry.normalizedImageToScreen(nr.bottomRight),
    );
    final color = _statusColor();
    final pulsing = widget.status == PlacementStatus.good;
    final text = widget.helperText ?? _copy[widget.status]!;

    // Helper text sits just below the box, clamped to stay on screen.
    final textTop = (boxRect.bottom + AppSpacing.lg)
        .clamp(0.0, geometry.screenSize.height - 56.0);

    return IgnorePointer(
      child: Stack(
        children: [
          // Scrim + brackets (+ pulse ring) — isolated repaint via the painter's
          // `repaint` listenable; the rest of the tree never repaints per frame.
          Positioned.fill(
            child: CustomPaint(
              painter: _PlacementPainter(
                boxRect: boxRect,
                color: color,
                pulse: _pulse,
                showPulse: pulsing,
              ),
            ),
          ),
          Positioned(
            top: textTop,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: AppColors.bgPrimary.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                child: Text(
                  text,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.textPrimary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlacementPainter extends CustomPainter {
  _PlacementPainter({
    required this.boxRect,
    required this.color,
    required this.pulse,
    required this.showPulse,
  }) : super(repaint: pulse);

  final Rect boxRect;
  final Color color;
  final Animation<double> pulse;
  final bool showPulse;

  static const double _radius = 16;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect =
        RRect.fromRectAndRadius(boxRect, const Radius.circular(_radius));

    // Dimmed scrim everywhere except inside the box (even-odd cut-out).
    final scrim = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      scrim,
      Paint()..color = AppColors.bgPrimary.withValues(alpha: 0.5),
    );

    // Gentle expanding pulse ring (good state only).
    if (showPulse && pulse.value > 0) {
      final t = pulse.value;
      final inflated = rrect.inflate(t * 8);
      canvas.drawRRect(
        inflated,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: (1 - t) * 0.5),
      );
    }

    // Corner brackets.
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = color;
    final len = (boxRect.shortestSide * 0.12).clamp(16.0, 48.0);
    final l = boxRect.left, t = boxRect.top, r = boxRect.right, b = boxRect.bottom;

    void corner(Offset p, Offset hDir, Offset vDir) {
      canvas.drawLine(p, p + hDir * len, stroke);
      canvas.drawLine(p, p + vDir * len, stroke);
    }

    corner(Offset(l, t), const Offset(1, 0), const Offset(0, 1)); // top-left
    corner(Offset(r, t), const Offset(-1, 0), const Offset(0, 1)); // top-right
    corner(Offset(l, b), const Offset(1, 0), const Offset(0, -1)); // bottom-left
    corner(Offset(r, b), const Offset(-1, 0), const Offset(0, -1)); // bottom-right
  }

  @override
  bool shouldRepaint(covariant _PlacementPainter old) =>
      old.boxRect != boxRect ||
      old.color != color ||
      old.showPulse != showPulse;
}
