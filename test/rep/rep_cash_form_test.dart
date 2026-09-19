// test/rep/rep_cash_form_test.dart
//
// Door 3, the rep's half. What this file most exists to pin:
//   • THE REP HAS NO PAY, NO REFUND, NO "MARK PAID" — one button, and it files
//     a REQUEST. The card says "Awaiting admin verification" while it waits.
//   • RUPEES IN, INTEGER PAISE OUT: ₹1,199.50 → 119950; ₹1,199.999 is refused
//     at validation, never rounded.
//   • OFFLINE: the submit is disabled with a reason, never queued (E40).
//   • A pending request makes the sheet read-only (§7 rule 3).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/data/repositories/payments_repository.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/domain/entities/subscription_payment.dart';
import 'package:recapture/presentation/widgets/rep/rep_cash_payment_sheet.dart';

import '../catalog/payments_fakes.dart';

const kCatalogId = 'c1';

Widget _harness(
  FakePaymentsRepository repo, {
  bool online = true,
  PlanId? currentPlan,
}) =>
    ProviderScope(
      overrides: [
        paymentsRepositoryProvider.overrideWithValue(repo),
        isOnlineProvider.overrideWithValue(online),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                key: const ValueKey('open'),
                onPressed: () => showRepCashPaymentSheet(
                  context,
                  catalogId: kCatalogId,
                  restaurantName: 'Blue Cafe',
                  plans: PlanCatalog.bundledDefault,
                  currentPlan: currentPlan,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  // Tall enough that the whole sheet is on screen; the form scrolls on a
  // phone but a test tapping an off-screen button proves nothing.
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('rep_cash_submit'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  group('parseRupeesToPaise', () {
    test('two decimals at most, integer paise out', () {
      expect(parseRupeesToPaise('1199'), 119900);
      expect(parseRupeesToPaise('1,199'), 119900);
      expect(parseRupeesToPaise('₹1,199.50'), 119950);
      expect(parseRupeesToPaise('1199.5'), 119950);
      expect(parseRupeesToPaise('0.01'), 1);
      expect(parseRupeesToPaise('1199.999'), isNull);
      expect(parseRupeesToPaise('0'), isNull);
      expect(parseRupeesToPaise(''), isNull);
      expect(parseRupeesToPaise('abc'), isNull);
      expect(parseRupeesToPaise('-5'), isNull);
    });

    test('formatPaise shows whole rupees plain and paise with two decimals',
        () {
      expect(formatPaise(119900), '₹1,199');
      expect(formatPaise(119950), '₹1,199.50');
      expect(formatPaise(1007160), '₹10,071.60');
      expect(formatPaise(5), '₹0.05');
    });
  });

  group('the cash sheet', () {
    testWidgets(
        'files a request with the plan price pre-filled and nothing else',
        (tester) async {
      final repo = FakePaymentsRepository();
      await tester.pumpWidget(_harness(repo));
      await _open(tester);

      expect(find.byKey(const ValueKey('rep_cash_form')), findsOneWidget);
      // Pre-filled with the plan's price so ₹1,000-for-₹1,199 is a choice.
      final amount = tester
          .widget<TextFormField>(find.byKey(const ValueKey('rep_cash_amount')));
      expect(amount.controller?.text, '1199');
      // No Pay / refund / mark-paid anywhere on this surface.
      for (final word in const ['Pay', 'Refund', 'Mark paid', 'Mark as paid']) {
        expect(find.widgetWithText(ElevatedButton, word), findsNothing);
        expect(find.widgetWithText(TextButton, word), findsNothing);
      }

      await tester.enterText(
          find.byKey(const ValueKey('rep_cash_reference')), 'UPI-778');
      await _submit(tester);

      expect(repo.submitted, hasLength(1));
      final request = repo.submitted.single;
      expect(request.planId, PlanId.taste);
      expect(request.interval, BillingInterval.monthly);
      expect(request.amountPaise, 119900);
      expect(request.method, ManualMethod.cash);
      expect(request.reference, 'UPI-778');
      expect(request.toBody(), {
        'planId': 'TASTE',
        'interval': 'MONTHLY',
        'amountPaise': 119900,
        'method': 'CASH',
        'reference': 'UPI-778',
      });
      expect(
          find.textContaining('awaiting admin verification'), findsOneWidget);
      expect(find.byKey(const ValueKey('rep_cash_form')), findsNothing);
    });

    testWidgets('₹1,199.50 becomes 119950 paise; ₹1,199.999 is refused',
        (tester) async {
      final repo = FakePaymentsRepository();
      await tester.pumpWidget(_harness(repo));
      await _open(tester);

      await tester.enterText(
          find.byKey(const ValueKey('rep_cash_amount')), '1199.999');
      await tester.enterText(
          find.byKey(const ValueKey('rep_cash_reference')), 'r1');
      await _submit(tester);
      expect(repo.submitted, isEmpty);
      expect(find.textContaining('two decimals at most'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('rep_cash_amount')), '1199.50');
      await _submit(tester);
      expect(repo.submitted.single.amountPaise, 119950);
    });

    testWidgets('the yearly toggle re-quotes the pre-filled amount',
        (tester) async {
      final repo = FakePaymentsRepository();
      await tester.pumpWidget(_harness(repo, currentPlan: PlanId.signature));
      await _open(tester);
      final amount = find.byKey(const ValueKey('rep_cash_amount'));
      expect(tester.widget<TextFormField>(amount).controller?.text, '1799');

      await tester.tap(find.text('Yearly'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(amount).controller?.text,
        '15111.60',
      );
      expect(find.textContaining('Plan price ₹15,111.60'), findsOneWidget);
    });

    testWidgets('offline: the submit is disabled with a reason, nothing queued',
        (tester) async {
      final repo = FakePaymentsRepository();
      await tester.pumpWidget(_harness(repo, online: false));
      await _open(tester);
      expect(find.text('Needs a connection'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('rep_cash_reference')), 'r1');
      await _submit(tester);
      expect(repo.submitted, isEmpty);
      expect(repo.calls.where((c) => c.startsWith('submit')), isEmpty);
    });

    testWidgets('a pending request makes the sheet read-only', (tester) async {
      final repo = FakePaymentsRepository()
        ..pending = ManualPaymentRecord.fromMap(
          manualPaymentPayload(amountPaise: 100000),
        );
      await tester.pumpWidget(_harness(repo));
      await _open(tester);
      expect(find.byKey(const ValueKey('rep_cash_pending')), findsOneWidget);
      expect(find.byKey(const ValueKey('rep_cash_form')), findsNothing);
      expect(
          find.textContaining('₹1,000 · Cash · receipt-0042'), findsOneWidget);
      expect(
          find.textContaining('Awaiting admin verification'), findsOneWidget);
    });
  });
}
