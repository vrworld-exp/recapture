// lib/domain/entities/catalog_subscription.dart
//
// The catalog's subscription, as the server describes it — hand-synced with
// `recapture-api/src/services/subscription/subscriptionService.ts`
// (`SubscriptionStatusDto`, `SubscriptionSummaryDto`) and the plan catalog in
// `src/models/types/subscription.types.ts`. No shared package (AGENTS.md
// §0.1), so every parser here is field-by-field and tolerant: a client one
// deploy behind renders, it does not crash.
//
// TWO NUMBERS THIS FILE DELIBERATELY DOES NOT COMPUTE:
//   • [CatalogSubscription.daysLeft] — the server's (D6). Two phones with two
//     clocks must read the same countdown, so the integer is rendered verbatim.
//   • [CatalogSubscription.threeDDishCount] — counted server-side over the
//     same list the publish gate counts (C1). The screen shows it; it never
//     recounts the draft.
import 'catalog_json.dart';

/// Where a subscription is in its life. Mirrors `SUBSCRIPTION_STATUSES` plus
/// the DTO's `'NONE'` (no row yet) and an [unknown] fallback for a status this
/// build has not heard of.
enum SubscriptionStatus {
  none,
  trial,
  active,
  grace,
  paused,
  cancelled,
  comped,
  unknown,
}

extension SubscriptionStatusX on SubscriptionStatus {
  String get apiValue => switch (this) {
        SubscriptionStatus.none => 'NONE',
        SubscriptionStatus.trial => 'TRIAL',
        SubscriptionStatus.active => 'ACTIVE',
        SubscriptionStatus.grace => 'GRACE',
        SubscriptionStatus.paused => 'PAUSED',
        SubscriptionStatus.cancelled => 'CANCELLED',
        SubscriptionStatus.comped => 'COMPED',
        SubscriptionStatus.unknown => 'UNKNOWN',
      };

  static SubscriptionStatus fromApiValue(String value) =>
      switch (value.toUpperCase()) {
        'NONE' => SubscriptionStatus.none,
        'TRIAL' => SubscriptionStatus.trial,
        'ACTIVE' => SubscriptionStatus.active,
        'GRACE' => SubscriptionStatus.grace,
        'PAUSED' => SubscriptionStatus.paused,
        'CANCELLED' => SubscriptionStatus.cancelled,
        'COMPED' => SubscriptionStatus.comped,
        _ => SubscriptionStatus.unknown,
      };

  /// Whether the status carries the right to publish 3D dishes — the
  /// server's `isEntitledTo3D`, mirrored for copy decisions only. The DTO's
  /// own flag is what a screen should read when it has one.
  bool get isEntitled =>
      this == SubscriptionStatus.trial ||
      this == SubscriptionStatus.active ||
      this == SubscriptionStatus.grace ||
      this == SubscriptionStatus.comped;
}

/// The three plans (`PLAN_IDS`). [unknown] for a plan this build has not
/// heard of — the row still renders, with the server's display name.
enum PlanId { taste, signature, masterchef, unknown }

extension PlanIdX on PlanId {
  String get apiValue => switch (this) {
        PlanId.taste => 'TASTE',
        PlanId.signature => 'SIGNATURE',
        PlanId.masterchef => 'MASTERCHEF',
        PlanId.unknown => 'UNKNOWN',
      };

  static PlanId fromApiValue(String value) => switch (value.toUpperCase()) {
        'TASTE' => PlanId.taste,
        'SIGNATURE' => PlanId.signature,
        'MASTERCHEF' => PlanId.masterchef,
        _ => PlanId.unknown,
      };

  static PlanId? fromApiValueOrNull(dynamic raw) =>
      raw is String && raw.isNotEmpty ? fromApiValue(raw) : null;

  /// The tier's name when only the id is at hand (a summary, not the DTO).
  /// Mirrors the bundled catalog's display names; a screen that HAS the
  /// server's `planName` should prefer it.
  String? get displayName => switch (this) {
        PlanId.taste => 'Taste plan',
        PlanId.signature => 'Signature plan',
        PlanId.masterchef => 'MasterChef plan',
        PlanId.unknown => null,
      };
}

