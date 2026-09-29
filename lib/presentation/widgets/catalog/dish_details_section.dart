// lib/presentation/widgets/catalog/dish_details_section.dart
//
// The product editor's Stage 5 section: the catalog's badges as multi-select
// chips, and a collapsible "Diet & allergens" group — dietary chips, allergen
// chips, spice (0–3 chillies) and serves / minutes / kcal. Stateless: the
// editor owns the [DishDetails] and its dirty tracking.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/catalog/dish_details.dart';
import 'dish_badge_chip.dart';

class DishDetailsSection extends StatelessWidget {
  const DishDetailsSection({
    super.key,
    required this.value,
    required this.library,
    required this.enabled,
    required this.onChanged,
    this.onManageBadges,
    this.problem,
  });

  final DishDetails value;

  /// The catalog's badge library.
  final List<CatalogBadge> library;
  final bool enabled;
  final ValueChanged<DishDetails> onChanged;

  /// Opens the badge manager — offered when the library is empty.
  final VoidCallback? onManageBadges;

  /// A rule the current choices break (e.g. vegan + non-veg), or null.
  final String? problem;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    final hasDiet = value.dietary.isNotEmpty ||
        value.allergens.isNotEmpty ||
        value.spiceLevel != null ||
        value.servesCount != null ||
        value.prepMinutes != null ||
        value.calories != null;

    return Column(
      key: const Key('dish-details-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Badges', style: text.titleMedium),
        const SizedBox(height: AppSpacing.xs),
        if (library.isEmpty)
          Row(
            children: [
              Expanded(child: Text('No badges yet.', style: muted)),
              if (onManageBadges != null)
                TextButton(onPressed: onManageBadges, child: const Text('Create badges')),
            ],
          )
        else
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final badge in library)
                if (badge.id != null)
                  FilterChip(
                    key: Key('dish-badge-${badge.id}'),
                    label: DishBadgeChip(badge: badge),
                    selected: value.badgeIds.contains(badge.id),
                    showCheckmark: false,
                    onSelected: !enabled
                        ? null
                        : (on) => onChanged(value.copyWith(
                              badgeIds: on
                                  ? [...value.badgeIds, badge.id!]
                                  : value.badgeIds.where((id) => id != badge.id).toList(),
                            )),
                  ),
            ],
          ),
        if (library.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text('The menu card shows the first two.', style: muted),
        ],
        const SizedBox(height: AppSpacing.lg),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const Key('dish-diet-expander'),
            tilePadding: EdgeInsets.zero,
            initiallyExpanded: hasDiet,
            title: Text('Diet & allergens', style: text.titleMedium),
            subtitle: Text('Shown on the dish; lets customers filter the menu.', style: muted),
            children: [
              _ChipGroup<DietaryCode>(
                title: 'Suitable for',
                all: DietaryCode.values,
                selected: value.dietary,
                label: (d) => d.label,
                enabled: enabled,
                onChanged: (s) => onChanged(value.copyWith(dietary: s)),
              ),
              const SizedBox(height: AppSpacing.md),
              _ChipGroup<AllergenCode>(
                title: 'Contains',
                all: AllergenCode.values,
                selected: value.allergens,
                label: (a) => a.label,
                enabled: enabled,
                onChanged: (s) => onChanged(value.copyWith(allergens: s)),
              ),
              const SizedBox(height: AppSpacing.md),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Spice', style: text.labelLarge),
              ),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  for (final level in [null, 0, 1, 2, 3])
                    ChoiceChip(
                      key: Key('dish-spice-${level ?? 'none'}'),
                      label: Text(switch (level) {
                        null => 'Not stated',
                        0 => 'Not spicy',
                        _ => '🌶️' * level,
                      }),
                      selected: value.spiceLevel == level,
                      onSelected: !enabled ? null : (_) => onChanged(value.copyWith(spiceLevel: level)),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: _NumberField(
                      fieldKey: const Key('dish-serves'),
                      label: 'Serves',
                      value: value.servesCount,
                      max: 50,
                      enabled: enabled,
                      onChanged: (v) => onChanged(value.copyWith(servesCount: v)),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: _NumberField(
                      fieldKey: const Key('dish-prep'),
                      label: 'Minutes',
                      value: value.prepMinutes,
                      max: 600,
                      enabled: enabled,
                      onChanged: (v) => onChanged(value.copyWith(prepMinutes: v)),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: _NumberField(
                      fieldKey: const Key('dish-kcal'),
                      label: 'kcal',
                      value: value.calories,
                      max: 5000,
                      enabled: enabled,
                      onChanged: (v) => onChanged(value.copyWith(calories: v)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),
        ),
        if (problem != null)
          Text(
            problem!,
            key: const Key('dish-details-problem'),
            style: text.bodySmall?.copyWith(color: AppColors.warning),
          ),
      ],
    );
  }
}

class _ChipGroup<T> extends StatelessWidget {
  const _ChipGroup({
    required this.title,
    required this.all,
    required this.selected,
    required this.label,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final List<T> all;
  final Set<T> selected;
  final String Function(T) label;
  final bool enabled;
  final ValueChanged<Set<T>> onChanged;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              for (final item in all)
                FilterChip(
                  label: Text(label(item)),
                  selected: selected.contains(item),
                  onSelected: !enabled
                      ? null
                      : (on) => onChanged(on ? {...selected, item} : ({...selected}..remove(item))),
                ),
            ],
          ),
        ],
      );
}

class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.max,
    required this.enabled,
    required this.onChanged,
  });

  final Key fieldKey;
  final String label;
  final int? value;
  final int max;
  final bool enabled;
  final ValueChanged<int?> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _c =
      TextEditingController(text: widget.value?.toString() ?? '');

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        key: widget.fieldKey,
        controller: _c,
        enabled: widget.enabled,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: widget.label, isDense: true),
        onChanged: (text) {
          final n = int.tryParse(text);
          widget.onChanged(n?.clamp(0, widget.max));
        },
      );
}
