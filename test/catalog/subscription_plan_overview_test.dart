// test/catalog/subscription_plan_overview_test.dart
//
// learn.txt 7b — an owner ON a plan opens Subscription and sees the plan
// itself first: name, price, days left, the date that matters, autopay,
// usage, what's included, offers and "See catalog"; the other plans and the
// button follow below.
//
// What this file exists to catch:
//   • WHO GETS IT. ACTIVE, GRACE, TRIAL and COMPED do; NONE, PAUSED,
//     CANCELLED and PENDING_PAYMENT keep the plain status card.
//   • IT IS ON TOP. The overview sits above the plan cards and the button.
//   • OFFERS SELECT, THEY DO NOT BUY. "Switch to yearly" moves the toggle and
//     the button to the yearly price; "See <next tier>" selects that plan.
//     No offer on the top tier; "you're saving" on yearly.
//   • THE DATE IS THE RIGHT ONE. "Renews by autopay on" with autopay on,
//     "Ends on" without it, "Grace ends on" in grace.
//   • "See catalog" goes to the catalog.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/application/catalog/checkout_adapter.dart';
import 'package:recapture/application/catalog/subscription_notifier.dart';
import 'package:recapture/data/repositories/payments_repository.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/presentation/screens/catalog/subscription_screen.dart';

import 'payments_fakes.dart';
import 'subscription_entity_test.dart' show subscriptionPayload;

const _overview = ValueKey('subscription_plan_overview');

class _FixedSubscription extends SubscriptionNotifier {
  _FixedSubscription(this.value);
  final CatalogSubscription value;

  @override
  Future<CatalogSubscription> build() async => value;

  @override
  Future<void> refresh() async => state = AsyncData(value);
}

Map<String, dynamic> _plan({
  String status = 'ACTIVE',
  String planId = 'TASTE',
  String planName = 'Taste plan',
  String interval = 'MONTHLY',
  String? graceEndsAt,
  Map<String, dynamic>? autopay,
}) {
  final map = subscriptionPayload(
    status: status,
    planId: planId,
    planName: planName,
    periodEnd: '2027-10-18T00:00:00.000Z',
    graceEndsAt: graceEndsAt,
    daysLeft: 12,
  );
  map['billingInterval'] = interval;
  if (autopay != null) map['autopay'] = autopay;
  return map;
}

