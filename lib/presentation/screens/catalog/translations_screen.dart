// lib/presentation/screens/catalog/translations_screen.dart
//
// "Translations" (more-customization Stage 6): everything customers read, per
// extra language — every dish, every section, the badge labels and the
// announcement — with how much is done ("Hindi · 60%") and a quick edit on
// each row. Untranslated rows sort first, so the work left is at the top.
//
// The owner types every word (Q3: no machine translation). Each save is its own
// small write that merges into that one language, and reaches the menu at the
// next Publish; anything left untranslated shows in the main language.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../application/catalog/menu_translations_provider.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/menu_translations_repository.dart';
import '../../../domain/catalog/menu_languages.dart';
import '../../../domain/entities/catalog_category.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/translation_dialogs.dart';

class TranslationsScreen extends ConsumerWidget {
  const TranslationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(menuTranslationsProvider);
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
        title: Text('Translations', style: Theme.of(context).textTheme.titleLarge),
        actions: [
          IconButton(
            key: const Key('translations-open-languages'),
            tooltip: 'Menu languages',
            icon: const Icon(Icons.tune),
            onPressed: () async {
              await context.pushNamed(AppRouteNames.catalogLanguages);
              ref.invalidate(menuTranslationsProvider);
            },
          ),
        ],
      ),
      body: dataAsync.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "We couldn't load your menu",
          body: error is CatalogFailure
              ? CatalogFeedback.failureText(error)
              : CatalogFeedback.textForCode(null),
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(menuTranslationsProvider),
        ),
        data: (data) {
          if (data == null) {
            return const CatalogMessage(
              icon: Icons.storefront_outlined,
              title: 'No catalog yet',
              body: 'Create your catalog first.',
            );
          }
          if (!data.profile.languages.hasExtra) {
            return CatalogMessage(
              icon: Icons.translate,
              title: 'Your menu is in one language',
              body: 'Pick up to $kMaxExtraLanguages more — Hindi, Marathi, Tamil and others — '
                  'and customers get a language switcher on your menu.',
              actionLabel: 'Choose languages',
              onAction: () async {
                await context.pushNamed(AppRouteNames.catalogLanguages);
                ref.invalidate(menuTranslationsProvider);
              },
            );
          }
          return _TranslationsBody(key: ValueKey(data.profile.id), data: data);
        },
      ),
    );
  }
}

class _TranslationsBody extends ConsumerStatefulWidget {
  const _TranslationsBody({super.key, required this.data});

  final MenuTranslationsData data;

  @override
  ConsumerState<_TranslationsBody> createState() => _TranslationsBodyState();
}

class _TranslationsBodyState extends ConsumerState<_TranslationsBody> {
  late MenuLanguage _lang = widget.data.profile.languages.extra.first;
  // Local copies, replaced row by row with what each save returns — the list
  // never refetches the whole catalog for one edited dish.
  late List<CatalogProduct> _products = [...widget.data.products];
  late List<CatalogCategory> _categories = [...widget.data.categories];
  late var _profile = widget.data.profile;
  bool _onlyMissing = false;
  String? _savingId;

  MenuLanguage get _primary => _profile.languages.primary;

  TranslationProgress _progressFor(MenuLanguage lang) =>
      TranslationProgress.of(_products.map((p) => p.i18n), lang);

