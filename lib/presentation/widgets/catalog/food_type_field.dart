// lib/presentation/widgets/catalog/food_type_field.dart
//
// The veg / non-veg / no-label row, and the marker the cards draw for it.
//
// ONE widget for all four editors (owner add, owner edit, rep add, rep edit)
// so the row cannot drift between them: same three values, same order, same
// words. It is a row rather than a switch because the third value is the
// whole point — "no label" is a real answer, and a switch has no room for it.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/entities/product_food_type.dart';

/// The three values in a row. Defaults to veg on every screen that uses it.
class FoodTypeField extends StatelessWidget {
  const FoodTypeField({
    super.key,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.fieldKey,
    this.showLabel = true,
  });

  final ProductFoodType value;
  final bool enabled;
  final ValueChanged<ProductFoodType> onChanged;

  /// Put on the segmented button itself, for tests that drive it.
  final Key? fieldKey;

  /// Whether to draw the "Veg / non-veg" heading above the row. Off where the
  /// caller already draws its own section heading.
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel) ...[
          Text(
            'Veg / non-veg',
            style: theme.textTheme.titleMedium
                ?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        // Full width, so the three segments share the row evenly on a phone
        // instead of huddling at the left under a 120-character name field.
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<ProductFoodType>(
            key: fieldKey,
            showSelectedIcon: false,
            segments: [
              for (final type in ProductFoodType.values)
                ButtonSegment(
                  value: type,
                  label: Text(type.label),
                  icon: type.showsMarker
                      ? FoodTypeMarker(type: type, size: 12)
                      : const Icon(Icons.label_off_outlined, size: 14),
                ),
            ],
            selected: {value},
            onSelectionChanged:
                enabled ? (selection) => onChanged(selection.first) : null,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        // This one DOES reach customers, unlike availability and featured, and
        // the row says so in the same breath — the editors around it spend a
        // lot of words on what customers cannot see.
        Text(
          switch (value) {
            ProductFoodType.veg =>
              'Customers see a green veg mark on this dish.',
            ProductFoodType.nonVeg =>
              'Customers see a red non-veg mark on this dish.',
            ProductFoodType.none =>
              'No veg or non-veg mark is shown on this dish.',
          },
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

/// The marker itself: the square-with-a-dot the public menu draws.
///
/// Green for veg, red for non-veg. Renders NOTHING for [ProductFoodType.none]
/// so a caller can place it unconditionally; the value decides.
class FoodTypeMarker extends StatelessWidget {
  const FoodTypeMarker({super.key, required this.type, this.size = 14});

  final ProductFoodType type;

  /// Outer edge of the square. The dot is scaled with it.
  final double size;

  @override
  Widget build(BuildContext context) {
    if (!type.showsMarker) return const SizedBox.shrink();
    final color =
        type == ProductFoodType.nonVeg ? AppColors.error : AppColors.success;
    return Semantics(
      label: type.label,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(size * 0.18),
          border: Border.all(color: color, width: 1.5),
        ),
        alignment: Alignment.center,
        child: Container(
          width: size * 0.5,
          height: size * 0.5,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
