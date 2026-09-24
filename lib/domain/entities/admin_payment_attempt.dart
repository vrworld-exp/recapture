// lib/domain/entities/admin_payment_attempt.dart
//
// One entry of the admin PAYMENT JOURNAL — an online payment attempt (one
// Razorpay order) with every step it went through — hand-synced with
// `recapture-api/src/services/subscription/paymentJournalService.ts`
// (`PaymentAttemptDto`). No shared package (AGENTS.md §0.1), so the parser is
// field-by-field and tolerant: an unknown stage or step state renders as
// "unknown", never a crash.
//
// The server decides everything here — the stage, each step's state and its
// sentence, whether the two fixes are allowed. The client draws it. That is
// what keeps the web build, the apk and the backend suite telling ONE story
// about a payment.
//
// PII: [owner], [initiatedBy] and the resolver are names only. The raw contact
// is one tap further, through the audited `GET /admin/users/:id`.
import 'catalog_json.dart';
import 'catalog_subscription.dart';
import 'project_owner.dart';

/// `PaymentAttemptStage` on the server.
enum PaymentAttemptStage {
  inProgress,
  notCompleted,
  paidNotApplied,
  flagged,
  notReflected,
  completed,
  resolved,
  refunded,
  unknown,
}

extension PaymentAttemptStageX on PaymentAttemptStage {
  static PaymentAttemptStage fromApiValue(Object? raw) => switch (raw) {
        'IN_PROGRESS' => PaymentAttemptStage.inProgress,
        'NOT_COMPLETED' => PaymentAttemptStage.notCompleted,
        'PAID_NOT_APPLIED' => PaymentAttemptStage.paidNotApplied,
        'FLAGGED' => PaymentAttemptStage.flagged,
        'NOT_REFLECTED' => PaymentAttemptStage.notReflected,
        'COMPLETED' => PaymentAttemptStage.completed,
        'RESOLVED' => PaymentAttemptStage.resolved,
        'REFUNDED' => PaymentAttemptStage.refunded,
        _ => PaymentAttemptStage.unknown,
      };

  /// The chip on the tile — short enough for a phone row.
  String get label => switch (this) {
        PaymentAttemptStage.inProgress => 'In progress',
        PaymentAttemptStage.notCompleted => 'Not completed',
        PaymentAttemptStage.paidNotApplied => 'Paid, not applied',
        PaymentAttemptStage.flagged => 'Flagged',
        PaymentAttemptStage.notReflected => 'Not on catalog',
        PaymentAttemptStage.completed => 'Completed',
        PaymentAttemptStage.resolved => 'Fixed by admin',
        PaymentAttemptStage.refunded => 'Refunded',
        PaymentAttemptStage.unknown => 'Unknown',
      };

  /// One sentence under the chip on the detail screen.
  String get explanation => switch (this) {
        PaymentAttemptStage.inProgress =>
          'The order is open. The owner may still be paying.',
        PaymentAttemptStage.notCompleted =>
          'The order expired with no payment on our ledger.',
        PaymentAttemptStage.paidNotApplied =>
          'Razorpay took the money, but the plan was not applied yet.',
        PaymentAttemptStage.flagged =>
          'Razorpay took the money, and a safety rule held the plan back.',
        PaymentAttemptStage.notReflected =>
          'The plan was applied, but the catalog does not show it.',
        PaymentAttemptStage.completed =>
          'Paid, applied, and the catalog shows it.',
        PaymentAttemptStage.resolved =>
          'An admin applied this payment to the catalog by hand.',
        PaymentAttemptStage.refunded => 'This payment was refunded.',
        PaymentAttemptStage.unknown => 'This app does not know this state yet.',
      };
}

/// The server's filter on `GET /admin/subscriptions/payments`.
enum AdminPaymentFilter { attention, all, succeeded, notCompleted }

