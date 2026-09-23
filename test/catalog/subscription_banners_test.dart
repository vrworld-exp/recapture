// test/catalog/subscription_banners_test.dart
//
// Stage 5 — the paused card and the grace banners.
//
// What this file exists to catch:
//   • THE PAUSED CARD IS FIRST. An owner whose 3D is off must read "your photo
//     menu is still live — pay to restore 3D" before the header, the product
//     count, or anything else; a card below the fold is a card nobody sees.
//   • THE GRACE BANNER SAYS THE SERVER'S NUMBER. `daysLeft` is rendered
//     verbatim (D6); nothing here counts days off a clock.
//   • TWO VOICES, ONE SENTENCE. The publish screen's grace banner tells an
//     OWNER to pay and a REP to notify the owner — the same widget, decided
//     by PublishVoice, never a second flag.
//   • A PAUSED publish screen shows NO banner: the gate row already says it.
//
// Hermetic: repositories and connectivity are faked; no HTTP, no timers left.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_link_service.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/catalog/publish_status.dart';
import 'package:recapture/domain/catalog/subscription_copy.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/presentation/screens/catalog/catalog_screen.dart';
import 'package:recapture/presentation/screens/catalog/publish_screen.dart';
import 'package:recapture/presentation/screens/rep/rep_publish_screen.dart';

import '../rep/rep_repo_catalog_defaults.dart';
import 'catalog_entities_test.dart' as golden;
import 'product_grid_test.dart' show FakeProductsRepository, pageOf;
import 'publish_fakes.dart';

const _catalogId = '6a83dd464aea89d1d2d28d50';

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// The compact summary the server puts on the catalog DTO, in one status.
Map<String, dynamic> summary(String status, {int? daysLeft, String? graceFrom}) => {
      'status': status,
      'daysLeft': daysLeft,
      'planId': 'TASTE',
      'graceFrom': graceFrom,
      'isEntitledTo3D': status == 'GRACE' || status == 'ACTIVE',
      'trialAvailable': false,
    };

Catalog catalogWith(Map<String, dynamic>? subscription) =>
    Catalog.fromMap(golden.catalogGolden()..['subscription'] = subscription);

Widget catalogHarness(FakePublishRepository repo) => ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(repo),
        catalogProductsRepositoryProvider.overrideWithValue(
          FakeProductsRepository((_) async => pageOf([])),
        ),
      ],
      child: const MaterialApp(home: CatalogScreen()),
    );

Widget publishHarness(FakePublishRepository repo) => ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(repo),
        isOnlineProvider.overrideWithValue(true),
        catalogLinkActionsProvider.overrideWithValue(FakeLinkActions()),
      ],
      child: const MaterialApp(home: PublishScreen()),
    );

/// The rep's seam: the publish surface plus the delegated catalog read, which
/// is where the summary the banner reads comes from.
class FakeRepRepository with RepRepoCatalogDefaults implements RepRepository {
  FakeRepRepository(this.summaryPayload);

  final Map<String, dynamic>? summaryPayload;

  @override
  Future<PublishStatus> publishStatus(String catalogId) async =>
      PublishStatus.fromMap(statusPayload());

  @override
  Future<Catalog> catalog(String catalogId) async =>
      Catalog.fromMap({...golden.catalogGolden(), 'id': catalogId}
        ..['subscription'] = summaryPayload);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

Widget repHarness(FakeRepRepository repo) => ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        repRepositoryProvider.overrideWithValue(repo),
        isOnlineProvider.overrideWithValue(true),
        catalogLinkActionsProvider.overrideWithValue(FakeLinkActions()),
      ],
      child: const MaterialApp(
        home: RepPublishScreen(catalogId: _catalogId),
      ),
    );

