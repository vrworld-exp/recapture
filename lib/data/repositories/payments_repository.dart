// lib/data/repositories/payments_repository.dart
//
// Data access for the money side of the subscription (Stage 3): the owner's
// in-app order and ledger, the rep's cash request, and the admin's queue,
// decisions, comp, grace extension, refund and collections list.
//
// A SEPARATE repository from [CatalogRepository] / [RepRepository] rather than
// more methods on them, for the same reason [AdminStandeeRepository] is: the
// three surfaces share one ledger and one error vocabulary, and a fake that
// wants to exercise a cash form should not owe forty unrelated stubs.
//
// Mirrors the house error boundary exactly: every method throws
// [CatalogFailure], never a [DioException], and screens branch on `code`.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/catalog_subscription.dart';
import '../../domain/entities/subscription_payment.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';

/// Error codes the payment endpoints return that a screen branches on.
abstract final class PaymentErrorCodes {
  /// RAZORPAY_* is absent on this deployment, or Razorpay did not answer.
  /// A DEGRADATION: "try again in a minute", never a bug report (D7).
  static const paymentsUnavailable = 'PAYMENTS_UNAVAILABLE';

  /// A second VERIFY/REJECT on a request somebody already decided.
  static const alreadyDecided = 'ALREADY_DECIDED';

  /// The cash amount is not the plan's price; the admin must override (E12).
  static const amountMismatch = 'AMOUNT_MISMATCH';

  /// The catalog was deleted; the request was auto-rejected (E37).
  static const catalogDeleted = 'CATALOG_DELETED';

  /// Refund refusals.
  static const overrideRequired = 'OVERRIDE_REQUIRED';
  static const notRefundable = 'NOT_REFUNDABLE';
  static const alreadyRefunded = 'ALREADY_REFUNDED';

  /// Extend-grace on a row that is not in GRACE.
  static const notInGrace = 'NOT_IN_GRACE';

  static const rateLimited = 'RATE_LIMITED';
}

/// What an admin does with a pending cash request.
enum ManualPaymentDecision { verify, reject }

abstract interface class PaymentsRepository {
  // ── Owner ────────────────────────────────────────────────────────────────

  /// `POST /catalog/subscription/order`. The server mints one order per
  /// catalog and hands the open one back on a repeat; [CheckoutOrder.reused]
  /// says which. 503 → [PaymentErrorCodes.paymentsUnavailable].
  Future<CheckoutOrder> createOrder({
    required PlanId planId,
    required BillingInterval interval,
  });

  /// `GET /catalog/subscription/payments` — the owner's last fifty rows.
  Future<List<PaymentRecordSummary>> ownerPayments();

  // ── Rep ──────────────────────────────────────────────────────────────────

  /// The request still awaiting an admin for this restaurant, or null.
  Future<ManualPaymentRecord?> pendingManualPayment(String catalogId);

  /// `POST /rep/catalogs/:id/subscription/manual-payment-request`. Writes a
  /// PENDING row; never touches the subscription (AC-6.1).
  Future<ManualPaymentSubmission> submitManualPayment(
    String catalogId,
    ManualPaymentRequest request,
  );

  // ── Admin ────────────────────────────────────────────────────────────────

  Future<List<ManualPaymentRecord>> manualPaymentQueue({
    VerificationStatus status = VerificationStatus.pending,
  });

  Future<AdminSubscriptionPage> subscriptions({
    required AdminSubscriptionFilter filter,
    String? cursor,
  });

  Future<AdminSubscriptionDetail> subscriptionDetail(String catalogId);

  /// VERIFY or REJECT one request. A reject needs a [note]; a verify of an
  /// amount that differs from the quote needs [override] plus a note of at
  /// least twenty characters, else the server answers AMOUNT_MISMATCH.
  Future<ManualPaymentRecord> decideManualPayment(
    String catalogId, {
    required String paymentRecordId,
    required ManualPaymentDecision decision,
    String? note,
    bool override = false,
  });

  Future<CatalogSubscription> comp(
    String catalogId, {
    required DateTime until,
    required String note,
  });

  Future<CatalogSubscription> extendGrace(
    String catalogId, {
    required int days,
    required String note,
  });

  /// Refund ONE PAID row in full. Needs the row flagged as a suspected
  /// duplicate, or [override] with a note of at least thirty characters.
  Future<PaymentRecordSummary> refund(
    String catalogId, {
    required String refundsPaymentId,
    required String note,
    bool override = false,
  });
}

class RemotePaymentsRepository implements PaymentsRepository {
  const RemotePaymentsRepository(this._dio);

  final Dio _dio;

  static const _malformed = CatalogFailure(
    code: 'MALFORMED_RESPONSE',
    message: 'Something went wrong. Please try again.',
  );

  Map<String, dynamic> _object(dynamic raw) {
    if (raw is! Map) throw _malformed;
    return raw.cast<String, dynamic>();
  }

