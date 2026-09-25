// test/catalog/checkout_forfeit_warning_test.dart
//
// Prompt B / E9 + E34 — what the owner reads before paying early.
//
// What this file exists to catch:
//   • THE AMBER LINE ONLY WHEN SOMETHING IS FORFEITED. `daysForfeited > 0`
//     shows "Your current period ends in N days. Paying now starts a new
//     30-day period today." above Pay; 0 (or an older server that sends
//     nothing) shows no line — and Pay still works.
//   • THE ORDER'S NUMBER WINS. Before an order exists the line reads the
//     status DTO; once the server has quoted, its `daysForfeited` is the one
//     on screen (it survives a cancelled SDK sheet).
//   • AUTOPAY (docs/subscription/autopay.md). On the SAME plan and interval
//     nothing is charged today, so nothing is forfeited — the line appears
//     for a plan or interval CHANGE, which is a purchase now. The sheet says
//     when the first charge is and that it repeats "every month / every
//     year" (a real calendar cycle now — the E34 "30 days" wording belonged
//     to the one-time period and is gone from the sheet).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/theme/app_colors.dart';
import 'package:recapture/application/catalog/checkout_adapter.dart';
import 'package:recapture/application/catalog/subscription_notifier.dart';
import 'package:recapture/data/repositories/payments_repository.dart';
import 'package:recapture/domain/catalog/subscription_copy.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/domain/entities/subscription_payment.dart';
import 'package:recapture/presentation/screens/catalog/subscription_screen.dart';

import 'payments_fakes.dart';
import 'subscription_entity_test.dart' show subscriptionPayload;

const _forfeitKey = ValueKey('subscription_forfeit_warning');
const _sheetForfeitKey = ValueKey('subscription_precheckout_forfeit');
const _payKey = ValueKey('subscription_pay_button');

/// A subscription whose reads never touch a repository.
class _FixedSubscription extends SubscriptionNotifier {
  _FixedSubscription(this.value);
  final CatalogSubscription value;

  @override
  Future<CatalogSubscription> build() async => value;

  @override
  Future<void> refresh() async => state = AsyncData(value);
}

