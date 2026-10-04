// lib/domain/catalog/customization_access.dart
//
// Whether the owner gets the menu-customization screens at all (decided
// 2026-10-04): Signature and MasterChef only. A Taste catalog does not see the
// entry points — the ⋮ items, the header palette and badge icons — and a typed
// URL lands on an upsell instead of the editor.
//
// Mirrors the server's `tierFor` (customizationEntitlements.ts) so the app and
// the publish-time "held back" list agree on who is covered:
//   • TRIAL, COMPED, PENDING_PAYMENT → full product (the trial is the pitch).
//   • ACTIVE / GRACE → by plan; a grace with no plan followed a trial and keeps
//     the trial's view.
//   • no row, NONE, PAUSED, CANCELLED → Taste → hidden.
//   • a status this build does not know → allowed. Fail-OPEN: a newer server
//     must never strip a paying owner's screens.
import '../entities/catalog_subscription.dart';

bool planAllowsCustomization(SubscriptionSummary? subscription) {
  if (subscription == null) return false;
  return switch (subscription.status) {
    SubscriptionStatus.trial ||
    SubscriptionStatus.comped ||
    SubscriptionStatus.pendingPayment ||
    SubscriptionStatus.unknown =>
      true,
    SubscriptionStatus.active || SubscriptionStatus.grace => switch (subscription.planId) {
        PlanId.taste => false,
        // signature, masterchef, an unknown newer tier, or a grace after a trial.
        _ => true,
      },
    SubscriptionStatus.none || SubscriptionStatus.paused || SubscriptionStatus.cancelled => false,
  };
}

/// The plans that include customization, for the Subscription screen's cards.
bool planIncludesCustomization(PlanId plan) => plan != PlanId.taste;
