// test/admin/admin_payment_journal_test.dart
//
// The admin payment journal and the panel's new actions. What this file most
// exists to pin:
//   • THE FILTERS FIT A PHONE. Every chip on both tabs is on screen and
//     tappable at 360 dp — the bug this screen was reworked for.
//   • The Payments tab opens on "Needs attention", badges the count, and a
//     row shows restaurant, stage and owner name — never contact.
//   • The attempt screen draws the server's five steps; "Check with Razorpay"
//     is one tap and shows what Razorpay said; "Apply to catalog" needs a
//     20-character reason and is offered only when the server allows it.
//   • The panel shows the owner (Contact opens the audited sheet), the
//     attempts, "Start plan" (price prefilled; a different amount needs the
//     override + 20 characters) and "Start trial" only when one is available.
//   • The Plans search reaches the server as `q`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/payments_repository.dart';
import 'package:recapture/domain/entities/admin_payment_attempt.dart';
import 'package:recapture/domain/entities/subscription_payment.dart';
import 'package:recapture/presentation/screens/admin/admin_payment_attempt_screen.dart';
import 'package:recapture/presentation/screens/admin/admin_subscription_detail_screen.dart';
import 'package:recapture/presentation/screens/admin/admin_subscriptions_screen.dart';

import '../catalog/payments_fakes.dart';
import '../catalog/subscription_entity_test.dart' show subscriptionPayload;

const _order = 'order_test_9';

Map<String, dynamic> _step(String key, String state, String detail) => {
      'key': key,
      'state': state,
      'at': state == 'DONE' ? '2026-09-24T08:30:00.000Z' : null,
      'detail': detail,
    };

Map<String, dynamic> attemptPayload({
  String orderId = _order,
  String stage = 'NOT_COMPLETED',
  bool needsAttention = false,
  bool canSync = true,
  bool canForceApply = false,
  int? paidPaise,
  String? outcomeNote,
  List<Map<String, dynamic>>? steps,
  String startedAt = '2026-09-24T08:30:00.000Z',
  Map<String, int>? priceChange,
  int daysForfeitedOnApply = 0,
  bool canRefund = false,
  bool refundNeedsOverride = true,
}) =>
    {
      'paymentRecordId': paidPaise == null ? null : '66f0000000000000000000p1',
      'priceChange': priceChange,
      'daysForfeitedOnApply': daysForfeitedOnApply,
      'canRefund': canRefund,
      'refundNeedsOverride': refundNeedsOverride,
      'orderId': orderId,
      'catalog': {'id': 'c1', 'name': 'blue cafe', 'deleted': false},
      'owner': {'id': 'u1', 'displayName': 'Asha Rao', 'hasAvatar': false},
      'initiatedBy': {'userId': 'u1', 'role': 'USER', 'displayName': 'Asha Rao'},
      'planId': 'TASTE',
      'planName': 'Taste plan',
      'interval': 'MONTHLY',
      'quotedPaise': 119900,
      'paidPaise': paidPaise,
      'providerPaymentId': paidPaise == null ? null : 'pay_x1',
      'startedAt': startedAt,
      'expiresAt': '2026-09-25T08:30:00.000Z',
      'recordedAt': null,
      'recordedVia': null,
      'appliedAt': null,
      'outcomeNote': outcomeNote,
      'resolution': null,
      'refunded': false,
      'catalogReflects': null,
      'subscription': null,
      'stage': stage,
      'needsAttention': needsAttention,
      'steps': steps ??
          [
            _step('STARTED', 'DONE', 'Order $orderId for ₹1,199.'),
            _step('PROVIDER', 'UNKNOWN', 'No payment reached our ledger.'),
            _step('RECORDED', 'SKIPPED', 'Nothing recorded.'),
            _step('APPLIED', 'SKIPPED', 'No plan applied.'),
            _step('CATALOG', 'SKIPPED', 'Not changed by this order.'),
          ],
      'canSync': canSync,
      'canForceApply': canForceApply,
    };

