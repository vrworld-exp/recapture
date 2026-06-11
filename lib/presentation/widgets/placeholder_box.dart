// lib/presentation/widgets/placeholder_box.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// Skeleton placeholder for complex UI zones (camera, 3D viewer, AR, ring map, etc.)
/// Used only in skeleton/prototype screens. Replaced with real widgets in P3–P8.
class PlaceholderBox extends StatelessWidget {
  const PlaceholderBox({
    super.key,
    required this.label,
    this.height = 200,
    this.icon = Icons.crop_square_outlined,
    this.width = double.infinity,
  });

  final String label;
  final double height;
  final double width;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: AppColors.disabled.withValues(alpha: 0.5),
          width: 0.5,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 36, color: AppColors.disabled),
          const SizedBox(height: AppSpacing.sm),
          Text(
            label,
            style: const TextStyle(
              fontSize: AppTypography.sizeCaption,
              color: AppColors.textMuted,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
