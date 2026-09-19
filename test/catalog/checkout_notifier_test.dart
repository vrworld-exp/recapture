// test/catalog/checkout_notifier_test.dart
//
// The owner's Pay flow, without a Razorpay and without a server.
//
// What this file most exists to pin:
//   • THE SDK'S SUCCESS IS NOT "PAID". After `success` the notifier is
//     `activating` and stays there until the subscription READ says ACTIVE;
//     the flip is judged against what the subscription was before.
//   • A timed-out poll is "being confirmed", never a failure or "unpaid" (B1).
//   • Cancelled goes back to idle; 503 is `unavailable`; a failure keeps the
//     SDK's code but never its prose on screen.
//   • No `prefill` reaches the adapter — ids, amount, description only.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/checkout_adapter.dart';
import 'package:recapture/application/catalog/checkout_notifier.dart';
import 'package:recapture/application/catalog/subscription_notifier.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/payments_repository.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/domain/entities/subscription_payment.dart';
import 'package:recapture/utils/analytics.dart';

import 'payments_fakes.dart';
import 'subscription_entity_test.dart' show subscriptionPayload;

/// A subscription whose next read the test controls.
class _ScriptedSubscription extends SubscriptionNotifier {
  _ScriptedSubscription(this.script);

  /// Each refresh pops the head; the last value repeats.
  final List<CatalogSubscription> script;
  int reads = 0;

  CatalogSubscription _next() {
    reads++;
    if (script.length > 1) return script.removeAt(0);
    return script.first;
  }

  @override
  Future<CatalogSubscription> build() async => _next();

  @override
  Future<void> refresh() async => state = AsyncData(_next());
}

CatalogSubscription sub(String status, {String? periodEnd, int? daysLeft}) =>
    CatalogSubscription.fromMap(subscriptionPayload(
      status: status,
      periodEnd: periodEnd ?? '2026-10-18T00:00:00.000Z',
      daysLeft: daysLeft,
      planId: status == 'ACTIVE' || status == 'GRACE' ? 'TASTE' : null,
      planName: status == 'ACTIVE' || status == 'GRACE' ? 'Taste plan' : null,
    ));

