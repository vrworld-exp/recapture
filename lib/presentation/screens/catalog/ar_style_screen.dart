// lib/presentation/screens/catalog/ar_style_screen.dart
//
// "3D & AR style" (more-customization Stage 7.1): how the menu's in-page 3D
// viewer carries the restaurant's brand — its logo as the loading ring, a small
// watermark, the dish's name + price, and a "stage" under the dish.
//
// Stated plainly on the screen: none of this can appear INSIDE the AR camera
// view — that is the phone's own app (Scene Viewer / Quick Look), which no
// website can draw on. And it appears only while 3D is on for the plan.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/menu_extras_repository.dart';
import '../../../domain/catalog/menu_extras.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/plan_lock_chip.dart';

class ArStyleScreen extends ConsumerWidget {
  const ArStyleScreen({super.key});

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
        title: Text('3D & AR style', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: profileAsync.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "We couldn't load your settings",
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
            : _ArStyleForm(
                key: ValueKey(profile.id),
                saved: profile.arBranding,
                hasLogo: profile.logoUrl != null,
              ),
      ),
    );
  }
}

class _ArStyleForm extends ConsumerStatefulWidget {
  const _ArStyleForm({super.key, required this.saved, required this.hasLogo});

  final ArBranding saved;
  final bool hasLogo;

  @override
  ConsumerState<_ArStyleForm> createState() => _ArStyleFormState();
}

class _ArStyleFormState extends ConsumerState<_ArStyleForm> {
  late ArBranding _value = widget.saved;
  late ArBranding _baseline = widget.saved;
  bool _saving = false;
  CatalogFailure? _error;

  Future<void> _save() async {
    final messenger = CatalogFeedback.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final profile = await ref.read(menuExtrasRepositoryProvider).updateArBranding(_value);
      await ref.read(businessProfileProvider.notifier).refresh();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _value = profile.arBranding;
        _baseline = profile.arBranding;
      });
      CatalogFeedback.confirm(messenger, 'Saved. Customers see it after your next publish.');
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
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: EntitlementLock(
                  feature: 'arBranding',
                  covered: (e) => e.arBrandingAndSpotlight,
                ),
              ),
              Text(
                'How the 3D view of a dish looks on your menu. The AR camera itself '
                "is your customer's phone app — nothing can be drawn inside it.",
                style: muted,
              ),
              if (!widget.hasLogo) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Add a logo on your business profile to use the logo options.',
                  style: text.bodySmall?.copyWith(color: AppColors.warning),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              SwitchListTile(
                key: const Key('ar-style-loader'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Logo while loading'),
                subtitle: Text('Your logo inside a ring in your menu colour.', style: muted),
                value: _value.logoLoader,
                onChanged: _saving || !widget.hasLogo
                    ? null
                    : (v) => setState(() => _value = _value.copyWith(logoLoader: v)),
              ),
              SwitchListTile(
                key: const Key('ar-style-watermark'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Logo watermark'),
                subtitle: Text('A small logo in the corner of the 3D view.', style: muted),
                value: _value.watermarkLogo,
                onChanged: _saving || !widget.hasLogo
                    ? null
                    : (v) => setState(() => _value = _value.copyWith(watermarkLogo: v)),
              ),
              SwitchListTile(
                key: const Key('ar-style-name'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Dish name & price'),
                subtitle: Text('Shown on the 3D view.', style: muted),
                value: _value.showDishName,
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _value = _value.copyWith(showDishName: v)),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Surface under the dish', style: text.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.md,
                children: [
                  for (final stage in ArStage.values)
                    _StageTile(
                      stage: stage,
                      selected: _value.stage == stage,
                      onTap: _saving ? null : () => setState(() => _value = _value.copyWith(stage: stage)),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  CatalogFeedback.failureText(_error!),
                  style: text.bodySmall?.copyWith(color: AppColors.warning),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                key: const Key('ar-style-save'),
                label: 'Save 3D & AR style',
                isLoading: _saving,
                onPressed: _value != _baseline && !_saving ? _save : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small swatch approximating each stage texture (mirage-fe public/stages/).
class _StageTile extends StatelessWidget {
  const _StageTile({required this.stage, required this.selected, required this.onTap});

  final ArStage stage;
  final bool selected;
  final VoidCallback? onTap;

  static const Map<ArStage, List<Color>> _colours = {
    ArStage.none: [Color(0xFF1E1E22), Color(0xFF1E1E22)],
    ArStage.plate: [Color(0xFFF4F1EC), Color(0xFFD8D2C8)],
    ArStage.wood: [Color(0xFF3B2A1E), Color(0xFF8A5A34)],
    ArStage.marble: [Color(0xFFFFFFFF), Color(0xFFD9DADD)],
    ArStage.dark: [Color(0xFF3A3A40), Color(0xFF0B0B0E)],
  };

  @override
  Widget build(BuildContext context) {
    final colours = _colours[stage]!;
    return InkWell(
      key: Key('ar-style-stage-${stage.apiValue}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        children: [
          Container(
            width: 84,
            height: 64,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: colours,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? AppColors.royalGold : AppColors.surface2,
                width: selected ? 2 : 1,
              ),
            ),
            child: stage == ArStage.none
                ? const Icon(Icons.block, color: AppColors.textMuted, size: 20)
                : stage == ArStage.plate
                    ? Center(
                        child: Container(
                          width: 56,
                          height: 18,
                          margin: const EdgeInsets.only(top: 24),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(40),
                          ),
                        ),
                      )
                    : null,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(stage.label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
