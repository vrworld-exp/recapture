// lib/presentation/screens/catalog/offers_screen.dart
//
// Offers, combos and happy hour (more-customization Stage 10):
//   • [OffersScreen] — `/catalog/offers`: every offer with its status chip
//     (Live now / Scheduled / Ended / Paused), a pause toggle, swipe to delete.
//   • [OfferEditorScreen] — `/catalog/offers/new` and `/catalog/offers/:offerId`:
//     one scrolling form in the four steps of the plan — 1 type, 2 which
//     dishes, 3 when (with the Happy hour / Weekday lunch / Weekend presets),
//     4 a preview of three dishes old → new, computed by the server so it is
//     the same price the menu will show.
//
// Nothing is live until Publish; after that each offer starts and stops by
// itself on the menu, in India time.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/menu_translations_provider.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/offers_repository.dart';
import '../../../domain/catalog/catalog_names.dart';
import '../../../domain/catalog/offer.dart';
import '../../../domain/entities/catalog_category.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';

const double _kMaxWidth = 720;
const _kDayLabels = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

String _time(String hhmm) {
  final parts = hhmm.split(':');
  final h = int.tryParse(parts.first) ?? 0;
  final m = parts.length > 1 ? parts[1] : '00';
  final suffix = h < 12 ? 'am' : 'pm';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return m == '00' ? '$h12 $suffix' : '$h12:$m $suffix';
}

String _money(double? v) =>
    v == null ? '—' : '₹${v == v.roundToDouble() ? v.toInt() : v.toStringAsFixed(2)}';