enum BillingInterval { monthly, yearly, unknown }

extension BillingIntervalX on BillingInterval {
  String get apiValue => switch (this) {
        BillingInterval.monthly => 'MONTHLY',
        BillingInterval.yearly => 'YEARLY',
        BillingInterval.unknown => 'UNKNOWN',
      };

  static BillingInterval fromApiValue(String value) =>
      switch (value.toUpperCase()) {
        'MONTHLY' => BillingInterval.monthly,
        'YEARLY' => BillingInterval.yearly,
        _ => BillingInterval.unknown,
      };
}

/// One plan tier, as sold. Money is integer paise, exactly as the server
/// holds it; [yearlyPricePaise] is the server's formula (monthly × 12 ×
/// (100 − discount) / 100, rounded), and rounding to rupees is a DISPLAY
/// decision taken by the widget, never here.
class PlanDefinition {
  const PlanDefinition({
    required this.planId,
    required this.displayName,
    required this.priceMonthlyPaise,
    required this.yearlyDiscountPct,
    required this.threeDDishCap,
    required this.includedStandeeCount,
    this.features = const [],
  });

  final PlanId planId;
  final String displayName;
  final int priceMonthlyPaise;
  final int yearlyDiscountPct;
  final int threeDDishCap;
  final int includedStandeeCount;
  final List<String> features;

  int get yearlyPricePaise =>
      (priceMonthlyPaise * 12 * (100 - yearlyDiscountPct) / 100).round();

  factory PlanDefinition.fromMap(Map<String, dynamic> map) => PlanDefinition(
        planId: PlanIdX.fromApiValue((map['planId'] ?? '').toString()),
        displayName: catalogText(map['displayName']) ?? 'Plan',
        priceMonthlyPaise: catalogCount(map['priceMonthlyPaise']),
        yearlyDiscountPct: catalogCount(map['yearlyDiscountPct']),
        threeDDishCap: catalogCount(map['threeDDishCap']),
        includedStandeeCount: catalogCount(map['includedStandeeCount']),
        features: catalogStringList(map['features']),
      );

  Map<String, dynamic> toMap() => {
        'planId': planId.apiValue,
        'displayName': displayName,
        'priceMonthlyPaise': priceMonthlyPaise,
        'yearlyDiscountPct': yearlyDiscountPct,
        'threeDDishCap': threeDDishCap,
        'includedStandeeCount': includedStandeeCount,
        'features': features,
      };
}

/// The three plans plus the shared constants — `PlanCatalog` on the server.
///
/// [bundledDefault] mirrors the server's `DEFAULT_PLAN_CATALOG` so a client
/// talking to an older server (no `subscriptionPlans` anywhere) still draws
/// the comparison cards with the numbers that were decided.
class PlanCatalog {
  const PlanCatalog({
    required this.plans,
    required this.trialDays,
    required this.trialThreeDCap,
    required this.graceDays,
    required this.grandfatherDays,
    required this.orderTtlHours,
  });

  /// In tier order: Taste, Signature, MasterChef.
  final List<PlanDefinition> plans;
  final int trialDays;
  final int trialThreeDCap;
  final int graceDays;
  final int grandfatherDays;
  final int orderTtlHours;

  static const PlanCatalog bundledDefault = PlanCatalog(
    plans: [
      PlanDefinition(
        planId: PlanId.taste,
        displayName: 'Taste plan',
        priceMonthlyPaise: 119900,
        yearlyDiscountPct: 30,
        threeDDishCap: 10,
        includedStandeeCount: 10,
      ),
      PlanDefinition(
        planId: PlanId.signature,
        displayName: 'Signature plan',
        priceMonthlyPaise: 179900,
        yearlyDiscountPct: 30,
        threeDDishCap: 15,
        includedStandeeCount: 15,
        features: ['whatsapp_instagram_buttons'],
      ),
      PlanDefinition(
        planId: PlanId.masterchef,
        displayName: 'MasterChef plan',
        priceMonthlyPaise: 249900,
        yearlyDiscountPct: 30,
        threeDDishCap: 30,
        includedStandeeCount: 30,
        features: [
          'whatsapp_instagram_buttons',
          'website_embed',
          'per_dish_analytics',
          'priority_support',
        ],
      ),
    ],
    trialDays: 30,
    trialThreeDCap: 10,
    graceDays: 7,
    grandfatherDays: 30,
    orderTtlHours: 24,
  );

