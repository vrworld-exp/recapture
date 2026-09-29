// lib/presentation/screens/catalog/opening_hours_screen.dart
//
// Opening hours (more-customization Stage 4): seven day rows, each with up to
// three time slots (lunch + dinner), a "same as Monday" copy, holidays, and the
// switch for the "Open · closes 11 pm" chip on the menu.
//
// Reached from the business profile, for both the owner and a rep on a
// delegated catalog — one screen, a [CatalogScope] tells them apart, exactly
// as the profile does. The menu stays browsable when closed: this drives a
// badge, never a gate. Goes live on Publish, like every authoring edit.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/catalog_scope.dart';
import '../../../domain/catalog/menu_time.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';

class OpeningHoursScreen extends ConsumerWidget {
  const OpeningHoursScreen({super.key}) : catalogId = null;

  const OpeningHoursScreen.delegated({super.key, required String this.catalogId});

  final String? catalogId;

  CatalogScope get _scope =>
      catalogId == null ? const CatalogScope.owner() : CatalogScope.delegated(catalogId!);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = _scope;
    final profileAsync = ref.watch(businessProfileFor(scope));
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => navigateBack(context),
        ),
        title: Text('Opening hours', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: profileAsync.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "We couldn't load your hours",
          body: error is CatalogFailure
              ? CatalogFeedback.failureText(error)
              : CatalogFeedback.textForCode(null),
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(businessProfileFor(scope)),
        ),
        data: (profile) => profile == null
            ? const CatalogMessage(
                icon: Icons.storefront_outlined,
                title: 'No catalog yet',
                body: 'Create your catalog first.',
              )
            : _HoursEditor(
                key: ValueKey(profile.id),
                scope: scope,
                initial: profile.hours,
              ),
      ),
    );
  }
}

class _HoursEditor extends ConsumerStatefulWidget {
  const _HoursEditor({super.key, required this.scope, required this.initial});

  final CatalogScope scope;
  final CatalogHours? initial;

  @override
  ConsumerState<_HoursEditor> createState() => _HoursEditorState();
}

class _HoursEditorState extends ConsumerState<_HoursEditor> {
  late CatalogHours _hours = widget.initial ?? const CatalogHours();
  late CatalogHours? _saved = widget.initial;
  bool _saving = false;
  CatalogFailure? _error;

  bool get _dirty => _hours != (_saved ?? const CatalogHours());

  void _setDay(int day, List<HoursSlot> slots) {
    setState(() {
      _hours = _hours.copyWith(
        weekly: [..._hours.weekly.where((s) => s.day != day), ...slots],
      );
    });
  }

