// Customization is Signature and up (2026-10-04) — the rule every entry point
// and route gate reads.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/catalog/customization_access.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';

SubscriptionSummary _sub(SubscriptionStatus status, [PlanId? plan]) => SubscriptionSummary(
      status: status,
      daysLeft: null,
      planId: plan,
      isEntitledTo3D: true,
      trialAvailable: false,
    );

void main() {
  test('Taste, no plan, paused and cancelled are hidden', () {
    expect(planAllowsCustomization(null), isFalse);
    expect(planAllowsCustomization(_sub(SubscriptionStatus.none)), isFalse);
    expect(planAllowsCustomization(_sub(SubscriptionStatus.active, PlanId.taste)), isFalse);
    expect(planAllowsCustomization(_sub(SubscriptionStatus.grace, PlanId.taste)), isFalse);
    expect(planAllowsCustomization(_sub(SubscriptionStatus.paused, PlanId.signature)), isFalse);
    expect(planAllowsCustomization(_sub(SubscriptionStatus.cancelled, PlanId.masterchef)), isFalse);
  });

  test('Signature and MasterChef, active or in grace, are shown', () {
    for (final plan in [PlanId.signature, PlanId.masterchef]) {
      expect(planAllowsCustomization(_sub(SubscriptionStatus.active, plan)), isTrue);
      expect(planAllowsCustomization(_sub(SubscriptionStatus.grace, plan)), isTrue);
    }
  });

  test('trial, comp, pending payment, grace after a trial and unknown fail open', () {
    expect(planAllowsCustomization(_sub(SubscriptionStatus.trial)), isTrue);
    expect(planAllowsCustomization(_sub(SubscriptionStatus.comped)), isTrue);
    expect(planAllowsCustomization(_sub(SubscriptionStatus.pendingPayment)), isTrue);
    expect(planAllowsCustomization(_sub(SubscriptionStatus.grace)), isTrue);
    expect(planAllowsCustomization(_sub(SubscriptionStatus.unknown)), isTrue);
  });

  test('plan cards', () {
    expect(planIncludesCustomization(PlanId.taste), isFalse);
    expect(planIncludesCustomization(PlanId.signature), isTrue);
    expect(planIncludesCustomization(PlanId.masterchef), isTrue);
  });
}
