// lib/domain/catalog/menu_entitlements.dart
//
// More-customization Stage 8 — which menu customizations the catalog's plan
// covers (recapture-api services/subscription/customizationEntitlements.ts),
// served by `GET /catalog/entitlements`. Hand-synced (AGENTS.md §0.1).
//
// Nothing here BLOCKS anything: the owner designs whatever they like and the
// publish sends the defaults for what the plan does not cover. These drive the
// lock chips ("Signature") and the "held back" list only.

/// Plan ids → the names the app shows.
const Map<String, String> kPlanLabels = {
  'TASTE': 'Taste',
  'SIGNATURE': 'Signature',
  'MASTERCHEF': 'MasterChef',
};

String planLabel(String? planId) => kPlanLabels[planId] ?? 'a higher';

class CustomizationEntitlements {
  const CustomizationEntitlements({
    this.customColors = true,
    this.layoutAndFonts = true,
    this.categorySchedules = true,
    this.maxBadges = 12,
    this.extraLanguages = 3,
    this.arBrandingAndSpotlight = true,
    this.allEngagement = true,
    this.brandedQr = true,
    this.customDomain = true,
    this.offers = true,
    this.plate = true,
  });

  final bool customColors;
  final bool layoutAndFonts;
  final bool categorySchedules;
  final int maxBadges;
  final int extraLanguages;
  final bool arBrandingAndSpotlight;

  /// False = only the "Rate us" link is covered.
  final bool allEngagement;
  final bool brandedQr;
  final bool customDomain;

  /// Stage 10 / 11 — Signature and above.
  final bool offers;
  final bool plate;

  /// Everything — flag off, a trial, a comp, or an older server.
  static const full = CustomizationEntitlements();

  factory CustomizationEntitlements.fromMap(Object? raw) {
    if (raw is! Map) return full;
    bool b(String k) => raw[k] != false;
    int n(String k, int d) => raw[k] is num ? (raw[k] as num).toInt() : d;
    return CustomizationEntitlements(
      customColors: b('customColors'),
      layoutAndFonts: b('layoutAndFonts'),
      categorySchedules: b('categorySchedules'),
      maxBadges: n('maxBadges', 12),
      extraLanguages: n('extraLanguages', 3),
      arBrandingAndSpotlight: b('arBrandingAndSpotlight'),
      allEngagement: raw['engagement'] != 'review',
      brandedQr: b('brandedQr'),
      customDomain: b('customDomain'),
      offers: b('offers'),
      plate: b('plate'),
    );
  }
}

/// Something the owner designed that the plan does not cover.
class HeldBackItem {
  const HeldBackItem({required this.feature, required this.requiredPlan, required this.message});

  final String feature;
  final String requiredPlan;
  final String message;

  static List<HeldBackItem> listFrom(Object? raw) => [
        if (raw is List)
          for (final r in raw)
            if (r is Map && r['message'] is String)
              HeldBackItem(
                feature: (r['feature'] ?? '').toString(),
                requiredPlan: (r['requiredPlan'] ?? '').toString(),
                message: r['message'] as String,
              ),
      ];
}

class MenuEntitlements {
  const MenuEntitlements({
    this.appearanceEnabled = false,
    this.enforced = false,
    this.planId,
    this.entitlements = CustomizationEntitlements.full,
    this.requiredPlan = const {},
    this.heldBack = const [],
  });

  /// Stage 8.3 rollout flag: show the customization entry points at all.
  final bool appearanceEnabled;

  /// False while the subscription gates are off (or on a trial / comp).
  final bool enforced;
  final String? planId;
  final CustomizationEntitlements entitlements;

  /// Feature → the lowest plan that covers it (for the chip label).
  final Map<String, String> requiredPlan;
  final List<HeldBackItem> heldBack;

  /// The chip to show on a control for [feature], or null when it is covered.
  String? lockFor(String feature, {required bool covered}) =>
      !enforced || covered ? null : planLabel(requiredPlan[feature]);

  factory MenuEntitlements.fromMap(Map<String, dynamic>? map) {
    final required = map?['requiredPlan'];
    return MenuEntitlements(
      appearanceEnabled: map?['appearanceEnabled'] == true,
      enforced: map?['enforced'] == true,
      planId: map?['planId'] is String ? map!['planId'] as String : null,
      entitlements: CustomizationEntitlements.fromMap(map?['entitlements']),
      requiredPlan: {
        if (required is Map)
          for (final e in required.entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
      },
      heldBack: HeldBackItem.listFrom(map?['heldBack']),
    );
  }
}