/// "Every day 5 pm – 7 pm", "Mon–Fri 12 pm – 3 pm · until 5 Oct", "Always".
String describeSchedule(OfferSchedule s) {
  final parts = <String>[];
  final days = [...s.days]..sort();
  if (days.isNotEmpty && days.length < 7) {
    const weekdays = [1, 2, 3, 4, 5];
    parts.add(days.length == 5 && weekdays.every(days.contains)
        ? 'Mon–Fri'
        : days.length == 2 && days.contains(0) && days.contains(6)
            ? 'Weekends'
            : days.map((d) => _kDayLabels[d]).join(', '));
  } else if (s.hasDailyWindow) {
    parts.add('Every day');
  }
  if (s.hasDailyWindow) parts.add('${_time(s.from!)} – ${_time(s.to!)}');
  String date(DateTime d) => '${d.toLocal().day} ${_months[d.toLocal().month - 1]}';
  if (s.startsAt != null) parts.add('from ${date(s.startsAt!)}');
  if (s.endsAt != null) parts.add('until ${date(s.endsAt!.subtract(const Duration(minutes: 1)))}');
  return parts.isEmpty ? 'Always' : parts.join(' · ');
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// ── The list ───────────────────────────────────────────────────────────────

class OffersScreen extends ConsumerWidget {
  const OffersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(offersListProvider);
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: const Text('Offers')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('offers-new'),
        onPressed: () async {
          await context.push(AppRoutes.catalogOfferNew);
          ref.invalidate(offersListProvider);
        },
        icon: const Icon(Icons.add),
        label: const Text('New offer'),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.local_offer_outlined,
          title: 'Offers unavailable',
          body: error is CatalogFailure ? error.message : 'Something went wrong. Please try again.',
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(offersListProvider),
        ),
        data: (offers) => offers.isEmpty
            ? const CatalogMessage(
                icon: Icons.local_offer_outlined,
                title: 'No offers yet',
                body: 'Happy hour, weekday lunch, a festival discount or a combo — '
                    'set it once and it starts and stops by itself.',
              )
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _kMaxWidth),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.screenPadding, AppSpacing.sm, AppSpacing.screenPadding, 96),
                    children: [
                      Text(
                        'Changes show on your menu after you publish. '
                        'Swipe an offer left to delete it.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      for (final offer in offers) _OfferTile(offer: offer),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _OfferTile extends ConsumerStatefulWidget {
  const _OfferTile({required this.offer});
  final Offer offer;

  @override
  ConsumerState<_OfferTile> createState() => _OfferTileState();
}

class _OfferTileState extends ConsumerState<_OfferTile> {
  bool _busy = false;

  Future<void> _toggle(bool active) async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(offersRepositoryProvider).setActive(widget.offer.id!, active);
      ref.invalidate(offersListProvider);
    } on CatalogFailure catch (failure) {
      if (mounted) CatalogFeedback.failure(messenger, failure, subject: 'offer');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete “${widget.offer.name}”?'),
        content: const Text('It comes off your menu at the next publish.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return false;
    final messenger = CatalogFeedback.of(context);
    try {
      await ref.read(offersRepositoryProvider).delete(widget.offer.id!);
      return true;
    } on CatalogFailure catch (failure) {
      if (mounted) CatalogFeedback.failure(messenger, failure, subject: 'offer');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer;
    final text = Theme.of(context).textTheme;
    final chipColor = switch (offer.status) {
      OfferStatus.live => AppColors.success,
      OfferStatus.scheduled => AppColors.royalGold,
      OfferStatus.ended => AppColors.textMuted,
      OfferStatus.paused => AppColors.textMuted,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Dismissible(
        key: ValueKey('offer-${offer.id}'),
        direction: DismissDirection.endToStart,
        confirmDismiss: (_) => _confirmDelete(),
        onDismissed: (_) => ref.invalidate(offersListProvider),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: AppSpacing.lg),
          decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(16)),
          child: const Icon(Icons.delete_outline, color: Colors.white),
        ),
        child: AppCard(
          onTap: () async {
            await context.push(AppRoutes.catalogOfferDetail.replaceFirst(':offerId', offer.id!));
            ref.invalidate(offersListProvider);
          },
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(offer.name,
                              overflow: TextOverflow.ellipsis,
                              style: text.titleMedium?.copyWith(color: AppColors.textPrimary)),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: chipColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(offer.status.label,
                              style: text.labelSmall?.copyWith(color: chipColor, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text('${offer.valueLabel} · ${describeSchedule(offer.schedule)}',
                        style: text.bodySmall?.copyWith(color: AppColors.textSecondary)),
                  ],
                ),
              ),
              Switch(
                key: Key('offer-active-${offer.id}'),
                value: offer.active,
                onChanged: _busy ? null : _toggle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── The editor ─────────────────────────────────────────────────────────────

class _Preset {
  const _Preset(this.label, this.schedule, {this.name});
  final String label;
  final OfferSchedule schedule;
  final String? name;
}

const _presets = [
  _Preset('Always', OfferSchedule()),
  _Preset('Happy hour 5–7 pm', OfferSchedule(from: '17:00', to: '19:00'), name: 'Happy hour'),
  _Preset('Weekday lunch 12–3 pm', OfferSchedule(days: [1, 2, 3, 4, 5], from: '12:00', to: '15:00'),
      name: 'Weekday lunch'),
  _Preset('Weekend', OfferSchedule(days: [0, 6]), name: 'Weekend special'),
];

class OfferEditorScreen extends ConsumerWidget {
  const OfferEditorScreen({super.key, this.offerId});

  /// Null = a new offer.
  final String? offerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(menuTranslationsProvider);
    final offers = offerId == null ? null : ref.watch(offersListProvider);
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(offerId == null ? 'New offer' : 'Edit offer'),
      ),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.local_offer_outlined,
          title: 'Could not load your menu',
          body: error is CatalogFailure ? error.message : 'Something went wrong. Please try again.',
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(menuTranslationsProvider),
        ),
        data: (menu) {
          if (menu == null) {
            return const CatalogMessage(
              icon: Icons.storefront_outlined,
              title: 'No catalog yet',
              body: 'Create your catalog first.',
            );
          }
          Offer? existing;
          if (offers != null) {
            final list = offers.valueOrNull;
            if (list == null) return const Center(child: CircularProgressIndicator());
            existing = list.where((o) => o.id == offerId).firstOrNull;
            if (existing == null) {
              return const CatalogMessage(
                icon: Icons.local_offer_outlined,
                title: 'Offer not found',
                body: 'It may have been deleted.',
              );
            }
          }
          return _OfferForm(
            initial: existing,
            products: menu.products,
            categories: menu.categories,
          );
        },
      ),
    );
  }
}

class _OfferForm extends ConsumerStatefulWidget {
  const _OfferForm({required this.products, required this.categories, this.initial});

  final Offer? initial;
  final List<CatalogProduct> products;
  final List<CatalogCategory> categories;

  @override
  ConsumerState<_OfferForm> createState() => _OfferFormState();
}

