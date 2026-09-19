// test/catalog/subscription_grace_copy_test.dart
//
// Prompt B / E16 — the three GRACE sentences, chosen by the server's
// `graceFrom`, on every surface that says one.
//
// What this file exists to catch:
//   • A restaurant whose FREE TRIAL ran out is never told "payment overdue";
//     neither is a COMPED one. The paid wording is the fallback — for
//     `graceFrom: ACTIVE`, and for a row written before the field existed.
//   • The owner's status line, the catalog banner, the publish banner and the
//     rep chip's long-press all read from ONE function, so a fixture that
//     changes one changes all of them.
//   • The number is still the SERVER's `daysLeft` (D6), rendered verbatim.
//
// Hermetic: the banners' harnesses are the Stage 5 ones, re-used.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/catalog/subscription_copy.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/presentation/screens/rep/rep_catalogs_screen.dart';

import '../rep/rep_repo_catalog_defaults.dart';
import 'publish_fakes.dart';
import 'subscription_banners_test.dart' as banners;
import 'subscription_entity_test.dart' show subscriptionPayload;

const _catalogId = '6a83dd464aea89d1d2d28d50';

const _trialLine =
    'Your free trial has ended — choose a plan within 3 days to keep 3D live';
const _compedLine =
    'Your complimentary period has ended — choose a plan within 3 days';
const _paidLine = 'Payment overdue — 3D menu pauses in 3 days';

/// `graceFrom` on the wire → the sentence every surface must show.
const _fixtures = <String?, String>{
  'TRIAL': _trialLine,
  'COMPED': _compedLine,
  'ACTIVE': _paidLine,
  // A row written before Stage 5 shipped, or an older server.
  null: _paidLine,
};

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// The rep's list seam: one delegated restaurant in GRACE.
class _FakeRepListRepo with RepRepoCatalogDefaults implements RepRepository {
  _FakeRepListRepo(this.summary);

  final Map<String, dynamic> summary;

  @override
  Future<List<RepCatalogSummary>> catalogs() async => [
        RepCatalogSummary.fromMap({
          'id': _catalogId,
          'name': 'blue_cafe',
          'businessName': 'Blue Cafe',
          'status': 'PUBLISHED',
          'subscription': summary,
        }),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

Widget _repListHarness(_FakeRepListRepo repo) => ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        repRepositoryProvider.overrideWithValue(repo),
        isOnlineProvider.overrideWithValue(true),
      ],
      child: const MaterialApp(home: RepCatalogsScreen()),
    );

void main() {
  group('graceLine', () {
    test('picks the sentence by graceFrom; null and ACTIVE read as overdue',
        () {
      expect(graceLine(SubscriptionStatus.trial, 3), _trialLine);
      expect(graceLine(SubscriptionStatus.comped, 3), _compedLine);
      expect(graceLine(SubscriptionStatus.active, 3), _paidLine);
      expect(graceLine(null, 3), _paidLine);
      // Anything else the server might one day send is the safe wording too.
      expect(graceLine(SubscriptionStatus.unknown, 3), _paidLine);
    });

    test('renders the server\'s number verbatim, singular at one', () {
      expect(
        graceLine(SubscriptionStatus.trial, 1),
        'Your free trial has ended — choose a plan within 1 day to keep 3D live',
      );
      expect(
        graceLine(SubscriptionStatus.comped, null),
        'Your complimentary period has ended — choose a plan within 0 days',
      );
      // The Stage 5 name still works, and agrees.
      expect(
        graceBannerLine(1, graceFrom: SubscriptionStatus.trial),
        graceLine(SubscriptionStatus.trial, 1),
      );
      expect(graceBannerLine(1), 'Payment overdue — 3D menu pauses in 1 day');
    });

    test('the owner status line uses it, so the subscription screen agrees',
        () {
      for (final entry in _fixtures.entries) {
        final payload = subscriptionPayload(
          status: 'GRACE',
          planId: 'TASTE',
          planName: 'Taste plan',
          daysLeft: 3,
        )..['graceFrom'] = entry.key;
        final subscription = CatalogSubscription.fromMap(payload);
        expect(
          ownerStatusLine(subscription, trialThreeDCap: 10),
          entry.value,
          reason: 'graceFrom ${entry.key}',
        );
        // Still red on every variant: a trial that ended is as urgent.
        expect(subscriptionTone(subscription.status), SubscriptionTone.danger);
      }
    });
  });

  group('the catalog screen banner', () {
    for (final entry in _fixtures.entries) {
      testWidgets('graceFrom ${entry.key}', (tester) async {
        final repo = FakePublishRepository(
          catalog: banners.catalogWith(
            banners.summary('GRACE', daysLeft: 3, graceFrom: entry.key),
          ),
        );

        await tester.pumpWidget(banners.catalogHarness(repo));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('subscription_grace_banner')),
            findsOneWidget);
        expect(find.text(entry.value), findsOneWidget);
        // Exactly one of the three, never two.
        for (final other in _fixtures.values.toSet()) {
          if (other != entry.value) expect(find.text(other), findsNothing);
        }
      });
    }
  });

  group('the publish screen banner', () {
    testWidgets('owner voice: the trial sentence over the owner action',
        (tester) async {
      final repo = FakePublishRepository(
        catalog: banners.catalogWith(
          banners.summary('GRACE', daysLeft: 3, graceFrom: 'TRIAL'),
        ),
        status: statusPayload(gates: [
          gatePayload(
              code: 'CATALOG_NO_CATEGORIES', message: 'No categories yet.'),
        ]),
      );

      await tester.pumpWidget(banners.publishHarness(repo));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('publish_grace_banner')), findsOneWidget);
      expect(find.text(_trialLine), findsOneWidget);
      expect(find.text(_paidLine), findsNothing);
      expect(find.text(graceBannerAction(isRep: false)), findsOneWidget);
    });

    testWidgets('rep voice: the comped sentence over the rep action',
        (tester) async {
      final repo = banners.FakeRepRepository(
        banners.summary('GRACE', daysLeft: 3, graceFrom: 'COMPED'),
      );

      await tester.pumpWidget(banners.repHarness(repo));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('publish_grace_banner')), findsOneWidget);
      expect(find.text(_compedLine), findsOneWidget);
      expect(find.text(graceBannerAction(isRep: true)), findsOneWidget);
    });
  });

  group('the rep list chip', () {
    testWidgets('GRACE: "Overdue 3d" with the full sentence on long-press',
        (tester) async {
      final repo = _FakeRepListRepo(
        banners.summary('GRACE', daysLeft: 3, graceFrom: 'TRIAL'),
      );

      await tester.pumpWidget(_repListHarness(repo));
      await tester.pumpAndSettle();

      expect(find.text('Overdue 3d'), findsOneWidget);
      final tooltip = find.byKey(const ValueKey('rep_subscription_chip_tooltip'));
      expect(tooltip, findsOneWidget);
      expect(tester.widget<Tooltip>(tooltip).message, _trialLine);

      await tester.longPress(find.byKey(const ValueKey('rep_subscription_chip')));
      await tester.pumpAndSettle();
      expect(find.text(_trialLine), findsOneWidget);
    });

    testWidgets('outside GRACE the chip carries no tooltip', (tester) async {
      final repo = _FakeRepListRepo(banners.summary('ACTIVE', daysLeft: 12));

      await tester.pumpWidget(_repListHarness(repo));
      await tester.pumpAndSettle();

      expect(find.text('Active'), findsOneWidget);
      expect(find.byKey(const ValueKey('rep_subscription_chip_tooltip')),
          findsNothing);
    });
  });
}
