// test/admin/admin_subscriptions_test.dart
//
// The admin's subscription screens. What this file most exists to pin:
//   • THE QUEUE AND THE LIST come from two routes and land in one screen; a
//     row opens the per-catalog panel.
//   • VERIFY carries the AC-5.2 notice, a mismatched amount needs the
//     override plus a 20-character reason, Reject needs a note.
//   • REFUND needs a 10-character note (30 with the override), shows the
//     original payment, and is offered ONLY on a refundable row.
//   • A 409 is a sentence, and the panel re-reads.
//   • The route gate: `/admin/subscriptions/*` is ADMIN-only.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/app/theme/app_colors.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/payments_repository.dart';
import 'package:recapture/domain/catalog/subscription_copy.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/domain/entities/subscription_payment.dart';
import 'package:recapture/domain/entities/user_role.dart';
import 'package:recapture/presentation/screens/admin/admin_subscription_detail_screen.dart';
import 'package:recapture/presentation/screens/admin/admin_subscriptions_screen.dart';

import '../catalog/payments_fakes.dart';
import '../catalog/subscription_entity_test.dart' show subscriptionPayload;

AdminSubscriptionDetail _detail({
  String status = 'ACTIVE',
  List<PaymentRecordSummary> payments = const [],
  bool deleted = false,
  DateTime? arEntitlementSyncedAt,
}) =>
    AdminSubscriptionDetail(
      catalogId: 'c1',
      catalogName: 'blue cafe',
      catalogDeleted: deleted,
      arEntitlementSyncedAt: arEntitlementSyncedAt,
      subscription: deleted
          ? null
          : CatalogSubscription.fromMap(subscriptionPayload(
              status: status,
              planId: 'TASTE',
              planName: 'Taste plan',
              daysLeft: 2,
              graceEndsAt:
                  status == 'GRACE' ? '2026-09-25T00:00:00.000Z' : null,
            )),
      payments: payments,
    );

Widget _harness(FakePaymentsRepository repo, {String initial = '/'}) {
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const AdminSubscriptionsScreen(),
      ),
      GoRoute(
        path: '${AppRoutes.adminSubscriptions}/:catalogId',
        builder: (_, state) => AdminSubscriptionDetailScreen(
          catalogId: state.pathParameters['catalogId']!,
        ),
      ),
    ],
  );
  return ProviderScope(
    overrides: [paymentsRepositoryProvider.overrideWithValue(repo)],
    child: MaterialApp.router(routerConfig: router),
  );
}

