// lib/presentation/screens/catalog/today_screen.dart
//
// "Today" (more-customization Stage 14.1–14.2): every dish in one dense list —
// stock switch, price, search, "sold out only" — for the daily "paneer is
// finished" and "+₹10 on drinks" changes. Changes collect in a bottom bar and
// go in ONE batch; "Save & publish" makes them live (only the changed dishes
// are pushed). Long-press a dish for "sold out until tomorrow".
//
// The same screen serves the owner (`/catalog/today`) and a helper
// (`/staff/catalogs/:id/today`); what a helper may change comes from their
// permissions, and the server refuses anything else anyway.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/today_repository.dart';
import '../../../domain/catalog/today.dart';
import '../../widgets/app_button.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';

String _money(double? v) =>
    v == null ? '' : (v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2));

class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({super.key, this.staffCatalogId, this.permissions = StaffPermissions.owner, this.title});

  final String? staffCatalogId;
  final StaffPermissions permissions;
  final String? title;

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen> {
  final Map<String, TodayEdit> _edits = {};
  final Set<String> _selected = {};
  String _query = '';
  bool _soldOutOnly = false;
  bool _selecting = false;
  bool _saving = false;

  TodayRepository get _repo => ref.read(todayRepositoryProvider(widget.staffCatalogId));

  int get _changeCount => _edits.values.where((e) => e.inStock != null || e.priceChanged).length;

  bool _inStock(TodayDish d) => _edits[d.id]?.inStock ?? d.inStock;

  Future<void> _save({required bool publish}) async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _saving = true);
    try {
      final outcome = await _repo.save(
        [
          for (final e in _edits.entries)
            if (e.value.inStock != null || e.value.priceChanged) e.value.toMap(e.key),
        ],
        publish: publish,
      );
      _edits.clear();
      ref.invalidate(todayProvider(widget.staffCatalogId));
      if (!mounted) return;
      CatalogFeedback.confirm(
        messenger,
        !publish
            ? 'Saved. Publish to show it on the menu.'
            : outcome == 'QUEUED' || outcome == 'IN_PROGRESS'
                ? 'Saved and publishing — live in a few seconds.'
                : 'Saved. Publishing is not possible right now; open Publish to see why.',
      );
    } on CatalogFailure catch (f) {
      if (mounted) CatalogFeedback.failure(messenger, f, subject: 'changes');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _dishMenu(TodayDish d) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.nightlight_outlined),
              title: const Text('Sold out until tomorrow'),
              subtitle: const Text('Back in stock at 5 am'),
              onTap: () => Navigator.pop(ctx, 'tomorrow'),
            ),
            ListTile(
              leading: const Icon(Icons.block),
              title: const Text('Sold out'),
              onTap: () => Navigator.pop(ctx, 'out'),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('In stock'),
              onTap: () => Navigator.pop(ctx, 'in'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    setState(() {
      final e = _edits.putIfAbsent(d.id, TodayEdit.new);
      e.inStock = choice == 'in';
      e.untilTomorrow = choice == 'tomorrow';
    });
  }

  Future<void> _bulkPrices(TodayData data) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _BulkPriceSheet(
        repo: _repo,
        productIds: _selected.toList(),
      ),
    );
    if (changed == true) {
      setState(() {
        _selected.clear();
        _selecting = false;
      });
      ref.invalidate(todayProvider(widget.staffCatalogId));
    }
  }

  Future<void> _undo() async {
    final messenger = CatalogFeedback.of(context);
    try {
      final (restored, kept) = await _repo.undoBulk();
      ref.invalidate(todayProvider(widget.staffCatalogId));
      CatalogFeedback.confirm(
        messenger,
        kept == 0 ? '$restored prices restored.' : '$restored prices restored; $kept changed since were kept.',
      );
    } on CatalogFailure catch (f) {
      CatalogFeedback.failure(messenger, f, subject: 'undo');
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(todayProvider(widget.staffCatalogId));
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    final canPrice = widget.permissions.prices;

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(widget.title ?? 'Today'),
        actions: [
          if (canPrice)
            TextButton(
              key: const Key('today-select'),
              onPressed: () => setState(() {
                _selecting = !_selecting;
                _selected.clear();
              }),
              child: Text(_selecting ? 'Cancel' : 'Select'),
            ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => CatalogMessage(
          icon: Icons.today_outlined,
          title: 'Could not load your dishes',
          body: e is CatalogFailure ? e.message : 'Something went wrong. Please try again.',
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(todayProvider(widget.staffCatalogId)),
        ),
        data: (data) {
          final q = _query.trim().toLowerCase();
          final sections = [
            for (final s in data.sections)
              (
                section: s,
                dishes: [
                  for (final d in s.dishes)
                    if ((q.isEmpty || d.name.toLowerCase().replaceAll('_', ' ').contains(q)) &&
                        (!_soldOutOnly || !_inStock(d)))
                      d,
                ],
              ),
          ].where((s) => s.dishes.isNotEmpty).toList();

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.screenPadding, 0, AppSpacing.screenPadding, AppSpacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search dishes', isDense: true),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilterChip(
                      key: const Key('today-sold-out-only'),
                      label: const Text('Sold out'),
                      selected: _soldOutOnly,
                      onSelected: (v) => setState(() => _soldOutOnly = v),
                    ),
                  ],
                ),
              ),
              if (data.undo != null && canPrice)
                MaterialBanner(
                  content: Text('${data.undo!.by} changed ${data.undo!.count} prices. Undo within 7 days.'),
                  actions: [TextButton(key: const Key('today-undo-prices'), onPressed: _undo, child: const Text('Undo'))],
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                  children: [
                    for (final s in sections) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.xs),
                        child: Row(
                          children: [
                            Expanded(child: Text(s.section.name, style: text.titleSmall?.copyWith(color: AppColors.textSecondary))),
                            if (_selecting)
                              TextButton(
                                onPressed: () => setState(() {
                                  final ids = s.dishes.map((d) => d.id);
                                  final all = ids.every(_selected.contains);
                                  all ? _selected.removeAll(ids) : _selected.addAll(ids);
                                }),
                                child: const Text('Select section'),
                              ),
                          ],
                        ),
                      ),
                      for (final d in s.dishes)
                        _DishRow(
                          key: ValueKey(d.id),
                          dish: d,
                          edit: _edits[d.id],
                          canPrice: canPrice,
                          selecting: _selecting,
                          selected: _selected.contains(d.id),
                          onSelect: (v) => setState(() => v ? _selected.add(d.id) : _selected.remove(d.id)),
                          onStock: (v) => setState(() {
                            final e = _edits.putIfAbsent(d.id, TodayEdit.new);
                            e.inStock = v == d.inStock && !e.untilTomorrow ? null : v;
                            e.untilTomorrow = false;
                          }),
                          onPrice: (v) => setState(() {
                            final e = _edits.putIfAbsent(d.id, TodayEdit.new);
                            e.price = v;
                            e.priceChanged = v != d.price;
                          }),
                          onLongPress: () => _dishMenu(d),
                        ),
                    ],
                    if (data.lastChanges.isNotEmpty)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text('Recent changes', style: text.titleSmall),
                        children: [
                          for (final c in data.lastChanges)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text('${c.by} ${c.text}'),
                              subtitle: c.at == null
                                  ? null
                                  : Text(
                                      '${TimeOfDay.fromDateTime(c.at!.toLocal()).format(context)}'
                                      ' · ${c.at!.toLocal().day}/${c.at!.toLocal().month}',
                                      style: muted,
                                    ),
                            ),
                        ],
                      ),
                    const SizedBox(height: 120),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: _selecting
              ? AppButton(
                  key: const Key('today-change-prices'),
                  label: 'Change prices (${_selected.length})',
                  onPressed: _selected.isEmpty ? null : () => _bulkPrices(async.value!),
                )
              : _changeCount == 0
                  ? const SizedBox.shrink()
                  : Row(
                      children: [
                        Expanded(
                          child: AppButton.secondary(
                            label: '$_changeCount change${_changeCount == 1 ? '' : 's'} · Save',
                            isLoading: _saving,
                            onPressed: _saving ? null : () => _save(publish: false),
                          ),
                        ),
                        if (widget.permissions.publish) ...[
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: AppButton(
                              key: const Key('today-publish'),
                              label: 'Publish now',
                              isLoading: _saving,
                              onPressed: _saving ? null : () => _save(publish: true),
                            ),
                          ),
                        ],
                      ],
                    ),
        ),
      ),
    );
  }
}