  Future<void> _run(String id, Future<void> Function() write) async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _savingId = id);
    try {
      await write();
      if (!mounted) return;
      CatalogFeedback.confirm(messenger, 'Saved. Customers see it after your next publish.');
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      CatalogFeedback.failure(messenger, failure, subject: 'translation');
    } finally {
      if (mounted) setState(() => _savingId = null);
    }
  }

  Future<void> _editDish(CatalogProduct product) async {
    final result = await showDishTranslationDialog(context, product: product, lang: _lang, primary: _primary);
    if (result == null || !mounted) return;
    await _run(product.id, () async {
      final updated =
          await ref.read(menuTranslationsRepositoryProvider).updateDish(product.id, _lang, result);
      setState(() => _products = [for (final p in _products) p.id == updated.id ? updated : p]);
    });
  }

  Future<void> _editCategory(CatalogCategory category) async {
    final result =
        await showCategoryTranslationDialog(context, category: category, lang: _lang, primary: _primary);
    if (result == null || !mounted) return;
    await _run(category.id, () async {
      final updated =
          await ref.read(menuTranslationsRepositoryProvider).updateCategory(category.id, _lang, result);
      setState(() => _categories = [for (final c in _categories) c.id == updated.id ? updated : c]);
    });
  }

  Future<void> _editCatalogText() async {
    final result = await showCatalogTextDialog(
      context,
      lang: _lang,
      primary: _primary,
      announcement: _profile.announcement,
      badges: _profile.badges,
      current: _profile.i18n[_lang] ?? const CatalogLanguageText(),
    );
    if (result == null || !mounted) return;
    await _run('catalog', () async {
      final profile = await ref.read(menuTranslationsRepositoryProvider).updateCatalogText(_lang, result);
      await ref.read(businessProfileProvider.notifier).refresh();
      setState(() => _profile = profile);
    });
  }

  /// Untranslated first, then the catalog's own order (a stable sort).
  List<T> _ordered<T>(List<T> rows, bool Function(T) translated) {
    final missing = [for (final r in rows) if (!translated(r)) r];
    if (_onlyMissing) return missing;
    return [...missing, for (final r in rows) if (translated(r)) r];
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final progress = _progressFor(_lang);
    bool dishDone(CatalogProduct p) => (p.i18n[_lang]?.name ?? '').isNotEmpty;
    bool sectionDone(CatalogCategory c) => (c.i18n[_lang] ?? '').isNotEmpty;
    final dishes = _ordered(_products, dishDone);
    final sections = _ordered(_categories, sectionDone);
    final catalogText = _profile.i18n[_lang];
    final hasCatalogText = _profile.announcement != null || _profile.badges.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final lang in _profile.languages.extra)
              ChoiceChip(
                key: Key('translations-lang-${lang.code}'),
                label: Text('${lang.label} · ${_progressFor(lang).percent}%'),
                selected: _lang == lang,
                onSelected: (_) => setState(() => _lang = lang),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        LinearProgressIndicator(
          value: progress.total == 0 ? 1 : progress.translated / progress.total,
          backgroundColor: AppColors.surface2,
          color: progress.isComplete ? AppColors.success : AppColors.royalGold,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '${progress.translated} of ${progress.total} dishes have a ${_lang.englishName} name. '
          'The rest show in ${_primary.englishName}.',
          style: text.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        SwitchListTile(
          key: const Key('translations-only-missing'),
          contentPadding: EdgeInsets.zero,
          value: _onlyMissing,
          onChanged: (v) => setState(() => _onlyMissing = v),
          title: Text('Only show what still needs translating', style: text.bodyMedium),
        ),
        const SizedBox(height: AppSpacing.sm),
        _SectionHeader('Dishes'),
        if (dishes.isEmpty)
          _Empty(_products.isEmpty ? 'No dishes yet.' : 'Every dish has a ${_lang.englishName} name.'),
        for (final p in dishes)
          _Row(
            key: Key('translations-dish-${p.id}'),
            primary: p.displayName,
            translated: p.i18n[_lang]?.name,
            saving: _savingId == p.id,
            onTap: _savingId == null ? () => _editDish(p) : null,
          ),
        const SizedBox(height: AppSpacing.lg),
        _SectionHeader('Menu sections'),
        if (sections.isEmpty)
          _Empty(_categories.isEmpty ? 'No sections yet.' : 'Every section is translated.'),
        for (final c in sections)
          _Row(
            key: Key('translations-section-${c.id}'),
            primary: c.displayName,
            translated: c.i18n[_lang],
            saving: _savingId == c.id,
            onTap: _savingId == null ? () => _editCategory(c) : null,
          ),
        if (hasCatalogText) ...[
          const SizedBox(height: AppSpacing.lg),
          _SectionHeader('Announcement & badges'),
          _Row(
            key: const Key('translations-catalog-text'),
            primary: [
              if (_profile.announcement != null) 'Announcement',
              if (_profile.badges.isNotEmpty) '${_profile.badges.length} badges',
            ].join(' · '),
            translated: catalogText == null || catalogText.isEmpty
                ? null
                : [
                    if ((catalogText.announcement ?? '').isNotEmpty) catalogText.announcement!,
                    if (catalogText.badges.isNotEmpty) '${catalogText.badges.length} badge labels',
                  ].join(' · '),
            saving: _savingId == 'catalog',
            onTap: _savingId == null ? _editCatalogText : null,
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        Text(
          'Translations reach your menu when you publish.',
          style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.md),
        AppButton(
          label: 'Menu languages',
          onPressed: () async {
            await context.pushNamed(AppRouteNames.catalogLanguages);
            ref.invalidate(menuTranslationsProvider);
          },
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Text(
          message,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      );
}

/// One translatable thing: its primary text, and the translation or "Not translated".
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.primary,
    required this.translated,
    required this.saving,
    required this.onTap,
  });

  final String primary;
  final String? translated;
  final bool saving;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final done = (translated ?? '').isNotEmpty;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      title: Text(primary, style: text.bodyMedium),
      subtitle: Text(
        done ? translated! : 'Not translated',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodySmall?.copyWith(color: done ? AppColors.textSecondary : AppColors.warning),
      ),
      trailing: saving
          ? const AppLoadingIndicator(size: 18)
          : Icon(done ? Icons.edit_outlined : Icons.add, size: 18, color: AppColors.textSecondary),
    );
  }
}