extension AdminPaymentFilterX on AdminPaymentFilter {
  String get apiValue => switch (this) {
        AdminPaymentFilter.attention => 'ATTENTION',
        AdminPaymentFilter.all => 'ALL',
        AdminPaymentFilter.succeeded => 'SUCCEEDED',
        AdminPaymentFilter.notCompleted => 'NOT_COMPLETED',
      };

  String get label => switch (this) {
        AdminPaymentFilter.attention => 'Needs attention',
        AdminPaymentFilter.all => 'All',
        AdminPaymentFilter.succeeded => 'Succeeded',
        AdminPaymentFilter.notCompleted => 'Not completed',
      };

  String get emptyBody => switch (this) {
        AdminPaymentFilter.attention =>
          'Every payment Razorpay took has reached its catalog.',
        AdminPaymentFilter.all => 'Nobody has started a payment yet.',
        AdminPaymentFilter.succeeded => 'No payment has been captured yet.',
        AdminPaymentFilter.notCompleted => 'Every order was paid.',
      };
}

enum JournalStepKey { started, provider, recorded, applied, catalog, unknown }

enum JournalStepState { done, waiting, failed, unknown, skipped }

/// One step of the pipeline.
class JournalStep {
  const JournalStep({
    required this.key,
    required this.state,
    required this.at,
    required this.detail,
  });

  final JournalStepKey key;
  final JournalStepState state;
  final DateTime? at;

  /// The server's sentence — ids and amounts only.
  final String detail;

  String get title => switch (key) {
        JournalStepKey.started => 'Payment started',
        JournalStepKey.provider => 'Razorpay received the money',
        JournalStepKey.recorded => 'Recorded on our ledger',
        JournalStepKey.applied => 'Plan applied',
        JournalStepKey.catalog => 'Catalog updated',
        JournalStepKey.unknown => 'Step',
      };

  factory JournalStep.fromMap(Map<String, dynamic> map) => JournalStep(
        key: switch (map['key']) {
          'STARTED' => JournalStepKey.started,
          'PROVIDER' => JournalStepKey.provider,
          'RECORDED' => JournalStepKey.recorded,
          'APPLIED' => JournalStepKey.applied,
          'CATALOG' => JournalStepKey.catalog,
          _ => JournalStepKey.unknown,
        },
        state: switch (map['state']) {
          'DONE' => JournalStepState.done,
          'WAITING' => JournalStepState.waiting,
          'FAILED' => JournalStepState.failed,
          'SKIPPED' => JournalStepState.skipped,
          _ => JournalStepState.unknown,
        },
        at: catalogDate(map['at']),
        detail: catalogText(map['detail']) ?? '',
      );
}

/// Who did something: a name when the account has one, and a role.
class JournalActor {
  const JournalActor({
    required this.userId,
    required this.role,
    required this.displayName,
  });

  final String userId;
  final String role;
  final String? displayName;

  /// "Asha Rao · USER", or the short id when there is no name.
  String get label {
    final name = displayName?.trim();
    final who = name == null || name.isEmpty
        ? '…${userId.length <= 6 ? userId : userId.substring(userId.length - 6)}'
        : name;
    return role.isEmpty ? who : '$who · ${_roleLabel(role)}';
  }

  /// As a summary the owner sheet can open.
  ProjectOwnerSummary get asOwnerSummary =>
      ProjectOwnerSummary(id: userId, displayName: displayName);

  static JournalActor? tryFrom(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['userId'];
    if (id is! String || id.isEmpty) return null;
    return JournalActor(
      userId: id,
      role: catalogText(raw['role']) ?? '',
      displayName: catalogText(raw['displayName']),
    );
  }
}

String _roleLabel(String role) => switch (role) {
      'USER' => 'owner',
      'SALES_REP' => 'sales rep',
      'MODEL_ARTIST' => 'staff',
      'ADMIN' => 'admin',
      _ => role.toLowerCase(),
    };

