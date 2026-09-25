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

  /// A rep or staff member published this restaurant before anybody paid for
  /// it. Full access and a DEADLINE: at [CatalogSubscription.paymentDueAt] the
  /// customer page itself is switched off, not just 3D. The one status whose
  /// expiry takes a live link down — see [CatalogSubscription.isPageDeactivated].
  pendingPayment,
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
        SubscriptionStatus.pendingPayment => 'PENDING_PAYMENT',
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
        'PENDING_PAYMENT' => SubscriptionStatus.pendingPayment,
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
      // Entitled on purpose: the rep's publish leaves a WORKING standee on the
      // table, 3D included, before anybody pays. What limits it is the cap on
      // the row and the deadline, not this getter.
      this == SubscriptionStatus.pendingPayment ||
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
    this.pendingPaymentDays = 7,
    this.pendingPaymentThreeDCap = 10,
    this.testingPrices = false,
  });

  /// In tier order: Taste, Signature, MasterChef.
  final List<PlanDefinition> plans;
  final int trialDays;
  final int trialThreeDCap;
  final int graceDays;
  final int grandfatherDays;
  final int orderTtlHours;

  /// How long a rep/staff publish that nobody has paid for stays live, and how
  /// many 3D dishes it may carry. Server-resolved; a screen shows the number
  /// only to explain the window BEFORE one exists — once one does, the
  /// authority is [CatalogSubscription.paymentDueAt], never days × a day.
  final int pendingPaymentDays;
  final int pendingPaymentThreeDCap;

  /// TRUE when every price in [plans] is a TESTING price rather than the real
  /// tier (the server's `SUBSCRIPTION_TESTING_PRICES`).
  ///
  /// The screen must say so, visibly, wherever it shows a price. A ₹3 plan with
  /// nothing explaining it is how a tester talks a real restaurant into a price
  /// we cannot honour — and the restaurant would be right to expect it.
  ///
  /// Never inferred from a low price: an older server sends nothing here and
  /// reads as false, which is correct, because an older server has no testing
  /// mode to be in.
  final bool testingPrices;

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
      pendingPaymentDays: _intOr(
        map['pendingPaymentDays'],
        bundledDefault.pendingPaymentDays,
      ),
      pendingPaymentThreeDCap: _intOr(
        map['pendingPaymentThreeDCap'],
        bundledDefault.pendingPaymentThreeDCap,
      ),
      // Only an EXPLICIT true. An absent key is an older server, which has no
      // testing mode, so its real prices are real.
      testingPrices: map['testingPrices'] == true,
    );
  }

  Map<String, dynamic> toMap() => {
        'plans': {for (final plan in plans) plan.planId.apiValue: plan.toMap()},
        'trialDays': trialDays,
        'trialThreeDCap': trialThreeDCap,
        'graceDays': graceDays,
        'grandfatherDays': grandfatherDays,
        'orderTtlHours': orderTtlHours,
        'pendingPaymentDays': pendingPaymentDays,
        'pendingPaymentThreeDCap': pendingPaymentThreeDCap,
        'testingPrices': testingPrices,
      };
}

int _intOr(dynamic raw, int fallback) =>
    raw is num && raw > 0 ? raw.toInt() : fallback;

/// "A deadline is running and the page is still up", in ONE place, shared by
/// [SubscriptionSummary] and [CatalogSubscription].
///
/// The `!isPageDeactivated` half is the whole point: once the page is dark the
/// deadline is history, and the surface owes the owner the other sentence
/// ("your link is off") rather than a countdown to something that happened.
bool _hasPaymentDue(DateTime? paymentDueAt, bool isPageDeactivated) =>
    paymentDueAt != null && !isPageDeactivated;

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
    this.paymentDueAt,
    this.isPageDeactivated = false,
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

  /// When this restaurant's LIVE CUSTOMER PAGE is due to be switched off for
  /// non-payment, or null when nothing is due. The SERVER's instant (D6) —
  /// never a day count this client multiplies back out.
  final DateTime? paymentDueAt;

  /// True when the page is ALREADY dark: the window expired unpaid.
  ///
  /// Deliberately separate from "[paymentDueAt] is in the past". The sweep that
  /// takes a page down only runs while the worker is awake, so a deadline can
  /// sit in the past with the link still answering — and copy that called that
  /// link dead would be wrong in the direction that loses trust.
  final bool isPageDeactivated;

  /// See [CatalogSubscription.hasPaymentDue] — the same rule, because a chip
  /// and a card looking at one restaurant must not disagree about whether its
  /// link is at risk.
  bool get hasPaymentDue => _hasPaymentDue(paymentDueAt, isPageDeactivated);

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
        paymentDueAt: catalogDate(map['paymentDueAt']),
        isPageDeactivated: map['isPageDeactivated'] == true,
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
        'paymentDueAt': paymentDueAt?.toIso8601String(),
        'isPageDeactivated': isPageDeactivated,
      };
}