void main() {
  // The notifier wires an AppLifecycleListener, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePaymentsRepository repo;
  late FakeCheckoutAdapter adapter;
  late List<(String, Map<String, Object?>)> events;

  setUp(() {
    repo = FakePaymentsRepository()
      ..onCreateOrder = () => CheckoutOrder.fromMap(orderPayload());
    adapter = FakeCheckoutAdapter();
    events = [];
    Analytics.testSink = (name, props) => events.add((name, props));
  });

  tearDown(() => Analytics.testSink = null);

  ProviderContainer container(
    List<CatalogSubscription> script, {
    Duration budget = const Duration(seconds: 30),
  }) {
    final c = ProviderContainer(overrides: [
      paymentsRepositoryProvider.overrideWithValue(repo),
      checkoutAdapterProvider.overrideWithValue(adapter),
      subscriptionProvider.overrideWith(() => _ScriptedSubscription(script)),
      checkoutPollBackoffProvider.overrideWithValue(const [Duration.zero]),
      checkoutPollBudgetProvider.overrideWithValue(budget),
    ]);
    addTearDown(c.dispose);
    // The screen watches both; without a listener the autoDispose providers
    // would be rebuilt between reads and the script would be consumed twice.
    c.listen(subscriptionProvider, (_, __) {}, fireImmediately: true);
    c.listen(checkoutProvider, (_, __) {}, fireImmediately: true);
    return c;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('success → activating → done once the read says ACTIVE, not before',
      () async {
    final c = container([sub('NONE'), sub('NONE'), sub('ACTIVE')]);
    // Prime the subscription so the baseline exists.
    await c.read(subscriptionProvider.future);

    final pay = c.read(checkoutProvider.notifier).pay(
          planId: PlanId.taste,
          interval: BillingInterval.monthly,
        );
    await settle();
    expect(c.read(checkoutProvider).phase, CheckoutPhase.showingSdk);
    expect(adapter.opened.single, {
      'keyId': 'rzp_test_vitest0000000',
      'orderId': 'order_test_1',
      'amountPaise': 119900,
      'description': 'Taste plan · monthly',
    });
    // No contact, no email, no phone ever reaches the sheet.
    expect(adapter.opened.single.keys, isNot(contains('prefill')));

    adapter.complete(const CheckoutOutcome.success('pay_1'));
    await pay;
    await settle();

    final state = c.read(checkoutProvider);
    expect(state.phase, CheckoutPhase.done);
    expect(state.order?.providerOrderId, 'order_test_1');
    expect(c.read(subscriptionProvider).valueOrNull?.status,
        SubscriptionStatus.active);
    expect(repo.calls, ['createOrder:TASTE:MONTHLY']);
    expect(events.map((e) => e.$1).toList(), [
      'checkout_opened',
      'checkout_result',
      'checkout_activation_confirmed',
    ]);
    expect(events[0].$2, {
      'plan_id': 'TASTE',
      'interval': 'MONTHLY',
      'amount_paise': 119900,
      'surface': 'owner',
    });
    expect(events[1].$2, {'result': 'success'});
  });

  test(
      'an early renewal is done only when periodEnd MOVES, not on the old ACTIVE',
      () async {
    final before = sub('ACTIVE', periodEnd: '2026-10-18T00:00:00.000Z');
    final c = container([
      before,
      before, // first poll: unchanged
      sub('ACTIVE', periodEnd: '2026-11-17T00:00:00.000Z'),
    ]);
    await c.read(subscriptionProvider.future);
    adapter.outcome = const CheckoutOutcome.success('pay_2');

    await c.read(checkoutProvider.notifier).pay(
          planId: PlanId.taste,
          interval: BillingInterval.monthly,
        );
    await settle();

    expect(c.read(checkoutProvider).phase, CheckoutPhase.done);
    expect(
      c.read(subscriptionProvider).valueOrNull?.periodEnd?.toIso8601String(),
      '2026-11-17T00:00:00.000Z',
    );
  });

  test('polling for the whole budget without a flip ends in "confirming" (B1)',
      () async {
    final c = container([sub('GRACE')], budget: Duration.zero);
    await c.read(subscriptionProvider.future);
    adapter.outcome = const CheckoutOutcome.success('pay_3');

    await c.read(checkoutProvider.notifier).pay(
          planId: PlanId.taste,
          interval: BillingInterval.monthly,
        );
    await settle();

    final state = c.read(checkoutProvider);
    expect(state.phase, CheckoutPhase.confirming);
    expect(state.failureCode, isNull);
    // The button is a button again after dismiss; nothing says "unpaid".
    c.read(checkoutProvider.notifier).dismiss();
    expect(c.read(checkoutProvider).phase, CheckoutPhase.idle);
  });

  test('cancelled goes back to idle and keeps nothing to remember', () async {
    final c = container([sub('NONE')]);
    adapter.outcome = const CheckoutOutcome.cancelled();

    await c.read(checkoutProvider.notifier).pay(
          planId: PlanId.signature,
          interval: BillingInterval.yearly,
        );

    expect(c.read(checkoutProvider).phase, CheckoutPhase.idle);
    expect(events.last.$1, 'checkout_result');
    expect(events.last.$2, {'result': 'cancelled'});
    // The next tap asks the server again, which hands the same order back.
    await c.read(checkoutProvider.notifier).pay(
          planId: PlanId.signature,
          interval: BillingInterval.yearly,
        );
    expect(repo.calls.where((c) => c.startsWith('createOrder')).length, 2);
  });

  test('a 503 is `unavailable`; another failure is `failed` with its code',
      () async {
    final c = container([sub('NONE')]);

    repo.onCreateOrder = () => throw const CatalogFailure(
          code: PaymentErrorCodes.paymentsUnavailable,
          message: 'x',
          statusCode: 503,
        );
    await c.read(checkoutProvider.notifier).pay(
          planId: PlanId.taste,
          interval: BillingInterval.monthly,
        );
    expect(c.read(checkoutProvider).phase, CheckoutPhase.unavailable);
    expect(adapter.opened, isEmpty);

    c.read(checkoutProvider.notifier).dismiss();
    repo.onCreateOrder = () => CheckoutOrder.fromMap(orderPayload());
    adapter.outcome =
        const CheckoutOutcome.failed(code: '2', message: 'Bank declined');
    await c.read(checkoutProvider.notifier).pay(
          planId: PlanId.taste,
          interval: BillingInterval.monthly,
        );
    final state = c.read(checkoutProvider);
    expect(state.phase, CheckoutPhase.failed);
    expect(state.failureCode, '2');
    expect(events.last.$1, 'checkout_result');
    expect(events.last.$2, {'result': 'failed'});
  });

  test('unsupported adapter: failed with UNSUPPORTED and the analytics result',
      () async {
    adapter = FakeCheckoutAdapter(
      supported: false,
      outcome: const CheckoutOutcome.unsupported(),
    );
    final c = container([sub('NONE')]);
    await c.read(checkoutProvider.notifier).pay(
          planId: PlanId.taste,
          interval: BillingInterval.monthly,
        );
    expect(c.read(checkoutProvider).failureCode, 'UNSUPPORTED');
    expect(events.last.$1, 'checkout_result');
    expect(events.last.$2, {'result': 'unsupported'});
  });

  test('a second tap while the sheet is up does nothing', () async {
    final c = container([sub('NONE')]);
    final first = c.read(checkoutProvider.notifier).pay(
          planId: PlanId.taste,
          interval: BillingInterval.monthly,
        );
    await settle();
    await c.read(checkoutProvider.notifier).pay(
          planId: PlanId.taste,
          interval: BillingInterval.monthly,
        );
    expect(repo.calls.where((c) => c.startsWith('createOrder')).length, 1);
    expect(adapter.opened, hasLength(1));
    adapter.complete(const CheckoutOutcome.cancelled());
    await first;
  });

  test('backgrounded mid-sheet: the resume re-read can finish the flow alone',
      () async {
    // The webhook landed while a UPI app had the screen; the SDK callback
    // arrives later. The re-read on resume must already say done.
    final c = container([sub('NONE'), sub('ACTIVE')]);
    await c.read(subscriptionProvider.future);
    final pay = c.read(checkoutProvider.notifier).pay(
          planId: PlanId.taste,
          interval: BillingInterval.monthly,
        );
    await settle();
    expect(c.read(checkoutProvider).phase, CheckoutPhase.showingSdk);

    c.read(checkoutProvider.notifier).debugLifecycle(hidden: true);
    c.read(checkoutProvider.notifier).debugLifecycle(hidden: false);
    await settle();
    expect(c.read(checkoutProvider).phase, CheckoutPhase.done);

    // The late SDK answer changes nothing.
    adapter.complete(const CheckoutOutcome.success('pay_late'));
    await pay;
    expect(c.read(checkoutProvider).phase, CheckoutPhase.done);
    expect(
        events.where((e) => e.$1 == 'checkout_activation_confirmed').length, 1);
  });
}
