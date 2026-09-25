// lib/domain/entities/subscription_payment.dart
//
// The money side of the subscription, as the server describes it — hand-synced
// with `recapture-api/src/services/subscription/{checkoutService,
// paymentLedgerService, manualPaymentService, adminSubscriptionService}.ts`.
// No shared package (AGENTS.md §0.1), so every parser is field-by-field and
// tolerant: an unknown enum value renders as [unknown], never a crash.
//
// MONEY IS INTEGER PAISE, exactly as the wire carries it. [formatPaise] is the
// one place paise become a string, and it is a display decision — nothing here
// rounds, converts or adds anything up.
import 'admin_payment_attempt.dart';
import 'catalog_json.dart';
import 'catalog_subscription.dart';
import 'project_owner.dart';

/// "₹1,199" for whole rupees, "₹1,199.50" otherwise — the Stage 3 display
/// rule, on top of the Indian grouping `formatRupees` already does.
String formatPaise(int paise) {
  final rupees = paise ~/ 100;
  final rest = paise.remainder(100).abs();
  final whole = _groupIndian(rupees.abs());
  final sign = paise < 0 ? '-' : '';
  if (rest == 0) return '$sign₹$whole';
  return '$sign₹$whole.${rest.toString().padLeft(2, '0')}';
}

/// "1199" → 119900, "1,199.5" → 119950, "1199.999" → null (three decimals is
/// not money), "" / "0" / "abc" → null. The cash form's ONE parser: the rep
/// types rupees, the wire carries integer paise, and nothing in between may
/// round.
int? parseRupeesToPaise(String raw) {
  final text = raw.trim().replaceAll(',', '').replaceAll('₹', '');
  if (text.isEmpty) return null;
  final match = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(text);
  if (match == null) return null;
  final rupees = int.tryParse(match.group(1)!);
  if (rupees == null) return null;
  final fraction = match.group(2);
  final paise = fraction == null
      ? 0
      : int.parse(fraction.length == 1 ? '${fraction}0' : fraction);
  final total = rupees * 100 + paise;
  return total > 0 ? total : null;
}

String _groupIndian(int value) {
  final digits = value.toString();
  if (digits.length <= 3) return digits;
  final tail = digits.substring(digits.length - 3);
  var head = digits.substring(0, digits.length - 3);
  final groups = <String>[];
  while (head.length > 2) {
    groups.insert(0, head.substring(head.length - 2));
    head = head.substring(0, head.length - 2);
  }
  if (head.isNotEmpty) groups.insert(0, head);
  return '${groups.join(',')},$tail';
}

// ── Checkout ────────────────────────────────────────────────────────────────

/// What `POST /catalog/subscription/order` hands back: the ids the in-app SDK
/// needs and the frozen quote. NO URL — payment never leaves the app (AC-7.2).
class CheckoutOrder {
  const CheckoutOrder({
    required this.providerOrderId,
    required this.amountPaise,
    required this.currency,
    required this.keyId,
    required this.planId,
    required this.planName,
    required this.interval,
    required this.expiresAt,
    required this.currentPeriodEnd,
    required this.daysForfeited,
    required this.reused,
  });

  final String providerOrderId;
  final int amountPaise;
  final String currency;

  /// The PUBLIC half of the key pair. The SDK needs it; it is not a secret.
  final String keyId;
  final PlanId planId;
  final String planName;
  final BillingInterval interval;
  final DateTime? expiresAt;
  final DateTime? currentPeriodEnd;

  /// Days on the running period a payment now would throw away (E9).
  final int daysForfeited;

  /// The server handed back the open order rather than minting a new one.
  final bool reused;