  @override
  Future<CheckoutOrder> createOrder({
    required PlanId planId,
    required BillingInterval interval,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog/subscription/order',
          data: {'planId': planId.apiValue, 'interval': interval.apiValue},
        );
        return CheckoutOrder.fromMap(
          _object(res.data?['order']),
          reused: res.headers.value('x-order-reused') == '1' ||
              res.statusCode == 200,
        );
      });

  @override
  Future<List<PaymentRecordSummary>> ownerPayments() =>
      mapCatalogErrors(() async {
        final res = await _dio
            .get<Map<String, dynamic>>('/catalog/subscription/payments');
        return PaymentRecordSummary.listFrom(res.data?['payments']);
      });

  @override
  Future<ManualPaymentRecord?> pendingManualPayment(String catalogId) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/subscription/manual-payment-request',
        );
        return ManualPaymentRecord.fromMapOrNull(res.data?['paymentRecord']);
      });

  @override
  Future<ManualPaymentSubmission> submitManualPayment(
    String catalogId,
    ManualPaymentRequest request,
  ) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/subscription/manual-payment-request',
          data: request.toBody(),
        );
        return ManualPaymentSubmission(
          record:
              ManualPaymentRecord.fromMap(_object(res.data?['paymentRecord'])),
          existing: res.data?['existing'] == true,
        );
      });

  @override
  Future<List<ManualPaymentRecord>> manualPaymentQueue({
    VerificationStatus status = VerificationStatus.pending,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/admin/subscriptions/manual-payments',
          queryParameters: {'status': status.apiValue},
        );
        final raw = res.data?['items'];
        return raw is List
            ? [
                for (final item in raw)
                  if (item is Map)
                    ManualPaymentRecord.fromMap(item.cast<String, dynamic>()),
              ]
            : const [];
      });

  @override
  Future<AdminSubscriptionPage> subscriptions({
    required AdminSubscriptionFilter filter,
    String? cursor,
  }) =>
      mapCatalogErrors(() async {
        final state = filter.stateApiValue;
        if (state == null) {
          throw const CatalogFailure(
            code: 'INVALID_REQUEST',
            message: 'The pending queue is read through manualPaymentQueue.',
          );
        }
        final res = await _dio.get<Map<String, dynamic>>(
          '/admin/subscriptions',
          queryParameters: {
            'state': state,
            if (cursor != null) 'cursor': cursor
          },
        );
        final raw = res.data?['items'];
        return AdminSubscriptionPage(
          items: raw is List
              ? [
                  for (final item in raw)
                    if (item is Map)
                      AdminSubscriptionListItem.fromMap(
                          item.cast<String, dynamic>()),
                ]
              : const [],
          nextCursor: res.data?['nextCursor'] is String
              ? res.data!['nextCursor'] as String
              : null,
        );
      });

  @override
  Future<AdminSubscriptionDetail> subscriptionDetail(String catalogId) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/admin/catalogs/$catalogId/subscription',
        );
        return AdminSubscriptionDetail.fromMap(_object(res.data));
      });

  @override
  Future<ManualPaymentRecord> decideManualPayment(
    String catalogId, {
    required String paymentRecordId,
    required ManualPaymentDecision decision,
    String? note,
    bool override = false,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/admin/catalogs/$catalogId/subscription/manual-payment',
          data: {
            'action':
                decision == ManualPaymentDecision.verify ? 'VERIFY' : 'REJECT',
            'paymentRecordId': paymentRecordId,
            if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
            if (override && decision == ManualPaymentDecision.verify)
              'override': true,
          },
        );
        return ManualPaymentRecord.fromMap(_object(res.data?['paymentRecord']));
      });

  @override
  Future<CatalogSubscription> comp(
    String catalogId, {
    required DateTime until,
    required String note,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/admin/catalogs/$catalogId/subscription/comp',
          data: {'until': until.toUtc().toIso8601String(), 'note': note},
        );
        return CatalogSubscription.fromMap(_object(res.data?['subscription']));
      });

  @override
  Future<CatalogSubscription> extendGrace(
    String catalogId, {
    required int days,
    required String note,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/admin/catalogs/$catalogId/subscription/extend-grace',
          data: {'days': days, 'note': note},
        );
        return CatalogSubscription.fromMap(_object(res.data?['subscription']));
      });

  @override
  Future<PaymentRecordSummary> refund(
    String catalogId, {
    required String refundsPaymentId,
    required String note,
    bool override = false,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/admin/catalogs/$catalogId/subscription/refund',
          data: {
            'refundsPaymentId': refundsPaymentId,
            'note': note,
            if (override) 'override': true,
          },
        );
        return PaymentRecordSummary.fromMap(
            _object(res.data?['paymentRecord']));
      });
}

/// App-wide payments repository. Tests override it with a fake.
final paymentsRepositoryProvider = Provider<PaymentsRepository>(
  (ref) => RemotePaymentsRepository(ref.watch(dioProvider)),
);
