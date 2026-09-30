// lib/presentation/screens/catalog/menu_languages_screen.dart
//
// "Menu languages" (more-customization Stage 6): the owner picks up to three
// extra languages. Customers then get a language switcher on the menu; every
// dish, section, badge and the announcement shows in the chosen language where
// the owner has translated it, and in the main language everywhere else.
//
// Switching a language OFF keeps its text — it simply stops being published,
// and comes back if the language is switched on again. Nothing reaches the
// menu until the next Publish.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/menu_translations_repository.dart';
import '../../../domain/catalog/menu_languages.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/plan_lock_chip.dart';

class MenuLanguagesScreen extends ConsumerWidget {
  const MenuLanguagesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(businessProfileProvider);
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
        title: Text('Menu languages', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: profileAsync.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "We couldn't load your languages",
          body: error is CatalogFailure
              ? CatalogFeedback.failureText(error)
              : CatalogFeedback.textForCode(null),
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(businessProfileProvider),
        ),
        data: (profile) => profile == null
            ? const CatalogMessage(
                icon: Icons.storefront_outlined,
                title: 'No catalog yet',
                body: 'Create your catalog first.',
              )
            : _LanguagePicker(key: ValueKey(profile.id), saved: profile.languages),
      ),
    );
  }
}

class _LanguagePicker extends ConsumerStatefulWidget {
  const _LanguagePicker({super.key, required this.saved});

  final MenuLanguages saved;

  @override
  ConsumerState<_LanguagePicker> createState() => _LanguagePickerState();
}

class _LanguagePickerState extends ConsumerState<_LanguagePicker> {
  late MenuLanguage _primary = widget.saved.primary;
  late List<MenuLanguage> _extra = [...widget.saved.extra];
  late MenuLanguages _baseline = widget.saved;
  bool _saving = false;
  CatalogFailure? _error;

  MenuLanguages get _value => MenuLanguages(primary: _primary, extra: _extra);
  bool get _dirty => _value != _baseline;

  void _toggle(MenuLanguage lang) => setState(() {
        if (_extra.contains(lang)) {
          _extra.remove(lang);
        } else if (_extra.length < kMaxExtraLanguages) {
          // Kept in the canonical order so the menu's switcher is stable.
          _extra = [for (final l in MenuLanguage.values) if (l == lang || _extra.contains(l)) l];
        }
      });

  Future<void> _save() async {
    final messenger = CatalogFeedback.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final profile = await ref.read(menuTranslationsRepositoryProvider).updateLanguages(_value);
      await ref.read(businessProfileProvider.notifier).refresh();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _primary = profile.languages.primary;
        _extra = [...profile.languages.extra];
        _baseline = profile.languages;
      });
      CatalogFeedback.confirm(
        messenger,
        profile.languages.hasExtra
            ? 'Languages saved. Add translations, then publish.'
            : 'Saved. Your menu is back to one language after your next publish.',
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
    final text = Theme.of(context).textTheme;
    final problem = _value.validate();
    final full = _extra.length >= kMaxExtraLanguages;
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
                'Customers get a language switcher on your menu. Anything you have '
                "not translated shows in your main language, so it's fine to start "
                'with a few dishes.',
                style: text.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text('Main language', style: text.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'The language your dish names and descriptions are written in.',
                style: text.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(height: AppSpacing.sm),
              DropdownButtonFormField<MenuLanguage>(
                key: const Key('languages-primary'),
                initialValue: _primary,
                dropdownColor: AppColors.surface1,
                items: [
                  for (final l in MenuLanguage.values)
                    DropdownMenuItem(value: l, child: Text(l.label)),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                          if (value == null) return;
                          _primary = value;
                          _extra.remove(value);
                        }),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text('Also offer (up to $kMaxExtraLanguages)', style: text.titleMedium),
              EntitlementLimitNote(
                text: (e) => e.entitlements.extraLanguages >= kMaxExtraLanguages
                    ? null
                    : e.entitlements.extraLanguages == 0
                        ? 'Your plan shows your menu in one language. Extra languages need Signature.'
                        : 'Your plan shows ${e.entitlements.extraLanguages} extra language on the menu; '
                            'more need MasterChef.',
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final l in MenuLanguage.values)
                    if (l != _primary)
                      FilterChip(
                        key: Key('languages-extra-${l.code}'),
                        label: Text(l.label),
                        selected: _extra.contains(l),
                        onSelected: _saving || (full && !_extra.contains(l)) ? null : (_) => _toggle(l),
                      ),
                ],
              ),
              if (widget.saved.extra.any((l) => !_extra.contains(l))) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  "Turning a language off keeps what you've translated — it just "
                  'stops showing on the menu.',
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ],
              if (problem != null || _error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  problem ?? CatalogFeedback.failureText(_error!),
                  style: text.bodySmall?.copyWith(color: AppColors.warning),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                key: const Key('languages-save'),
                label: 'Save languages',
                isLoading: _saving,
                onPressed: _dirty && problem == null && !_saving ? _save : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