/// `graceFrom` off the wire: a known status, or null for absent / unknown.
SubscriptionStatus? _graceFromOrNull(dynamic raw) {
  if (raw is! String || raw.isEmpty) return null;
  final status = SubscriptionStatusX.fromApiValue(raw);
  return status == SubscriptionStatus.unknown ? null : status;
}

/// The whole subscription screen — `SubscriptionStatusDto`.
/// A Razorpay subscription's state (`AutopayMandate.status` on the server),
/// as far as the owner's screen cares. Only the states the DTO ever carries
/// are named; anything else is [unknown] and renders as "on".
enum AutopayStatus {
  /// Approved; the first charge is still to come (a deferred start).
  authenticated,

  /// Charging on schedule.
  active,

  /// The last renewal failed and Razorpay is retrying.
  pending,

  /// Razorpay gave up retrying. The owner must turn autopay on again.
  halted,
  unknown,
}

extension AutopayStatusX on AutopayStatus {
  static AutopayStatus fromApiValue(String value) =>
      switch (value.toUpperCase()) {
        'AUTHENTICATED' => AutopayStatus.authenticated,
        'ACTIVE' => AutopayStatus.active,
        'PENDING' => AutopayStatus.pending,
        'HALTED' => AutopayStatus.halted,
        _ => AutopayStatus.unknown,
      };

  String get apiValue => switch (this) {
        AutopayStatus.authenticated => 'AUTHENTICATED',
        AutopayStatus.active => 'ACTIVE',
        AutopayStatus.pending => 'PENDING',
        AutopayStatus.halted => 'HALTED',
        AutopayStatus.unknown => 'UNKNOWN',
      };

  /// Razorpay will charge again by itself (possibly after a retry).
  bool get willCharge => this != AutopayStatus.halted;
}

/// The owner's autopay — `SubscriptionStatusDto.autopay`. Null on the entity
/// means autopay is OFF (never set up, turned off, or ended), which is also
/// what an older server that has no autopay reads as.
class AutopayInfo {
  const AutopayInfo({
    required this.status,
    required this.planId,
    required this.planName,
    required this.interval,
    required this.amountPaise,
    this.nextChargeAt,
  });

  final AutopayStatus status;
  final PlanId planId;
  final String planName;
  final BillingInterval interval;

  /// What each charge takes, in paise.
  final int amountPaise;

  /// Razorpay's next charge. Null when none is scheduled (HALTED).
  final DateTime? nextChargeAt;

  /// On and nothing is wrong — the state in which "Turn off" is offered and
  /// the pay buttons for THIS plan are not.
  bool get isHealthy =>
      status == AutopayStatus.authenticated ||
      status == AutopayStatus.active ||
      status == AutopayStatus.unknown;

  static AutopayInfo? fromMapOrNull(dynamic raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    final status = map['status'];
    if (status is! String || status.isEmpty) return null;
    return AutopayInfo(
      status: AutopayStatusX.fromApiValue(status),
      planId: PlanIdX.fromApiValue((map['planId'] ?? '').toString()),
      planName: catalogText(map['planName']) ?? 'Plan',
      interval: BillingIntervalX.fromApiValue((map['interval'] ?? '').toString()),
      amountPaise: catalogCount(map['amountPaise']),
      nextChargeAt: catalogDate(map['nextChargeAt']),
    );
  }
}

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
    this.paymentDueAt,
    this.isPageDeactivated = false,
    this.isReported = true,
    this.autopay,
  });

  final SubscriptionStatus status;
  final PlanId? planId;

  /// The owner's autopay, or null when it is off. Independent of [status]: a
  /// catalog can be ACTIVE with autopay off (a one-time or cash payment), or
  /// in GRACE with autopay [AutopayStatus.pending] (a renewal failing).
  final AutopayInfo? autopay;
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

  /// See [SubscriptionSummary.paymentDueAt].
  final DateTime? paymentDueAt;

  /// See [SubscriptionSummary.isPageDeactivated].
  final bool isPageDeactivated;

  /// Whether a deadline is running and the page is still up — the state the
  /// "pay or the link goes" banner and its Pay button exist for.
  bool get hasPaymentDue => _hasPaymentDue(paymentDueAt, isPageDeactivated);

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
        paymentDueAt: paymentDueAt,
        isPageDeactivated: isPageDeactivated,
        isReported: isReported,
        autopay: autopay,
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
          paymentDueAt: paymentDueAt,
          isPageDeactivated: isPageDeactivated,
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
      paymentDueAt: catalogDate(map['paymentDueAt']),
      isPageDeactivated: map['isPageDeactivated'] == true,
      isReported: map['status'] != null,
      autopay: AutopayInfo.fromMapOrNull(map['autopay']),
    );
  }
}