  PlanDefinition? byId(PlanId id) {
    for (final plan in plans) {
      if (plan.planId == id) return plan;
    }
    return null;
  }

  /// Parses the server's `{ plans: { TASTE: {...}, ... }, trialDays, ... }`.
  /// A missing or malformed block — an older server — falls back to
  /// [bundledDefault] whole, matching the server's own reject-to-defaults.
  static PlanCatalog fromMapOrDefault(dynamic raw) {
    if (raw is! Map) return bundledDefault;
    final map = raw.cast<String, dynamic>();
    final rawPlans = map['plans'];
    if (rawPlans is! Map) return bundledDefault;
    final plans = <PlanDefinition>[];
    for (final key in const ['TASTE', 'SIGNATURE', 'MASTERCHEF']) {
      final entry = rawPlans[key];
      if (entry is! Map) return bundledDefault;
      plans.add(PlanDefinition.fromMap(entry.cast<String, dynamic>()));
    }
    return PlanCatalog(
      plans: plans,
      trialDays: _intOr(map['trialDays'], bundledDefault.trialDays),
      trialThreeDCap:
          _intOr(map['trialThreeDCap'], bundledDefault.trialThreeDCap),
      graceDays: _intOr(map['graceDays'], bundledDefault.graceDays),
      grandfatherDays:
          _intOr(map['grandfatherDays'], bundledDefault.grandfatherDays),
      orderTtlHours: _intOr(map['orderTtlHours'], bundledDefault.orderTtlHours),
    );
  }

  Map<String, dynamic> toMap() => {
        'plans': {for (final plan in plans) plan.planId.apiValue: plan.toMap()},
        'trialDays': trialDays,
        'trialThreeDCap': trialThreeDCap,
        'graceDays': graceDays,
        'grandfatherDays': grandfatherDays,
        'orderTtlHours': orderTtlHours,
      };
}

int _intOr(dynamic raw, int fallback) =>
    raw is num && raw > 0 ? raw.toInt() : fallback;

/// The compact summary `GET /catalog` and the rep list carry — enough for a
/// chip, nothing that needed a second query.
class SubscriptionSummary {
  const SubscriptionSummary({
    required this.status,
    required this.daysLeft,
    required this.planId,
    required this.isEntitledTo3D,
    required this.trialAvailable,
    this.graceFrom,
  });

  final SubscriptionStatus status;

  /// The server's countdown, or null when nothing is counting down.
  final int? daysLeft;
  final PlanId? planId;
  final bool isEntitledTo3D;
  final bool trialAvailable;

  /// In [SubscriptionStatus.grace]: which state the row lapsed from (trial,
  /// active or comped), so a banner can say "trial ended" to a restaurant
  /// that never paid (E16). Null outside grace and on an older server —
  /// both read as the "payment overdue" wording.
  final SubscriptionStatus? graceFrom;

  factory SubscriptionSummary.fromMap(Map<String, dynamic> map) =>
      SubscriptionSummary(
        status:
            SubscriptionStatusX.fromApiValue((map['status'] ?? '').toString()),
        daysLeft:
            map['daysLeft'] is num ? (map['daysLeft'] as num).toInt() : null,
        planId: PlanIdX.fromApiValueOrNull(map['planId']),
        isEntitledTo3D: map['isEntitledTo3D'] == true,
        trialAvailable: map['trialAvailable'] == true,
        graceFrom: _graceFromOrNull(map['graceFrom']),
      );

  /// Null in, null out — the catalog DTO carries `subscription: null` for a
  /// catalog with no row, and that is a real answer ("No plan"), not a gap.
  static SubscriptionSummary? fromMapOrNull(dynamic raw) =>
      raw is Map<String, dynamic> ? SubscriptionSummary.fromMap(raw) : null;