Future<void> _tall(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('the list screen', () {
    testWidgets('Pending shows the queue; another segment shows the state list',
        (tester) async {
      final repo = FakePaymentsRepository()
        ..queue = [
          ManualPaymentRecord.fromMap(
              manualPaymentPayload(amountPaise: 100000)),
        ]
        ..pages = {
          AdminSubscriptionFilter.grace: AdminSubscriptionPage(
            items: [
              AdminSubscriptionListItem.fromMap({
                'catalogId': 'c9',
                'catalogName': 'grace cafe',
                'status': 'GRACE',
                'periodEnd': '2026-09-15T00:00:00.000Z',
                'graceEndsAt': '2026-09-22T00:00:00.000Z',
                'daysLeft': 3,
                'planId': 'TASTE',
              }),
            ],
            nextCursor: 'more',
          ),
        };
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      expect(find.textContaining('blue cafe'), findsOneWidget);
      expect(find.text('Pending cash'), findsOneWidget);
      expect(find.textContaining('amount differs'), findsOneWidget);

      await tester.tap(find.text('In grace'));
      await tester.pumpAndSettle();
      expect(find.textContaining('grace cafe'), findsOneWidget);
      expect(find.textContaining('3 days left'), findsOneWidget);
      expect(find.text('GRACE'), findsOneWidget);
      expect(find.byKey(const ValueKey('admin_subscriptions_more')),
          findsOneWidget);
      expect(repo.calls, contains('subscriptions:grace:'));

      // No contact anywhere on these rows.
      expect(find.textContaining('@'), findsNothing);
      expect(find.textContaining('+91'), findsNothing);
    });

    testWidgets('a queue row opens the per-catalog panel', (tester) async {
      final repo = FakePaymentsRepository()
        ..queue = [ManualPaymentRecord.fromMap(manualPaymentPayload())]
        ..detail = _detail(payments: [
          PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000c1',
            kind: 'MANUAL',
            method: 'CASH',
            verificationStatus: 'PENDING_VERIFICATION',
          )),
        ]);
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('admin_queue_66f0000000000000000000c1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_subscription_detail')),
          findsOneWidget);
      expect(repo.calls, contains('detail:c1'));
    });
  });

  group('the detail panel', () {
    testWidgets(
        'Verify shows the AC-5.2 notice and decides; the queue drops it',
        (tester) async {
      await _tall(tester);
      final repo = FakePaymentsRepository()
        ..queue = [ManualPaymentRecord.fromMap(manualPaymentPayload())]
        ..detail = _detail(status: 'PAUSED', payments: [
          PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000c1',
            kind: 'MANUAL',
            method: 'CASH',
            verificationStatus: 'PENDING_VERIFICATION',
          )),
        ]);
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();

      await tester.tap(
          find.byKey(const ValueKey('admin_decide_66f0000000000000000000c1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_decide_dialog')), findsOneWidget);
      expect(find.text(kPaymentConsentLine), findsOneWidget);
      // Amount matches the quote: no override asked for.
      expect(find.byKey(const ValueKey('admin_decide_override')), findsNothing);
      // Reject is disabled until a note is typed.
      expect(
        tester
            .widget<TextButton>(
                find.byKey(const ValueKey('admin_decide_reject')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('admin_decide_verify')));
      await tester.pumpAndSettle();

      expect(repo.decisions.single, {
        'paymentRecordId': '66f0000000000000000000c1',
        'decision': 'verify',
        'note': null,
        'override': false,
      });
      expect(find.textContaining('Verified — the plan is active.'),
          findsOneWidget);
      // Re-read after the decision.
      expect(repo.calls.where((c) => c == 'detail:c1').length, 2);
    });

    testWidgets(
        'a mismatched amount needs the override and a 20-char reason (E12)',
        (tester) async {
      await _tall(tester);
      final repo = FakePaymentsRepository()
        ..queue = [
          ManualPaymentRecord.fromMap(
              manualPaymentPayload(amountPaise: 100000)),
        ]
        ..detail = _detail(payments: [
          PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000c1',
            kind: 'MANUAL',
            amountPaise: 100000,
            method: 'CASH',
            verificationStatus: 'PENDING_VERIFICATION',
          )),
        ]);
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Plan price is ₹1,199'), findsOneWidget);

      await tester.tap(
          find.byKey(const ValueKey('admin_decide_66f0000000000000000000c1')));
      await tester.pumpAndSettle();
      final verify = find.byKey(const ValueKey('admin_decide_verify'));
      expect(tester.widget<FilledButton>(verify).onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('admin_decide_override')));
      await tester.enterText(
          find.byKey(const ValueKey('admin_decide_note')), 'discount');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(verify).onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('admin_decide_note')),
          'Launch discount agreed by the founder on the phone.');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(verify).onPressed, isNotNull);
      await tester.tap(verify);
      await tester.pumpAndSettle();
      expect(repo.decisions.single['override'], true);
      expect(repo.decisions.single['decision'], 'verify');
    });

    testWidgets('a second Verify shows the 409 sentence and re-reads',
        (tester) async {
      await _tall(tester);
      final repo = FakePaymentsRepository()
        ..queue = [ManualPaymentRecord.fromMap(manualPaymentPayload())]
        ..decideFailure = const CatalogFailure(
          code: PaymentErrorCodes.alreadyDecided,
          message: 'server prose',
          statusCode: 409,
        )
        ..detail = _detail(payments: [
          PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000c1',
            kind: 'MANUAL',
            method: 'CASH',
            verificationStatus: 'PENDING_VERIFICATION',
          )),
        ]);
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('admin_decide_66f0000000000000000000c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin_decide_verify')));
      await tester.pumpAndSettle();

      expect(find.textContaining('already been verified or rejected'),
          findsOneWidget);
      expect(find.textContaining('server prose'), findsNothing);
      expect(repo.calls.where((c) => c == 'detail:c1').length, 2);
    });

    testWidgets('Refund is offered only on a refundable row, with the original',
        (tester) async {
      await _tall(tester);
      final repo = FakePaymentsRepository()
        ..detail = _detail(payments: [
          PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000d1',
            note: 'DUPLICATE_SUSPECTED',
            isRefundable: true,
          )),
          PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000d2',
            isRefundable: false,
          )),
          PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000d3',
            kind: 'MANUAL',
            method: 'CASH',
            verificationStatus: 'VERIFIED',
          )),
        ]);
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('admin_refund_66f0000000000000000000d1')),
          findsOneWidget);
      expect(
          find.byKey(const ValueKey('admin_refund_66f0000000000000000000d2')),
          findsNothing);
      expect(
          find.byKey(const ValueKey('admin_refund_66f0000000000000000000d3')),
          findsNothing);
      expect(find.text('DUPLICATE_SUSPECTED'), findsOneWidget);

      await tester.tap(
          find.byKey(const ValueKey('admin_refund_66f0000000000000000000d1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_refund_dialog')), findsOneWidget);
      expect(
          find.textContaining('₹1,199 · Online · RC-000000D1'), findsOneWidget);
      // A flagged duplicate: no override asked for, but a 10-char note.
      expect(find.byKey(const ValueKey('admin_refund_override')), findsNothing);
      final confirm = find.byKey(const ValueKey('admin_refund_confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(
          find.byKey(const ValueKey('admin_refund_note')), 'short');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('admin_refund_note')),
          'Charged twice on 12 Sep');
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(repo.refunds.single, {
        'id': '66f0000000000000000000d1',
        'note': 'Charged twice on 12 Sep',
        'override': false,
      });
      expect(find.textContaining('Refund of ₹1,199 issued.'), findsOneWidget);
    });

    testWidgets('an unflagged refund needs the override and 30 characters',
        (tester) async {
      await _tall(tester);
      final repo = FakePaymentsRepository()
        ..detail = _detail(payments: [
          PaymentRecordSummary.fromMap(paymentRowPayload(
            id: '66f0000000000000000000e1',
            note: 'ORPHAN_PAYMENT',
            isRefundable: true,
          )),
        ]);
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('admin_refund_66f0000000000000000000e1')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('admin_refund_override')), findsOneWidget);
      final confirm = find.byKey(const ValueKey('admin_refund_confirm'));
      await tester.enterText(find.byKey(const ValueKey('admin_refund_note')),
          'Catalog deleted before the payment landed; refunding.');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('admin_refund_override')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(repo.refunds.single['override'], true);
    });

    testWidgets('Extend grace appears only in GRACE; Comp always',
        (tester) async {
      await _tall(tester);
      final repo = FakePaymentsRepository()..detail = _detail(status: 'ACTIVE');
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_comp')), findsOneWidget);
      expect(find.byKey(const ValueKey('admin_extend_grace')), findsNothing);

      repo.detail = _detail(status: 'GRACE');
      // A fresh scope, or the first read is still cached under the screen.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_extend_grace')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('admin_extend_grace')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('admin_grace_note')), 'Owner travelling');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin_grace_confirm')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('extendGrace:7'));
      expect(find.textContaining('Grace extended by 7 days.'), findsOneWidget);
    });

    testWidgets('a deleted catalog shows its ledger and no actions',
        (tester) async {
      final repo = FakePaymentsRepository()
        ..detail = _detail(deleted: true, payments: [
          PaymentRecordSummary.fromMap(
              paymentRowPayload(note: 'ORPHAN_PAYMENT', isRefundable: true)),
        ]);
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('This catalog has been deleted'), findsOneWidget);
      expect(find.byKey(const ValueKey('admin_comp')), findsNothing);
      // The orphan can still be refunded (E5).
      expect(find.textContaining('Refund…'), findsOneWidget);
    });
  });

  group('the 3D entitlement sync (Stage 5, E18)', () {
    testWidgets('a PAUSED row never synced is flagged, and Resync 3D queues a job',
        (tester) async {
      await _tall(tester);
      final repo = FakePaymentsRepository()..detail = _detail(status: 'PAUSED');
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();

      final line = find.byKey(const ValueKey('admin_ar_sync_line'));
      expect(line, findsOneWidget);
      expect(find.textContaining('never synced — Mirage still shows 3D'),
          findsOneWidget);
      expect(
        tester.widget<Text>(line).style?.color,
        AppColors.warning,
      );

      await tester.tap(find.byKey(const ValueKey('admin_resync_ar')));
      await tester.pump();
      await tester.pump();

      expect(repo.calls, contains('resyncAr'));
      expect(find.textContaining('3D sync queued'), findsOneWidget);
      // Re-read after the action, like every other one.
      expect(repo.calls.where((c) => c == 'detail:c1').length, 2);
    });

    testWidgets('a synced row shows the stamp in muted text', (tester) async {
      await _tall(tester);
      final repo = FakePaymentsRepository()
        ..detail = _detail(
          status: 'ACTIVE',
          arEntitlementSyncedAt: DateTime.utc(2026, 9, 19, 8, 32),
        );
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();

      final line = find.byKey(const ValueKey('admin_ar_sync_line'));
      expect(find.textContaining('3D on Mirage: synced 19 Sep 2026'),
          findsOneWidget);
      expect(tester.widget<Text>(line).style?.color, AppColors.textMuted);
      expect(find.byKey(const ValueKey('admin_resync_ar')), findsOneWidget);
    });

    testWidgets('a deleted catalog has no row and no Resync button',
        (tester) async {
      await _tall(tester);
      final repo = FakePaymentsRepository()..detail = _detail(deleted: true);
      await tester.pumpWidget(
          _harness(repo, initial: '${AppRoutes.adminSubscriptions}/c1'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('admin_ar_sync_line')), findsNothing);
      expect(find.byKey(const ValueKey('admin_resync_ar')), findsNothing);
    });
  });

  group('the route gate', () {
    test('/admin/subscriptions/* is ADMIN-only, by prefix', () {
      for (final location in [
        AppRoutes.adminSubscriptions,
        '${AppRoutes.adminSubscriptions}/c1',
      ]) {
        expect(
          adminStandeesRedirectFor(location,
              canUseStandees: UserRole.admin.isAdmin),
          isNull,
        );
        for (final role in [
          UserRole.user,
          UserRole.salesRep,
          UserRole.modelArtist
        ]) {
          expect(
            adminStandeesRedirectFor(location, canUseStandees: role.isAdmin),
            AppRoutes.projects,
            reason: '$role at $location',
          );
        }
      }
      // A different /admin subtree is not caught by it.
      expect(
        adminStandeesRedirectFor('/admin/projects/p1/preview',
            canUseStandees: false),
        isNull,
      );
    });
  });
}