class _DishRow extends StatelessWidget {
  const _DishRow({
    super.key,
    required this.dish,
    required this.edit,
    required this.canPrice,
    required this.selecting,
    required this.selected,
    required this.onSelect,
    required this.onStock,
    required this.onPrice,
    required this.onLongPress,
  });

  final TodayDish dish;
  final TodayEdit? edit;
  final bool canPrice;
  final bool selecting;
  final bool selected;
  final ValueChanged<bool> onSelect;
  final ValueChanged<bool> onStock;
  final ValueChanged<double?> onPrice;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final inStock = edit?.inStock ?? dish.inStock;
    final changed = edit != null && (edit!.inStock != null || edit!.priceChanged);
    final tomorrow = (edit?.inStock == false && edit!.untilTomorrow) ||
        (edit?.inStock == null && dish.backInStockAt != null && !dish.inStock);
    return InkWell(
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: changed
            ? BoxDecoration(border: Border(left: BorderSide(color: AppColors.royalGold, width: 3)))
            : null,
        child: Row(
          children: [
            if (selecting) Checkbox(value: selected, onChanged: (v) => onSelect(v ?? false)),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dish.name.replaceAll('_', ' '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyLarge?.copyWith(
                        color: inStock ? AppColors.textPrimary : AppColors.textMuted,
                        decoration: inStock ? null : TextDecoration.lineThrough,
                      ),
                    ),
                    if (!inStock)
                      Text(tomorrow ? 'Sold out · back 5 am' : 'Sold out',
                          style: text.bodySmall?.copyWith(color: AppColors.warning)),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: 84,
              child: canPrice && !selecting
                  ? TextFormField(
                      initialValue: _money(dish.price),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      decoration: const InputDecoration(isDense: true, prefixText: '₹ '),
                      onChanged: (v) => onPrice(v.trim().isEmpty ? null : double.tryParse(v)),
                    )
                  : Text(dish.price == null ? '—' : '₹${_money(dish.price)}', textAlign: TextAlign.right),
            ),
            Switch(
              key: Key('today-stock-${dish.id}'),
              value: inStock,
              onChanged: selecting ? null : onStock,
            ),
          ],
        ),
      ),
    );
  }
}