PaymentAttempt _attempt({
  String stage = 'NOT_COMPLETED',
  bool needsAttention = false,
  bool canSync = true,
  bool canForceApply = false,
  int? paidPaise,
  String? outcomeNote,
  List<Map<String, dynamic>>? steps,
  Map<String, int>? priceChange,
  int daysForfeitedOnApply = 0,
  bool canRefund = false,
  bool refundNeedsOverride = true,
}) =>
    PaymentAttempt.fromMap(attemptPayload(
      stage: stage,
      needsAttention: needsAttention,
      canSync: canSync,
      canForceApply: canForceApply,
      paidPaise: paidPaise,
      outcomeNote: outcomeNote,
      steps: steps,
      priceChange: priceChange,
      daysForfeitedOnApply: daysForfeitedOnApply,
      canRefund: canRefund,
      refundNeedsOverride: refundNeedsOverride,
    ));

final _completedSteps = [
  _step('STARTED', 'DONE', 'Order $_order for ₹1,199.'),
  _step('PROVIDER', 'DONE', 'Razorpay captured ₹1,199 as payment pay_x1.'),
  _step('RECORDED', 'DONE', "Recorded by an admin's check with Razorpay."),
  _step('APPLIED', 'DONE', 'Taste plan, monthly, applied.'),
  _step('CATALOG', 'DONE', 'The catalog shows this payment.'),
];

AdminSubscriptionDetail _detail({
  String status = 'ACTIVE',
  bool trialAvailable = false,
  List<PaymentAttempt> attempts = const [],
  List<Map<String, dynamic>> attemptPayloads = const [],
}) =>
    AdminSubscriptionDetail.fromMap({
      'catalog': {
        'id': 'c1',
        'name': 'blue cafe',
        'deleted': false,
        'businessName': 'Blue Cafe Pvt',
        'status': 'PUBLISHED',
        'publicUrl': 'https://menu.example/blue-cafe',
        'lastPublishedAt': '2026-09-20T10:00:00.000Z',
        'onMirage': true,
        'createdAt': '2026-08-01T10:00:00.000Z',
      },
      'owner': {'id': 'u1', 'displayName': 'Asha Rao', 'hasAvatar': false},
      'subscription': subscriptionPayload(
        status: status,
        planId: status == 'NONE' ? null : 'TASTE',
        planName: status == 'NONE' ? null : 'Taste plan',
        trialAvailable: trialAvailable,
      ),
      'payments': const [],
      'attempts': [
        for (final a in attempts) attemptPayload(orderId: a.orderId),
        ...attemptPayloads,
      ],
      'arEntitlementSyncedAt': null,
    });

Widget _harness(FakePaymentsRepository repo, {String initial = '/'}) {
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/', builder: (_, __) => const AdminSubscriptionsScreen()),
      GoRoute(
        path: AppRoutes.adminPaymentAttempt,
        builder: (_, state) => AdminPaymentAttemptScreen(
          orderId: state.pathParameters['orderId']!,
        ),
      ),
      GoRoute(
        path: AppRoutes.adminSubscriptionDetail,
        builder: (_, state) => AdminSubscriptionDetailScreen(
          catalogId: state.pathParameters['catalogId']!,
          initialReference: state.uri.queryParameters['ref'],
        ),
      ),
    ],
  );
  return ProviderScope(
    overrides: [paymentsRepositoryProvider.overrideWithValue(repo)],
    child: MaterialApp.router(routerConfig: router),
  );
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Every chip is fully inside the 360-wide screen and hit-testable.
void _expectAllOnScreen(WidgetTester tester, List<String> keys) {
  for (final key in keys) {
    final finder = find.byKey(ValueKey('admin_filter_$key'));
    expect(finder, findsOneWidget, reason: key);
    final rect = tester.getRect(finder);
    expect(rect.left, greaterThanOrEqualTo(0), reason: '$key starts off screen');
    expect(rect.right, lessThanOrEqualTo(360), reason: '$key is cut off');
    expect(finder.hitTestable(), findsOneWidget, reason: '$key cannot be tapped');
  }
}

