// lib/domain/catalog/plan_benefits.dart
//
// Every benefit the app gives, as ✓ / ✗ rows for one plan — the Subscription
// screen's plan cards (2026-10-04). EVERY plan lists EVERY row, in the same
// order, so three cards side by side read as a comparison.
//
// Sources, so the card cannot promise what the app does not do:
//   • 3D cap, standees and the server feature keys come from the plan itself
//     (ops can change them through the plan catalog override).
//   • The customization rows follow [planIncludesCustomization] — the same rule
//     that hides those screens from a Taste owner.
//   • Languages and the web address mirror the server's default entitlements
//     (customizationEntitlements.ts: Signature 1 extra language, MasterChef 3;
//     custom address MasterChef only).
import '../entities/catalog_subscription.dart';
import 'customization_access.dart';

enum BenefitGroup { menu, look, growth }

extension BenefitGroupX on BenefitGroup {
  String get title => switch (this) {
        BenefitGroup.menu => 'Your menu',
        BenefitGroup.look => 'Make it yours',
        BenefitGroup.growth => 'Grow & support',
      };
}

class PlanBenefit {
  const PlanBenefit({
    required this.id,
    required this.group,
    required this.label,
    required this.included,
    String? compareLabel,
    this.value,
  }) : compareLabel = compareLabel ?? label;

  /// Stable — the widget picks the row's icon by it.
  final String id;
  final BenefitGroup group;
  /// This plan's wording ("Up to 10 3D/AR dishes").
  final String label;
  final bool included;

  /// The plan-neutral wording for the comparison table ("3D/AR dishes").
  final String compareLabel;

  /// A count for the table cell instead of a tick ("10"), when the row has one.
  final String? value;
}

/// The server feature keys, in the order the card lists them.
const _featureRows = <String, String>{
  'whatsapp_instagram_buttons': 'WhatsApp, Instagram & call-waiter buttons',
  'website_embed': 'AR menu on your own website',
  'per_dish_analytics': 'Per-dish view analytics',
  'priority_support': 'Priority call support',
};

/// A feature key's label — also used by the upgrade offer's sentence.
String planFeatureLabel(String key) => _featureRows[key] ?? key.replaceAll('_', ' ');

List<PlanBenefit> planBenefits(PlanDefinition plan) {
  final custom = planIncludesCustomization(plan.planId);
  final masterchef = plan.planId == PlanId.masterchef;
  final threeD = plan.threeDDishCap;
  final standees = plan.includedStandeeCount;

  PlanBenefit row(String id, BenefitGroup g, String label, bool on,
          {String? compare, String? value}) =>
      PlanBenefit(
        id: id,
        group: g,
        label: label,
        included: on,
        compareLabel: compare,
        value: on ? value : null,
      );

  return [
    row('threeD', BenefitGroup.menu,
        threeD > 0 ? 'Up to $threeD 3D/AR dishes' : '3D/AR dishes', threeD > 0,
        compare: '3D/AR dishes', value: '$threeD'),
    row('images', BenefitGroup.menu, 'Unlimited photo dishes', true),
    row('standees', BenefitGroup.menu,
        standees > 0 ? '$standees QR-code standee${standees == 1 ? '' : 's'} included' : 'QR-code standees included',
        standees > 0,
        compare: 'QR-code standees included', value: '$standees'),
    row('hours', BenefitGroup.menu, 'Opening hours & announcements', true),
    row('diet', BenefitGroup.menu, 'Veg, diet & allergen labels', true),
    row('themes', BenefitGroup.look, 'Themes, colours, layouts & fonts', custom),
    row('badges', BenefitGroup.look, 'Custom dish badges', custom),
    row('languages', BenefitGroup.look,
        !custom
            ? 'Menu in other languages'
            : masterchef
                ? 'Up to 3 extra menu languages'
                : '1 extra menu language',
        custom,
        compare: 'Extra menu languages', value: masterchef ? '3' : '1'),
    row('spotlight', BenefitGroup.look, 'Spotlight dishes & "Goes well with"', custom),
    row('arBranding', BenefitGroup.look, '3D & AR in your brand style', custom),
    row('brandedQr', BenefitGroup.look, 'Branded QR code with your logo', custom),
    row('offers', BenefitGroup.look, 'Offers, combos & happy hour', custom),
    row('plate', BenefitGroup.look, '"My plate" for your guests', custom),
    row('address', BenefitGroup.look, 'Your own menu web address', masterchef),
    for (final e in _featureRows.entries)
      row(e.key, BenefitGroup.growth, e.value, plan.features.contains(e.key)),
    // A feature key a newer server added — shown, never dropped.
    for (final key in plan.features)
      if (!_featureRows.containsKey(key)) row(key, BenefitGroup.growth, planFeatureLabel(key), true),
  ];
}

/// The rows the plan CARD shows; the rest are in the comparison.
const planCardHighlights = ['threeD', 'standees', 'themes', 'offers'];