/// What Razorpay said about the order when an admin pressed "Check".
class ProviderSnapshot {
  const ProviderSnapshot({
    required this.orderStatus,
    required this.orderAmountPaise,
    required this.payments,
    required this.checkedAt,
  });

  final String orderStatus;
  final int orderAmountPaise;
  final List<({String id, String status, int amountPaise})> payments;
  final DateTime? checkedAt;

  static ProviderSnapshot? tryFrom(Object? raw) {
    if (raw is! Map) return null;
    final list = raw['payments'];
    return ProviderSnapshot(
      orderStatus: catalogText(raw['orderStatus']) ?? 'unknown',
      orderAmountPaise: catalogCount(raw['orderAmountPaise']),
      payments: list is List
          ? [
              for (final p in list)
                if (p is Map)
                  (
                    id: catalogText(p['id']) ?? '',
                    status: catalogText(p['status']) ?? '',
                    amountPaise: catalogCount(p['amountPaise']),
                  ),
            ]
          : const [],
      checkedAt: catalogDate(raw['checkedAt']),
    );
  }
}

/// The server's answer to "Check with Razorpay".
enum PaymentSyncOutcome { applied, flagged, alreadyDone, notPaid, notCaptured, unknown }

extension PaymentSyncOutcomeX on PaymentSyncOutcome {
  static PaymentSyncOutcome fromApiValue(Object? raw) => switch (raw) {
        'APPLIED' => PaymentSyncOutcome.applied,
        'FLAGGED' => PaymentSyncOutcome.flagged,
        'ALREADY_DONE' => PaymentSyncOutcome.alreadyDone,
        'NOT_PAID' => PaymentSyncOutcome.notPaid,
        'NOT_CAPTURED' => PaymentSyncOutcome.notCaptured,
        _ => PaymentSyncOutcome.unknown,
      };

  /// The toast after the check.
  String get sentence => switch (this) {
        PaymentSyncOutcome.applied =>
          'Razorpay confirmed the payment — the plan is applied.',
        PaymentSyncOutcome.flagged =>
          'Payment recorded, but a safety rule held the plan back. See the steps.',
        PaymentSyncOutcome.alreadyDone =>
          'Already recorded and applied — nothing to fix.',
        PaymentSyncOutcome.notPaid =>
          'Razorpay has no captured payment on this order.',
        PaymentSyncOutcome.notCaptured =>
          'Razorpay authorized a payment but never captured it. Nothing was applied.',
        PaymentSyncOutcome.unknown => 'Checked with Razorpay.',
      };
}

class PaymentSyncResult {
  const PaymentSyncResult({
    required this.outcome,
    required this.provider,
    required this.attempt,
    this.capturable,
  });

  final PaymentSyncOutcome outcome;
  final ProviderSnapshot? provider;
  final PaymentAttempt attempt;

  /// Edge case #6: the authorized payment "Capture payment" would take —
  /// only when its amount is exactly the order's.
  final ({String paymentId, int amountPaise})? capturable;

  static ({String paymentId, int amountPaise})? capturableFrom(Object? raw) {
    if (raw is! Map) return null;
    final id = catalogText(raw['paymentId']);
    if (id == null) return null;
    return (paymentId: id, amountPaise: catalogCount(raw['amountPaise']));
  }
}

/// `GET /admin/subscriptions/payments/lookup` — where a Razorpay id is.
sealed class PaymentLookupResult {
  const PaymentLookupResult();