  Future<String?> _pickTime(String current) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: minutesOf(current) ~/ 60,
        minute: minutesOf(current) % 60,
      ),
    );
    if (picked == null) return null;
    return '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _addHoliday() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 366)),
      initialDate: now,
    );
    if (picked == null) return;
    final key =
        '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    if (_hours.closedDates.contains(key)) return;
    setState(() {
      _hours = _hours.copyWith(closedDates: [..._hours.closedDates, key]..sort());
    });
  }

  Future<void> _save({bool clear = false}) async {
    final problem = clear ? null : _hours.validate();
    if (problem != null) return;
    final messenger = CatalogFeedback.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final profile = await ref
          .read(businessProfileFor(widget.scope).notifier)
          .saveHours(clear || _hours.weekly.isEmpty ? null : _hours);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved = profile.hours;
        _hours = profile.hours ?? const CatalogHours();
      });
      CatalogFeedback.confirm(
        messenger,
        'Hours saved. They reach your menu the next time you publish.',
      );
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = failure;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final problem = _hours.validate();
    final monday = _hours.slotsFor(1);
    final text = Theme.of(context).textTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Times are in India time (IST). Your menu stays open to browse when '
                'you are closed — this only sets the "Open / Closed" badge.',
                style: text.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(height: AppSpacing.lg),
              for (final day in kWeekOrder)
                _DayRow(
                  key: Key('hours-day-$day'),
                  day: day,
                  slots: _hours.slotsFor(day),
                  enabled: !_saving,
                  onChanged: (slots) => _setDay(day, slots),
                  pickTime: _pickTime,
                  onCopyMonday: day == 1 || monday.isEmpty
                      ? null
                      : () => _setDay(day, [for (final s in monday) s.copyWith(day: day)]),
                ),
              const SizedBox(height: AppSpacing.xl),
              Text('Holidays', style: text.titleSmall),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final date in _hours.closedDates)
                    InputChip(
                      label: Text(date),
                      onDeleted: _saving
                          ? null
                          : () => setState(() {
                                _hours = _hours.copyWith(
                                  closedDates: _hours.closedDates.where((d) => d != date).toList(),
                                );
                              }),
                    ),
                  ActionChip(
                    key: const Key('hours-add-holiday'),
                    avatar: const Icon(Icons.add, size: 16),
                    label: const Text('Add a holiday'),
                    onPressed: _saving ? null : _addHoliday,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              SwitchListTile(
                key: const Key('hours-show-badge'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Show "Open now" on the menu'),
                value: _hours.showOpenBadge,
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _hours = _hours.copyWith(showOpenBadge: v)),
              ),
              if (problem != null || _error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  problem ?? CatalogFeedback.failureText(_error!),
                  key: const Key('hours-problem'),
                  style: text.bodySmall?.copyWith(color: AppColors.warning),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                key: const Key('hours-save'),
                label: 'Save hours',
                isLoading: _saving,
                onPressed: _dirty && problem == null && !_saving ? () => _save() : null,
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton.secondary(
                key: const Key('hours-clear'),
                label: 'Remove opening hours',
                onPressed: _saved == null || _saving ? null : () => _save(clear: true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({
    super.key,
    required this.day,
    required this.slots,
    required this.enabled,
    required this.onChanged,
    required this.pickTime,
    this.onCopyMonday,
  });

  final int day;
  final List<HoursSlot> slots;
  final bool enabled;
  final ValueChanged<List<HoursSlot>> onChanged;
  final Future<String?> Function(String current) pickTime;
  final VoidCallback? onCopyMonday;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(kWeekdayNames[day], style: text.titleSmall)),
              if (slots.isEmpty)
                Text('Closed', style: text.bodySmall?.copyWith(color: AppColors.textMuted)),
              if (onCopyMonday != null)
                TextButton(
                  onPressed: enabled ? onCopyMonday : null,
                  child: const Text('Same as Monday'),
                ),
              IconButton(
                tooltip: 'Add a time slot',
                icon: const Icon(Icons.add_circle_outline, size: 20),
                onPressed: enabled && slots.length < kMaxSlotsPerDay
                    ? () => onChanged([
                          ...slots,
                          HoursSlot(
                            day: day,
                            open: slots.isEmpty ? '11:00' : '19:00',
                            close: slots.isEmpty ? '23:00' : '23:00',
                          ),
                        ])
                    : null,
              ),
            ],
          ),
          for (var i = 0; i < slots.length; i++)
            Row(
              children: [
                _TimeButton(
                  value: slots[i].open,
                  enabled: enabled,
                  onPick: () async {
                    final t = await pickTime(slots[i].open);
                    if (t != null) onChanged([...slots]..[i] = slots[i].copyWith(open: t));
                  },
                ),
                const Text('  –  '),
                _TimeButton(
                  value: slots[i].close,
                  enabled: enabled,
                  onPick: () async {
                    final t = await pickTime(slots[i].close);
                    if (t != null) onChanged([...slots]..[i] = slots[i].copyWith(close: t));
                  },
                ),
                if (slots[i].pastMidnight)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.sm),
                    child: Text(
                      'next day',
                      style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                    ),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: 'Remove this slot',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: enabled ? () => onChanged([...slots]..removeAt(i)) : null,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _TimeButton extends StatelessWidget {
  const _TimeButton({required this.value, required this.enabled, required this.onPick});

  final String value;
  final bool enabled;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: enabled ? onPick : null,
        child: Text(formatMenuTime(value)),
      );
}