  Map<String, dynamic> toMap() => {
        'status': status.apiValue,
        'daysLeft': daysLeft,
        'planId': planId?.apiValue,
        'graceFrom': graceFrom?.apiValue,
        'isEntitledTo3D': isEntitledTo3D,
        'trialAvailable': trialAvailable,
      };
}

/// `graceFrom` off the wire: a known status, or null for absent / unknown.
SubscriptionStatus? _graceFromOrNull(dynamic raw) {
  if (raw is! String || raw.isEmpty) return null;
  final status = SubscriptionStatusX.fromApiValue(raw);
  return status == SubscriptionStatus.unknown ? null : status;
}

/// The whole subscription screen — `SubscriptionStatusDto`.
class CatalogSubscription {
  const CatalogSubscription({
    required this.status,
    required this.planId,
    required this.planName,
    required this.billingInterval,
    required this.periodEnd,
    required this.graceEndsAt,
    required this.daysLeft,
    required this.threeDDishCount,
    required this.threeDDishCap,
    required this.imageDishCount,
    required this.trialAvailable,
    required this.isEntitledTo3D,
    required this.standeeIncluded,
    required this.standeeIssued,
    required this.plans,
    this.planSnapshot,
    this.nudgeNextAllowedAt,
    this.graceFrom,
    this.isReported = true,
  });

  final SubscriptionStatus status;
  final PlanId? planId;
  final String? planName;

  /// See [SubscriptionSummary.graceFrom].
  final SubscriptionStatus? graceFrom;

  /// REP SURFACE ONLY. When the next "Notify owner to pay" nudge on this
  /// restaurant is allowed (`nudge.nextAllowedAt` beside the DTO on
  /// `GET /rep/catalogs/:id/subscription`), or null when one is allowed now
  /// — which is also what the owner's own route, which has no nudge, reads
  /// as. Not part of `SubscriptionStatusDto`; carried here so the rep card
  /// has one state to watch.
  final DateTime? nudgeNextAllowedAt;

  /// The plan AS BOUGHT — the server's frozen copy the running period is
  /// under. Null on a trial, a comp, no row, or an older server. Compared to
  /// [plans] by [lockedPriceNotice]; never a source for the plan cards.
  final PlanDefinition? planSnapshot;
  final BillingInterval? billingInterval;
  final DateTime? periodEnd;
  final DateTime? graceEndsAt;

  /// SERVER-computed (D6). Rendered verbatim, never recomputed from
  /// [periodEnd].
  final int? daysLeft;
  final int threeDDishCount;

  /// Null = uncapped (a comp).
  final int? threeDDishCap;
  final int imageDishCount;
  final bool trialAvailable;
  final bool isEntitledTo3D;
  final int? standeeIncluded;
  final int? standeeIssued;
  final PlanCatalog plans;

  /// Whether the payload actually CARRIED a status — i.e. this is the
  /// server's subscription DTO and not an older server's empty body.
  ///
  /// THE ONE THING [status] ALONE CANNOT TELL YOU. `SubscriptionStatusDto`
  /// always sends a status, `'NONE'` included, so a body without one did not
  /// come from a deployment that knows about subscriptions at all — and both
  /// parse to [SubscriptionStatus.none]. "No row on a server that has rows"
  /// and "a server that has none" are different answers, and only the first
  /// is grounds for the client to refuse a publish
  /// ([evaluateSubscriptionGates]). Defaults to true for a hand-built
  /// instance; only [CatalogSubscription.fromMap] can set it false.
  final bool isReported;

  bool get hasRow => status != SubscriptionStatus.none;

  /// Over the cap right now — the state the publish gate would refuse.
  bool get isOverCap =>
      threeDDishCap != null && threeDDishCount > threeDDishCap!;

