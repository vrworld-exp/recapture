// test/catalog/price_change_notice_test.dart
//
// Gaps-addendum G6, G2 and G3 on the owner's Subscription screen:
//   • The B6 sentence ("your price was locked; renewals are ₹Y") appears ONLY
//     when the frozen snapshot's price differs from the plan's current price,
//     and under the plan it is about.
//   • "QR standees: N of M delivered" appears only when the plan includes any.
//   • The receipt icon is drawn on PAID / verified-cash / COMP rows and no
//     other; a tap fetches the PDF and hands it to the ONE download seam.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/catalog_qr_service.dart';
import 'package:recapture/application/catalog/checkout_adapter.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/payments_repository.dart';
import 'package:recapture/domain/catalog/subscription_copy.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/domain/entities/subscription_payment.dart';
import 'package:recapture/presentation/screens/catalog/subscription_screen.dart';

import 'payments_fakes.dart';
import 'publish_fakes.dart';
import 'subscription_entity_test.dart' show subscriptionPayload;

/// An ACTIVE Taste-monthly, bought at [lockedPaise] a month, with the plan
/// catalog's Taste price at [currentPaise].
Map<String, dynamic> activeTaste({
  int lockedPaise = 119900,
  int currentPaise = 119900,
  Map<String, dynamic>? standees = const {'included': 10, 'issued': 4},
}) {
  final plans = PlanCatalog.bundledDefault.toMap();
  final tiers = (plans['plans'] as Map).cast<String, dynamic>();
  tiers['TASTE'] = <String, dynamic>{
    ...(tiers['TASTE'] as Map).cast<String, dynamic>(),
    'priceMonthlyPaise': currentPaise,
  };
  plans['plans'] = tiers;
  return {
    ...subscriptionPayload(
      status: 'ACTIVE',
      planId: 'TASTE',
      planName: 'Taste plan',
      daysLeft: 20,
    ),
    'periodEnd': '2026-10-09T00:00:00.000Z',
    'planSnapshot': {
      'planId': 'TASTE',
      'displayName': 'Taste plan',
      'priceMonthlyPaise': lockedPaise,
      'yearlyDiscountPct': 30,
      'threeDDishCap': 10,
      'includedStandeeCount': 10,
      'features': <String>[],
    },
    'standeeAllocation': standees,
    'plans': plans,
  };
}

