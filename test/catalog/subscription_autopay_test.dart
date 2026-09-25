// test/catalog/subscription_autopay_test.dart
//
// Autopay on the owner's Subscription screen (docs/subscription/autopay.md).
//
// What this file exists to catch:
//   • THE DTO. `autopay` parses when present and is null when absent — an
//     older server reads as "autopay off", never as a crash.
//   • NO DOUBLE CHARGE, SAID OUT LOUD. Inside a paid period of the same plan
//     the button is "Turn on autopay", there is no forfeit line, and the sheet
//     says nothing is charged for the plan today.
//   • A PLAN CHANGE IS A PURCHASE NOW. Another plan keeps the E9 forfeit line
//     and the Upgrade label.
//   • ON MEANS OFF IS ONE TAP AWAY. A healthy mandate shows its next charge
//     and "Turn off autopay"; confirming calls the server; the button for the
//     plan autopay already covers is replaced by a line.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/checkout_adapter.dart';
import 'package:recapture/application/catalog/subscription_notifier.dart';
import 'package:recapture/data/repositories/payments_repository.dart';
import 'package:recapture/domain/catalog/subscription_copy.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/presentation/screens/catalog/subscription_screen.dart';

import 'payments_fakes.dart';
import 'subscription_entity_test.dart' show subscriptionPayload;

class _FixedSubscription extends SubscriptionNotifier {
  _FixedSubscription(this.value);
  CatalogSubscription value;
  int refreshes = 0;

  @override
  Future<CatalogSubscription> build() async => value;

  @override
  Future<void> refresh() async {
    refreshes++;
    state = AsyncData(value);
  }
}

Map<String, dynamic> _autopay({
  String status = 'ACTIVE',
  String planId = 'TASTE',
  String interval = 'MONTHLY',
  String? nextChargeAt = '2026-10-18T00:00:00.000Z',
}) =>
    {
      'status': status,
      'planId': planId,
      'planName': 'Taste plan',
      'interval': interval,
      'amountPaise': 119900,
      'nextChargeAt': nextChargeAt,
    };

Map<String, dynamic> _active({Map<String, dynamic>? autopay}) {
  final map = subscriptionPayload(
    status: 'ACTIVE',
    planId: 'TASTE',
    planName: 'Taste plan',
    // Far enough out that the half-hour rule never bites.
    periodEnd: '2027-10-18T00:00:00.000Z',
    daysLeft: 12,
  );
  if (autopay != null) map['autopay'] = autopay;
  return map;
}

