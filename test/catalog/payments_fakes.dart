// test/catalog/payments_fakes.dart
//
// Scripted stand-ins for the Stage 3 seams: the payments repository and the
// checkout adapter. Shared by the checkout, cash-form and admin suites.
import 'dart:async';
import 'dart:typed_data';

import 'package:recapture/application/catalog/checkout_adapter.dart';
import 'package:recapture/application/catalog/qr_download_file.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/payments_repository.dart';
import 'package:recapture/domain/entities/admin_payment_attempt.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/domain/entities/subscription_payment.dart';

/// The order the server would mint for a Taste monthly.
Map<String, dynamic> orderPayload({
  String providerOrderId = 'order_test_1',
  int amountPaise = 119900,
  String planId = 'TASTE',
  String interval = 'MONTHLY',
  int daysForfeited = 0,
}) =>
    {
      'providerOrderId': providerOrderId,
      'amountPaise': amountPaise,
      'currency': 'INR',
      'keyId': 'rzp_test_vitest0000000',
      'quote': {
        'planId': planId,
        'interval': interval,
        'totalPaise': amountPaise,
        'planSnapshot': {
          'planId': planId,
          'displayName': 'Taste plan',
          'priceMonthlyPaise': 119900,
          'yearlyDiscountPct': 30,
          'threeDDishCap': 10,
          'includedStandeeCount': 10,
          'features': <String>[],
        },
      },
      'expiresAt': '2026-09-20T00:00:00.000Z',
      'currentPeriodEnd': null,
      'daysForfeited': daysForfeited,
    };

/// One owner-ledger row.
Map<String, dynamic> paymentRowPayload({
  String id = '66f0000000000000000000a1',
  String kind = 'PAID',
  int amountPaise = 119900,
  String? method,
  String? verificationStatus,
  String? note,
  bool isRefundable = false,
  String createdAt = '2026-09-18T10:00:00.000Z',
}) =>
    {
      'id': id,
      'kind': kind,
      'amountPaise': amountPaise,
      'currency': 'INR',
      'createdAt': createdAt,
      'method': method,
      'verificationStatus': verificationStatus,
      'planId': 'TASTE',
      'interval': 'MONTHLY',
      'receiptNo': 'RC-${id.substring(id.length - 8).toUpperCase()}',
      if (note != null) 'note': note,
      'isRefundable': isRefundable,
      'initiatedBy': {'userId': '66f00000000000000000000b', 'role': 'USER'},
    };

/// A pending cash request as the server describes it.
Map<String, dynamic> manualPaymentPayload({
  String id = '66f0000000000000000000c1',
  String catalogId = 'c1',
  String catalogName = 'blue cafe',
  int amountPaise = 119900,
  int quotedPaise = 119900,
  String status = 'PENDING_VERIFICATION',
  String method = 'CASH',
}) =>
    {
      'id': id,
      'catalogId': catalogId,
      'catalogName': catalogName,
      'planId': 'TASTE',
      'interval': 'MONTHLY',
      'quotedPaise': quotedPaise,
      'amountPaise': amountPaise,
      'amountMatchesQuote': amountPaise == quotedPaise,
      'method': method,
      'reference': 'receipt-0042',
      'note': null,
      'verificationStatus': status,
      'initiatedBy': {'userId': 'rep1', 'role': 'SALES_REP'},
      'collectedBy': {'userId': 'rep1', 'role': 'SALES_REP'},
      'verifiedBy': null,
      'verifiedAt': null,
      'createdAt': '2026-09-18T10:00:00.000Z',
      'receiptNo': 'RC-000000C1',
    };

/// Every method records its call and answers from a scripted slot; anything
/// not scripted throws so a test never passes on a silent default.
class FakePaymentsRepository implements PaymentsRepository {
  final List<String> calls = [];

  CheckoutOrder Function()? onCreateOrder;

