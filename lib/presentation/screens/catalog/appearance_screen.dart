// lib/presentation/screens/catalog/appearance_screen.dart
//
// Catalog → Appearance (more-customization Stage 2): pick a preset look for the
// public Mirage menu, optionally a primary / accent colour, see it on a phone
// preview, save. It goes live on the next Publish (decision D6), like every
// other authoring edit.
//
// What it is careful about:
//   • It never lets an unreadable colour be saved. The same contrast rules the
//     API enforces and Mirage-fe re-checks run here first, and Save is disabled
//     with the reason shown while they fail. A colour one of them refuses would
//     be a colour the owner sees here and never on the menu.
//   • It never implies a save is live. The footer says Publish, and offers it.
//   • ONE SCREEN, TWO READERS — the owner's own catalog and a rep's delegated
//     one, told apart by a [CatalogScope] exactly as the business profile does.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/appearance_notifier.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../application/config/config_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/catalog_products_repository.dart';
import '../../../data/repositories/rep_repository.dart';
import '../../../domain/catalog/appearance.dart';
import '../../../domain/catalog/catalog_scope.dart';
import '../../../domain/catalog/color_contrast.dart';
import '../../../domain/catalog/menu_theme_presets.dart';
import '../../../domain/entities/business_profile.dart';
import '../../../utils/price_format.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/menu_theme_preview.dart';

/// Width at or above which the controls and the preview sit side by side.
const double kAppearanceTwoColumnWidth = 900;

/// The swatch row under each colour. Wide enough to suit dark and light
/// presets; a swatch the current preset cannot carry is drawn dimmed.
const List<String> kAppearanceSwatches = [
  '#E10600', '#C62828', '#AD1457', '#6A1B9A', '#283593', '#1565C0', //
  '#00695C', '#2E7D32', '#8F5200', '#6D4C41', '#37474F', '#FFC400',
  '#FF7A45', '#E8C468', '#80DEEA', '#F48FB1',
];

/// Up to two real dishes for the preview. Best-effort: any failure (or an empty
/// catalog) falls back to the preview's placeholder dishes.
final appearanceSampleDishesProvider = FutureProvider.autoDispose
    .family<List<PreviewDish>, CatalogScope>((ref, scope) async {
  try {
    final catalogId = scope.delegatedCatalogId;
    final products = catalogId == null
        ? (await ref.read(catalogProductsRepositoryProvider).list(limit: 2)).items
        : (await ref.read(repRepositoryProvider).products(catalogId)).take(2).toList();
    return [
      for (final p in products)
        PreviewDish(
          name: p.displayName,
          price: formatPrice(p.price, p.currency),
          imageUrl: p.thumbnailUrl,
          featured: p.featured,
        ),
    ];
  } catch (_) {
    return const [];
  }
});

class AppearanceScreen extends ConsumerWidget {
  /// The signed-in user's own catalog — `/catalog/appearance`.
  const AppearanceScreen({super.key}) : catalogId = null;

  /// A restaurant's look, set by a rep holding a delegation on it.
  const AppearanceScreen.delegated({super.key, required String this.catalogId});

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
        title: Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: profileAsync.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "We couldn't load your menu's look",
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
                body: 'Create your catalog first — then choose how its menu looks.',
              )
            : _AppearanceBody(scope: scope, profile: profile),
      ),
    );
  }
}

class _AppearanceBody extends ConsumerWidget {
  const _AppearanceBody({required this.scope, required this.profile});

  final CatalogScope scope;
  final BusinessProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presets = ref.watch(captureConfigProvider.select((c) => c.themePresets));
    final state = ref.watch(appearanceFor(scope));
    final notifier = ref.read(appearanceFor(scope).notifier);
    final problem = appearanceContrastProblem(state.draft, presets);
    final colors = resolveMenuColors(state.draft, presets);
    final dishes = ref.watch(appearanceSampleDishesProvider(scope)).valueOrNull ?? const [];

    final preview = Center(
      child: MenuThemePreview(
        colors: colors,
        restaurantName: profile.displayName,
        logoUrl: profile.logoUrl,
        dishes: dishes,
      ),
    );

    final controls = _Controls(
      scope: scope,
      presets: presets,
      state: state,
      problem: problem,
      notifier: notifier,
    );

