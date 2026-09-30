// lib/presentation/widgets/catalog/dish_translations_tile.dart
//
// "Other languages" in the product editor (more-customization Stage 6): one row
// per extra language the menu offers, each opening the same quick-edit dialog
// as the Translations screen.
//
// Saved on its OWN call the moment the dialog closes, not with the editor's
// Save — so it never makes the form dirty and never waits on a name change.
// Renders nothing on a menu with no extra languages.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/menu_translations_repository.dart';
import '../../../domain/catalog/menu_languages.dart';
import '../../../domain/entities/catalog_product.dart';
import '../app_loading_indicator.dart';
import 'catalog_feedback.dart';
import 'translation_dialogs.dart';

class DishTranslationsTile extends ConsumerStatefulWidget {
  const DishTranslationsTile({super.key, required this.product, this.enabled = true});

  final CatalogProduct product;
  final bool enabled;

  @override
  ConsumerState<DishTranslationsTile> createState() => _DishTranslationsTileState();
}

class _DishTranslationsTileState extends ConsumerState<DishTranslationsTile> {
  // What the last save returned; the editor's own copy of the product is not
  // refetched for a translation.
  late Map<MenuLanguage, DishTranslation> _i18n = widget.product.i18n;
  MenuLanguage? _saving;

  Future<void> _edit(MenuLanguage lang, MenuLanguage primary) async {
    final messenger = CatalogFeedback.of(context);
    final result = await showDishTranslationDialog(
      context,
      product: widget.product.copyWith(i18n: _i18n),
      lang: lang,
      primary: primary,
    );
    if (result == null || !mounted) return;
    setState(() => _saving = lang);
    try {
      final updated =
          await ref.read(menuTranslationsRepositoryProvider).updateDish(widget.product.id, lang, result);
      if (!mounted) return;
      setState(() => _i18n = updated.i18n);
      CatalogFeedback.confirm(messenger, 'Saved. Customers see it after your next publish.');
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      CatalogFeedback.failure(messenger, failure, subject: 'translation');
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final languages = ref.watch(
      businessProfileProvider.select((p) => p.valueOrNull?.languages ?? MenuLanguages.englishOnly),
    );
    if (!languages.hasExtra) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Other languages', style: text.titleMedium),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Saved as you go. Anything left empty shows in ${languages.primary.englishName}.',
          style: text.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        for (final lang in languages.extra)
          ListTile(
            key: Key('dish-translation-${lang.code}'),
            contentPadding: EdgeInsets.zero,
            enabled: widget.enabled && _saving == null,
            onTap: () => _edit(lang, languages.primary),
            title: Text(lang.label, style: text.bodyMedium),
            subtitle: Text(
              (_i18n[lang]?.name ?? '').isNotEmpty ? _i18n[lang]!.name! : 'Not translated',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(
                color: (_i18n[lang]?.name ?? '').isNotEmpty ? AppColors.textSecondary : AppColors.warning,
              ),
            ),
            trailing: _saving == lang
                ? const AppLoadingIndicator(size: 18)
                : const Icon(Icons.translate, size: 18, color: AppColors.textSecondary),
          ),
      ],
    );
  }
}
