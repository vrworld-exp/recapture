// lib/presentation/widgets/catalog/category_schedule_dialog.dart
//
// "Available at certain times" for one menu section (more-customization
// Stage 4): breakfast 7–11 am on weekdays, happy hour 5–7 pm. Outside the
// window the public menu either DIMS the section (still listed, with its hours)
// or HIDES it. Shared by the owner's and the rep's category managers; each
// saves through its own repository.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/catalog/menu_time.dart';
import '../../../domain/entities/catalog_category.dart';

/// What the dialog decided. `schedule == null` means always available.
typedef CategoryScheduleChoice = ({CategorySchedule? schedule, bool hide});

Future<CategoryScheduleChoice?> showCategoryScheduleDialog(
  BuildContext context,
  CatalogCategory category,
) =>
    showDialog<CategoryScheduleChoice>(
      context: context,
      builder: (_) => _CategoryScheduleDialog(category: category),
    );

class _CategoryScheduleDialog extends StatefulWidget {
  const _CategoryScheduleDialog({required this.category});

  final CatalogCategory category;

  @override
  State<_CategoryScheduleDialog> createState() => _CategoryScheduleDialogState();
}

class _CategoryScheduleDialogState extends State<_CategoryScheduleDialog> {
  late bool _limited = widget.category.schedule != null;
  late Set<int> _days = {...?widget.category.schedule?.days};
  late String _from = widget.category.schedule?.from ?? '07:00';
  late String _to = widget.category.schedule?.to ?? '11:00';
  late bool _hide = widget.category.hideOutsideWindow;

  CategorySchedule get _schedule =>
      CategorySchedule(days: _days.toList()..sort(), from: _from, to: _to);

  Future<void> _pick(bool isFrom) async {
    final current = isFrom ? _from : _to;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minutesOf(current) ~/ 60, minute: minutesOf(current) % 60),
    );
    if (picked == null) return;
    final v =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    setState(() => isFrom ? _from = v : _to = v);
  }

  @override
  Widget build(BuildContext context) {
    final problem = _limited ? _schedule.validate() : null;
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: Text('When is "${widget.category.displayName}" served?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const Key('category-schedule-toggle'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Available at certain times'),
              value: _limited,
              onChanged: (v) => setState(() {
                _limited = v;
                if (v && _days.isEmpty) _days = {1, 2, 3, 4, 5, 6, 0};
              }),
            ),
            if (_limited) ...[
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final day in kWeekOrder)
                    FilterChip(
                      label: Text(kWeekdayNames[day].substring(0, 3)),
                      selected: _days.contains(day),
                      onSelected: (v) => setState(() => v ? _days.add(day) : _days.remove(day)),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  OutlinedButton(onPressed: () => _pick(true), child: Text(formatMenuTime(_from))),
                  const Text('  –  '),
                  OutlinedButton(onPressed: () => _pick(false), child: Text(formatMenuTime(_to))),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text('Outside these times', style: text.labelMedium),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  ChoiceChip(
                    key: const Key('category-schedule-dim'),
                    label: const Text('Show greyed out, with its hours'),
                    selected: !_hide,
                    onSelected: (_) => setState(() => _hide = false),
                  ),
                  ChoiceChip(
                    key: const Key('category-schedule-hide'),
                    label: const Text('Hide it from the menu'),
                    selected: _hide,
                    onSelected: (_) => setState(() => _hide = true),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (problem != null)
                Text(problem, style: text.bodySmall?.copyWith(color: AppColors.warning)),
            ],
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Uses India time (IST). Changes go live when you publish.',
              style: text.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('category-schedule-save'),
          onPressed: problem != null
              ? null
              : () => Navigator.of(context).pop<CategoryScheduleChoice>(
                    (schedule: _limited ? _schedule : null, hide: _hide),
                  ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// "Breakfast · Available 7 am – 11 am" hint under a category row.
String? categoryScheduleHint(CatalogCategory c) =>
    c.schedule == null ? null : '${c.schedule!.label}${c.hideOutsideWindow ? ' · hidden otherwise' : ''}';