void main() {
  late FakePaymentsRepository payments;
  late FakeQrDeliverer deliverer;

  Future<void> pump(WidgetTester tester, Map<String, dynamic> payload) {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(ProviderScope(
      overrides: [
        paymentsRepositoryProvider.overrideWithValue(payments),
        checkoutAdapterProvider.overrideWithValue(FakeCheckoutAdapter()),
        qrDelivererProvider.overrideWithValue(deliverer),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SubscriptionBody(
            subscription: CatalogSubscription.fromMap(payload),
          ),
        ),
      ),
    ));
  }

  setUp(() {
    payments = FakePaymentsRepository();
    deliverer = FakeQrDeliverer();
  });

  const noticeKey = ValueKey('subscription_price_change_notice');

  group('lockedPriceNotice', () {
    test('null when the snapshot price equals the current price', () {
      expect(lockedPriceNotice(CatalogSubscription.fromMap(activeTaste())),
          isNull);
    });

    test('null without a snapshot (trial, comp, older server)', () {
      final payload = activeTaste(currentPaise: 149900)..remove('planSnapshot');
      expect(lockedPriceNotice(CatalogSubscription.fromMap(payload)), isNull);
    });

    test('the B6 sentence when the price moved, rupees from the server', () {
      final sub = CatalogSubscription.fromMap(
        activeTaste(lockedPaise: 119900, currentPaise: 149900),
      );
      expect(sub.priceChange, (lockedPaise: 119900, currentPaise: 149900));
      expect(
        lockedPriceNotice(sub),
        'Your current price ₹1,199/month was locked until 9 Oct 2026. '
        'Renewals are ₹1,499/month.',
      );
    });

    test('a price DROP is said too — the owner should know renewals are cheaper',
        () {
      final sub = CatalogSubscription.fromMap(
        activeTaste(lockedPaise: 119900, currentPaise: 99900),
      );
      expect(lockedPriceNotice(sub), contains('Renewals are ₹999/month.'));
    });
  });

  group('the owner screen', () {
    testWidgets('shows the notice under the current plan only when prices differ',
        (tester) async {
      await pump(tester, activeTaste());
      await tester.pump();
      expect(find.byKey(noticeKey), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await pump(tester, activeTaste(currentPaise: 149900));
      await tester.pump();
      expect(find.byKey(noticeKey), findsOneWidget);
      expect(find.textContaining('Renewals are ₹1,499/month'), findsOneWidget);
      // Under the Taste card, not the others: the notice sits between the
      // Taste card and the Signature card in the list.
      final taste = tester.getBottomLeft(
          find.byKey(const ValueKey('subscription_plan_TASTE')));
      final signature = tester.getTopLeft(
          find.byKey(const ValueKey('subscription_plan_SIGNATURE')));
      final notice = tester.getCenter(find.byKey(noticeKey));
      expect(notice.dy, greaterThan(taste.dy));
      expect(notice.dy, lessThan(signature.dy));
    });

    testWidgets('renders the standee line only when the plan includes any',
        (tester) async {
      await pump(tester, activeTaste());
      await tester.pump();
      expect(find.byKey(const ValueKey('subscription_standee_line')),
          findsOneWidget);
      expect(find.text('4 of 10 delivered'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await pump(tester, activeTaste(standees: {'included': 0, 'issued': 0}));
      await tester.pump();
      expect(find.byKey(const ValueKey('subscription_standee_line')),
          findsNothing);

      await tester.pumpWidget(const SizedBox());
      await pump(tester, activeTaste(standees: null));
      await tester.pump();
      expect(find.byKey(const ValueKey('subscription_standee_line')),
          findsNothing);
    });

    testWidgets(
        'draws the receipt icon on PAID, verified cash and COMP rows only, '
        'and a tap goes through the one download seam', (tester) async {
      payments.ownerLedger = [
        PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000a1', kind: 'PAID')),
        PaymentRecordSummary.fromMap(paymentRowPayload(
          id: '66f0000000000000000000a2',
          kind: 'MANUAL',
          method: 'CASH',
          verificationStatus: 'VERIFIED',
        )),
        PaymentRecordSummary.fromMap(paymentRowPayload(
          id: '66f0000000000000000000a3',
          kind: 'MANUAL',
          method: 'CASH',
          verificationStatus: 'PENDING_VERIFICATION',
        )),
        PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000a4', kind: 'COMP', amountPaise: 0)),
        PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000a5', kind: 'REFUNDED')),
        PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000a6', kind: 'CHECKOUT_CREATED')),
        PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000a7', kind: 'DISPUTED')),
      ];
      await pump(tester, activeTaste());
      await tester.pumpAndSettle();

      Finder icon(String id) => find.byKey(ValueKey('payment_receipt_$id'));
      expect(icon('66f0000000000000000000a1'), findsOneWidget);
      expect(icon('66f0000000000000000000a2'), findsOneWidget);
      expect(icon('66f0000000000000000000a4'), findsOneWidget);
      for (final none in ['a3', 'a5', 'a6', 'a7']) {
        expect(icon('66f000000000000000000$none'), findsNothing, reason: none);
      }

      await tester.tap(icon('66f0000000000000000000a1'));
      await tester.pumpAndSettle();
      expect(payments.receiptsFetched, ['66f0000000000000000000a1']);
      expect(deliverer.delivered, hasLength(1));
      expect(deliverer.delivered.single.fileName, 'receipt-RC-TEST.pdf');
      expect(deliverer.delivered.single.mimeType, 'application/pdf');
    });

    testWidgets('a failed receipt fetch is a sentence, not a crash',
        (tester) async {
      payments.ownerLedger = [
        PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000b1', kind: 'PAID')),
      ];
      payments.receiptFailure = const CatalogFailure(
        code: 'PAYMENT_NOT_FOUND',
        message: 'That payment was not found.',
      );
      await pump(tester, activeTaste());
      await tester.pumpAndSettle();

      await tester
          .tap(find.byKey(const ValueKey('payment_receipt_66f0000000000000000000b1')));
      // Two frames: the fetch fails, the toast is scheduled and shown. Not
      // pumpAndSettle, which would also wait the toast OUT.
      await tester.pump();
      await tester.pump();
      expect(deliverer.delivered, isEmpty);
      expect(find.byType(MaterialBanner), findsOneWidget);
      expect(find.textContaining("Couldn't download the receipt"), findsOneWidget);
      await tester.pumpAndSettle();
      // The icon is back for another try.
      expect(find.byKey(const ValueKey('payment_receipt_66f0000000000000000000b1')),
          findsOneWidget);
    });
  });
}