void main() {
  group('the filters fit a phone', () {
    testWidgets('every Payments and Plans chip is on screen at 360 dp',
        (tester) async {
      _phone(tester);
      await tester.pumpWidget(_harness(FakePaymentsRepository()));
      await tester.pumpAndSettle();

      _expectAllOnScreen(tester, [
        for (final f in AdminPaymentFilter.values) f.name,
      ]);

      await tester.tap(find.byKey(const ValueKey('admin_tab_plans')));
      await tester.pumpAndSettle();
      _expectAllOnScreen(tester, const [
        'all',
        'expiring7d',
        'grace',
        'paused',
        'paused90d',
        'trial',
      ]);
      // The last chip — the one the old bar cut off — actually selects.
      await tester.tap(find.byKey(const ValueKey('admin_filter_trial')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('the Payments tab', () {
    testWidgets('opens on Needs attention with a badge; a row names the owner',
        (tester) async {
      final repo = FakePaymentsRepository()
        ..attemptPages = {
          AdminPaymentFilter.attention: PaymentAttemptPage(
            items: [
              _attempt(
                stage: 'FLAGGED',
                needsAttention: true,
                paidPaise: 119800,
                outcomeNote: 'AMOUNT_MISMATCH',
              ),
            ],
            nextCursor: null,
          ),
        };
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      expect(repo.calls, contains('attempts:attention:'));
      expect(find.byKey(const ValueKey('admin_attention_badge')), findsOneWidget);
      expect(find.text('blue cafe'), findsOneWidget);
      expect(find.text('Flagged'), findsOneWidget);
      expect(find.textContaining('Owner: Asha Rao'), findsOneWidget);
      expect(find.textContaining('₹1,198'), findsOneWidget);
      expect(find.textContaining('@'), findsNothing);
      expect(find.textContaining('+91'), findsNothing);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('attempts:all:'));
      expect(find.text('Nothing here.'), findsOneWidget);
    });

    testWidgets('a row opens the attempt', (tester) async {
      final attempt = _attempt(stage: 'NOT_COMPLETED');
      final repo = FakePaymentsRepository()
        ..attemptPages = {
          AdminPaymentFilter.attention:
              PaymentAttemptPage(items: [attempt], nextCursor: null),
        }
        ..attempts = {_order: attempt};
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin_attempt_$_order')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_attempt_detail')), findsOneWidget);
      expect(repo.calls, contains('attempt:$_order'));
    });
  });

  group('the attempt screen', () {
    testWidgets('draws the five steps and who is involved', (tester) async {
      _tall(tester);
      final repo = FakePaymentsRepository()..attempts = {_order: _attempt()};
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminPayments}/$_order'));
      await tester.pumpAndSettle();

      for (final key in ['started', 'provider', 'recorded', 'applied', 'catalog']) {
        expect(find.byKey(ValueKey('admin_step_$key')), findsOneWidget);
      }
      expect(find.text('Razorpay received the money'), findsOneWidget);
      expect(find.text('No payment reached our ledger.'), findsOneWidget);
      expect(find.text('Asha Rao'), findsOneWidget);
      expect(find.text('Asha Rao · owner'), findsOneWidget);
      expect(find.text(_order), findsOneWidget);
      expect(find.byKey(const ValueKey('admin_attempt_contact')), findsOneWidget);
      // Not flagged: no override offered.
      expect(find.byKey(const ValueKey('admin_attempt_apply')), findsNothing);
    });

    testWidgets('Check with Razorpay is one tap and shows what Razorpay said',
        (tester) async {
      _tall(tester);
      final repo = FakePaymentsRepository()
        ..attempts = {_order: _attempt()}
        ..onSync = (orderId) => PaymentSyncResult(
              outcome: PaymentSyncOutcome.applied,
              provider: ProviderSnapshot.tryFrom({
                'orderStatus': 'paid',
                'orderAmountPaise': 119900,
                'payments': [
                  {'id': 'pay_x1', 'status': 'captured', 'amountPaise': 119900},
                ],
                'checkedAt': '2026-09-24T09:00:00.000Z',
              }),
              attempt: _attempt(
                stage: 'COMPLETED',
                canSync: false,
                paidPaise: 119900,
                steps: _completedSteps,
              ),
            );
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminPayments}/$_order'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('admin_attempt_sync')));
      await tester.pump();
      await tester.pump();

      expect(repo.calls, contains('sync:$_order'));
      expect(find.textContaining('Razorpay confirmed the payment'), findsOneWidget);
      expect(find.byKey(const ValueKey('admin_attempt_provider')), findsOneWidget);
      expect(find.textContaining('pay_x1 · captured'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      // Done: the button is gone because the server says so.
      expect(find.byKey(const ValueKey('admin_attempt_sync')), findsNothing);
    });

    testWidgets('a 503 from the check is a sentence, not a crash',
        (tester) async {
      _tall(tester);
      final repo = FakePaymentsRepository()
        ..attempts = {_order: _attempt()}
        ..syncFailure = const CatalogFailure(
          code: PaymentErrorCodes.paymentsUnavailable,
          message: 'server prose',
          statusCode: 503,
        );
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminPayments}/$_order'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin_attempt_sync')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining("Couldn't reach the payment service"),
          findsOneWidget);
      expect(find.textContaining('server prose'), findsNothing);
    });

    testWidgets('Apply to catalog needs a 20-character reason',
        (tester) async {
      _tall(tester);
      final repo = FakePaymentsRepository()
        ..attempts = {
          _order: _attempt(
            stage: 'FLAGGED',
            needsAttention: true,
            canSync: false,
            canForceApply: true,
            paidPaise: 119800,
            outcomeNote: 'AMOUNT_MISMATCH',
          ),
        }
        ..onForceApply = (orderId, note) => _attempt(
              stage: 'RESOLVED',
              canSync: false,
              paidPaise: 119800,
              outcomeNote: 'AMOUNT_MISMATCH',
              steps: _completedSteps,
            );
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminPayments}/$_order'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Order was for ₹1,199'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('admin_attempt_apply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_apply_dialog')), findsOneWidget);
      expect(find.textContaining('Held back as AMOUNT_MISMATCH'), findsOneWidget);
      final confirm = find.byKey(const ValueKey('admin_apply_confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

      await tester.enterText(
          find.byKey(const ValueKey('admin_apply_note')), 'too short');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('admin_apply_note')),
          'Owner paid ₹1 less by mistake; confirmed on call.');
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pump();
      await tester.pump();

      expect(repo.calls, contains('forceApply:$_order'));
      expect(find.textContaining('Applied — the plan is active'), findsOneWidget);
      expect(find.text('Fixed by admin'), findsOneWidget);
    });
  });

  group('the restaurant panel', () {
    testWidgets('shows the owner, the catalog and its attempts',
        (tester) async {
      _tall(tester);
      final repo = FakePaymentsRepository()
        ..detail = _detail(attempts: [_attempt()]);
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();

      expect(find.text('Owner: Asha Rao'), findsOneWidget);
      expect(find.byKey(const ValueKey('admin_owner_contact')), findsOneWidget);
      expect(find.textContaining('Business: Blue Cafe Pvt'), findsOneWidget);
      expect(find.textContaining('Menu published · published'), findsOneWidget);
      expect(find.textContaining('· on Mirage ·'), findsOneWidget);
      expect(find.byKey(const ValueKey('admin_attempt_$_order')), findsOneWidget);
      expect(find.byKey(const ValueKey('admin_no_attempts')), findsNothing);
    });

    testWidgets('Start plan prefills the price; a different amount needs the '
        'override and 20 characters', (tester) async {
      _tall(tester);
      final repo = FakePaymentsRepository()..detail = _detail(status: 'ACTIVE');
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('admin_start_plan')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_start_plan_dialog')), findsOneWidget);
      // A period is running: the forfeit rule is said out loud.
      expect(find.byKey(const ValueKey('admin_start_forfeit')), findsOneWidget);
      final amount = tester.widget<TextField>(
          find.byKey(const ValueKey('admin_start_amount')));
      expect(amount.controller!.text, '1199');

      final confirm = find.byKey(const ValueKey('admin_start_plan_confirm'));
      // No reference yet.
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(
          find.byKey(const ValueKey('admin_start_reference')), 'pay_Q1w2e3');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

      await tester.enterText(
          find.byKey(const ValueKey('admin_start_amount')), '1000');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('admin_start_override')));
      await tester.enterText(find.byKey(const ValueKey('admin_start_note')),
          'Festival discount agreed with the owner.');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(repo.plansStarted.single, {
        'planId': 'TASTE',
        'interval': 'MONTHLY',
        'amountPaise': 100000,
        'method': 'UPI',
        'reference': 'pay_Q1w2e3',
        'note': 'Festival discount agreed with the owner.',
        'override': true,
      });
      expect(find.textContaining('Plan started'), findsOneWidget);
      // Re-read after the action, like every other one.
      expect(repo.calls.where((c) => c == 'detail:c1').length, 2);
    });

    testWidgets('Start trial appears only when a trial is available',
        (tester) async {
      _tall(tester);
      final repo = FakePaymentsRepository()..detail = _detail(status: 'ACTIVE');
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_start_trial')), findsNothing);

      repo.detail = _detail(status: 'NONE', trialAvailable: true);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin_start_trial')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin_start_trial_confirm')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('startTrial:c1'));
      expect(find.textContaining('Trial started.'), findsOneWidget);
    });
  });

  group('edge cases on the attempt screen', () {
    testWidgets('#3 a duplicate puts Refund first and Apply says what it throws away',
        (tester) async {
      _tall(tester);
      final repo = FakePaymentsRepository()
        ..attempts = {
          _order: _attempt(
            stage: 'FLAGGED',
            needsAttention: true,
            canSync: false,
            canForceApply: true,
            paidPaise: 119900,
            outcomeNote: 'DUPLICATE_SUSPECTED',
            daysForfeitedOnApply: 28,
            canRefund: true,
            refundNeedsOverride: false,
          ),
        };
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminPayments}/$_order'));
      await tester.pumpAndSettle();

      final refund = find.byKey(const ValueKey('admin_attempt_refund'));
      expect(find.text('Refund duplicate…'), findsOneWidget);
      expect(find.text('Apply anyway…'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('admin_attempt_apply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_apply_forfeit')), findsOneWidget);
      expect(find.textContaining('28 days left on the current period'),
          findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(refund);
      await tester.pumpAndSettle();
      // A flagged duplicate: no override, 10 characters.
      expect(find.byKey(const ValueKey('admin_attempt_refund_override')),
          findsNothing);
      final confirm = find.byKey(const ValueKey('admin_attempt_refund_confirm'));
      await tester.enterText(
          find.byKey(const ValueKey('admin_attempt_refund_note')), 'short');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('admin_attempt_refund_note')),
          'Paid twice on 24 Sep');
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(repo.refunds.single, {
        'id': '66f0000000000000000000p1',
        'note': 'Paid twice on 24 Sep',
        'override': false,
      });
    });

    testWidgets('#5 a changed price is shown and must be confirmed before Check',
        (tester) async {
      _tall(tester);
      final repo = FakePaymentsRepository()
        ..attempts = {
          _order: _attempt(
            priceChange: {'quotedPaise': 300, 'currentPaise': 119900},
          ),
        }
        ..onSync = (orderId) => PaymentSyncResult(
              outcome: PaymentSyncOutcome.applied,
              provider: null,
              attempt: _attempt(stage: 'COMPLETED', canSync: false),
            );
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminPayments}/$_order'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_attempt_price_change')),
          findsOneWidget);

      // Backing out sends nothing.
      await tester.tap(find.byKey(const ValueKey('admin_attempt_sync')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_price_dialog')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.calls.where((c) => c.startsWith('sync:')), isEmpty);

      await tester.tap(find.byKey(const ValueKey('admin_attempt_sync')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin_price_accept')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('sync:$_order:accept'));
    });

    testWidgets('#6 a Check that finds an authorized payment offers Capture',
        (tester) async {
      _tall(tester);
      final repo = FakePaymentsRepository()
        ..attempts = {_order: _attempt()}
        // Parenthesised: an arrow closure mid-cascade swallows the next `..`.
        ..onSync = ((orderId) => PaymentSyncResult(
              outcome: PaymentSyncOutcome.notCaptured,
              provider: null,
              capturable: (paymentId: 'pay_auth', amountPaise: 119900),
              attempt: _attempt(),
            ))
        ..onCapture = ((orderId) => _attempt(
              stage: 'COMPLETED',
              canSync: false,
              paidPaise: 119900,
              steps: _completedSteps,
            ));
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminPayments}/$_order'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_attempt_capture')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('admin_attempt_sync')));
      await tester.pumpAndSettle();
      expect(find.textContaining('authorized a payment but never captured'),
          findsOneWidget);
      expect(find.text('Capture ₹1,199'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('admin_attempt_capture')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('capture:$_order'));
      expect(find.text('Completed'), findsOneWidget);
    });
  });

  group('#8 Find a payment', () {
    testWidgets('an id on the ledger opens its entry', (tester) async {
      _tall(tester);
      final repo = FakePaymentsRepository()
        ..lookupResult = const PaymentLookupOnLedger(_order)
        ..attempts = {_order: _attempt()};
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('admin_lookup_field')), 'pay_known');
      await tester.tap(find.byKey(const ValueKey('admin_lookup_go')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('lookup:pay_known'));
      expect(find.byKey(const ValueKey('admin_attempt_detail')), findsOneWidget);
    });

    testWidgets('a payment we never saw leads to Start plan with the id filled in',
        (tester) async {
      _tall(tester);
      final repo = FakePaymentsRepository()
        ..lookupResult = const PaymentLookupNotOnLedger(
          id: 'pay_stranger',
          status: 'captured',
          amountPaise: 119900,
          orderId: 'order_stranger',
          catalogId: 'c1',
          catalogName: 'blue cafe',
        )
        ..detail = _detail(status: 'PAUSED');
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('admin_lookup_field')), 'pay_stranger');
      await tester.tap(find.byKey(const ValueKey('admin_lookup_go')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_lookup_not_on_ledger')),
          findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('admin_lookup_start_plan')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_record_reference')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('admin_record_reference_start')));
      await tester.pumpAndSettle();
      final reference = tester.widget<TextField>(
          find.byKey(const ValueKey('admin_start_reference')));
      expect(reference.controller!.text, 'pay_stranger');
    });
  });

  group('#2 Start plan warns about a recent online payment', () {
    testWidgets('an applied payment this month is named in the dialog',
        (tester) async {
      _tall(tester);
      final repo = FakePaymentsRepository()
        ..detail = _detail(attemptPayloads: [
          attemptPayload(
            orderId: 'order_recent',
            stage: 'COMPLETED',
            canSync: false,
            paidPaise: 119900,
            startedAt: DateTime.now()
                .subtract(const Duration(days: 3))
                .toUtc()
                .toIso8601String(),
          ),
        ]);
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin_start_plan')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_start_recent_online')),
          findsOneWidget);
    });
  });

  group('the Plans search', () {
    testWidgets('reaches the server as q after the debounce', (tester) async {
      final repo = FakePaymentsRepository();
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin_tab_plans')));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const ValueKey('admin_subscriptions_search')), 'asha');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('subscriptions:all::q=asha'));
      expect(find.textContaining('No restaurant or owner matches "asha"'),
          findsOneWidget);
    });
  });
}