class _OfferFormState extends ConsumerState<_OfferForm> {
  late final TextEditingController _name = TextEditingController(text: widget.initial?.name ?? '');
  late final TextEditingController _value = TextEditingController(
      text: _numText(widget.initial?.kind == OfferKind.combo ? widget.initial?.comboPrice : widget.initial?.value));
  late final TextEditingController _comboTitle =
      TextEditingController(text: widget.initial?.comboTitle ?? '');
  late OfferKind _kind = widget.initial?.kind ?? OfferKind.percent;
  late OfferTargetType _targetType = widget.initial?.targetType ?? OfferTargetType.products;
  late Set<String> _productIds = {
    ...(widget.initial?.kind == OfferKind.combo
        ? widget.initial!.comboProductIds
        : widget.initial?.targetType == OfferTargetType.products
            ? widget.initial!.targetIds
            : const <String>[]),
  };
  late Set<String> _categoryIds = {
    if (widget.initial?.targetType == OfferTargetType.categories) ...widget.initial!.targetIds,
  };
  late OfferSchedule _schedule = widget.initial?.schedule ?? const OfferSchedule();
  late final int _priority = widget.initial?.priority ?? 0;
  bool _saving = false;
  bool _previewing = false;
  OfferPreview? _preview;

  static String _numText(double? v) =>
      v == null ? '' : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    _comboTitle.dispose();
    super.dispose();
  }

  double? get _number => double.tryParse(_value.text.trim());

  Offer _build() => Offer(
        id: widget.initial?.id,
        name: _name.text.trim(),
        kind: _kind,
        value: _kind == OfferKind.combo ? null : _number,
        targetType: _kind == OfferKind.fixedPrice ? OfferTargetType.products : _targetType,
        targetIds: _targetType == OfferTargetType.categories && _kind != OfferKind.fixedPrice
            ? _categoryIds.toList()
            : _productIds.toList(),
        comboProductIds: _kind == OfferKind.combo ? _productIds.toList() : const [],
        comboPrice: _kind == OfferKind.combo ? _number : null,
        comboTitle: _comboTitle.text.trim(),
        schedule: _schedule,
        active: widget.initial?.active ?? true,
        priority: _priority,
      );

  String? get _problem {
    if (_name.text.trim().isEmpty) return 'Give the offer a name.';
    final n = _number;
    if (n == null || n <= 0) return _kind == OfferKind.combo ? 'Enter the combo price.' : 'Enter the discount.';
    if (_kind == OfferKind.percent && n >= 100) return 'A percentage must be below 100.';
    if (_kind == OfferKind.combo) {
      if (_productIds.length < 2) return 'Pick at least two dishes for the combo.';
      return null;
    }
    final type = _kind == OfferKind.fixedPrice ? OfferTargetType.products : _targetType;
    if (type == OfferTargetType.products && _productIds.isEmpty) return 'Pick at least one dish.';
    if (type == OfferTargetType.categories && _categoryIds.isEmpty) return 'Pick at least one section.';
    return null;
  }

  Future<void> _runPreview() async {
    if (_problem != null) return;
    setState(() => _previewing = true);
    final messenger = CatalogFeedback.of(context);
    try {
      final preview = await ref.read(offersRepositoryProvider).preview(_build());
      if (mounted) setState(() => _preview = preview);
    } on CatalogFailure catch (failure) {
      if (mounted) CatalogFeedback.failure(messenger, failure, subject: 'preview');
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  Future<void> _save() async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _saving = true);
    try {
      final repo = ref.read(offersRepositoryProvider);
      final offer = _build();
      if (offer.id == null) {
        await repo.create(offer);
      } else {
        await repo.update(offer);
      }
      ref.invalidate(offersListProvider);
      if (!mounted) return;
      CatalogFeedback.confirm(messenger, 'Offer saved. It shows on your menu after you publish.');
      context.pop();
    } on CatalogFailure catch (failure) {
      if (mounted) CatalogFeedback.failure(messenger, failure, subject: 'offer');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _changed(VoidCallback fn) => setState(() {
        fn();
        _preview = null;
      });

  Future<void> _pickTime(bool start) async {
    final current = start ? _schedule.from : _schedule.to;
    final parts = (current ?? (start ? '17:00' : '19:00')).split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
    );
    if (picked == null) return;
    final hhmm = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    _changed(() {
      final from = start ? hhmm : (_schedule.from ?? '17:00');
      final to = start ? (_schedule.to ?? '19:00') : hhmm;
      _schedule = OfferSchedule(
        startsAt: _schedule.startsAt,
        endsAt: _schedule.endsAt,
        days: _schedule.days,
        from: from,
        to: to,
      );
    });
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
    );
    if (range == null) return;
    _changed(() => _schedule = OfferSchedule(
          // Dates are the phone's calendar days; the menu judges them in India time.
          startsAt: DateTime(range.start.year, range.start.month, range.start.day),
          endsAt: DateTime(range.end.year, range.end.month, range.end.day).add(const Duration(days: 1)),
          days: _schedule.days,
          from: _schedule.from,
          to: _schedule.to,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    final isCombo = _kind == OfferKind.combo;
    final targetType = _kind == OfferKind.fixedPrice ? OfferTargetType.products : _targetType;
    final problem = _problem;

    Widget step(String n, String title) => Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xl, bottom: AppSpacing.sm),
          child: Text('$n  $title', style: text.titleMedium?.copyWith(color: AppColors.textPrimary)),
        );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kMaxWidth),
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          children: [
            TextField(
              key: const Key('offer-name'),
              controller: _name,
              maxLength: kMaxOfferName,
              enabled: !_saving,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Name customers see',
                hintText: 'Happy hour',
              ),
            ),

            // 1 ── Type
            step('1', 'What kind of offer?'),
            SegmentedButton<OfferKind>(
              segments: const [
                ButtonSegment(value: OfferKind.percent, label: Text('% off')),
                ButtonSegment(value: OfferKind.flat, label: Text('₹ off')),
                ButtonSegment(value: OfferKind.fixedPrice, label: Text('New price')),
                ButtonSegment(value: OfferKind.combo, label: Text('Combo')),
              ],
              selected: {_kind},
              onSelectionChanged: _saving ? null : (s) => _changed(() => _kind = s.first),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('offer-value'),
              controller: _value,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              onChanged: (_) => _changed(() {}),
              decoration: InputDecoration(
                labelText: switch (_kind) {
                  OfferKind.percent => 'Percent off',
                  OfferKind.flat => 'Rupees off each dish',
                  OfferKind.fixedPrice => 'New price for each chosen dish (₹)',
                  OfferKind.combo => 'Combo price (₹)',
                },
                suffixText: _kind == OfferKind.percent ? '%' : null,
                prefixText: _kind == OfferKind.percent ? null : '₹ ',
              ),
            ),
            if (isCombo)
              TextField(
                controller: _comboTitle,
                maxLength: kMaxComboTitle,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'Combo title (optional)',
                  hintText: 'Burger + Fries + Coke',
                ),
              ),

            // 2 ── Dishes
            step('2', isCombo ? 'Which dishes are in the combo?' : 'Which dishes?'),
            if (!isCombo && _kind != OfferKind.fixedPrice)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: SegmentedButton<OfferTargetType>(
                  segments: const [
                    ButtonSegment(value: OfferTargetType.products, label: Text('Dishes')),
                    ButtonSegment(value: OfferTargetType.categories, label: Text('Sections')),
                    ButtonSegment(value: OfferTargetType.all, label: Text('Whole menu')),
                  ],
                  selected: {_targetType},
                  onSelectionChanged: _saving ? null : (s) => _changed(() => _targetType = s.first),
                ),
              ),
            if (_kind == OfferKind.fixedPrice)
              Text('A new price is set on chosen dishes only.', style: muted),
            if (isCombo || targetType == OfferTargetType.products)
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final p in widget.products)
                    FilterChip(
                      key: Key('offer-dish-${p.id}'),
                      label: Text(p.price == null ? p.displayName : '${p.displayName} · ${_money(p.price)}'),
                      selected: _productIds.contains(p.id),
                      onSelected: _saving ||
                              (isCombo &&
                                  !_productIds.contains(p.id) &&
                                  _productIds.length >= kMaxComboDishes)
                          ? null
                          : (on) => _changed(() => _productIds = on
                              ? {..._productIds, p.id}
                              : ({..._productIds}..remove(p.id))),
                    ),
                ],
              )
            else if (targetType == OfferTargetType.categories)
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final c in widget.categories)
                    FilterChip(
                      label: Text(c.name),
                      selected: _categoryIds.contains(c.id),
                      onSelected: _saving
                          ? null
                          : (on) => _changed(() => _categoryIds = on
                              ? {..._categoryIds, c.id}
                              : ({..._categoryIds}..remove(c.id))),
                    ),
                ],
              )
            else
              Text('Every dish on the menu.', style: muted),

            // 3 ── When
            step('3', 'When?'),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final preset in _presets)
                  ChoiceChip(
                    label: Text(preset.label),
                    selected: describeSchedule(_schedule) == describeSchedule(preset.schedule),
                    onSelected: _saving
                        ? null
                        : (_) => _changed(() {
                              _schedule = preset.schedule;
                              if (_name.text.trim().isEmpty && preset.name != null) _name.text = preset.name!;
                            }),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Days (none = every day)', style: muted),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              children: [
                for (var d = 0; d < 7; d++)
                  FilterChip(
                    label: Text(_kDayLabels[d]),
                    selected: _schedule.days.contains(d),
                    onSelected: _saving
                        ? null
                        : (on) => _changed(() => _schedule = OfferSchedule(
                              startsAt: _schedule.startsAt,
                              endsAt: _schedule.endsAt,
                              days: on
                                  ? ([..._schedule.days, d]..sort())
                                  : _schedule.days.where((x) => x != d).toList(),
                              from: _schedule.from,
                              to: _schedule.to,
                            )),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.schedule, size: 18),
                    label: Text(_schedule.hasDailyWindow
                        ? '${_time(_schedule.from!)} – ${_time(_schedule.to!)}'
                        : 'All day'),
                    onPressed: _saving ? null : () => _pickTime(true),
                  ),
                ),
                if (_schedule.hasDailyWindow) ...[
                  const SizedBox(width: AppSpacing.sm),
                  TextButton(
                    onPressed: _saving ? null : () => _pickTime(false),
                    child: const Text('End time'),
                  ),
                  IconButton(
                    tooltip: 'All day',
                    icon: const Icon(Icons.close),
                    onPressed: _saving
                        ? null
                        : () => _changed(() => _schedule = OfferSchedule(
                              startsAt: _schedule.startsAt,
                              endsAt: _schedule.endsAt,
                              days: _schedule.days,
                            )),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.date_range, size: 18),
                    label: Text(_schedule.startsAt == null && _schedule.endsAt == null
                        ? 'No end date'
                        : describeSchedule(OfferSchedule(
                            startsAt: _schedule.startsAt, endsAt: _schedule.endsAt))),
                    onPressed: _saving ? null : _pickDates,
                  ),
                ),
                if (_schedule.startsAt != null || _schedule.endsAt != null)
                  IconButton(
                    tooltip: 'No end date',
                    icon: const Icon(Icons.close),
                    onPressed: _saving
                        ? null
                        : () => _changed(() => _schedule = OfferSchedule(
                              days: _schedule.days,
                              from: _schedule.from,
                              to: _schedule.to,
                            )),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text('Summary: ${describeSchedule(_schedule)} · times are India time.', style: muted),

            // 4 ── Preview
            step('4', 'Preview'),
            if (_preview == null)
              OutlinedButton(
                key: const Key('offer-preview'),
                onPressed: problem != null || _previewing ? null : _runPreview,
                child: Text(_previewing ? 'Checking prices…' : 'Show new prices'),
              )
            else
              _PreviewCard(preview: _preview!, isCombo: isCombo, comboPrice: _number),
            const SizedBox(height: AppSpacing.xxl),
            if (problem != null) ...[
              Text(problem, style: text.bodySmall?.copyWith(color: AppColors.warning)),
              const SizedBox(height: AppSpacing.sm),
            ],
            AppButton(
              key: const Key('offer-save'),
              label: 'Save offer',
              isLoading: _saving,
              onPressed: problem != null || _saving ? null : _save,
            ),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.preview, required this.isCombo, this.comboPrice});

  final OfferPreview preview;
  final bool isCombo;
  final double? comboPrice;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isCombo) ...[
            Text(
              'Dishes on their own: ${_money(preview.comboFullPrice)} · combo ${_money(comboPrice)}',
              style: text.bodyMedium?.copyWith(color: AppColors.textPrimary),
            ),
            if ((preview.comboSaves ?? 0) > 0)
              Text('Customers save ${_money(preview.comboSaves)}',
                  style: text.bodySmall?.copyWith(color: AppColors.success)),
          ] else ...[
            Text('${preview.affectedCount} dish${preview.affectedCount == 1 ? '' : 'es'} affected',
                style: muted),
            const SizedBox(height: AppSpacing.xs),
            for (final s in preview.samples)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(catalogDisplayName(s.name),
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(color: AppColors.textPrimary)),
                    ),
                    if (s.finalPrice == null)
                      Text(s.price == null ? 'no price' : '${_money(s.price)} · unchanged', style: muted)
                    else ...[
                      Text(_money(s.price),
                          style: muted?.copyWith(decoration: TextDecoration.lineThrough)),
                      const SizedBox(width: AppSpacing.sm),
                      Text(_money(s.finalPrice),
                          style: text.bodyMedium?.copyWith(
                              color: AppColors.mirageRed, fontWeight: FontWeight.w700)),
                    ],
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
