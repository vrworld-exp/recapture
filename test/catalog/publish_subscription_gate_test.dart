// test/catalog/publish_subscription_gate_test.dart
//
// The pre-publish subscription check — the paywall the owner meets when they
// press Publish without a plan, and the publish that happens by itself once
// they have one.
//
// WHAT THIS FILE EXISTS TO CATCH, in order of how badly the alternative goes:
//   • A PAYWALL INVENTED BY A BUG. Blocking a restaurant that HAS paid — or one
//     talking to an API that does not send a subscription DTO at all — locks a
//     paying business out of its own menu, and the only signal is a support
//     call. So every fail-open path is pinned: an unreported body, a failed
//     read, a status this build does not know.
//   • A PUBLISH THAT SLIPS THROUGH THE PAYWALL. `?start=1` fires a run the
//     moment the status says it can, and the subscription read finishes LATER
//     than the status read. If "not loaded yet" counted as permission, the one
//     press the card exists to stop would go through every single time.
//   • A DEAD END AFTER PAYING. The user pressed Publish, got a paywall, paid,
//     and came back: the run they asked for has to start on its own. A card
//     that clears and leaves them looking at an idle button is the whole
//     feature failing at the last step.
//   • THE CLIENT'S RULES DRIFTING FROM THE SERVER'S. The table below is
//     `evaluateSubscriptionGate`'s, case for case.
//
// Hermetic: the repository and connectivity are faked. No HTTP, no timers left.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_link_service.dart';
import 'package:recapture/application/catalog/checkout_adapter.dart';
import 'package:recapture/application/catalog/checkout_notifier.dart';
import 'package:recapture/application/catalog/subscription_notifier.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/data/repositories/payments_repository.dart';
import 'package:recapture/domain/catalog/publish_gate.dart';
import 'package:recapture/domain/catalog/subscription_publish_gate.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/presentation/screens/catalog/publish_screen.dart';
import 'package:recapture/presentation/screens/catalog/subscription_screen.dart';

import 'payments_fakes.dart';
import 'publish_fakes.dart';

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

Widget harness(
  FakePublishRepository repo, {
  bool startPublish = false,
  bool online = true,
}) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(repo),
        isOnlineProvider.overrideWithValue(online),
        catalogLinkActionsProvider.overrideWithValue(FakeLinkActions()),
      ],
      child: MaterialApp(home: PublishScreen(startPublish: startPublish)),
    );

ElevatedButton _ctaOf(WidgetTester tester) => tester.widget<ElevatedButton>(
      find.descendant(
        of: find.byKey(const ValueKey('publish_cta')),
        matching: find.byType(ElevatedButton),
      ),
    );

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(PublishScreen)));

final _card = find.byKey(const ValueKey('publish_subscription_gate'));

CatalogSubscription _sub({
  String status = 'ACTIVE',
  int threeDDishCount = 0,
  int? threeDDishCap = 10,
  String? planName = 'Taste plan',
}) =>
    CatalogSubscription.fromMap(subscriptionPayloadFor(
      status: status,
      threeDDishCount: threeDDishCount,
      threeDDishCap: threeDDishCap,
      planName: planName,
    ));

