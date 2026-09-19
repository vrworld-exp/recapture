// test/catalog/delete_dialog_subscription_copy_test.dart
//
// C9 in the delete dialog (gaps-addendum G5): the "what goes" list carries
// the non-refund sentence ONLY when a paid period is running (ACTIVE / GRACE),
// the trial sentence only on TRIAL, and nothing about the subscription at all
// otherwise — no row, PAUSED, CANCELLED, COMPED. Four fixtures, plus the
// copy helper on its own.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/catalog/subscription_copy.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/presentation/screens/catalog/delete_catalog_dialog.dart';

import 'catalog_entities_test.dart' as golden;

Catalog catalogWith(Map<String, dynamic>? subscription) => Catalog.fromMap({
      ...golden.catalogGolden(),
      'subscription': subscription,
    });

Future<void> pumpDialog(WidgetTester tester, Catalog catalog) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      home: Scaffold(body: DeleteCatalogDialog(catalog: catalog)),
    ),
  ));
  await tester.pump();
}

void main() {
  const nonRefund = 'Payments are non-refundable';
  const trialEnds = 'Your free trial ends and cannot be restarted.';

  group('deleteSubscriptionConsequence', () {
    test('ACTIVE and GRACE → the non-refund sentence naming the plan', () {
      expect(
        deleteSubscriptionConsequence(SubscriptionStatus.active,
            planName: 'Signature plan'),
        'Your Signature plan subscription ends now. Payments are '
        'non-refundable — the unused days are not credited.',
      );
      expect(
        deleteSubscriptionConsequence(SubscriptionStatus.grace),
        startsWith('Your paid subscription ends now.'),
      );
    });

    test('TRIAL → the trial sentence', () {
      expect(deleteSubscriptionConsequence(SubscriptionStatus.trial), trialEnds);
    });

    test('everything else → nothing', () {
      for (final status in [
        null,
        SubscriptionStatus.none,
        SubscriptionStatus.paused,
        SubscriptionStatus.cancelled,
        SubscriptionStatus.comped,
        SubscriptionStatus.unknown,
      ]) {
        expect(deleteSubscriptionConsequence(status), isNull, reason: '$status');
      }
    });
  });

  group('DeleteCatalogDialog', () {
    testWidgets('ACTIVE Signature → the non-refund bullet, with the plan name',
        (tester) async {
      await pumpDialog(
        tester,
        catalogWith({
          'status': 'ACTIVE',
          'planId': 'SIGNATURE',
          'daysLeft': 20,
          'isEntitledTo3D': true,
          'trialAvailable': false,
        }),
      );
      expect(find.textContaining(nonRefund), findsOneWidget);
      expect(find.textContaining('Your Signature plan subscription ends now'),
          findsOneWidget);
      expect(find.textContaining(trialEnds), findsNothing);
    });

    testWidgets('GRACE → the non-refund bullet', (tester) async {
      await pumpDialog(
        tester,
        catalogWith({
          'status': 'GRACE',
          'planId': 'TASTE',
          'daysLeft': 3,
          'isEntitledTo3D': true,
          'trialAvailable': false,
        }),
      );
      expect(find.textContaining(nonRefund), findsOneWidget);
      expect(find.textContaining('Your Taste plan subscription'), findsOneWidget);
    });

    testWidgets('TRIAL → the trial bullet, not the money one', (tester) async {
      await pumpDialog(
        tester,
        catalogWith({
          'status': 'TRIAL',
          'planId': null,
          'daysLeft': 12,
          'isEntitledTo3D': true,
          'trialAvailable': false,
        }),
      );
      expect(find.textContaining(trialEnds), findsOneWidget);
      expect(find.textContaining(nonRefund), findsNothing);
    });

    testWidgets('no subscription → neither bullet; the rest of the list stays',
        (tester) async {
      await pumpDialog(tester, catalogWith(null));
      expect(find.textContaining(nonRefund), findsNothing);
      expect(find.textContaining(trialEnds), findsNothing);
      // The list itself is unchanged.
      expect(find.textContaining('12 products'), findsOneWidget);
      expect(find.textContaining('printed codes will stop'), findsOneWidget);
    });

    testWidgets('PAUSED → neither bullet (nothing is running to lose)',
        (tester) async {
      await pumpDialog(
        tester,
        catalogWith({
          'status': 'PAUSED',
          'planId': 'TASTE',
          'daysLeft': null,
          'isEntitledTo3D': false,
          'trialAvailable': false,
        }),
      );
      expect(find.textContaining(nonRefund), findsNothing);
      expect(find.textContaining(trialEnds), findsNothing);
    });
  });
}