  static PaymentLookupResult fromMap(Map<String, dynamic> map) {
    switch (map['outcome']) {
      case 'ON_LEDGER':
        return PaymentLookupOnLedger(catalogText(map['orderId']) ?? '');
      case 'CASH_ENTRY':
        return PaymentLookupCashEntry(
          catalogId: catalogText(map['catalogId']) ?? '',
          catalogName: catalogText(map['catalogName']) ?? '',
        );
      default:
        final provider = map['provider'] is Map
            ? (map['provider'] as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        final catalog = map['catalog'] is Map
            ? (map['catalog'] as Map).cast<String, dynamic>()
            : null;
        return PaymentLookupNotOnLedger(
          id: catalogText(provider['id']) ?? '',
          status: catalogText(provider['status']) ?? 'unknown',
          amountPaise: catalogCount(provider['amountPaise']),
          orderId: catalogText(provider['orderId']),
          catalogId: catalog == null ? null : catalogText(catalog['id']),
          catalogName: catalog == null ? null : catalogText(catalog['name']),
        );
    }
  }
}

/// The order is on our ledger — open its journal entry.
class PaymentLookupOnLedger extends PaymentLookupResult {
  const PaymentLookupOnLedger(this.orderId);
  final String orderId;
}

/// This Razorpay payment was recorded as a manual ("Start plan") entry.
class PaymentLookupCashEntry extends PaymentLookupResult {
  const PaymentLookupCashEntry({required this.catalogId, required this.catalogName});
  final String catalogId;
  final String catalogName;
}

/// Razorpay knows it; our ledger does not.
class PaymentLookupNotOnLedger extends PaymentLookupResult {
  const PaymentLookupNotOnLedger({
    required this.id,
    required this.status,
    required this.amountPaise,
    required this.orderId,
    required this.catalogId,
    required this.catalogName,
  });
  final String id;
  final String status;
  final int amountPaise;
  final String? orderId;

  /// The catalog the payment's notes name, when we have it.
  final String? catalogId;
  final String? catalogName;
}

/// One journal entry.
class PaymentAttempt {
  const PaymentAttempt({
    required this.orderId,
    required this.catalogId,
    required this.catalogName,
    required this.catalogDeleted,
    required this.owner,
    required this.initiatedBy,
    required this.planId,
    required this.planName,
    required this.interval,
    required this.quotedPaise,
    required this.paidPaise,
    required this.providerPaymentId,
    required this.startedAt,
    required this.expiresAt,
    required this.recordedVia,
    required this.appliedAt,
    required this.outcomeNote,
    required this.resolutionNote,
    required this.resolvedBy,
    required this.resolvedAt,
    required this.refunded,
    required this.subscriptionStatus,
    required this.subscriptionPeriodEnd,
    required this.stage,
    required this.needsAttention,
    required this.steps,
    required this.canSync,
    required this.canForceApply,
    this.paymentRecordId,
    this.priceChange,
    this.daysForfeitedOnApply = 0,
    this.canRefund = false,
    this.refundNeedsOverride = true,
  });

  final String orderId;

  /// The PAID ledger row — what Refund acts on.
  final String? paymentRecordId;

  /// Edge case #5: the order's price vs today's for the same plan; null when
  /// equal. When set, every fix asks the admin to accept the quoted price.
  final ({int quotedPaise, int currentPaise})? priceChange;

  /// Edge case #3: days on the running period that "Apply" would throw away.
  final int daysForfeitedOnApply;
  final bool canRefund;

  /// A refund needs the override and 30 characters (a flagged duplicate does not).
  final bool refundNeedsOverride;

  bool get isDuplicate => outcomeNote == 'DUPLICATE_SUSPECTED';
  final String catalogId;
  final String catalogName;
  final bool catalogDeleted;
  final ProjectOwnerSummary? owner;
  final JournalActor? initiatedBy;
  final PlanId? planId;
  final String? planName;
  final BillingInterval? interval;
  final int? quotedPaise;
  final int? paidPaise;
  final String? providerPaymentId;
  final DateTime? startedAt;
  final DateTime? expiresAt;
  final String? recordedVia;
  final DateTime? appliedAt;
  final String? outcomeNote;
  final String? resolutionNote;
  final JournalActor? resolvedBy;
  final DateTime? resolvedAt;
  final bool refunded;
  final SubscriptionStatus? subscriptionStatus;
  final DateTime? subscriptionPeriodEnd;
  final PaymentAttemptStage stage;
  final bool needsAttention;
  final List<JournalStep> steps;
  final bool canSync;
  final bool canForceApply;

