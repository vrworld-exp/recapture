// lib/presentation/widgets/app_card.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';

/// Reusable surface card for ReCapture.
///
/// Uses AppColors.surface1 background with a subtle border.
/// Optional onTap adds an InkWell ripple effect.
///
/// Usage:
///   AppCard(child: Text('Hello'))
///   AppCard(onTap: () => _open(), child: ProjectCardContent())
///   AppCard(padding: EdgeInsets.zero, child: FullBleedContent())
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding,
    this.margin,
    this.borderRadius,
  });

  final Widget child;

  /// Optional tap handler. When non-null, card becomes interactive
  /// with InkWell ripple effect clipped to card border radius.
  final VoidCallback? onTap;

  /// Optional long-press handler (used for multi-select on project cards).
  final VoidCallback? onLongPress;

  /// Inner content padding. Defaults to EdgeInsets.all(AppSpacing.lg).
  final EdgeInsetsGeometry? padding;

  /// Outer margin. Null by default — caller controls placement.
  final EdgeInsetsGeometry? margin;

  /// Custom border radius. Defaults to AppRadius.sm on all corners.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = borderRadius ?? BorderRadius.circular(AppRadius.sm);

    final effectivePadding = padding ?? const EdgeInsets.all(AppSpacing.lg);

    // Static card — no interaction
    if (onTap == null && onLongPress == null) {
      return Container(
        margin: margin,
        padding: effectivePadding,
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: effectiveRadius,
          border: Border.all(
            color: AppColors.disabled.withValues(alpha: 0.4),
            width: 0.5,
          ),
        ),
        child: child,
      );
    }

    // Interactive card — InkWell ripple clipped to border radius
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: effectiveRadius,
        border: Border.all(
          color: AppColors.disabled.withValues(alpha: 0.4),
          width: 0.5,
        ),
      ),
      child: ClipRRect(
        borderRadius: effectiveRadius,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            borderRadius: effectiveRadius,
            child: Padding(
              padding: effectivePadding,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
