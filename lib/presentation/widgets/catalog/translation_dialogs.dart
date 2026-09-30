// lib/presentation/widgets/catalog/translation_dialogs.dart
//
// The quick-edit dialogs for multi-language menus (more-customization Stage 6),
// shared by the Translations screen and the product editor.
//
// Each shows the primary text above the field it translates, so the owner is
// never translating from memory. Clearing every field and saving removes that
// language — the menu then shows the primary text, which is also what it shows
// for anything never translated.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/catalog/dish_details.dart';
import '../../../domain/catalog/menu_languages.dart';
import '../../../domain/catalog/menu_time.dart';
import '../../../domain/entities/catalog_category.dart';
import '../../../domain/entities/catalog_product.dart';

/// Bounds mirrored from catalogSchemas.ts — a translation fits where the
/// primary text does.
const int kMaxTranslatedDishName = 120;
const int kMaxTranslatedDescription = 2000;

/// The primary text, muted, above a field — "In English: paneer tikka".
class _Original extends StatelessWidget {
  const _Original({required this.primary, required this.text});

  final MenuLanguage primary;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final value = (text ?? '').trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Text(
        value.isEmpty ? 'Nothing in ${primary.englishName} yet' : 'In ${primary.englishName}: $value',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// A dish's name + description in [lang]. Pops the new translation, or null.
Future<DishTranslation?> showDishTranslationDialog(
  BuildContext context, {
  required CatalogProduct product,
  required MenuLanguage lang,
  required MenuLanguage primary,
}) =>
    showDialog<DishTranslation>(
      context: context,
      builder: (_) => _DishTranslationDialog(product: product, lang: lang, primary: primary),
    );

class _DishTranslationDialog extends StatefulWidget {
  const _DishTranslationDialog({required this.product, required this.lang, required this.primary});

  final CatalogProduct product;
  final MenuLanguage lang;
  final MenuLanguage primary;

  @override
  State<_DishTranslationDialog> createState() => _DishTranslationDialogState();
}

class _DishTranslationDialogState extends State<_DishTranslationDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.product.i18n[widget.lang]?.name ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.product.i18n[widget.lang]?.description ?? '');

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text('${widget.product.displayName} — ${widget.lang.nativeName}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Original(primary: widget.primary, text: widget.product.displayName),
              TextField(
                key: const Key('translation-dish-name'),
                controller: _name,
                maxLength: kMaxTranslatedDishName,
                decoration: InputDecoration(labelText: 'Name in ${widget.lang.englishName}'),
              ),
              const SizedBox(height: AppSpacing.sm),
              _Original(primary: widget.primary, text: widget.product.description),
              TextField(
                key: const Key('translation-dish-description'),
                controller: _description,
                maxLength: kMaxTranslatedDescription,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(labelText: 'Description in ${widget.lang.englishName}'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            key: const Key('translation-dish-save'),
            onPressed: () => Navigator.pop(
              context,
              DishTranslation(name: _name.text.trim(), description: _description.text.trim()),
            ),
            child: const Text('Save'),
          ),
        ],
      );
}

/// One line of text in [lang] — a section name. Pops the new text ('' = remove), or null.
Future<String?> showCategoryTranslationDialog(
  BuildContext context, {
  required CatalogCategory category,
  required MenuLanguage lang,
  required MenuLanguage primary,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _LineDialog(
        title: '${category.displayName} — ${lang.nativeName}',
        original: category.displayName,
        initial: category.i18n[lang] ?? '',
        label: 'Section name in ${lang.englishName}',
        maxLength: kMaxCategoryNameLength,
        primary: primary,
      ),
    );

class _LineDialog extends StatefulWidget {
  const _LineDialog({
    required this.title,
    required this.original,
    required this.initial,
    required this.label,
    required this.maxLength,
    required this.primary,
  });

  final String title;
  final String original;
  final String initial;
  final String label;
  final int maxLength;
  final MenuLanguage primary;

  @override
  State<_LineDialog> createState() => _LineDialogState();
}

class _LineDialogState extends State<_LineDialog> {
  late final TextEditingController _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Original(primary: widget.primary, text: widget.original),
            TextField(
              key: const Key('translation-line'),
              controller: _text,
              maxLength: widget.maxLength,
              decoration: InputDecoration(labelText: widget.label),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            key: const Key('translation-line-save'),
            onPressed: () => Navigator.pop(context, _text.text.trim()),
            child: const Text('Save'),
          ),
        ],
      );
}

/// The announcement and every badge label in [lang]. Pops the new text, or null.
///
/// Only CURRENT badges are offered, so saving also drops the label of a badge
/// deleted since — the next save cleans up after the badge manager.
Future<CatalogLanguageText?> showCatalogTextDialog(
  BuildContext context, {
  required MenuLanguage lang,
  required MenuLanguage primary,
  required CatalogAnnouncement? announcement,
  required List<CatalogBadge> badges,
  required CatalogLanguageText current,
}) =>
    showDialog<CatalogLanguageText>(
      context: context,
      builder: (_) => _CatalogTextDialog(
        lang: lang,
        primary: primary,
        announcement: announcement,
        badges: [for (final b in badges) if (b.id != null) b],
        current: current,
      ),
    );

class _CatalogTextDialog extends StatefulWidget {
  const _CatalogTextDialog({
    required this.lang,
    required this.primary,
    required this.announcement,
    required this.badges,
    required this.current,
  });

  final MenuLanguage lang;
  final MenuLanguage primary;
  final CatalogAnnouncement? announcement;
  final List<CatalogBadge> badges;
  final CatalogLanguageText current;

  @override
  State<_CatalogTextDialog> createState() => _CatalogTextDialogState();
}

class _CatalogTextDialogState extends State<_CatalogTextDialog> {
  late final TextEditingController _announcement =
      TextEditingController(text: widget.current.announcement ?? '');
  late final Map<String, TextEditingController> _labels = {
    for (final b in widget.badges) b.id!: TextEditingController(text: widget.current.badges[b.id] ?? ''),
  };

  @override
  void dispose() {
    _announcement.dispose();
    for (final c in _labels.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: Text('Announcement & badges — ${widget.lang.nativeName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.announcement != null) ...[
              _Original(primary: widget.primary, text: widget.announcement!.text),
              TextField(
                key: const Key('translation-announcement'),
                controller: _announcement,
                maxLength: kMaxAnnouncementLength,
                decoration: InputDecoration(labelText: 'Announcement in ${widget.lang.englishName}'),
              ),
            ],
            if (widget.badges.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text('Badges', style: text.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              for (final b in widget.badges)
                TextField(
                  key: Key('translation-badge-${b.id}'),
                  controller: _labels[b.id],
                  maxLength: kMaxBadgeLabel,
                  decoration: InputDecoration(labelText: b.label),
                ),
            ],
            if (widget.announcement == null && widget.badges.isEmpty)
              Text(
                'You have no announcement or badges yet — there is nothing here to translate.',
                style: text.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          key: const Key('translation-catalog-save'),
          onPressed: () => Navigator.pop(
            context,
            CatalogLanguageText(
              // An announcement that no longer exists keeps no translation.
              announcement: widget.announcement == null ? null : _announcement.text.trim(),
              badges: {for (final e in _labels.entries) e.key: e.value.text.trim()},
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