  /// The verify answer, or null to answer with [verifyFailure] (or a
  /// NOT_SCRIPTED failure — the notifier treats any failure as best-effort).
  ({bool recorded, CatalogSubscription subscription}) Function()? onVerify;
  CatalogFailure? verifyFailure;

  /// When set, verify waits on it before answering — a verify still in
  /// flight while the screen goes away.
  Future<void>? verifyGate;
  List<PaymentRecordSummary> ownerLedger = const [];
  ManualPaymentRecord? pending;
  CatalogFailure? submitFailure;
  List<ManualPaymentRequest> submitted = [];
  List<ManualPaymentRecord> queue = const [];
  Map<AdminSubscriptionFilter, AdminSubscriptionPage> pages = const {};
  AdminSubscriptionDetail? detail;
  CatalogFailure? decideFailure;
  List<Map<String, Object?>> decisions = [];
  List<Map<String, Object?>> refunds = [];
  CatalogFailure? refundFailure;
  List<String> receiptsFetched = [];
  CatalogFailure? receiptFailure;
  List<Map<String, Object?>> standeesSet = [];
  CatalogFailure? standeesFailure;

  /// The journal, by filter; an unscripted filter answers an empty page.
  Map<AdminPaymentFilter, PaymentAttemptPage> attemptPages = const {};

  /// One attempt by order id — what the detail read answers.
  Map<String, PaymentAttempt> attempts = {};
  PaymentSyncResult Function(String orderId)? onSync;
  CatalogFailure? syncFailure;
  PaymentAttempt Function(String orderId, String note)? onForceApply;
  CatalogFailure? forceApplyFailure;
  List<Map<String, Object?>> plansStarted = [];
  CatalogFailure? startPlanFailure;
  CatalogFailure? startTrialFailure;

  @override
  Future<CheckoutOrder> createOrder({
    required PlanId planId,
    required BillingInterval interval,
  }) async {
    calls.add('createOrder:${planId.apiValue}:${interval.apiValue}');
    final make = onCreateOrder;
    if (make == null) throw UnimplementedError('createOrder not scripted');
    return make();
  }

  @override
  Future<({bool recorded, CatalogSubscription subscription})> verifyPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async {
    calls.add('verify:$orderId:$paymentId:$signature');
    final gate = verifyGate;
    if (gate != null) await gate;
    final make = onVerify;
    if (make != null) return make();
    throw verifyFailure ??
        const CatalogFailure(code: 'NOT_SCRIPTED', message: 'verify not scripted');
  }

  @override
  Future<List<PaymentRecordSummary>> ownerPayments() async {
    calls.add('ownerPayments');
    return ownerLedger;
  }

  @override
  Future<QrDownloadFile> receipt(String paymentId) async {
    calls.add('receipt:$paymentId');
    receiptsFetched.add(paymentId);
    final failure = receiptFailure;
    if (failure != null) throw failure;
    return QrDownloadFile(
      bytes: Uint8List.fromList('%PDF-1.4 fake'.codeUnits),
      fileName: 'receipt-RC-TEST.pdf',
      mimeType: 'application/pdf',
    );
  }

  @override
  Future<ManualPaymentRecord?> pendingManualPayment(String catalogId) async {
    calls.add('pending:$catalogId');
    return pending;
  }

  @override
  Future<ManualPaymentSubmission> submitManualPayment(
    String catalogId,
    ManualPaymentRequest request,
  ) async {
    calls.add('submit:$catalogId');
    submitted.add(request);
    final failure = submitFailure;
    if (failure != null) throw failure;
    final record = ManualPaymentRecord.fromMap(manualPaymentPayload(
      catalogId: catalogId,
      amountPaise: request.amountPaise,
      method: request.method.apiValue,
    ));
    pending = record;
    return ManualPaymentSubmission(record: record, existing: false);
  }

  @override
  Future<List<ManualPaymentRecord>> manualPaymentQueue({
    VerificationStatus status = VerificationStatus.pending,
  }) async {
    calls.add('queue:${status.apiValue}');
    return queue;
  }