class _BulkPriceSheet extends StatefulWidget {
  const _BulkPriceSheet({required this.repo, required this.productIds});

  final TodayRepository repo;
  final List<String> productIds;

  @override
  State<_BulkPriceSheet> createState() => _BulkPriceSheetState();
}

class _BulkPriceSheetState extends State<_BulkPriceSheet> {
  bool _percent = true;
  bool _up = true;
  final _amount = TextEditingController(text: '5');
  PriceRounding _rounding = PriceRounding.none;
  List<BulkPreviewRow>? _preview;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  double? get _value {
    final n = double.tryParse(_amount.text.trim());
    if (n == null || n <= 0) return null;
    return _up ? n : -n;
  }

  Future<void> _runPreview() async {
    final v = _value;
    if (v == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rows = await widget.repo.previewBulk(
        productIds: widget.productIds,
        categoryIds: const [],
        percent: _percent,
        amount: v,
        rounding: _rounding,
      );
      if (mounted) setState(() => _preview = rows);
    } on CatalogFailure catch (f) {
      if (mounted) setState(() => _error = f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    setState(() => _busy = true);
    try {
      await widget.repo.applyBulk(
        productIds: widget.productIds,
        categoryIds: const [],
        percent: _percent,
        amount: _value!,
        rounding: _rounding,
      );
      if (mounted) Navigator.pop(context, true);
    } on CatalogFailure catch (f) {
      if (mounted) {
        setState(() {
          _error = f.message;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Change ${widget.productIds.length} prices', style: text.titleLarge),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                SegmentedButton<bool>(
                  segments: const [ButtonSegment(value: true, label: Text('Up')), ButtonSegment(value: false, label: Text('Down'))],
                  selected: {_up},
                  onSelectionChanged: (s) => setState(() {
                    _up = s.first;
                    _preview = null;
                  }),
                ),
                const SizedBox(width: AppSpacing.sm),
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() => _preview = null),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                SegmentedButton<bool>(
                  segments: const [ButtonSegment(value: true, label: Text('%')), ButtonSegment(value: false, label: Text('₹'))],
                  selected: {_percent},
                  onSelectionChanged: (s) => setState(() {
                    _percent = s.first;
                    _preview = null;
                  }),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                for (final r in PriceRounding.values)
                  ChoiceChip(
                    label: Text(r.label),
                    selected: _rounding == r,
                    onSelected: (_) => setState(() {
                      _rounding = r;
                      _preview = null;
                    }),
                  ),
              ],
            ),
            if (_error != null) Text(_error!, style: text.bodySmall?.copyWith(color: AppColors.warning)),
            const SizedBox(height: AppSpacing.md),
            if (_preview != null) ...[
              for (final r in _preview!.take(30))
                Row(
                  children: [
                    Expanded(child: Text(r.name.replaceAll('_', ' '), overflow: TextOverflow.ellipsis)),
                    Text('₹${_money(r.from)} → ', style: text.bodySmall),
                    Text(r.to == null ? 'skipped' : '₹${_money(r.to)}',
                        style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                  ],
                ),
              if (_preview!.length > 30) Text('…and ${_preview!.length - 30} more', style: text.bodySmall),
              const SizedBox(height: AppSpacing.md),
              AppButton(
                key: const Key('today-apply-prices'),
                label: 'Apply to ${_preview!.where((r) => r.to != null && r.to != r.from).length} dishes',
                isLoading: _busy,
                onPressed: _busy ? null : _apply,
              ),
            ] else
              AppButton(
                key: const Key('today-preview-prices'),
                label: 'Preview',
                isLoading: _busy,
                onPressed: _busy || _value == null ? null : _runPreview,
              ),
          ],
        ),
      ),
    );
  }
}