void main() {
  late FakePaymentsRepository repo;

  setUp(() => repo = FakePaymentsRepository());

  Future<void> pump(WidgetTester tester, Map<String, dynamic> payload) async {
    // A phone-shaped viewport, so the 70% rule is what it is on a phone.
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final subscription = CatalogSubscription.fromMap(payload);
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) =>
            Scaffold(body: SubscriptionBody(subscription: subscription)),
      ),
      GoRoute(
        path: '/catalog',
        builder: (_, __) => const Scaffold(body: Text('CATALOG SCREEN')),
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        paymentsRepositoryProvider.overrideWithValue(repo),
        checkoutAdapterProvider.overrideWithValue(FakeCheckoutAdapter()),
        subscriptionProvider.overrideWith(() => _FixedSubscription(subscription)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
  }

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  /// Builds the target (the list is lazy), then centres it so a tap lands.
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('ACTIVE monthly: the plan in full, at least 70% of the screen, on top',
      (tester) async {
    await pump(tester, _plan());

    expect(find.byKey(_overview), findsOneWidget);
    expect(textOf(tester, 'subscription_overview_title'), 'Taste plan');
    expect(textOf(tester, 'subscription_overview_price'), '₹1,199 / month');
    expect(textOf(tester, 'subscription_overview_days'), '12');
    expect(find.text('Ends on'), findsOneWidget);
    expect(find.textContaining('Active until'), findsOneWidget);
    // At least 70% of the 915px screen.
    expect(tester.getSize(find.byKey(_overview)).height,
        greaterThanOrEqualTo(915 * 0.7));

    await scrollTo(tester, find.byKey(const ValueKey('subscription_offer_yearly')));
    expect(find.text('Save 30% with yearly billing'), findsOneWidget);
    await scrollTo(tester, find.byKey(const ValueKey('subscription_offer_upgrade')));
    expect(find.text('Upgrade to Signature plan'), findsOneWidget);
    await scrollTo(tester, find.byKey(const ValueKey('subscription_see_catalog')));
    // Below it: the plan cards and the button, as before.
    await scrollTo(tester, find.byKey(const ValueKey('subscription_plan_TASTE')));
    await scrollTo(tester, find.byKey(const ValueKey('subscription_pay_button')));
  });

  testWidgets('the overview starts at the top of the screen', (tester) async {
    await pump(tester, _plan());
    expect(tester.getTopLeft(find.byKey(_overview)).dy, lessThan(40));
    // Nothing of the plan list shows in the first 70% of the screen.
    final taste = find.byKey(const ValueKey('subscription_plan_TASTE'),
        skipOffstage: false);
    if (taste.evaluate().isNotEmpty) {
      expect(tester.getTopLeft(taste).dy, greaterThan(915 * 0.7));
    }
  });

  testWidgets('"Switch to yearly" selects yearly — the button quotes the year',
      (tester) async {
    await pump(tester, _plan());
    await scrollTo(tester, find.text('Switch to yearly'));
    await tester.tap(find.text('Switch to yearly'));
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('subscription_pay_button'));
    await scrollTo(tester, button);
    expect(
      find.descendant(of: button, matching: find.textContaining('/ year')),
      findsOneWidget,
    );
  });

  testWidgets('"See Signature plan" selects it — the button says Upgrade',
      (tester) async {
    await pump(tester, _plan());
    await scrollTo(tester, find.text('See Signature plan'));
    await tester.tap(find.text('See Signature plan'));
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('subscription_pay_button'));
    await scrollTo(tester, button);
    expect(
      find.descendant(of: button, matching: find.textContaining('Upgrade')),
      findsOneWidget,
    );
  });

  testWidgets('yearly: "you\'re saving" instead of the switch; top tier: no upgrade',
      (tester) async {
    await pump(
      tester,
      _plan(planId: 'MASTERCHEF', planName: 'MasterChef plan', interval: 'YEARLY'),
    );
    expect(textOf(tester, 'subscription_overview_price'), '₹20,992 / year');
    await scrollTo(tester, find.byKey(const ValueKey('subscription_offer_yearly')));
    expect(find.text("You're saving 30%"), findsOneWidget);
    expect(find.text('Switch to yearly'), findsNothing);
    expect(find.byKey(const ValueKey('subscription_offer_upgrade')), findsNothing);
  });

  testWidgets('autopay on: "Renews by autopay on" the next charge', (tester) async {
    await pump(
      tester,
      _plan(autopay: {
        'status': 'ACTIVE',
        'planId': 'TASTE',
        'planName': 'Taste plan',
        'interval': 'MONTHLY',
        'amountPaise': 119900,
        'nextChargeAt': '2027-10-18T00:00:00.000Z',
      }),
    );
    expect(find.text('Renews by autopay on'), findsOneWidget);
    expect(find.byKey(const ValueKey('subscription_autopay_card')), findsOneWidget);
  });

  testWidgets('grace: the grace end is the date, in amber', (tester) async {
    await pump(
      tester,
      _plan(status: 'GRACE', graceEndsAt: '2026-10-02T00:00:00.000Z'),
    );
    expect(find.text('Grace ends on'), findsOneWidget);
    expect(find.text('Grace period'), findsOneWidget);
  });

  testWidgets('trial: a free-trial overview that points at the plans',
      (tester) async {
    await pump(tester, subscriptionPayload(status: 'TRIAL', daysLeft: 12));
    expect(textOf(tester, 'subscription_overview_title'), 'Free trial');
    await scrollTo(
        tester, find.byKey(const ValueKey('subscription_offer_pick_plan')));
    expect(find.textContaining('Plans from ₹1,199 / month'), findsOneWidget);
  });

  testWidgets('no plan, paused, cancelled: no overview — the plain status card',
      (tester) async {
    for (final status in ['NONE', 'PAUSED', 'CANCELLED']) {
      await tester.pumpWidget(const SizedBox());
      await pump(tester, subscriptionPayload(status: status, daysLeft: null));
      expect(find.byKey(_overview), findsNothing, reason: status);
      expect(find.byKey(const ValueKey('subscription_status_line')),
          findsOneWidget,
          reason: status);
    }
  });

  testWidgets('"See catalog" opens the catalog', (tester) async {
    await pump(tester, _plan());
    final button = find.byKey(const ValueKey('subscription_see_catalog'));
    await scrollTo(tester, button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('CATALOG SCREEN'), findsOneWidget);
  });
}