    return PopScope(
      // Leaving drops an unsaved try-out; say so rather than lose it silently.
      canPop: !state.isDirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmDiscard(context);
        if (leave && context.mounted) navigateBack(context);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoColumn = constraints.maxWidth >= kAppearanceTwoColumnWidth;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: twoColumn
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 3, child: controls),
                          const SizedBox(width: AppSpacing.xxxl),
                          Expanded(flex: 2, child: preview),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          preview,
                          const SizedBox(height: AppSpacing.xxl),
                          controls,
                        ],
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}

Future<bool> _confirmDiscard(BuildContext context) async {
  final discard = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Discard this look?'),
      content: const Text("You haven't saved it. Leaving now loses it."),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep editing'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Discard', style: TextStyle(color: AppColors.error)),
        ),
      ],
    ),
  );
  return discard == true;
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.scope,
    required this.presets,
    required this.state,
    required this.problem,
    required this.notifier,
  });

  final CatalogScope scope;
  final List<MenuThemePreset> presets;
  final AppearanceDraft state;
  final AppearanceContrastProblem? problem;
  final AppearanceNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final selected = MenuThemePreset.resolve(state.draft.presetId, presets);
    final canSave = state.isDirty && problem == null && !state.saving;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Label('Style'),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            for (final preset in presets)
              _PresetCard(
                preset: preset,
                selected: preset.id == selected.id,
                onTap: state.saving ? null : () => notifier.pickPreset(preset.id),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxl),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const Key('appearance-customize'),
            tilePadding: EdgeInsets.zero,
            initiallyExpanded: state.draft.primary != null || state.draft.accent != null,
            title: const Text('Customize colours'),
            subtitle: Text(
              'Optional — your brand colour for buttons and prices, and an accent.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
            children: [
              _ColourRow(
                label: 'Primary colour',
                fieldKey: 'primary',
                value: state.draft.primary,
                presetValue: selected.colors.primary,
                passes: (hex) =>
                    appearanceContrastProblem(
                      CatalogAppearance(presetId: selected.id, primary: hex),
                      presets,
                    ) ==
                    null,
                onChanged: state.saving ? null : notifier.setPrimary,
              ),
              const SizedBox(height: AppSpacing.lg),
              _ColourRow(
                label: 'Accent colour',
                fieldKey: 'accent',
                value: state.draft.accent,
                presetValue: selected.colors.accent,
                passes: (hex) =>
                    appearanceContrastProblem(
                      CatalogAppearance(presetId: selected.id, accent: hex),
                      presets,
                    ) ==
                    null,
                onChanged: state.saving ? null : notifier.setAccent,
              ),
            ],
          ),
        ),
        if (problem != null) ...[
          const SizedBox(height: AppSpacing.md),
          _Warning(
            key: const Key('appearance-contrast-warning'),
            text: '${problem!.explanation} Pick a darker or lighter shade, or use '
                "the style's own colour.",
          ),
        ],
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.md),
          _Warning(text: CatalogFeedback.failureText(state.error!)),
        ],
        const SizedBox(height: AppSpacing.xxl),
        AppButton(
          key: const Key('appearance-save'),
          label: 'Save look',
          isLoading: state.saving,
          onPressed: canSave
              ? () async {
                  final messenger = CatalogFeedback.of(context);
                  if (await notifier.save()) {
                    CatalogFeedback.confirm(
                      messenger,
                      'Look saved. It goes live the next time you publish.',
                    );
                  }
                }
              : null,
        ),
        const SizedBox(height: AppSpacing.md),
        AppButton.secondary(
          key: const Key('appearance-reset'),
          label: 'Reset to default',
          onPressed: state.saved == null || state.saving
              ? null
              : () async {
                  final messenger = CatalogFeedback.of(context);
                  if (await notifier.reset()) {
                    CatalogFeedback.confirm(
                      messenger,
                      'Back to the default look after your next publish.',
                    );
                  }
                },
        ),
        const SizedBox(height: AppSpacing.xxl),
        _PublishNote(scope: scope),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AppColors.textMuted,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
            ),
      );
}

/// One preset: a mini menu — page, a card, the primary button — and its name.
class _PresetCard extends StatelessWidget {
  const _PresetCard({required this.preset, required this.selected, this.onTap});

