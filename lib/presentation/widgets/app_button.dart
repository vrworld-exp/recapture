// lib/presentation/widgets/app_button.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';

/// Button variant for ReCapture.
/// primary   — filled Mirage Red background (primary CTA)
/// secondary — outlined, no fill (secondary / cancel actions)
enum AppButtonVariant { primary, secondary }

/// Reusable button widget for ReCapture.
///
/// Usage:
///   AppButton(label: 'Start Capture', onPressed: _start)
///   AppButton.secondary(label: 'Cancel', onPressed: _cancel)
///   AppButton(label: 'Uploading…', isLoading: true, onPressed: null)
///   AppButton(label: 'New Project', icon: Icons.add, onPressed: _new)
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.isLoading = false,
    this.isFullWidth = true,
    this.icon,
  });

  /// Convenience constructor for secondary variant.
  const AppButton.secondary({
    super.key,
    required this.label,
    this.onPressed,
    this.isLoading = false,
    this.isFullWidth = true,
    this.icon,
  }) : variant = AppButtonVariant.secondary;

  final String label;

  /// Null disables the button (greyed state via theme).
  final VoidCallback? onPressed;

  final AppButtonVariant variant;

  /// When true: shows a spinner inside the button and disables taps.
  /// The button retains its full size — it does not collapse.
  final bool isLoading;

  /// When true (default): button stretches to full parent width.
  /// When false: button wraps content width.
  final bool isFullWidth;

  /// Optional leading icon. Renders left of label with an 8dp gap.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    // Effective onPressed: null when loading (disables the button)
    final effectiveOnPressed = isLoading ? null : onPressed;

    // Button child: spinner when loading, icon+label or label otherwise
    final Widget child = isLoading
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.textPrimary,
            ),
          )
        : icon != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  Text(label),
                ],
              )
            : Text(label);

    // Width wrapper: full-width or content-width
    Widget button = switch (variant) {
      AppButtonVariant.primary => ElevatedButton(
          onPressed: effectiveOnPressed,
          child: child,
        ),
      AppButtonVariant.secondary => OutlinedButton(
          onPressed: effectiveOnPressed,
          child: child,
        ),
    };

    // Wrap in SizedBox only for full-width — avoids unnecessary widget nesting
    if (isFullWidth) {
      button = SizedBox(width: double.infinity, child: button);
    }

    return button;
  }
}