  /// The amount to show: what was captured once there is one, else the quote.
  int get displayPaise => paidPaise ?? quotedPaise ?? 0;

  factory PaymentAttempt.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic> obj(Object? raw) =>
        raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
    final catalog = obj(map['catalog']);
    final resolution = map['resolution'] is Map ? obj(map['resolution']) : null;
    final subscription =
        map['subscription'] is Map ? obj(map['subscription']) : null;
    final rawSteps = map['steps'];
    return PaymentAttempt(
      orderId: catalogText(map['orderId']) ?? '',
      catalogId: catalogText(catalog['id']) ?? '',
      catalogName: catalogText(catalog['name']) ?? '',
      catalogDeleted: catalog['deleted'] == true,
      owner: ProjectOwnerSummary.tryFrom(map['owner']),
      initiatedBy: JournalActor.tryFrom(map['initiatedBy']),
      planId: PlanIdX.fromApiValueOrNull(map['planId']),
      planName: catalogText(map['planName']),
      interval: map['interval'] is String
          ? BillingIntervalX.fromApiValue(map['interval'] as String)
          : null,
      quotedPaise:
          map['quotedPaise'] is num ? (map['quotedPaise'] as num).toInt() : null,
      paidPaise:
          map['paidPaise'] is num ? (map['paidPaise'] as num).toInt() : null,
      providerPaymentId: catalogText(map['providerPaymentId']),
      startedAt: catalogDate(map['startedAt']),
      expiresAt: catalogDate(map['expiresAt']),
      recordedVia: catalogText(map['recordedVia']),
      appliedAt: catalogDate(map['appliedAt']),
      outcomeNote: catalogText(map['outcomeNote']),
      resolutionNote: resolution == null ? null : catalogText(resolution['note']),
      resolvedBy: resolution == null ? null : JournalActor.tryFrom(resolution['by']),
      resolvedAt: resolution == null ? null : catalogDate(resolution['at']),
      refunded: map['refunded'] == true,
      subscriptionStatus: subscription == null
          ? null
          : SubscriptionStatusX.fromApiValue(
              (subscription['status'] ?? '').toString()),
      subscriptionPeriodEnd:
          subscription == null ? null : catalogDate(subscription['periodEnd']),
      stage: PaymentAttemptStageX.fromApiValue(map['stage']),
      needsAttention: map['needsAttention'] == true,
      steps: rawSteps is List
          ? [
              for (final s in rawSteps)
                if (s is Map) JournalStep.fromMap(s.cast<String, dynamic>()),
            ]
          : const [],
      canSync: map['canSync'] == true,
      canForceApply: map['canForceApply'] == true,
      paymentRecordId: catalogText(map['paymentRecordId']),
      priceChange: map['priceChange'] is Map
          ? (
              quotedPaise: catalogCount((map['priceChange'] as Map)['quotedPaise']),
              currentPaise:
                  catalogCount((map['priceChange'] as Map)['currentPaise']),
            )
          : null,
      daysForfeitedOnApply: catalogCount(map['daysForfeitedOnApply']),
      canRefund: map['canRefund'] == true,
      // Absent on an older server: assume the stricter rule.
      refundNeedsOverride: map['refundNeedsOverride'] != false,
    );
  }

  static List<PaymentAttempt> listFrom(Object? raw) => raw is List
      ? [
          for (final item in raw)
            if (item is Map) PaymentAttempt.fromMap(item.cast<String, dynamic>()),
        ]
      : const [];
}

/// A page of the journal.
class PaymentAttemptPage {
  const PaymentAttemptPage({required this.items, required this.nextCursor});

  final List<PaymentAttempt> items;
  final String? nextCursor;
}