  final MenuThemePreset preset;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = preset.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: '${preset.label} style',
      child: InkWell(
        key: Key('appearance-preset-${preset.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          width: 132,
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppColors.surface1,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
              color: selected ? AppColors.mirageRed : AppColors.textMuted.withValues(alpha: 0.25),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 72,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: menuColor(c.bg),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      height: 8,
                      width: 40,
                      alignment: Alignment.centerLeft,
                      child: Container(width: 40, color: menuColor(c.text)),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: menuColor(c.surface),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        alignment: Alignment.bottomRight,
                        padding: const EdgeInsets.all(4),
                        child: Container(
                          width: 30,
                          height: 10,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [menuColor(c.ctaFrom), menuColor(c.ctaTo)],
                            ),
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      preset.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  if (selected)
                    const Icon(Icons.check_circle, size: 16, color: AppColors.mirageRed),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A colour: the swatch row, a hex field, and "use the style's colour".
class _ColourRow extends StatefulWidget {
  const _ColourRow({
    required this.label,
    required this.fieldKey,
    required this.value,
    required this.presetValue,
    required this.passes,
    required this.onChanged,
  });

  final String label;
  final String fieldKey;

  /// The override, or null when the preset's own colour is in use.
  final String? value;
  final String presetValue;
  final bool Function(String hex) passes;
  final ValueChanged<String?>? onChanged;

  @override
  State<_ColourRow> createState() => _ColourRowState();
}

class _ColourRowState extends State<_ColourRow> {
  late final TextEditingController _hex =
      TextEditingController(text: widget.value?.substring(1) ?? '');

  @override
  void didUpdateWidget(covariant _ColourRow old) {
    super.didUpdateWidget(old);
    // A swatch tap or a preset change moves the value; follow it unless the
    // field already says the same thing (never fight the user's typing).
    final next = widget.value?.substring(1) ?? '';
    if (next.toUpperCase() != _hex.text.toUpperCase()) _hex.text = next;
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.value ?? widget.presetValue;
    final onChanged = widget.onChanged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: menuColor(current),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.textMuted),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(widget.label)),
            if (widget.value != null)
              TextButton(
                onPressed: onChanged == null ? null : () => onChanged(null),
                child: const Text("Use style's colour"),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final hex in kAppearanceSwatches)
              _Swatch(
                hex: hex,
                selected: widget.value == hex,
                readable: widget.passes(hex),
                onTap: onChanged == null ? null : () => onChanged(hex),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          width: 160,
          child: TextField(
            key: Key('appearance-hex-${widget.fieldKey}'),
            controller: _hex,
            enabled: onChanged != null,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]'))],
            decoration: const InputDecoration(
              prefixText: '#',
              hintText: 'RRGGBB',
              counterText: '',
              isDense: true,
            ),
            onChanged: (text) {
              if (text.length == 6) onChanged?.call('#${text.toUpperCase()}');
              if (text.isEmpty) onChanged?.call(null);
            },
          ),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.hex,
    required this.selected,
    required this.readable,
    this.onTap,
  });

  final String hex;
  final bool selected;
  final bool readable;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: readable ? hex : '$hex — hard to read on this style',
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Opacity(
            opacity: readable ? 1 : 0.3,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: menuColor(hex),
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? AppColors.textPrimary : Colors.transparent,
                  width: 2,
                ),
              ),
              child: selected ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
            ),
          ),
        ),
      );
}

class _Warning extends StatelessWidget {
  const _Warning({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.contrast, size: 16, color: AppColors.warning),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textSecondary, height: 1.4),
              ),
            ),
          ],
        ),
      );
}

/// "Changes go live when you Publish." — and the way there.
class _PublishNote extends StatelessWidget {
  const _PublishNote({required this.scope});

  final CatalogScope scope;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Icon(Icons.info_outline, size: 16, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Changes go live when you publish.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            key: const Key('appearance-publish'),
            // Opens the publish screen WITHOUT starting a run: publishing is a
            // decision for that screen, not a side effect of a shortcut.
            onPressed: () {
              final catalogId = scope.delegatedCatalogId;
              if (catalogId == null) {
                context.pushNamed(AppRouteNames.catalogPublish);
              } else {
                context.push('${AppRoutes.repCatalogs}/$catalogId/publish');
              }
            },
            child: const Text('Go to Publish'),
          ),
        ],
      );
}
