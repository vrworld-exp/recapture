// lib/presentation/widgets/selectable_option_card.dart
//
// One selectable option in a radio-style list: accent border + radio glyph for
// the selection, muted + inert when the list is locked.
//
// Extracted from PreCaptureScreen's `_VariantOptionCard` when the project-
// creation sheet needed the same affordance. Generic over the option's value
// type so the two callers (flow variant, capture mode) share one widget rather
// than one visual language maintained twice — a copy would drift the moment one
// of them adjusted a padding or a semantics label.
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import 'app_card.dart';

class SelectableOptionCard<T> extends StatelessWidget {
  const SelectableOptionCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.selected,
    required this.onSelect,
    this.locked = false,
  });

  final String title;
  final String subtitle;

  /// This card's value, handed back through [onSelect].
  final T value;

  /// The list's current selection — this card is selected when it equals
  /// [value].
  final T selected;

  final ValueChanged<T> onSelect;

  /// The whole list is locked: the unselected options mute and taps no-op. The
  /// SELECTED card stays visually normal so the screen still says what was
  /// chosen rather than greying out the answer.
  final bool locked;

  bool get _isSelected => value == selected;

  @override
  Widget build(BuildContext context) {
    final disabled = locked && !_isSelected;
    return Semantics(
      button: true,
      selected: _isSelected,
      enabled: !locked,
      label: title,
      hint: subtitle,
      child: ConstrainedBox(
        // Comfortable tap target (≥48dp) even with tight text scaling.
        constraints: const BoxConstraints(minHeight: 56),
        child: AppCard(
          onTap: locked ? null : () => onSelect(value),
          border: _isSelected
              ? const BorderSide(color: AppColors.mirageRed, width: 1.5)
              : null,
          child: Row(
            children: [
              Icon(
                _isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: _isSelected
                    ? AppColors.mirageRed
                    : (disabled ? AppColors.disabled : AppColors.textMuted),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: disabled ? AppColors.textMuted : null,
                          ),
                    ),
                    Text(
                      subtitle,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