void main() {
  late FakePaymentsRepository repo;
  late FakeCheckoutAdapter adapter;
  late _FixedSubscription fixed;

  setUp(() {
    repo = FakePaymentsRepository();
    adapter = FakeCheckoutAdapter();
  });

  Future<void> pump(WidgetTester tester, Map<String, dynamic> payload) async {
    tester.view.physicalSize = const Size(1080, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final subscription = CatalogSubscription.fromMap(payload);
    fixed = _FixedSubscription(subscription);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        paymentsRepositoryProvider.overrideWithValue(repo),
        checkoutAdapterProvider.overrideWithValue(adapter),
        subscriptionProvider.overrideWith(() => fixed),
      ],
      child: MaterialApp(
        home: Scaffold(body: SubscriptionBody(subscription: subscription)),
      ),
    ));
    await tester.pump();
  }

  group('the DTO', () {
    test('parses autopay when present, null when absent', () {
      final on = CatalogSubscription.fromMap(_active(autopay: _autopay()));
      expect(on.autopay?.status, AutopayStatus.active);
      expect(on.autopay?.planId, PlanId.taste);
      expect(on.autopay?.interval, BillingInterval.monthly);
      expect(on.autopay?.amountPaise, 119900);
      expect(on.autopay?.nextChargeAt, DateTime.utc(2026, 10, 18));
      expect(on.autopay?.isHealthy, isTrue);

      expect(CatalogSubscription.fromMap(_active()).autopay, isNull);
      final halted = CatalogSubscription.fromMap(
          _active(autopay: _autopay(status: 'HALTED', nextChargeAt: null)));
      expect(halted.autopay?.isHealthy, isFalse);
      expect(halted.autopay?.status.willCharge, isFalse);
    });
  });

  group('the copy', () {
    test('deferred only inside a paid period of the same plan, and not in its last half hour',
        () {
      final sub = CatalogSubscription.fromMap(_active());
      final now = DateTime.utc(2026, 9, 25);
      expect(
        autopayDeferredUntil(sub, PlanId.taste, BillingInterval.monthly, now: now),
        DateTime.utc(2027, 10, 18),
      );
      expect(
        autopayDeferredUntil(sub, PlanId.signature, BillingInterval.monthly, now: now),
        isNull,
      );
      expect(
        autopayDeferredUntil(sub, PlanId.taste, BillingInterval.yearly, now: now),
        isNull,
      );
      expect(
        autopayDeferredUntil(
          sub,
          PlanId.taste,
          BillingInterval.monthly,
          now: DateTime.utc(2027, 10, 17, 23, 45),
        ),
        isNull,
      );
    });

    test('the status line for each state', () {
      AutopayInfo info(String status) =>
          AutopayInfo.fromMapOrNull(_autopay(status: status))!;
      expect(autopayStatusLine(null), isNull);
      expect(autopayStatusLine(info('ACTIVE')),
          startsWith('Autopay is on · ₹1,199 every month · next charge on'));
      expect(autopayStatusLine(info('PENDING')),
          startsWith('Autopay could not take the last payment'));
      expect(autopayStatusLine(info('HALTED')), startsWith('Autopay has stopped'));
    });

    test('the charge line says when, and that it repeats', () {
      expect(
        autopayChargeLine(
          amountPaise: 119900,
          interval: BillingInterval.monthly,
          deferredUntil: null,
        ),
        '₹1,199 is charged now, then automatically every month until you '
        'turn autopay off.',
      );
      expect(
        autopayChargeLine(
          amountPaise: 119900,
          interval: BillingInterval.yearly,
          deferredUntil: DateTime.utc(2026, 10, 18),
        ),
        startsWith('Nothing is charged for the plan today.'),
      );
    });
  });

  group('the screen', () {
    testWidgets(
        'paid plan, autopay off: "Turn on autopay", no forfeit line, the sheet says nothing today',
        (tester) async {
      await pump(tester, _active());

      expect(find.byKey(const ValueKey('subscription_autopay_card')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('subscription_autopay_line')))
            .data,
        startsWith('Autopay is off'),
      );
      expect(find.byKey(const ValueKey('subscription_forfeit_warning')), findsNothing);
      expect(find.textContaining('Turn on autopay'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('subscription_pay_button')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(
                find.byKey(const ValueKey('subscription_precheckout_period')))
            .data,
        startsWith('Nothing is charged for the plan today.'),
      );
      expect(find.byKey(const ValueKey('subscription_precheckout_forfeit')),
          findsNothing);
    });

    testWidgets('another plan is a purchase now: Upgrade and the forfeit line',
        (tester) async {
      await pump(tester, _active());
      await tester.tap(find.byKey(const ValueKey('subscription_plan_SIGNATURE')));
      await tester.pump();

      expect(find.byKey(const ValueKey('subscription_forfeit_warning')), findsOneWidget);
      expect(find.textContaining('Upgrade'), findsWidgets);
      expect(find.textContaining('Turn on autopay'), findsNothing);
    });

    testWidgets(
        'autopay on for this plan: next charge shown, no pay button, turn off calls the server',
        (tester) async {
      await pump(tester, _active(autopay: _autopay()));

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('subscription_autopay_line')))
            .data,
        startsWith('Autopay is on · ₹1,199 every month · next charge on'),
      );
      expect(find.byKey(const ValueKey('subscription_autopay_covers')), findsOneWidget);
      expect(find.byKey(const ValueKey('subscription_pay_button')), findsNothing);

      repo.onCancelAutopay = () => CatalogSubscription.fromMap(_active());
      await tester.tap(find.byKey(const ValueKey('subscription_autopay_off')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('subscription_autopay_off_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('subscription_autopay_off_confirm')));
      await tester.pump();
      await tester.pump();

      expect(repo.calls, contains('cancelAutopay'));
      expect(fixed.refreshes, greaterThan(0));
    });

    testWidgets('a halted mandate offers no "Turn off" — nothing will charge',
        (tester) async {
      await pump(tester,
          _active(autopay: _autopay(status: 'HALTED', nextChargeAt: null)));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('subscription_autopay_line')))
            .data,
        startsWith('Autopay has stopped'),
      );
      expect(find.byKey(const ValueKey('subscription_autopay_off')), findsNothing);
      // The pay button is back: turning autopay on again is the fix.
      expect(find.byKey(const ValueKey('subscription_pay_button')), findsOneWidget);
    });

    testWidgets('no plan and no autopay: no autopay card at all', (tester) async {
      await pump(tester, subscriptionPayload(status: 'NONE', daysLeft: null));
      expect(find.byKey(const ValueKey('subscription_autopay_card')), findsNothing);
      expect(find.byKey(const ValueKey('subscription_pay_button')), findsOneWidget);
    });
  });
}