  factory CheckoutOrder.fromMap(Map<String, dynamic> map,
      {bool reused = false}) {
    final quote = map['quote'] is Map
        ? (map['quote'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final snapshot = quote['planSnapshot'] is Map
        ? (quote['planSnapshot'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return CheckoutOrder(
      providerOrderId: catalogText(map['providerOrderId']) ?? '',
      amountPaise: catalogCount(map['amountPaise']),
      currency: catalogText(map['currency']) ?? 'INR',
      keyId: catalogText(map['keyId']) ?? '',
      planId: PlanIdX.fromApiValue((quote['planId'] ?? '').toString()),
      planName: catalogText(snapshot['displayName']) ?? 'Plan',
      interval:
          BillingIntervalX.fromApiValue((quote['interval'] ?? '').toString()),
      expiresAt: catalogDate(map['expiresAt']),
      currentPeriodEnd: catalogDate(map['currentPeriodEnd']),
      daysForfeited: catalogCount(map['daysForfeited']),
      reused: reused,
    );
  }

  /// "Signature plan · monthly" — the SDK's description line. No PII.
  String get description =>
      '$planName · ${interval == BillingInterval.yearly ? 'yearly' : 'monthly'}';
}

/// `POST /catalog/subscription/autopay` — an AUTOPAY mandate the checkout
/// sheet opens on (a Razorpay subscription, `sub_…`), hand-synced with
/// `AutopayCheckoutDto` in `recapture-api/src/services/subscription/
/// autopayService.ts`. Nothing is charged when it is minted; the sheet's
/// approval is what charges (now, or at [firstChargeAt]).
class AutopayCheckout {
  const AutopayCheckout({
    required this.providerSubscriptionId,
    required this.keyId,
    required this.amountPaise,
    required this.planId,
    required this.planName,
    required this.interval,
    required this.firstChargeAt,
    required this.expiresAt,
    required this.currentPeriodEnd,
    required this.daysForfeited,
    required this.reused,
  });

  final String providerSubscriptionId;

  /// The PUBLIC half of the key pair. The SDK needs it; it is not a secret.
  final String keyId;

  /// Each charge, in paise.
  final int amountPaise;
  final PlanId planId;
  final String planName;
  final BillingInterval interval;

  /// When the FIRST charge happens, when it is not at approval: the owner is
  /// inside a paid period of this plan, so autopay takes over at its end
  /// instead of charging twice for the same days. Null = charged on approval.
  final DateTime? firstChargeAt;
  final DateTime? expiresAt;
  final DateTime? currentPeriodEnd;

  /// Days of the running period a charge NOW forfeits (E9). 0 when deferred.
  final int daysForfeited;

  /// The server handed back the open mandate rather than minting a new one.
  final bool reused;

  /// Approval charges nothing today.
  bool get isDeferred => firstChargeAt != null;

  factory AutopayCheckout.fromMap(Map<String, dynamic> map,
      {bool reused = false}) {
    final quote = map['quote'] is Map
        ? (map['quote'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final snapshot = quote['planSnapshot'] is Map
        ? (quote['planSnapshot'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return AutopayCheckout(
      providerSubscriptionId: catalogText(map['providerSubscriptionId']) ?? '',
      keyId: catalogText(map['keyId']) ?? '',
      amountPaise: catalogCount(map['amountPaise']),
      planId: PlanIdX.fromApiValue((quote['planId'] ?? '').toString()),
      planName: catalogText(snapshot['displayName']) ?? 'Plan',
      interval:
          BillingIntervalX.fromApiValue((quote['interval'] ?? '').toString()),
      firstChargeAt: catalogDate(map['firstChargeAt']),
      expiresAt: catalogDate(map['expiresAt']),
      currentPeriodEnd: catalogDate(map['currentPeriodEnd']),
      daysForfeited: catalogCount(map['daysForfeited']),
      reused: reused,
    );
  }

  /// "Signature plan · monthly autopay" — the sheet's description. No PII.
  String get description =>
      '$planName · ${interval == BillingInterval.yearly ? 'yearly' : 'monthly'} autopay';
}

// ── The ledger ──────────────────────────────────────────────────────────────

/// `PAYMENT_KINDS` on the server.
enum PaymentKind {
  checkoutCreated,
  paid,
  manual,
  comp,
  refunded,
  disputed,
  unknown
}

extension PaymentKindX on PaymentKind {
  static PaymentKind fromApiValue(String value) =>
      switch (value.toUpperCase()) {
        'CHECKOUT_CREATED' => PaymentKind.checkoutCreated,
        'PAID' => PaymentKind.paid,
        'MANUAL' => PaymentKind.manual,
        'COMP' => PaymentKind.comp,
        'REFUNDED' => PaymentKind.refunded,
        'DISPUTED' => PaymentKind.disputed,
        _ => PaymentKind.unknown,
      };

  String get label => switch (this) {
        PaymentKind.checkoutCreated => 'Order',
        PaymentKind.paid => 'Paid online',
        PaymentKind.manual => 'Paid to rep',
        PaymentKind.comp => 'Complimentary',
        PaymentKind.refunded => 'Refund',
        PaymentKind.disputed => 'Disputed',
        PaymentKind.unknown => 'Payment',
      };
}

/// `MANUAL_METHODS` on the server — how cash reached the rep.
enum ManualMethod { cash, bankTransfer, cheque, upi }

extension ManualMethodX on ManualMethod {
  String get apiValue => switch (this) {
        ManualMethod.cash => 'CASH',
        ManualMethod.bankTransfer => 'BANK_TRANSFER',
        ManualMethod.cheque => 'CHEQUE',
        ManualMethod.upi => 'UPI',
      };

  String get label => switch (this) {
        ManualMethod.cash => 'Cash',
        ManualMethod.bankTransfer => 'Bank transfer',
        ManualMethod.cheque => 'Cheque',
        ManualMethod.upi => 'UPI',
      };

  static ManualMethod? fromApiValueOrNull(dynamic raw) => switch (raw) {
        'CASH' => ManualMethod.cash,
        'BANK_TRANSFER' => ManualMethod.bankTransfer,
        'CHEQUE' => ManualMethod.cheque,
        'UPI' => ManualMethod.upi,
        _ => null,
      };
}

/// `VERIFICATION_STATUSES` — the one thing on the ledger that transitions.
enum VerificationStatus { pending, verified, rejected, unknown }

extension VerificationStatusX on VerificationStatus {
  String get apiValue => switch (this) {
        VerificationStatus.pending => 'PENDING_VERIFICATION',
        VerificationStatus.verified => 'VERIFIED',
        VerificationStatus.rejected => 'REJECTED',
        VerificationStatus.unknown => 'UNKNOWN',
      };

  static VerificationStatus? fromApiValueOrNull(dynamic raw) => switch (raw) {
        'PENDING_VERIFICATION' => VerificationStatus.pending,
        'VERIFIED' => VerificationStatus.verified,
        'REJECTED' => VerificationStatus.rejected,
        String() => VerificationStatus.unknown,
        _ => null,
      };
}

/// One ledger row as the OWNER sees it (`OwnerPaymentDto`), and — with the
/// admin fields filled — as the admin sees it (`AdminPaymentDto`). One class:
/// the admin's row IS the owner's row plus columns, and a table that renders
/// both must not have to know which it was handed.
class PaymentRecordSummary {
  const PaymentRecordSummary({
    required this.id,
    required this.kind,
    required this.amountPaise,
    required this.currency,
    required this.createdAt,
    required this.method,
    required this.verificationStatus,
    required this.planId,
    required this.interval,
    required this.receiptNo,
    this.note,
    this.initiatedByRole,
    this.verifiedByRole,
    this.refundsPaymentId,
    this.isRefundable = false,
  });

  final String id;
  final PaymentKind kind;
  final int amountPaise;
  final String currency;
  final DateTime? createdAt;
  final ManualMethod? method;
  final VerificationStatus? verificationStatus;
  final PlanId? planId;
  final BillingInterval? interval;
  final String receiptNo;

  // Admin-only columns; null on the owner's read.
  final String? note;
  final String? initiatedByRole;
  final String? verifiedByRole;
  final String? refundsPaymentId;
  final bool isRefundable;

  /// The server's DUPLICATE_SUSPECTED flag — the one case a refund needs no
  /// override.
  bool get isSuspectedDuplicate => note == 'DUPLICATE_SUSPECTED';

  /// Whether the owner can download a receipt for this row — the server's
  /// eligibility, mirrored so the icon is only drawn where a tap would work:
  /// money taken (PAID, cash once VERIFIED) or access granted (COMP).
  bool get hasReceipt =>
      kind == PaymentKind.paid ||
      kind == PaymentKind.comp ||
      (kind == PaymentKind.manual &&
          verificationStatus == VerificationStatus.verified);

  /// "Cash" / "Online" / "Comp" / "Refund" — the method column.
  String get methodLabel => switch (kind) {
        PaymentKind.manual => method?.label ?? 'Manual',
        PaymentKind.paid || PaymentKind.checkoutCreated => 'Online',
        PaymentKind.comp => 'Comp',
        PaymentKind.refunded => 'Refund',
        PaymentKind.disputed => 'Dispute',
        PaymentKind.unknown => '—',
      };

  factory PaymentRecordSummary.fromMap(Map<String, dynamic> map) =>
      PaymentRecordSummary(
        id: catalogText(map['id']) ?? '',
        kind: PaymentKindX.fromApiValue((map['kind'] ?? '').toString()),
        amountPaise: catalogCount(map['amountPaise']),
        currency: catalogText(map['currency']) ?? 'INR',
        createdAt: catalogDate(map['createdAt']),
        method: ManualMethodX.fromApiValueOrNull(map['method']),
        verificationStatus:
            VerificationStatusX.fromApiValueOrNull(map['verificationStatus']),
        planId: PlanIdX.fromApiValueOrNull(map['planId']),
        interval: map['interval'] is String
            ? BillingIntervalX.fromApiValue(map['interval'] as String)
            : null,
        receiptNo: catalogText(map['receiptNo']) ?? '',
        note: catalogText(map['note']),
        initiatedByRole: map['initiatedBy'] is Map
            ? catalogText((map['initiatedBy'] as Map)['role'])
            : null,
        verifiedByRole: map['verifiedBy'] is Map
            ? catalogText((map['verifiedBy'] as Map)['role'])
            : null,
        refundsPaymentId: catalogText(map['refundsPaymentId']),
        isRefundable: map['isRefundable'] == true,
      );

  static List<PaymentRecordSummary> listFrom(dynamic raw) => raw is List
      ? [
          for (final item in raw)
            if (item is Map)
              PaymentRecordSummary.fromMap(item.cast<String, dynamic>()),
        ]
      : const [];
}

// ── Manual payments (Door 3) ────────────────────────────────────────────────

/// What a rep types into the cash form. [amountPaise] is already integer
/// paise: the form validates "two decimals at most" and multiplies by 100
/// BEFORE this exists, so nothing downstream can meet ₹1,199.999.
class ManualPaymentRequest {
  const ManualPaymentRequest({
    required this.planId,
    required this.interval,
    required this.amountPaise,
    required this.method,
    required this.reference,
    this.note,
  });

  final PlanId planId;
  final BillingInterval interval;
  final int amountPaise;
  final ManualMethod method;
  final String reference;
  final String? note;

  Map<String, dynamic> toBody() => {
        'planId': planId.apiValue,
        'interval': interval.apiValue,
        'amountPaise': amountPaise,
        'method': method.apiValue,
        'reference': reference,
        if (note != null && note!.trim().isNotEmpty) 'note': note!.trim(),
      };
}

/// `ManualPaymentDto` — a cash request as the rep and the admin read it.
class ManualPaymentRecord {
  const ManualPaymentRecord({
    required this.id,
    required this.catalogId,
    required this.catalogName,
    required this.planId,
    required this.interval,
    required this.quotedPaise,
    required this.amountPaise,
    required this.method,
    required this.reference,
    required this.note,
    required this.verificationStatus,
    required this.initiatedByRole,
    required this.verifiedAt,
    required this.createdAt,
    required this.receiptNo,
  });

  final String id;
  final String catalogId;

  /// De-slugged for display; empty on the rep's own read (they know where they are).
  final String catalogName;
  final PlanId planId;
  final BillingInterval interval;
  final int quotedPaise;
  final int amountPaise;
  final ManualMethod? method;
  final String reference;
  final String? note;
  final VerificationStatus verificationStatus;
  final String initiatedByRole;
  final DateTime? verifiedAt;
  final DateTime? createdAt;
  final String receiptNo;

  bool get amountMatchesQuote => amountPaise == quotedPaise;
  bool get isPending => verificationStatus == VerificationStatus.pending;

  factory ManualPaymentRecord.fromMap(Map<String, dynamic> map) =>
      ManualPaymentRecord(
        id: catalogText(map['id']) ?? '',
        catalogId: catalogText(map['catalogId']) ?? '',
        catalogName: catalogText(map['catalogName']) ?? '',
        planId: PlanIdX.fromApiValue((map['planId'] ?? '').toString()),
        interval:
            BillingIntervalX.fromApiValue((map['interval'] ?? '').toString()),
        quotedPaise: catalogCount(map['quotedPaise']),
        amountPaise: catalogCount(map['amountPaise']),
        method: ManualMethodX.fromApiValueOrNull(map['method']),
        reference: catalogText(map['reference']) ?? '',
        note: catalogText(map['note']),
        verificationStatus:
            VerificationStatusX.fromApiValueOrNull(map['verificationStatus']) ??
                VerificationStatus.unknown,
        initiatedByRole: map['initiatedBy'] is Map
            ? catalogText((map['initiatedBy'] as Map)['role']) ?? ''
            : '',
        verifiedAt: catalogDate(map['verifiedAt']),
        createdAt: catalogDate(map['createdAt']),
        receiptNo: catalogText(map['receiptNo']) ?? '',
      );

  static ManualPaymentRecord? fromMapOrNull(dynamic raw) => raw is Map
      ? ManualPaymentRecord.fromMap(raw.cast<String, dynamic>())
      : null;
}

/// What the rep's submit came back with: the record, and whether it was one
/// that already existed (the server's `existing: true`).
class ManualPaymentSubmission {
  const ManualPaymentSubmission({required this.record, required this.existing});

  final ManualPaymentRecord record;
  final bool existing;
}

// ── Admin ───────────────────────────────────────────────────────────────────

/// The collections list's filter — `ADMIN_SUBSCRIPTION_STATES` plus the
/// manual-payment queue, which the screen shows as its own tab.
/// `paused90d` (E23) is the follow-up list: paused 90+ days, oldest first.
/// `all` is every subscription row, most recently changed first.
enum AdminSubscriptionFilter {
  pending,
  all,
  expiring7d,
  grace,
  paused,
  paused90d,
  trial,
}

extension AdminSubscriptionFilterX on AdminSubscriptionFilter {
  /// The `?state=` value, or null for the queue (a different route).
  String? get stateApiValue => switch (this) {
        AdminSubscriptionFilter.pending => null,
        AdminSubscriptionFilter.all => 'ALL',
        AdminSubscriptionFilter.expiring7d => 'EXPIRING_7D',
        AdminSubscriptionFilter.grace => 'GRACE',
        AdminSubscriptionFilter.paused => 'PAUSED',
        AdminSubscriptionFilter.paused90d => 'PAUSED_90D',
        AdminSubscriptionFilter.trial => 'TRIAL',
      };

  String get label => switch (this) {
        AdminSubscriptionFilter.pending => 'Pending',
        AdminSubscriptionFilter.all => 'All',
        AdminSubscriptionFilter.expiring7d => 'Expiring 7d',
        AdminSubscriptionFilter.grace => 'In grace',
        AdminSubscriptionFilter.paused => 'Paused',
        AdminSubscriptionFilter.paused90d => 'Paused 90d+',
        AdminSubscriptionFilter.trial => 'Trial',
      };
}

/// One row of `GET /admin/subscriptions`.
class AdminSubscriptionListItem {
  const AdminSubscriptionListItem({
    required this.catalogId,
    required this.catalogName,
    required this.status,
    required this.periodEnd,
    required this.graceEndsAt,
    required this.daysLeft,
    required this.planId,
    this.photoCoverage,
    this.owner,
    this.billingInterval,
  });

  final String catalogId;
  final String catalogName;

  /// The restaurant's account — a name, never contact. Null on an older
  /// server or when the account is gone.
  final ProjectOwnerSummary? owner;
  final BillingInterval? billingInterval;
  final SubscriptionStatus status;
  final DateTime? periodEnd;
  final DateTime? graceEndsAt;
  final int? daysLeft;
  final PlanId? planId;

  /// E46: whole percent of live dishes with a card image; null when the menu
  /// has no live dish or the server predates the field. Under 100 on a
  /// PAUSED row, some customer cards are placeholders right now.
  final int? photoCoverage;

  factory AdminSubscriptionListItem.fromMap(Map<String, dynamic> map) =>
      AdminSubscriptionListItem(
        catalogId: catalogText(map['catalogId']) ?? '',
        catalogName: catalogText(map['catalogName']) ?? '',
        status:
            SubscriptionStatusX.fromApiValue((map['status'] ?? '').toString()),
        periodEnd: catalogDate(map['periodEnd']),
        graceEndsAt: catalogDate(map['graceEndsAt']),
        daysLeft:
            map['daysLeft'] is num ? (map['daysLeft'] as num).toInt() : null,
        planId: PlanIdX.fromApiValueOrNull(map['planId']),
        photoCoverage: map['photoCoverage'] is num
            ? (map['photoCoverage'] as num).toInt()
            : null,
        owner: ProjectOwnerSummary.tryFrom(map['owner']),
        billingInterval: map['billingInterval'] is String
            ? BillingIntervalX.fromApiValue(map['billingInterval'] as String)
            : null,
      );
}

/// A page of the collections list.
class AdminSubscriptionPage {
  const AdminSubscriptionPage({required this.items, required this.nextCursor});

  final List<AdminSubscriptionListItem> items;
  final String? nextCursor;
}

/// `GET /admin/catalogs/:id/subscription` — the per-catalog panel.
class AdminSubscriptionDetail {
  const AdminSubscriptionDetail({
    required this.catalogId,
    required this.catalogName,
    required this.catalogDeleted,
    required this.subscription,
    required this.payments,
    this.arEntitlementSyncedAt,
    this.owner,
    this.catalogInfo,
    this.attempts = const [],
  });

  final String catalogId;
  final String catalogName;
  final bool catalogDeleted;

  /// The restaurant's account, list-safe. The contact is one tap further
  /// (`showProjectOwnerSheet`, the audited `GET /admin/users/:id`).
  final ProjectOwnerSummary? owner;

  /// What the restaurant is, beyond its name; null on an older server.
  final AdminCatalogInfo? catalogInfo;

  /// Every online payment attempt on this catalog, newest first.
  final List<PaymentAttempt> attempts;

  /// Null when the catalog is gone — its ledger is still worth reading.
  final CatalogSubscription? subscription;
  final List<PaymentRecordSummary> payments;

  /// When Mirage was last told this restaurant's 3D entitlement (Stage 5,
  /// E18). Null = never, which for a restaurant that has never paused is the
  /// normal state — Mirage's default is entitled. Beside the DTO on the
  /// wire, not inside it, so the owner's DTO stays byte-equal everywhere.
  final DateTime? arEntitlementSyncedAt;

  factory AdminSubscriptionDetail.fromMap(Map<String, dynamic> map) {
    final catalog = map['catalog'] is Map
        ? (map['catalog'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return AdminSubscriptionDetail(
      catalogId: catalogText(catalog['id']) ?? '',
      catalogName: catalogText(catalog['name']) ?? '',
      catalogDeleted: catalog['deleted'] == true,
      subscription: map['subscription'] is Map
          ? CatalogSubscription.fromMap(
              (map['subscription'] as Map).cast<String, dynamic>())
          : null,
      payments: PaymentRecordSummary.listFrom(map['payments']),
      arEntitlementSyncedAt: catalogDate(map['arEntitlementSyncedAt']),
      owner: ProjectOwnerSummary.tryFrom(map['owner']),
      catalogInfo:
          catalog.containsKey('status') ? AdminCatalogInfo.fromMap(catalog) : null,
      attempts: PaymentAttempt.listFrom(map['attempts']),
    );
  }
}

/// The catalog facts the admin panel shows beside the subscription.
class AdminCatalogInfo {
  const AdminCatalogInfo({
    required this.businessName,
    required this.status,
    required this.publicUrl,
    required this.lastPublishedAt,
    required this.onMirage,
    required this.createdAt,
  });

  final String? businessName;

  /// `DRAFT` / `PUBLISHED` … as the server names it.
  final String? status;
  final String? publicUrl;
  final DateTime? lastPublishedAt;

  /// Whether the restaurant exists on Mirage (it has been provisioned).
  final bool onMirage;
  final DateTime? createdAt;

  factory AdminCatalogInfo.fromMap(Map<String, dynamic> map) => AdminCatalogInfo(
        businessName: catalogText(map['businessName']),
        status: catalogText(map['status']),
        publicUrl: catalogText(map['publicUrl']),
        lastPublishedAt: catalogDate(map['lastPublishedAt']),
        onMirage: map['onMirage'] == true,
        createdAt: catalogDate(map['createdAt']),
      );
}
