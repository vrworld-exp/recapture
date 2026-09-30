// lib/presentation/widgets/catalog/plan_lock_chip.dart
//
// The lock + plan chip on a customization the owner's plan does not cover
// (more-customization Stage 8.1). It does NOT disable the control — the owner
// may design anything; the publish holds it back — it says so, and a tap opens
// the subscription screen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../data/repositories/menu_extras_repository.dart';
import '../../../domain/catalog/menu_entitlements.dart';

/// A [PlanLockChip] for [feature] when the owner's plan does not cover it;
/// nothing while the entitlements are loading, not enforced, or covered.
class EntitlementLock extends ConsumerWidget {
  const EntitlementLock({super.key, required this.feature, required this.covered});

  /// The server's feature key (`customColors`, `arBranding`, …).
  final String feature;
  final bool Function(CustomizationEntitlements e) covered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ents = ref.watch(catalogEntitlementsProvider).valueOrNull;
    final plan = ents?.lockFor(feature, covered: covered(ents.entitlements));
    return plan == null ? const SizedBox.shrink() : PlanLockChip(plan: plan);
  }
}

/// "Your plan shows 3 badges on the menu." — for the counted features.
class EntitlementLimitNote extends ConsumerWidget {
  const EntitlementLimitNote({super.key, required this.text});

  /// Built from the entitlements; return null when there is nothing to say.
  final String? Function(MenuEntitlements e) text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ents = ref.watch(catalogEntitlementsProvider).valueOrNull;
    final note = ents == null || !ents.enforced ? null : text(ents);
    if (note == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: InkWell(
        onTap: () => context.pushNamed(AppRouteNames.catalogSubscription),
        child: Row(
          children: [
            const Icon(Icons.lock_outline, size: 14, color: AppColors.royalGold),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                note,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.royalGold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlanLockChip extends StatelessWidget {
  const PlanLockChip({super.key, required this.plan});

  /// "Signature", "MasterChef".
  final String plan;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Needs the $plan plan to show on your menu. Tap to see plans.',
        child: ActionChip(
          key: Key('plan-lock-$plan'),
          visualDensity: VisualDensity.compact,
          avatar: const Icon(Icons.lock_outline, size: 14, color: AppColors.royalGold),
          label: Text(plan, style: const TextStyle(fontSize: 12, color: AppColors.royalGold)),
          side: BorderSide(color: AppColors.royalGold.withValues(alpha: 0.5)),
          backgroundColor: AppColors.surface1,
          onPressed: () => context.pushNamed(AppRouteNames.catalogSubscription),
        ),
      );
}
