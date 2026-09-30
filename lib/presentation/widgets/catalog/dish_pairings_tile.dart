// lib/presentation/widgets/catalog/dish_pairings_tile.dart
//
// "Goes well with" in the product editor (more-customization Stage 7.2): up to
// four other dishes shown as tappable mini-cards on this dish's page on the menu.
//
// Saved on its OWN call when the picker closes, like the Stage 6 translations
// tile — it never makes the editor's form dirty. A paired dish that is later
// archived or deleted simply drops off the menu.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/menu_translations_provider.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/menu_extras_repository.dart';
import '../../../domain/catalog/menu_extras.dart';
import '../../../domain/entities/catalog_product.dart';
import '../app_loading_indicator.dart';
import 'catalog_feedback.dart';
import 'plan_lock_chip.dart';

class DishPairingsTile extends ConsumerStatefulWidget {
  const DishPairingsTile({super.key, required this.product, this.enabled = true});

  final CatalogProduct product;
  final bool enabled;

  @override
  ConsumerState<DishPairingsTile> createState() => _DishPairingsTileState();
}

class _DishPairingsTileState extends ConsumerState<DishPairingsTile> {
  late List<String> _ids = widget.product.pairsWith;
  bool _saving = false;

  Future<void> _edit(List<CatalogProduct> others) async {
    final messenger = CatalogFeedback.of(context);
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => _PairingPicker(others: others, initial: _ids),
    );
    if (picked == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final updated = await ref
          .read(menuExtrasRepositoryProvider)
          .updatePairings(widget.product.id, picked);
      if (!mounted) return;
      setState(() => _ids = updated.pairsWith);
      CatalogFeedback.confirm(messenger, 'Saved. Customers see it after your next publish.');
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      CatalogFeedback.failure(messenger, failure, subject: 'pairings');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final others = [
      for (final p in ref.watch(menuTranslationsProvider).valueOrNull?.products ?? const <CatalogProduct>[])
        if (p.id != widget.product.id && !p.isArchived) p,
    ];
    final byId = {for (final p in others) p.id: p};
    final names = [for (final id in _ids) if (byId[id] != null) byId[id]!.displayName];

    return ListTile(
      key: const Key('dish-pairings'),
      contentPadding: EdgeInsets.zero,
      enabled: widget.enabled && !_saving && others.isNotEmpty,
      onTap: () => _edit(others),
      title: Row(
        children: [
          Text('Goes well with', style: text.titleMedium),
          const SizedBox(width: AppSpacing.sm),
          EntitlementLock(feature: 'pairings', covered: (e) => e.arBrandingAndSpotlight),
        ],
      ),
      subtitle: Text(
        names.isEmpty ? 'Suggest up to $kMaxPairings dishes to have with this one.' : names.join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: text.bodySmall?.copyWith(color: AppColors.textMuted),
      ),
      trailing: _saving ? const AppLoadingIndicator(size: 18) : const Icon(Icons.chevron_right),
    );
  }
}

class _PairingPicker extends StatefulWidget {
  const _PairingPicker({required this.others, required this.initial});

  final List<CatalogProduct> others;
  final List<String> initial;

  @override
  State<_PairingPicker> createState() => _PairingPickerState();
}

class _PairingPickerState extends State<_PairingPicker> {
  late List<String> _ids = [
    for (final id in widget.initial)
      if (widget.others.any((p) => p.id == id)) id,
  ];

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text('Goes well with (${_ids.length}/$kMaxPairings)'),
        content: SingleChildScrollView(
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final p in widget.others)
                FilterChip(
                  key: Key('pairing-${p.id}'),
                  label: Text(p.displayName),
                  selected: _ids.contains(p.id),
                  onSelected: !_ids.contains(p.id) && _ids.length >= kMaxPairings
                      ? null
                      : (on) => setState(() {
                            _ids = on ? [..._ids, p.id] : [..._ids.where((id) => id != p.id)];
                          }),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            key: const Key('pairing-save'),
            onPressed: () => Navigator.pop(context, _ids),
            child: const Text('Save'),
          ),
        ],
      );
}
