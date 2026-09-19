// test/catalog/subscription_entity_test.dart
//
// The subscription entity and its copy: the parse is tolerant of an older
// server, every enum round-trips, the money formula matches the server's, and
// the seven status lines / chips read exactly as the table says — from the
// SERVER's daysLeft, never from a clock.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/checkout_adapter.dart';
import 'package:recapture/data/repositories/payments_repository.dart';
import 'package:recapture/domain/catalog/subscription_copy.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/domain/entities/subscription_payment.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/presentation/screens/catalog/subscription_screen.dart';

import 'catalog_entities_test.dart' as golden;
import 'payments_fakes.dart';

/// A `SubscriptionStatusDto`, in the shape the server emits it.
Map<String, dynamic> subscriptionPayload({
  String status = 'TRIAL',
  String? planId,
  String? planName,
  String? periodEnd = '2026-10-18T00:00:00.000Z',
  String? graceEndsAt,
  int? daysLeft = 12,
  int threeDDishCount = 4,
  int? threeDDishCap = 10,
  int imageDishCount = 6,
  bool trialAvailable = false,
  bool isEntitledTo3D = true,
}) =>
    {
      'status': status,
      'planId': planId,
      'planName': planName,
      'billingInterval': planId == null ? null : 'MONTHLY',
      'periodEnd': periodEnd,
      'graceEndsAt': graceEndsAt,
      'daysLeft': daysLeft,
      'threeDDishCount': threeDDishCount,
      'threeDDishCap': threeDDishCap,
      'imageDishCount': imageDishCount,
      'trialAvailable': trialAvailable,
      'isEntitledTo3D': isEntitledTo3D,
      'standeeAllocation': {'included': 10, 'issued': 2},
      'plans': PlanCatalog.bundledDefault.toMap(),
    };