void main() {
  group('the rules, mirrored from the server', () {
    test('a reported NONE needs a plan, whatever the menu holds', () {
      for (final count in const [0, 1, 9]) {
        final gates =
            evaluateSubscriptionGates(_sub(status: 'NONE', threeDDishCount: count));
        expect(gates.single.code, PublishGateCode.subscriptionRequired);
      }
    });

    test('PAUSED and CANCELLED block only a menu with 3D dishes', () {
      for (final status in const ['PAUSED', 'CANCELLED']) {
        expect(
          evaluateSubscriptionGates(_sub(status: status, threeDDishCount: 0)),
          isEmpty,
          reason: 'a photo-only menu still publishes (README C5)',
        );
        expect(
          evaluateSubscriptionGates(_sub(status: status, threeDDishCount: 1))
              .single
              .code,
          PublishGateCode.subscriptionRequired,
        );
      }
    });

    test('over the cap is a capacity gate; at the cap is not', () {
      expect(
        evaluateSubscriptionGates(
          _sub(status: 'ACTIVE', threeDDishCount: 10, threeDDishCap: 10),
        ),
        isEmpty,
      );
      final gate = evaluateSubscriptionGates(
        _sub(status: 'ACTIVE', threeDDishCount: 11, threeDDishCap: 10),
      ).single;
      expect(gate.code, PublishGateCode.subscriptionCapacityExceeded);
      // The plan AS BOUGHT, and both numbers.
      expect(gate.message, contains('11 3D dishes'));
      expect(gate.message, contains('Taste plan covers 10'));
    });

    test('GRACE keeps access but not extra capacity', () {
      expect(
        evaluateSubscriptionGates(_sub(status: 'GRACE', threeDDishCount: 4)),
        isEmpty,
        reason: 'lapsing is a banner, never a blocker',
      );
      expect(
        evaluateSubscriptionGates(_sub(status: 'GRACE', threeDDishCount: 44))
            .single
            .code,
        PublishGateCode.subscriptionCapacityExceeded,
      );
    });

    test('an uncapped comp never trips the cap', () {
      expect(
        evaluateSubscriptionGates(
          _sub(status: 'COMPED', threeDDishCount: 99, threeDDishCap: null),
        ),
        isEmpty,
      );
    });

    test('a status this build does not know invents nothing', () {
      expect(
        evaluateSubscriptionGates(
          _sub(status: 'SOMETHING_NEW', threeDDishCount: 3),
        ),
        isEmpty,
      );
    });

    test('an API that sends no subscription DTO is not "no subscription"', () {
      // The empty body an older server answers with. It parses to NONE — and
      // must NOT be read as a missing plan, or one deploy skew paywalls the
      // whole fleet.
      final older = CatalogSubscription.fromMap(const {});
      expect(older.status, SubscriptionStatus.none);
      expect(older.isReported, isFalse);
      expect(evaluateSubscriptionGates(older), isEmpty);
      // A real server always sends one, `'NONE'` included.
      expect(_sub(status: 'NONE').isReported, isTrue);
    });
  });

  group('who decides', () {
    final serverGate = [
      const PublishGate(
        code: PublishGateCode.subscriptionRequired,
        message: "the server's own sentence",
      ),
    ];

    test('the server wins when it produced a gate', () {
      final check = checkSubscriptionForPublish(
        serverGates: serverGate,
        // The client would have said "fine" — the server still refuses.
        subscription: _sub(status: 'ACTIVE'),
        isLoading: false,
      );
      expect(check.blocks, isTrue);
      expect(check.gate!.message, "the server's own sentence");
    });

    test('a read still in flight is UNSETTLED, not permission', () {
      final check = checkSubscriptionForPublish(
        serverGates: const [],
        subscription: null,
        isLoading: true,
      );
      expect(check.isSettled, isFalse);
      expect(check.blocks, isFalse);
    });

    test('a FAILED read is ready — a flaky connection is not an unpaid bill',
        () {
      final check = checkSubscriptionForPublish(
        serverGates: const [],
        subscription: null,
        isLoading: false,
      );
      expect(check.isSettled, isTrue);
      expect(check.blocks, isFalse);
    });
  });

  group("the owner's publish screen", () {
    testWidgets('no plan: the card, and a Publish button that cannot fire',
        (tester) async {
      final repo = FakePublishRepository()
        ..subscriptionPayload = subscriptionPayloadFor(status: 'NONE');

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(_card, findsOneWidget);
      expect(find.text('Choose a plan to publish'), findsOneWidget);
      expect(_ctaOf(tester).onPressed, isNull);
      expect(repo.publishCalls, 0);
    });

    testWidgets('over the cap: the card names both numbers', (tester) async {
      final repo = FakePublishRepository()
        ..subscriptionPayload = subscriptionPayloadFor(
          status: 'ACTIVE',
          threeDDishCount: 12,
          threeDDishCap: 10,
        );

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.text('More 3D dishes than your plan covers'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('publish_subscription_gate_usage')),
        findsOneWidget,
      );
      expect(find.textContaining('12 / 10'), findsOneWidget);
      expect(_ctaOf(tester).onPressed, isNull);
    });

    testWidgets('on a plan: no card, and Publish works', (tester) async {
      final repo = FakePublishRepository()
        ..subscriptionPayload = subscriptionPayloadFor(status: 'ACTIVE');

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(_card, findsNothing);
      expect(_ctaOf(tester).onPressed, isNotNull);
    });

    testWidgets('a subscription read that fails leaves Publish alone',
        (tester) async {
      final repo = _FailingSubscription();

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(_card, findsNothing);
      expect(_ctaOf(tester).onPressed, isNotNull);
    });

    testWidgets('offline, the card says so instead of offering a dead button',
        (tester) async {
      final repo = FakePublishRepository()
        ..subscriptionPayload = subscriptionPayloadFor(status: 'NONE');

      await tester.pumpWidget(harness(repo, online: false));
      await tester.pumpAndSettle();

      final cta = tester.widget<ElevatedButton>(
        find.descendant(
          of: find.byKey(const ValueKey('publish_subscription_cta')),
          matching: find.byType(ElevatedButton),
        ),
      );
      expect(cta.onPressed, isNull);
      expect(find.text('Needs a connection'), findsOneWidget);
    });
  });

  group('press Publish, pay, and the run starts by itself', () {
    testWidgets('?start=1 does NOT publish past the paywall', (tester) async {
      final repo = FakePublishRepository()
        ..subscriptionPayload = subscriptionPayloadFor(status: 'NONE');

      await tester.pumpWidget(harness(repo, startPublish: true));
      await tester.pumpAndSettle();

      expect(_card, findsOneWidget);
      expect(repo.publishCalls, 0);
    });

    testWidgets('and fires the moment the plan is live', (tester) async {
      final repo = FakePublishRepository()
        ..subscriptionPayload = subscriptionPayloadFor(status: 'NONE');

      await tester.pumpWidget(harness(repo, startPublish: true));
      await tester.pumpAndSettle();
      expect(repo.publishCalls, 0);

      // What returning from the Subscription screen after a successful checkout
      // does: the row is re-read, and the intent the user pressed is still
      // armed.
      repo.subscriptionPayload = subscriptionPayloadFor(status: 'ACTIVE');
      await _containerOf(tester).read(subscriptionProvider.notifier).refresh();
      await tester.pumpAndSettle();

      expect(_card, findsNothing);
      expect(repo.publishCalls, 1);
    });

    testWidgets('?start=1 on a paid plan publishes once, as it always did',
        (tester) async {
      final repo = FakePublishRepository()
        ..subscriptionPayload = subscriptionPayloadFor(status: 'ACTIVE');

      await tester.pumpWidget(harness(repo, startPublish: true));
      await tester.pumpAndSettle();

      expect(repo.publishCalls, 1);
    });
  });

  group('the way back from the plans screen', () {
    /// The Subscription screen as the paywall opens it, with the checkout
    /// parked in [phase].
    Future<void> pumpPlans(
      WidgetTester tester, {
      required CheckoutPhase phase,
      required bool fromPublish,
    }) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final subscription =
          CatalogSubscription.fromMap(subscriptionPayloadFor(status: 'ACTIVE'));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          paymentsRepositoryProvider
              .overrideWithValue(FakePaymentsRepository()),
          checkoutAdapterProvider.overrideWithValue(FakeCheckoutAdapter()),
          subscriptionProvider
              .overrideWith(() => _FixedSubscription(subscription)),
          checkoutProvider.overrideWith(() => _FixedCheckout(phase)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SubscriptionBody(
              subscription: subscription,
              fromPublish: fromPublish,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    final back = find.byKey(const ValueKey('subscription_back_to_publish'));

    testWidgets('appears once the SERVER says the plan is active',
        (tester) async {
      await pumpPlans(tester, phase: CheckoutPhase.done, fromPublish: true);
      expect(back, findsOneWidget);
      expect(find.text('Back to publishing'), findsOneWidget);
    });

    testWidgets('not while the payment is only confirming', (tester) async {
      // The SDK may already have said "success"; the plan is not active until
      // the server says so, and offering the way back before then would send
      // the owner into a paywall that has not moved.
      for (final phase in const [
        CheckoutPhase.idle,
        CheckoutPhase.showingSdk,
        CheckoutPhase.activating,
        CheckoutPhase.confirming,
        CheckoutPhase.failed,
      ]) {
        await pumpPlans(tester, phase: phase, fromPublish: true);
        expect(back, findsNothing, reason: '$phase');
      }
    });

    testWidgets('never when the owner came from the header chip or Profile',
        (tester) async {
      await pumpPlans(tester, phase: CheckoutPhase.done, fromPublish: false);
      expect(back, findsNothing);
    });
  });
}

/// A checkout parked in one phase — the screen's own polling is not what this
/// file is about (checkout_notifier_test.dart owns it).
class _FixedCheckout extends CheckoutNotifier {
  _FixedCheckout(this.phase);
  final CheckoutPhase phase;

  @override
  CheckoutState build() => CheckoutState(phase: phase);
}

/// A subscription whose read never touches a repository.
class _FixedSubscription extends SubscriptionNotifier {
  _FixedSubscription(this.value);
  final CatalogSubscription value;

  @override
  Future<CatalogSubscription> build() async => value;

  @override
  Future<void> refresh() async => state = AsyncData(value);
}

/// A repository whose subscription read fails — the fail-open case.
class _FailingSubscription extends FakePublishRepository {
  @override
  Future<CatalogSubscription> subscription() async =>
      throw const CatalogFailure(
        code: 'OFFLINE',
        message: 'no connection',
        isOffline: true,
      );
}
