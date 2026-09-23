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
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/catalog/qr_download_file.dart';
import '../../domain/entities/catalog_subscription.dart';
import '../../domain/entities/subscription_payment.dart';
import '../remote/api_client.dart';
import 'bytes_response.dart';
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

  /// Standees-delivered count above what the plan includes (or no plan).
  static const exceedsIncluded = 'EXCEEDS_INCLUDED';

  /// A receipt asked for on a row that has none, or that is not this owner's.
  static const paymentNotFound = 'PAYMENT_NOT_FOUND';

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
  /// `POST /catalog/subscription/verify` — hands the sheet's signed success
  /// response to the server, which checks the signature, asks Razorpay and
  /// records the payment at once. [recorded] false (202) means genuine but not
  /// captured yet: keep polling. Either way [subscription] is the server's.
  Future<({bool recorded, CatalogSubscription subscription})> verifyPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  });

  Future<List<PaymentRecordSummary>> ownerPayments();

  /// `GET /catalog/subscription/payments/:id/receipt` — one row as a PDF
  /// receipt (a receipt, not a GST invoice). BYTES, on the same seam as the
  /// QR download: the endpoint needs the Bearer token, so there is no link a
  /// browser could open. Only PAID, verified cash and comp rows have one;
  /// anything else is [PaymentErrorCodes.paymentNotFound].
  Future<QrDownloadFile> receipt(String paymentId);

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

  /// Re-tell Mirage this restaurant's CURRENT 3D entitlement (Stage 5,
  /// E18). The write happens on the worker; the answer is the job id, and
  /// the panel's sync stamp moves when it lands. 409 `NO_SUBSCRIPTION` when
  /// the catalog has no row.
  Future<String> resyncArEntitlement(String catalogId);

  /// Re-tells Mirage whether this restaurant's CUSTOMER PAGE should be live,
  /// and what its payment deadline is. The sibling of [resyncArEntitlement] for
  /// the field that decides whether the printed QR answers at all. Answers the
  /// job id.
  Future<String> resyncPageState(String catalogId);

  /// Refund ONE PAID row in full. Needs the row flagged as a suspected
  /// duplicate, or [override] with a note of at least thirty characters.
  Future<PaymentRecordSummary> refund(
    String catalogId, {
    required String refundsPaymentId,
    required String note,
    bool override = false,
  });

  /// `PATCH /admin/catalogs/:id/subscription/standees` — how many of the
  /// plan's complimentary standees have been handed over. An ABSOLUTE count
  /// a human sets, capped at what the plan includes
  /// ([PaymentErrorCodes.exceedsIncluded]).
  Future<CatalogSubscription> setStandeesIssued(
    String catalogId, {
    required int issued,
    String? note,
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
  Future<({bool recorded, CatalogSubscription subscription})> verifyPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog/subscription/verify',
          data: {
            'orderId': orderId,
            'paymentId': paymentId,
            'signature': signature,
          },
        );
        return (
          recorded: res.data?['recorded'] == true,
          subscription:
              CatalogSubscription.fromMap(_object(res.data?['subscription'])),
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
  Future<QrDownloadFile> receipt(String paymentId) async {
    try {
      final res = await _dio.get<List<int>>(
        '/catalog/subscription/payments/$paymentId/receipt',
        options: Options(responseType: ResponseType.bytes),
      );
      final data = res.data;
      if (data == null || data.isEmpty) throw _malformed;
      return QrDownloadFile(
        bytes: Uint8List.fromList(data),
        fileName:
            fileNameFromDisposition(res.headers.value('content-disposition')) ??
                'receipt.pdf',
        mimeType:
            res.headers.value(Headers.contentTypeHeader) ?? 'application/pdf',
      );
    } on DioException catch (error) {
      // A bytes request gets a bytes-shaped 404 too; decode it so the code
      // survives (see CatalogRepository.fetchQr).
      throw CatalogFailure.fromDio(withDecodedBody(error));
    }
  }

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
  Future<String> resyncArEntitlement(String catalogId) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/admin/catalogs/$catalogId/subscription/resync-ar',
        );
        return (res.data?['jobId'] ?? '').toString();
      });

  @override
  Future<String> resyncPageState(String catalogId) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/admin/catalogs/$catalogId/subscription/resync-page',
        );
        return (res.data?['jobId'] ?? '').toString();
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

  @override
  Future<CatalogSubscription> setStandeesIssued(
    String catalogId, {
    required int issued,
    String? note,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/admin/catalogs/$catalogId/subscription/standees',
          data: {
            'issued': issued,
            if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
          },
        );
        return CatalogSubscription.fromMap(_object(res.data?['subscription']));
      });
}

/// App-wide payments repository. Tests override it with a fake.
final paymentsRepositoryProvider = Provider<PaymentsRepository>(
  (ref) => RemotePaymentsRepository(ref.watch(dioProvider)),
);
