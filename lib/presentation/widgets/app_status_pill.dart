// lib/presentation/widgets/app_status_pill.dart
import 'package:flutter/material.dart';
import '../../domain/entities/project_status.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// Status badge for ReCapture project cards.
///
/// Displays the human-readable label and semantic color for a ProjectStatus,
/// plus a small leading affordance:
///   - in-progress (capturing/uploading/processing) → a lightweight pulsing dot
///   - completed                                     → a check icon
///   - failed                                        → an alert icon
///   - draft / unknown                               → none
///
/// Color and label are driven entirely by the ProjectStatusDisplay extension —
/// no color values are hardcoded here. The animated dot is isolated in its own
/// widget so only it repaints on each tick (never the whole card), keeping long
/// lists of in-progress badges cheap.
class AppStatusPill extends StatelessWidget {
  const AppStatusPill({
    super.key,
    required this.status,
  });

  final ProjectStatus status;

  @override
  Widget build(BuildContext context) {
    final color = status.color;
    final affordance = _affordance(color);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(
          color: color.withValues(alpha: 0.35),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (affordance != null) ...[
            affordance,
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(
            status.label,
            style: TextStyle(
              fontSize: AppTypography.sizeLabel,
              fontWeight: FontWeight.w500,
              color: color,
              height: 1.0,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  /// The leading affordance for [status], or null when none applies.
  Widget? _affordance(Color color) {
    if (status.isInProgress) return _PulsingDot(color: color);
    return switch (status) {
      ProjectStatus.completed => Icon(Icons.check_circle, size: 11, color: color),
      ProjectStatus.failed => Icon(Icons.error, size: 11, color: color),
      _ => null,
    };
  }
}

/// A small dot that gently pulses its opacity to signal a live/in-progress
/// state. Self-contained: owns a single repeating controller and rebuilds only
/// itself via [FadeTransition], so it never repaints the surrounding card.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});

  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween<double>(
    begin: 0.35,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
