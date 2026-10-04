// lib/presentation/widgets/catalog/customization_plan_gate.dart
//
// The route-level half of "customization is Signature and up" (2026-10-04).
// Hiding the entry points is not enough on web, where an owner can type
// /catalog/appearance or open an old bookmark — every owner customization
// route is wrapped in this, and a Taste catalog lands on an upsell instead.
//
// Waits for the catalog on a cold load (a web refresh straight onto the URL),
// so a Taste owner never sees the editor flash before the lock. A failed read
// opens the screen: a network blip must not lock a paying owner out.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_notifier.dart';
import '../../../data/repositories/menu_extras_repository.dart';
import '../app_button.dart';
import '../app_loading_indicator.dart';

class CustomizationPlanGate extends ConsumerWidget {
  const CustomizationPlanGate({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider);
    if (catalog.isLoading && !catalog.hasValue) {
      return const Scaffold(
        backgroundColor: AppColors.bgPrimary,
        body: AppLoadingIndicator(),
      );
    }
    if (ref.watch(customizationPlanAllowedProvider)) return child;

    final text = Theme.of(context).textTheme;
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
        title: Text(title),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 40, color: AppColors.textMuted),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Part of the Signature plan',
                  key: const Key('customization-plan-locked'),
                  style: text.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Make your menu your own: themes, colours, badges, languages, '
                  'offers and more. Available on the Signature and MasterChef plans.',
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppButton(
                  key: const Key('customization-see-plans'),
                  label: 'See plans',
                  onPressed: () => context.pushNamed(AppRouteNames.catalogSubscription),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