  @override
  Future<AdminSubscriptionPage> subscriptions({
    required AdminSubscriptionFilter filter,
    String? cursor,
    String? query,
  }) async {
    calls.add('subscriptions:${filter.name}:${cursor ?? ''}'
        '${query == null || query.isEmpty ? '' : ':q=$query'}');
    return pages[filter] ??
        const AdminSubscriptionPage(items: [], nextCursor: null);
  }

  @override
  Future<PaymentAttemptPage> paymentAttempts({
    required AdminPaymentFilter filter,
    String? cursor,
  }) async {
    calls.add('attempts:${filter.name}:${cursor ?? ''}');
    return attemptPages[filter] ??
        const PaymentAttemptPage(items: [], nextCursor: null);
  }

  @override
  Future<PaymentAttempt> paymentAttempt(String orderId) async {
    calls.add('attempt:$orderId');
    final found = attempts[orderId];
    if (found == null) {
      throw const CatalogFailure(
        code: PaymentErrorCodes.paymentNotFound,
        message: 'not scripted',
        statusCode: 404,
      );
    }
    return found;
  }

  @override
  Future<PaymentSyncResult> syncPaymentAttempt(
    String orderId, {
    bool acceptQuotedPrice = false,
  }) async {
    calls.add('sync:$orderId${acceptQuotedPrice ? ':accept' : ''}');
    final failure = syncFailure;
    if (failure != null) throw failure;
    final make = onSync;
    if (make == null) throw UnimplementedError('sync not scripted');
    final result = make(orderId);
    attempts[orderId] = result.attempt;
    return result;
  }

  @override
  Future<PaymentAttempt> forceApplyPaymentAttempt(
    String orderId, {
    required String note,
    bool acceptQuotedPrice = false,
  }) async {
    calls.add('forceApply:$orderId${acceptQuotedPrice ? ':accept' : ''}');
    final failure = forceApplyFailure;
    if (failure != null) throw failure;
    final make = onForceApply;
    if (make == null) throw UnimplementedError('forceApply not scripted');
    final attempt = make(orderId, note);
    attempts[orderId] = attempt;
    return attempt;
  }

  PaymentAttempt Function(String orderId)? onCapture;
  PaymentLookupResult? lookupResult;
  CatalogFailure? lookupFailure;

  @override
  Future<PaymentAttempt> capturePaymentAttempt(
    String orderId, {
    bool acceptQuotedPrice = false,
  }) async {
    calls.add('capture:$orderId${acceptQuotedPrice ? ':accept' : ''}');
    final make = onCapture;
    if (make == null) throw UnimplementedError('capture not scripted');
    final attempt = make(orderId);
    attempts[orderId] = attempt;
    return attempt;
  }

  @override
  Future<PaymentLookupResult> lookupPayment(String id) async {
    calls.add('lookup:$id');
    final failure = lookupFailure;
    if (failure != null) throw failure;
    final result = lookupResult;
    if (result == null) throw UnimplementedError('lookup not scripted');
    return result;
  }

  @override
  Future<ManualPaymentRecord> startPlan(
    String catalogId,
    ManualPaymentRequest request, {
    bool override = false,
  }) async {
    calls.add('startPlan:$catalogId');
    plansStarted.add({
      'planId': request.planId.apiValue,
      'interval': request.interval.apiValue,
      'amountPaise': request.amountPaise,
      'method': request.method.apiValue,
      'reference': request.reference,
      'note': request.note,
      'override': override,
    });
    final failure = startPlanFailure;
    if (failure != null) throw failure;
    return ManualPaymentRecord.fromMap(manualPaymentPayload(
      catalogId: catalogId,
      amountPaise: request.amountPaise,
      status: 'VERIFIED',
      method: request.method.apiValue,
    ));
  }

