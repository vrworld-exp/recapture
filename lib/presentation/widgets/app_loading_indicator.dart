// lib/presentation/widgets/app_loading_indicator.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';

/// Full-area centred loading indicator for ReCapture.
///
/// Used for screen-level and section-level loading states.
/// Always Mirage Red — color is not configurable (brand consistency).
///
/// For loading inside a button, use CircularProgressIndicator directly
/// (AppButton handles this internally via isLoading: true).
///
/// Usage:
///   if (isLoading) const AppLoadingIndicator()
///   AppLoadingIndicator(size: 32) // larger for splash/hero loading
class AppLoadingIndicator extends StatelessWidget {
  const AppLoadingIndicator({
    super.key,
    this.size = 24,
  });

  /// Diameter of the spinner in logical pixels. Default: 24.
  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: size < 20 ? 2.0 : 2.5,
          color: AppColors.mirageRed,
        ),
      ),
    );
  }
}