void main() {
  group('CatalogSubscription.fromMap', () {
    test('reads every field the server sends', () {
      final sub = CatalogSubscription.fromMap(subscriptionPayload(
        status: 'ACTIVE',
        planId: 'SIGNATURE',
        planName: 'Signature plan',
        threeDDishCap: 15,
      ));
      expect(sub.status, SubscriptionStatus.active);
      expect(sub.planId, PlanId.signature);
      expect(sub.planName, 'Signature plan');
      expect(sub.billingInterval, BillingInterval.monthly);
      expect(sub.periodEnd, DateTime.parse('2026-10-18T00:00:00.000Z'));
      expect(sub.daysLeft, 12);
      expect(sub.threeDDishCount, 4);
      expect(sub.threeDDishCap, 15);
      expect(sub.imageDishCount, 6);
      expect(sub.standeeIncluded, 10);
      expect(sub.standeeIssued, 2);
      expect(sub.plans.plans.map((p) => p.planId),
          [PlanId.taste, PlanId.signature, PlanId.masterchef]);
      expect(sub.isOverCap, isFalse);
    });

    test('tolerates an empty body — an older server — as "no subscription"',
        () {
      final sub = CatalogSubscription.fromMap(const {});
      expect(sub.status, SubscriptionStatus.none);
      expect(sub.hasRow, isFalse);
      expect(sub.daysLeft, isNull);
      expect(sub.threeDDishCap, isNull);
      expect(sub.threeDDishCount, 0);
      expect(sub.trialAvailable, isFalse);
      // The comparison cards still draw, from the bundled numbers.
      expect(sub.plans.plans, hasLength(3));
      expect(sub.plans.trialThreeDCap, 10);
    });

    test('a null cap is uncapped; a negative one is never trusted as a number',
        () {
      expect(
        CatalogSubscription.fromMap(subscriptionPayload(threeDDishCap: null))
            .threeDDishCap,
        isNull,
      );
      expect(
        CatalogSubscription.fromMap(subscriptionPayload(threeDDishCap: -1))
            .threeDDishCap,
        isNull,
      );
    });

    test('falls back to the bundled plans when the block is malformed', () {
      final payload = subscriptionPayload()
        ..['plans'] = {
          'plans': {'TASTE': {}},
        };
      final sub = CatalogSubscription.fromMap(payload);
      expect(sub.plans.plans, hasLength(3));
      expect(sub.plans.plans.first.priceMonthlyPaise, 119900);
    });

    test('an unknown status or plan degrades, never throws', () {
      final sub = CatalogSubscription.fromMap(
        subscriptionPayload(status: 'FROZEN', planId: 'PLATINUM'),
      );
      expect(sub.status, SubscriptionStatus.unknown);
      expect(sub.planId, PlanId.unknown);
    });
  });

  group('the enums round-trip', () {
    test('SubscriptionStatus, PlanId, BillingInterval', () {
      for (final s in SubscriptionStatus.values) {
        expect(SubscriptionStatusX.fromApiValue(s.apiValue), s);
      }
      for (final p in PlanId.values) {
        expect(PlanIdX.fromApiValue(p.apiValue), p);
      }
      for (final b in BillingInterval.values) {
        expect(BillingIntervalX.fromApiValue(b.apiValue), b);
      }
      expect(
          SubscriptionStatusX.fromApiValue('trial'), SubscriptionStatus.trial);
    });
  });

  group('money', () {
    test('the yearly price is the server formula, in paise (AC-8.1)', () {
      final plans = PlanCatalog.bundledDefault;
      expect(plans.byId(PlanId.taste)!.yearlyPricePaise, 1007160);
      expect(plans.byId(PlanId.signature)!.yearlyPricePaise, 1511160);
      expect(plans.byId(PlanId.masterchef)!.yearlyPricePaise, 2099160);
    });

    test('formatRupees rounds to the rupee with Indian grouping', () {
      expect(formatRupees(119900), '₹1,199');
      expect(formatRupees(1007160), '₹10,072');
      expect(formatRupees(2099160), '₹20,992');
      expect(formatRupees(123456700), '₹12,34,567');
      expect(formatRupees(50), '₹1');
      expect(formatRupees(0), '₹0');
    });
  });

  group('the copy table', () {
    CatalogSubscription sub(String status, {int? daysLeft, String? planName}) =>
        CatalogSubscription.fromMap(subscriptionPayload(
          status: status,
          daysLeft: daysLeft,
          planName: planName,
          periodEnd: '2026-10-18T12:00:00.000Z',
          graceEndsAt: '2026-10-25T12:00:00.000Z',
        ));

    test('owner lines, from the SERVER daysLeft', () {
      expect(ownerStatusLine(sub('NONE'), trialThreeDCap: 10),
          'No subscription yet');
      expect(ownerStatusLine(sub('TRIAL', daysLeft: 12), trialThreeDCap: 10),
          'Free trial — 12 days left, up to 10 3D dishes');
      expect(ownerStatusLine(sub('TRIAL', daysLeft: 1), trialThreeDCap: 10),
          'Free trial — 1 day left, up to 10 3D dishes');
      expect(
        ownerStatusLine(sub('ACTIVE', planName: 'Signature plan'),
            trialThreeDCap: 10),
        'Active until ${formatSubscriptionDate(DateTime.parse('2026-10-18T12:00:00.000Z'))} · Signature plan',
      );
      expect(ownerStatusLine(sub('GRACE', daysLeft: 3), trialThreeDCap: 10),
          'Payment overdue — 3D menu pauses in 3 days');
      expect(ownerStatusLine(sub('PAUSED'), trialThreeDCap: 10),
          '3D menu paused — your photo menu is still live');
      expect(ownerStatusLine(sub('CANCELLED'), trialThreeDCap: 10),
          'Cancelled — resubscribe anytime');
      expect(
        ownerStatusLine(sub('COMPED'), trialThreeDCap: 10),
        'Complimentary until ${formatSubscriptionDate(DateTime.parse('2026-10-18T12:00:00.000Z'))}',
      );
    });

    test('rep chips', () {
      SubscriptionSummary summary(String status, {int? daysLeft}) =>
          SubscriptionSummary.fromMap({'status': status, 'daysLeft': daysLeft});
      expect(repStatusChip(null), 'No plan');
      expect(repStatusChip(summary('NONE')), 'No plan');
      expect(repStatusChip(summary('TRIAL', daysLeft: 12)), 'Trial 12d');
      expect(repStatusChip(summary('ACTIVE')), 'Active');
      expect(repStatusChip(summary('GRACE', daysLeft: 3)), 'Overdue 3d');
      expect(repStatusChip(summary('PAUSED')), '3D paused');
      expect(repStatusChip(summary('CANCELLED')), 'Cancelled');
      expect(repStatusChip(summary('COMPED')), 'Comped');
    });

    test('the usage line names the cap the server sent', () {
      expect(threeDUsageLine(sub('TRIAL')), '4 / 10 (trial)');
      expect(
        threeDUsageLine(CatalogSubscription.fromMap(subscriptionPayload(
          status: 'ACTIVE',
          planName: 'Signature plan',
          threeDDishCount: 12,
          threeDDishCap: 15,
        ))),
        '12 / 15 (Signature plan)',
      );
      expect(
        threeDUsageLine(CatalogSubscription.fromMap(
            subscriptionPayload(status: 'COMPED', threeDDishCap: null))),
        '4 (unlimited)',
      );
    });
  });

  group('the summary rides on the catalog DTOs', () {
    test('Catalog.fromMap reads it, and null stays null', () {
      final withRow = Catalog.fromMap({
        ...golden.catalogGolden(),
        'subscription': {
          'status': 'TRIAL',
          'daysLeft': 12,
          'planId': null,
          'isEntitledTo3D': true,
          'trialAvailable': false,
        },
      });
      expect(withRow.subscription?.status, SubscriptionStatus.trial);
      expect(withRow.subscription?.daysLeft, 12);
      expect(withRow.toMap()['subscription'], isA<Map<String, dynamic>>());

      final without = Catalog.fromMap({...golden.catalogGolden()});
      expect(without.subscription, isNull);
      expect(without.copyWith(name: 'x').subscription, isNull);
    });

    test('RepCatalogSummary.fromMap reads it', () {
      final row = RepCatalogSummary.fromMap({
        'id': 'c1',
        'name': 'blue_cafe',
        'status': 'DRAFT',
        'subscription': {'status': 'ACTIVE', 'planId': 'TASTE'},
      });
      expect(row.subscription?.status, SubscriptionStatus.active);
      expect(row.subscription?.planId, PlanId.taste);
    });
  });

  group('the owner screen body', () {
    Future<void> pump(
      WidgetTester tester,
      Map<String, dynamic> payload, {
      bool checkoutSupported = true,
    }) {
      // Tall enough that the whole list — three plan cards, the checkout and
      // the history under them — is built; a ListView builds nothing off-screen.
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      return tester.pumpWidget(ProviderScope(
        overrides: [
          paymentsRepositoryProvider
              .overrideWithValue(FakePaymentsRepository()),
          checkoutAdapterProvider.overrideWithValue(
              FakeCheckoutAdapter(supported: checkoutSupported)),
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

    testWidgets('renders every status line, with ONE button labelled by status',
        (tester) async {
      final cases = <Map<String, dynamic>, (String, String)>{
        subscriptionPayload(status: 'NONE', daysLeft: null): (
          'No subscription yet',
          'Pay'
        ),
        subscriptionPayload(status: 'TRIAL', daysLeft: 12): (
          'Free trial — 12 days left',
          'Pay'
        ),
        subscriptionPayload(
          status: 'ACTIVE',
          planId: 'TASTE',
          planName: 'Taste plan',
        ): ('Active until', 'Renew'),
        subscriptionPayload(status: 'GRACE', planId: 'TASTE', daysLeft: 2): (
          'Payment overdue',
          'Renew'
        ),
        subscriptionPayload(status: 'PAUSED', daysLeft: null): (
          '3D menu paused',
          'Pay'
        ),
        subscriptionPayload(status: 'CANCELLED', daysLeft: null): (
          'Cancelled — resubscribe anytime',
          'Pay'
        ),
        subscriptionPayload(status: 'COMPED'): ('Complimentary until', 'Pay'),
      };
      for (final entry in cases.entries) {
        await tester.pumpWidget(const SizedBox());
        await pump(tester, entry.key);
        await tester.pump();
        expect(find.textContaining(entry.value.$1), findsOneWidget,
            reason: 'status ${entry.key['status']}');
        final button = find.byKey(const ValueKey('subscription_pay_button'));
        expect(button, findsOneWidget, reason: 'status ${entry.key['status']}');
        expect(
          find.descendant(
            of: button,
            matching: find.textContaining('${entry.value.$2} · ₹'),
          ),
          findsOneWidget,
          reason: 'status ${entry.key['status']}',
        );
        // The consent line sits above the button on every status (AC-5.2).
        expect(find.byKey(const ValueKey('subscription_consent_line')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('subscription_checkout_slot')),
            findsOneWidget);
      }
    });

    testWidgets('selecting a higher tier than the running plan says Upgrade',
        (tester) async {
      await pump(
        tester,
        subscriptionPayload(
          status: 'ACTIVE',
          planId: 'TASTE',
          planName: 'Taste plan',
        ),
      );
      await tester.pump();
      expect(find.textContaining('Renew · ₹1,199 / month'), findsOneWidget);

      await tester
          .tap(find.byKey(const ValueKey('subscription_plan_MASTERCHEF')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Upgrade · ₹2,499 / month'), findsOneWidget);

      // The E9 warning: days left on a running period are forfeited.
      expect(find.byKey(const ValueKey('subscription_forfeit_warning')),
          findsOneWidget);
      expect(find.textContaining('12 days left on your current period'),
          findsOneWidget);
    });

    testWidgets('the pre-checkout sheet carries the consent line (AC-5.2)',
        (tester) async {
      await pump(tester, subscriptionPayload(status: 'NONE', daysLeft: null));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('subscription_pay_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('subscription_precheckout_sheet')),
          findsOneWidget);
      expect(find.text(kPaymentConsentLine), findsNWidgets(2));
      expect(find.textContaining('Continue to Pay'), findsOneWidget);
    });

    testWidgets('on web there is no Pay button — the phone card instead',
        (tester) async {
      await pump(
        tester,
        subscriptionPayload(status: 'NONE', daysLeft: null),
        checkoutSupported: false,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('subscription_pay_from_phone')),
          findsOneWidget);
      expect(
          find.byKey(const ValueKey('subscription_pay_button')), findsNothing);
      expect(find.textContaining('Pay from the ReCapture app on your phone'),
          findsOneWidget);
    });

    testWidgets('the toggle switches the three cards to yearly prices',
        (tester) async {
      await pump(tester, subscriptionPayload(status: 'TRIAL'));
      await tester.pump();
      expect(find.text('₹1,199 / month'), findsOneWidget);
      expect(find.text('₹10,072 / year'), findsNothing);

      await tester.tap(find.text('Yearly'));
      await tester.pumpAndSettle();

      expect(find.text('₹10,072 / year'), findsOneWidget);
      expect(find.text('₹15,112 / year'), findsOneWidget);
      expect(find.text('₹20,992 / year'), findsOneWidget);
      expect(find.textContaining('save 30%'), findsNWidgets(3));
      // And the button follows the toggle.
      expect(find.textContaining('Pay · ₹10,071.60 / year'), findsOneWidget);
    });

    testWidgets('the usage row is the server count against the server cap',
        (tester) async {
      await pump(
        tester,
        subscriptionPayload(
          status: 'ACTIVE',
          planName: 'Signature plan',
          threeDDishCount: 17,
          threeDDishCap: 15,
        ),
      );
      await tester.pump();
      expect(find.text('17 / 15 (Signature plan)'), findsOneWidget);
      expect(find.textContaining('More 3D dishes than your plan covers'),
          findsOneWidget);
    });

    testWidgets('the payment history lists rows newest first, refund muted',
        (tester) async {
      final repo = FakePaymentsRepository()
        ..ownerLedger = [
          PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000ff',
            kind: 'REFUNDED',
            createdAt: '2026-09-19T10:00:00.000Z',
          )),
          PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000a1',
            kind: 'PAID',
            amountPaise: 119950,
          )),
          PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000b2',
            kind: 'MANUAL',
            method: 'CASH',
            verificationStatus: 'PENDING_VERIFICATION',
            createdAt: '2026-09-17T10:00:00.000Z',
          )),
        ];
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          paymentsRepositoryProvider.overrideWithValue(repo),
          checkoutAdapterProvider.overrideWithValue(FakeCheckoutAdapter()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SubscriptionBody(
              subscription: CatalogSubscription.fromMap(
                subscriptionPayload(status: 'ACTIVE', planName: 'Taste plan'),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('subscription_payment_history')),
          findsOneWidget);
      expect(find.textContaining('Refund · RC-000000FF'), findsOneWidget);
      expect(find.text('−₹1,199'), findsOneWidget);
      expect(find.text('₹1,199.50'), findsOneWidget);
      expect(find.textContaining('Awaiting verification · RC-000000B2'),
          findsOneWidget);
      expect(find.textContaining('19 Sep 2026 · Refund'), findsOneWidget);
      // No refund ACTION anywhere on the owner's screen (AC-5.1).
      expect(find.textContaining('Refund duplicate'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Refund…'), findsNothing);
    });
  });
}