  @override
  Future<CatalogSubscription> startTrial(String catalogId) async {
    calls.add('startTrial:$catalogId');
    final failure = startTrialFailure;
    if (failure != null) throw failure;
    return detail!.subscription!;
  }

  @override
  Future<AdminSubscriptionDetail> subscriptionDetail(String catalogId) async {
    calls.add('detail:$catalogId');
    final d = detail;
    if (d == null) throw UnimplementedError('detail not scripted');
    return d;
  }

  @override
  Future<ManualPaymentRecord> decideManualPayment(
    String catalogId, {
    required String paymentRecordId,
    required ManualPaymentDecision decision,
    String? note,
    bool override = false,
  }) async {
    calls.add('decide:${decision.name}');
    decisions.add({
      'paymentRecordId': paymentRecordId,
      'decision': decision.name,
      'note': note,
      'override': override,
    });
    final failure = decideFailure;
    if (failure != null) throw failure;
    queue = queue.where((r) => r.id != paymentRecordId).toList();
    return ManualPaymentRecord.fromMap(manualPaymentPayload(
      id: paymentRecordId,
      status:
          decision == ManualPaymentDecision.verify ? 'VERIFIED' : 'REJECTED',
    ));
  }

  @override
  Future<CatalogSubscription> comp(
    String catalogId, {
    required DateTime until,
    required String note,
  }) async {
    calls.add('comp:$note');
    return detail!.subscription!;
  }

  @override
  Future<CatalogSubscription> extendGrace(
    String catalogId, {
    required int days,
    required String note,
  }) async {
    calls.add('extendGrace:$days');
    return detail!.subscription!;
  }

  @override
  Future<String> resyncArEntitlement(String catalogId) async {
    calls.add('resyncAr');
    return 'job-resync-1';
  }

  @override
  Future<String> resyncPageState(String catalogId) async {
    calls.add('resyncPage');
    return 'job-resync-page-1';
  }

  @override
  Future<PaymentRecordSummary> refund(
    String catalogId, {
    required String refundsPaymentId,
    required String note,
    bool override = false,
  }) async {
    calls.add('refund:$refundsPaymentId');
    refunds.add({'id': refundsPaymentId, 'note': note, 'override': override});
    final failure = refundFailure;
    if (failure != null) throw failure;
    return PaymentRecordSummary.fromMap(
      paymentRowPayload(id: '66f0000000000000000000ff', kind: 'REFUNDED'),
    );
  }

  @override
  Future<CatalogSubscription> setStandeesIssued(
    String catalogId, {
    required int issued,
    String? note,
  }) async {
    calls.add('standees:$issued');
    standeesSet.add({'catalogId': catalogId, 'issued': issued, 'note': note});
    final failure = standeesFailure;
    if (failure != null) throw failure;
    return detail!.subscription!;
  }
}

/// A checkout sheet whose answer the test decides — immediately, or when
/// the test says so through [complete].
class FakeCheckoutAdapter implements CheckoutAdapter {
  FakeCheckoutAdapter({this.supported = true, this.outcome});

  final bool supported;

  /// Answered as soon as [open] is called, when set.
  CheckoutOutcome? outcome;

  final List<Map<String, Object>> opened = [];
  Completer<CheckoutOutcome>? _pending;

  @override
  bool get isSupported => supported;

  @override
  Future<CheckoutOutcome> open({
    required String keyId,
    required String orderId,
    required int amountPaise,
    required String description,
  }) {
    opened.add({
      'keyId': keyId,
      'orderId': orderId,
      'amountPaise': amountPaise,
      'description': description,
    });
    final scripted = outcome;
    if (scripted != null) return Future.value(scripted);
    _pending = Completer<CheckoutOutcome>();
    return _pending!.future;
  }

  /// Lets the sheet answer while the test holds the flow open.
  void complete(CheckoutOutcome result) {
    _pending?.complete(result);
    _pending = null;
  }

  bool get isOpen => _pending != null;
}