  /// The plan's CURRENT price when it differs from the one this period was
  /// bought at (B6) — the pair the renewal notice is built from, or null when
  /// there is nothing to say: no snapshot, an unknown plan, or the same price.
  ({int lockedPaise, int currentPaise})? get priceChange {
    final snapshot = planSnapshot;
    final id = planId;
    if (snapshot == null || id == null) return null;
    final current = plans.byId(id);
    if (current == null) return null;
    if (current.priceMonthlyPaise == snapshot.priceMonthlyPaise) return null;
    return (
      lockedPaise: snapshot.priceMonthlyPaise,
      currentPaise: current.priceMonthlyPaise,
    );
  }

  /// Whether the rep's nudge is on cooldown at [now].
  bool nudgeOnCooldownAt(DateTime now) {
    final at = nudgeNextAllowedAt;
    return at != null && at.isAfter(now);
  }

  /// The same row with the nudge cooldown replaced — what the card adopts
  /// after a send or a 429, without re-reading the whole subscription.
  CatalogSubscription withNudgeNextAllowedAt(DateTime? at) =>
      CatalogSubscription(
        status: status,
        planId: planId,
        planName: planName,
        billingInterval: billingInterval,
        periodEnd: periodEnd,
        graceEndsAt: graceEndsAt,
        daysLeft: daysLeft,
        threeDDishCount: threeDDishCount,
        threeDDishCap: threeDDishCap,
        imageDishCount: imageDishCount,
        trialAvailable: trialAvailable,
        isEntitledTo3D: isEntitledTo3D,
        standeeIncluded: standeeIncluded,
        standeeIssued: standeeIssued,
        plans: plans,
        planSnapshot: planSnapshot,
        nudgeNextAllowedAt: at,
        graceFrom: graceFrom,
        isReported: isReported,
      );

  /// The compact view of the same row, for a chip that has only this.
  SubscriptionSummary? get summary => hasRow
      ? SubscriptionSummary(
          status: status,
          daysLeft: daysLeft,
          planId: planId,
          isEntitledTo3D: isEntitledTo3D,
          trialAvailable: trialAvailable,
          graceFrom: graceFrom,
        )
      : null;

  /// Tolerant of every key being absent: an older server answering an empty
  /// object renders as "No subscription yet" with the bundled plans.
  ///
  /// [nudgeNextAllowedAt] is the rep route's sibling `nudge` block, parsed
  /// by the rep repository and handed in; the DTO itself never carries it.
  factory CatalogSubscription.fromMap(
    Map<String, dynamic> map, {
    DateTime? nudgeNextAllowedAt,
  }) {
    final allocation = map['standeeAllocation'];
    final cap = map['threeDDishCap'];
    return CatalogSubscription(
      status: map['status'] == null
          ? SubscriptionStatus.none
          : SubscriptionStatusX.fromApiValue(map['status'].toString()),
      planId: PlanIdX.fromApiValueOrNull(map['planId']),
      planName: catalogText(map['planName']),
      billingInterval: map['billingInterval'] is String
          ? BillingIntervalX.fromApiValue(map['billingInterval'] as String)
          : null,
      periodEnd: catalogDate(map['periodEnd']),
      graceEndsAt: catalogDate(map['graceEndsAt']),
      daysLeft:
          map['daysLeft'] is num ? (map['daysLeft'] as num).toInt() : null,
      threeDDishCount: catalogCount(map['threeDDishCount']),
      threeDDishCap: cap is num && cap >= 0 ? cap.toInt() : null,
      imageDishCount: catalogCount(map['imageDishCount']),
      trialAvailable: map['trialAvailable'] == true,
      isEntitledTo3D: map['isEntitledTo3D'] == true,
      standeeIncluded:
          allocation is Map ? catalogCount(allocation['included']) : null,
      standeeIssued:
          allocation is Map ? catalogCount(allocation['issued']) : null,
      plans: PlanCatalog.fromMapOrDefault(map['plans']),
      planSnapshot: map['planSnapshot'] is Map
          ? PlanDefinition.fromMap(
              (map['planSnapshot'] as Map).cast<String, dynamic>())
          : null,
      nudgeNextAllowedAt: nudgeNextAllowedAt,
      graceFrom: _graceFromOrNull(map['graceFrom']),
      isReported: map['status'] != null,
    );
  }
}