void main() {
  group('the catalog screen', () {
    testWidgets('PAUSED: the A9 card is the FIRST thing on the screen',
        (tester) async {
      final repo = FakePublishRepository(catalog: catalogWith(summary('PAUSED')));

      await tester.pumpWidget(catalogHarness(repo));
      await tester.pumpAndSettle();

      final card = find.byKey(const ValueKey('subscription_paused_card'));
      expect(card, findsOneWidget);
      expect(find.text(kPausedCardTitle), findsOneWidget);
      expect(find.text(kPausedCardBody), findsOneWidget);
      // Above the header card — the catalog's name is the header's first line.
      final cardTop = tester.getTopLeft(card).dy;
      final headerTop = tester.getTopLeft(find.text('Cafe Mocha')).dy;
      expect(cardTop, lessThan(headerTop));
      // Its button is live and there is no grace banner beside it.
      final cta = tester.widget<ElevatedButton>(
        find.descendant(
          of: find.byKey(const ValueKey('subscription_paused_cta')),
          matching: find.byType(ElevatedButton),
        ),
      );
      expect(cta.onPressed, isNotNull);
      expect(find.byKey(const ValueKey('subscription_grace_banner')), findsNothing);
    });

    testWidgets('GRACE: the red banner with the server\'s countdown',
        (tester) async {
      final repo = FakePublishRepository(
        catalog: catalogWith(summary('GRACE', daysLeft: 3, graceFrom: 'ACTIVE')),
      );

      await tester.pumpWidget(catalogHarness(repo));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('subscription_grace_banner')), findsOneWidget);
      expect(find.text('Payment overdue — 3D menu pauses in 3 days'), findsOneWidget);
      expect(find.byKey(const ValueKey('subscription_paused_card')), findsNothing);
      // The E16 variants live in subscription_grace_copy_test.dart.
      expect(repo.catalog!.subscription!.graceFrom, SubscriptionStatus.active);
    });

    testWidgets('ACTIVE, or no row: neither', (tester) async {
      for (final subscription in [summary('ACTIVE', daysLeft: 20), null]) {
        // The blank frame matters here too, and this loop is where it was
        // easiest to miss: both cases assert `findsNothing`, so a second
        // iteration still showing the FIRST case's screen would pass anyway.
        await tester.pumpWidget(const SizedBox.shrink());
        final repo = FakePublishRepository(catalog: catalogWith(subscription));
        await tester.pumpWidget(catalogHarness(repo));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('subscription_paused_card')), findsNothing);
        expect(find.byKey(const ValueKey('subscription_grace_banner')), findsNothing);
      }
    });

    // ── The header's status line (requirement 3) ────────────────────────────
    //
    // The four states above get a card; every OTHER state used to get a
    // two-word chip and nothing else. The line fills exactly that gap, and
    // `subscriptionHasOwnCard` is the single predicate that decides which side
    // a status falls on — which is what stops the two saying the same sentence
    // twice on one screen.
    const lineKey = ValueKey('catalog_subscription_status_line');

    testWidgets('states with no card of their own say it in words',
        (tester) async {
      final cases = {
        summary('ACTIVE', daysLeft: 20): 'Active — 20 days left · Taste plan',
        summary('TRIAL', daysLeft: 12): 'Free trial — 12 days left',
        summary('COMPED', daysLeft: 40): 'Complimentary — 40 days left',
        summary('CANCELLED'): 'Cancelled — resubscribe anytime',
      };

      for (final entry in cases.entries) {
        // A blank frame FIRST. `catalogHarness` builds a ProviderScope with no
        // key, so pumping the next case straight after the last one UPDATES
        // that element rather than replacing it — the scope survives, the
        // providers keep the previous repository's catalog, and the second
        // case silently asserts against the first case's screen.
        await tester.pumpWidget(const SizedBox.shrink());

        final repo = FakePublishRepository(catalog: catalogWith(entry.key));
        await tester.pumpWidget(catalogHarness(repo));
        await tester.pumpAndSettle();

        expect(find.byKey(lineKey), findsOneWidget, reason: entry.value);
        expect(find.text(entry.value), findsOneWidget);
      }
    });

    testWidgets('a catalog with no row is told it has no plan', (tester) async {
      final repo = FakePublishRepository(catalog: catalogWith(null));
      await tester.pumpWidget(catalogHarness(repo));
      await tester.pumpAndSettle();

      expect(find.byKey(lineKey), findsOneWidget);
      expect(find.text('No plan yet — choose one to publish your menu'),
          findsOneWidget);
    });

    testWidgets('a state that already has a card does NOT repeat itself',
        (tester) async {
      // The GRACE case is the one that caught this: the banner and the line
      // render the very same string, so `findsOneWidget` on that sentence
      // fails the moment both are drawn.
      for (final subscription in [
        summary('GRACE', daysLeft: 3, graceFrom: 'ACTIVE'),
        summary('PAUSED'),
      ]) {
        await tester.pumpWidget(const SizedBox.shrink()); // see above
        final repo = FakePublishRepository(catalog: catalogWith(subscription));
        await tester.pumpWidget(catalogHarness(repo));
        await tester.pumpAndSettle();

        expect(find.byKey(lineKey), findsNothing);
      }
    });
  });

  group('the owner\'s publish screen', () {
    testWidgets('GRACE: the banner, in the owner\'s voice, above the checklist',
        (tester) async {
      final repo = FakePublishRepository(
        catalog: catalogWith(summary('GRACE', daysLeft: 2)),
        status: statusPayload(gates: [gatePayload(code: 'CATALOG_NO_CATEGORIES', message: 'No categories yet.')]),
      );

      await tester.pumpWidget(publishHarness(repo));
      await tester.pumpAndSettle();

      final banner = find.byKey(const ValueKey('publish_grace_banner'));
      expect(banner, findsOneWidget);
      expect(find.text('Payment overdue — 3D menu pauses in 2 days'), findsOneWidget);
      expect(find.text(graceBannerAction(isRep: false)), findsOneWidget);
      expect(find.text('Pay now'), findsOneWidget);
      expect(find.text('Notify owner'), findsNothing);
      // Above the checklist.
      final bannerTop = tester.getTopLeft(banner).dy;
      final checklistTop =
          tester.getTopLeft(find.byKey(const ValueKey('publish_gate_checklist'))).dy;
      expect(bannerTop, lessThan(checklistTop));
    });

    testWidgets('PAUSED: no banner — the paywall card says it', (tester) async {
      final repo = FakePublishRepository(
        catalog: catalogWith(summary('PAUSED')),
        status: statusPayload(gates: [gatePayload(code: 'SUBSCRIPTION_REQUIRED', message: 'Needs a plan.')]),
      )..subscriptionPayload = subscriptionPayloadFor(
          status: 'PAUSED',
          threeDDishCount: 4,
        );

      await tester.pumpWidget(publishHarness(repo));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('publish_grace_banner')), findsNothing);
      // The subscription gate is the card's, so the checklist — which had this
      // row and nothing else — is not drawn at all.
      expect(find.byKey(const ValueKey('publish_subscription_gate')), findsOneWidget);
      expect(find.byKey(const ValueKey('publish_gate_checklist')), findsNothing);
      expect(find.text(kPausedCardTitle), findsOneWidget);
    });
  });

  group('the rep\'s publish screen', () {
    testWidgets('GRACE: the same banner, in the rep\'s voice', (tester) async {
      final repo = FakeRepRepository(summary('GRACE', daysLeft: 5));

      await tester.pumpWidget(repHarness(repo));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('publish_grace_banner')), findsOneWidget);
      expect(find.text('Payment overdue — 3D menu pauses in 5 days'), findsOneWidget);
      expect(find.text(graceBannerAction(isRep: true)), findsOneWidget);
      expect(find.text('Notify owner'), findsOneWidget);
      expect(find.text('Pay now'), findsNothing);
    });

    testWidgets('ACTIVE: nothing', (tester) async {
      final repo = FakeRepRepository(summary('ACTIVE', daysLeft: 12));

      await tester.pumpWidget(repHarness(repo));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('publish_grace_banner')), findsNothing);
    });
  });

  group('the copy', () {
    test('the rep card\'s PAUSED secondary line and the A9 sentences are fixed', () {
      expect(kPausedPhotoMenuLine, 'Photo menu is still live at the same QR');
      expect(kPausedCardTitle, 'Your 3D menu is paused');
      expect(kPausedCardBody, contains('photo menu is still live'));
      expect(kPausedCardBody, contains('pay to restore 3D'));
      expect(graceBannerLine(1), 'Payment overdue — 3D menu pauses in 1 day');
      expect(graceBannerLine(null), 'Payment overdue — 3D menu pauses in 0 days');
    });

    test('graceFrom parses on the summary and the DTO, and tolerates absence', () {
      final withIt = SubscriptionSummary.fromMap(summary('GRACE', daysLeft: 3, graceFrom: 'COMPED'));
      expect(withIt.graceFrom, SubscriptionStatus.comped);
      final without = SubscriptionSummary.fromMap(summary('GRACE', daysLeft: 3));
      expect(without.graceFrom, isNull);
      final unknown = SubscriptionSummary.fromMap(summary('GRACE', daysLeft: 3, graceFrom: 'MYSTERY'));
      expect(unknown.graceFrom, isNull);
      final dto = CatalogSubscription.fromMap({'status': 'GRACE', 'graceFrom': 'TRIAL'});
      expect(dto.graceFrom, SubscriptionStatus.trial);
      expect(dto.summary!.graceFrom, SubscriptionStatus.trial);
    });
  });
}
