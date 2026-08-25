// lib/presentation/widgets/verdict_badge.dart
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../domain/entities/capture_evaluation.dart';

/// Compact corner badge mapping a [CaptureVerdict] to the SAME colour + icon
/// language the post-shot toast uses (accepted = success/check, warn = amber
/// alert, reject = Mirage-Red cross) — one visual vocabulary across capture and
/// review. A dark scrim disc behind the coloured glyph keeps it legible on any
/// thumbnail, bright or dark.
///
/// The verdict→colour/icon/label mapping lives here as static helpers so the
/// review grid's header summary chips reuse the exact same tokens.
class VerdictBadge extends StatelessWidget {
  const VerdictBadge({super.key, required this.verdict, this.size = 16});

  final CaptureVerdict verdict;

  /// Diameter of the inner glyph (logical px). The disc grows proportionally.
  final double size;

  /// The accent colour for a verdict — reused from the post-shot toast tokens.
  static Color colorFor(CaptureVerdict v) {
    switch (v) {
      case CaptureVerdict.accepted:
        return AppColors.success;
      case CaptureVerdict.warn:
        return AppColors.warning;
      case CaptureVerdict.reject:
        return AppColors.mirageRed;
    }
  }

  /// The glyph for a verdict — matches the post-shot toast.
  static IconData iconFor(CaptureVerdict v) {
    switch (v) {
      case CaptureVerdict.accepted:
        return Icons.check_circle;
      case CaptureVerdict.warn:
        return Icons.warning_amber_rounded;
      case CaptureVerdict.reject:
        return Icons.error_outline;
    }
  }

  /// Human-readable verdict label for semantics and summary chips.
  static String labelFor(CaptureVerdict v) {
    switch (v) {
      case CaptureVerdict.accepted:
        return 'Accepted';
      case CaptureVerdict.warn:
        return 'Warned';
      case CaptureVerdict.reject:
        return 'Rejected';
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFor(verdict);
    return Container(
      padding: EdgeInsets.all(size * 0.2),
      decoration: BoxDecoration(
        // Dark backing → legible on bright thumbnails; colour carries verdict.
        color: AppColors.bgPrimary.withValues(alpha: 0.72),
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.5),
      ),
      child: Icon(iconFor(verdict), color: color, size: size),
    );
  }
}