void main() {
  late FakePaymentsRepository repo;
  late FakeCheckoutAdapter adapter;

  setUp(() {
    repo = FakePaymentsRepository();
    adapter = FakeCheckoutAdapter();
  });

  Future<void> pump(WidgetTester tester, Map<String, dynamic> payload) {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final subscription = CatalogSubscription.fromMap(payload);
    return tester.pumpWidget(ProviderScope(
      overrides: [
        paymentsRepositoryProvider.overrideWithValue(repo),
        checkoutAdapterProvider.overrideWithValue(adapter),
        subscriptionProvider.overrideWith(() => _FixedSubscription(subscription)),
      ],
      child: MaterialApp(
        home: Scaffold(body: SubscriptionBody(subscription: subscription)),
      ),
    ));
  }

  group('earlyRenewalLine', () {
    test('null at zero, the sentence above it, with the period in days', () {
      expect(
        earlyRenewalLine(daysForfeited: 0, interval: BillingInterval.monthly),
        isNull,
      );
      expect(
        earlyRenewalLine(daysForfeited: -1, interval: BillingInterval.monthly),
        isNull,
      );
      expect(
        earlyRenewalLine(daysForfeited: 20, interval: BillingInterval.monthly),
        'Your current period ends in 20 days. '
        'Paying now starts a new 30-day period today.',
      );
      expect(
        earlyRenewalLine(daysForfeited: 1, interval: BillingInterval.yearly),
        'Your current period ends in 1 day. '
        'Paying now starts a new 365-day period today.',
      );
      expect(periodLengthLabel(BillingInterval.monthly), '30 days');
      expect(periodLengthLabel(BillingInterval.yearly), '365 days');
    });

    test('the pre-order figure is the DTO\'s daysLeft on a running period only',
        () {
      CatalogSubscription sub(String status, int? daysLeft) =>
          CatalogSubscription.fromMap(
              subscriptionPayload(status: status, daysLeft: daysLeft));
      expect(daysForfeitedFor(sub('ACTIVE', 20)), 20);
      expect(daysForfeitedFor(sub('TRIAL', 5)), 5);
      expect(daysForfeitedFor(sub('COMPED', 9)), 9);
      // Grace and paused have nothing left to lose; nothing counts down.
      expect(daysForfeitedFor(sub('GRACE', 3)), 0);
      expect(daysForfeitedFor(sub('PAUSED', null)), 0);
      expect(daysForfeitedFor(sub('NONE', null)), 0);
      expect(
        paymentForfeitWarning(sub('GRACE', 3),
            interval: BillingInterval.monthly),
        isNull,
      );
    });
  });

  group('the checkout section', () {
    testWidgets('ACTIVE with 12 days left, switching plan: the amber line above Pay',
        (tester) async {
      await pump(
        tester,
        subscriptionPayload(
          status: 'ACTIVE',
          planId: 'TASTE',
          planName: 'Taste plan',
          daysLeft: 12,
        ),
      );
      await tester.pump();
      // Same plan and interval: autopay defers, nothing is forfeited.
      expect(find.byKey(_forfeitKey), findsNothing);
      await tester.tap(find.byKey(const ValueKey('subscription_plan_MASTERCHEF')));
      await tester.pump();

      final line = find.byKey(_forfeitKey);
      expect(line, findsOneWidget);
      expect(
        tester.widget<Text>(line).data,
        'Your current period ends in 12 days. '
        'Paying now starts a new 30-day period today.',
      );
      expect(tester.widget<Text>(line).style?.color, AppColors.warning);
      // Above the button.
      expect(
        tester.getTopLeft(line).dy,
        lessThan(tester.getTopLeft(find.byKey(_payKey)).dy),
      );

      // The toggle changes the period words, not the number.
      await tester.tap(find.text('Yearly'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(_forfeitKey)).data,
        'Your current period ends in 12 days. '
        'Paying now starts a new 365-day period today.',
      );
    });

    testWidgets('GRACE, PAUSED, no row: no line, and Pay is live',
        (tester) async {
      for (final payload in [
        subscriptionPayload(status: 'GRACE', planId: 'TASTE', daysLeft: 3),
        subscriptionPayload(status: 'PAUSED', daysLeft: null),
        subscriptionPayload(status: 'NONE', daysLeft: null),
      ]) {
        await pump(tester, payload);
        await tester.pump();
        expect(find.byKey(_forfeitKey), findsNothing,
            reason: 'status ${payload['status']}');
        final button = tester.widget<ElevatedButton>(
          find.descendant(
            of: find.byKey(_payKey),
            matching: find.byType(ElevatedButton),
          ),
        );
        expect(button.onPressed, isNotNull,
            reason: 'status ${payload['status']}');
      }
    });

    testWidgets(
        'once the server has quoted, its daysForfeited is the number on screen',
        (tester) async {
      // The DTO says 12; the server's quote says 11 (a day passed). After a
      // cancelled SDK sheet the order is still in hand, and it wins.
      repo.onCreateOrder =
          () => CheckoutOrder.fromMap(orderPayload(daysForfeited: 11));
      adapter.outcome = const CheckoutCancelled();
      await pump(
        tester,
        subscriptionPayload(
          status: 'ACTIVE',
          planId: 'TASTE',
          planName: 'Taste plan',
          daysLeft: 12,
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('subscription_plan_MASTERCHEF')));
      await tester.pump();
      expect(find.textContaining('ends in 12 days'), findsOneWidget);

      await tester.tap(find.byKey(_payKey));
      await tester.pumpAndSettle();
      // The sheet, before any order exists, reads the DTO.
      expect(find.byKey(_sheetForfeitKey), findsOneWidget);
      expect(find.textContaining('ends in 12 days'), findsNWidgets(2));
      await tester
          .tap(find.byKey(const ValueKey('subscription_precheckout_continue')));
      await tester.pumpAndSettle();

      // No autopay route on this fake server: the one-time fallback.
      expect(repo.calls, contains('createOrder:MASTERCHEF:MONTHLY'));
      expect(adapter.opened, hasLength(1));
      expect(find.textContaining('ends in 11 days'), findsOneWidget);
      expect(find.textContaining('ends in 12 days'), findsNothing);
    });

    testWidgets('an older server that sends no daysForfeited shows no line; Pay works',
        (tester) async {
      final payload = orderPayload()..remove('daysForfeited');
      repo.onCreateOrder = () => CheckoutOrder.fromMap(payload);
      adapter.outcome = const CheckoutCancelled();
      await pump(
        tester,
        subscriptionPayload(
          status: 'ACTIVE',
          planId: 'TASTE',
          planName: 'Taste plan',
          daysLeft: 12,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(_payKey));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('subscription_precheckout_continue')));
      await tester.pumpAndSettle();

      expect(adapter.opened, hasLength(1));
      expect(find.byKey(_forfeitKey), findsNothing);
      // Back to idle after the cancel; a second tap is allowed.
      final button = tester.widget<ElevatedButton>(
        find.descendant(
          of: find.byKey(_payKey),
          matching: find.byType(ElevatedButton),
        ),
      );
      expect(button.onPressed, isNotNull);
    });
  });

  group('the pre-checkout sheet', () {
    Future<void> openSheet(WidgetTester tester, {bool yearly = false}) async {
      await pump(
        tester,
        subscriptionPayload(
          status: 'ACTIVE',
          planId: 'TASTE',
          planName: 'Taste plan',
          daysLeft: 12,
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('subscription_plan_MASTERCHEF')));
      await tester.pump();
      if (yearly) {
        await tester.tap(find.text('Yearly'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(_payKey));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('subscription_precheckout_sheet')),
          findsOneWidget);
    }

    /// Every Text under the sheet, joined — the "widget tree grep".
    String sheetText(WidgetTester tester) => tester
        .widgetList<Text>(find.descendant(
          of: find.byKey(const ValueKey('subscription_precheckout_sheet')),
          matching: find.byType(Text),
        ))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join('\n');

    testWidgets('monthly: charged now, then every month until turned off; the E9 line in amber',
        (tester) async {
      await openSheet(tester);
      final text = sheetText(tester);
      expect(text, contains('charged now, then automatically every month'));
      expect(text, contains('until you turn autopay off'));
      expect(text, isNot(contains('every year')));
      // No bare "a month" / "1 month" promise anywhere on the sheet.
      expect(text, isNot(matches(RegExp(r'\b(a|1|one) (month|year)\b'))));

      final forfeit = find.byKey(_sheetForfeitKey);
      expect(forfeit, findsOneWidget);
      expect(
        tester.widget<Text>(forfeit).data,
        'Your current period ends in 12 days. '
        'Paying now starts a new 30-day period today.',
      );
    });

    testWidgets('yearly: every year', (tester) async {
      await openSheet(tester, yearly: true);
      final text = sheetText(tester);
      expect(text, contains('every year'));
      expect(text, isNot(contains('every month')));
      expect(
        tester.widget<Text>(find.byKey(_sheetForfeitKey)).data,
        contains('a new 365-day period today'),
      );
    });

    testWidgets('nothing forfeited: no amber line on the sheet either',
        (tester) async {
      await pump(tester, subscriptionPayload(status: 'NONE', daysLeft: null));
      await tester.pump();
      await tester.tap(find.byKey(_payKey));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('subscription_precheckout_sheet')),
          findsOneWidget);
      expect(find.byKey(_sheetForfeitKey), findsNothing);
      expect(find.byKey(const ValueKey('subscription_precheckout_period')),
          findsOneWidget);
    });
  });
}
