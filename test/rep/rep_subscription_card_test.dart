// test/rep/rep_subscription_card_test.dart
//
// The rep's Subscription card and the list chip (Door 1).
//
// What this file exists to catch:
//   • A TRIAL THAT STARTS ON THE CARD BUT NOT ON THE LIST. The chip on 'My
//     restaurants' reads a different provider; after Start trial it must say
//     "Trial 30d" with no pull-to-refresh, or a rep walks back to the list and
//     believes the tap did nothing.
//   • A TRIAL STARTED OFFLINE. The button must be disabled with a reason and
//     nothing may be queued (E40).
//   • A 409 SHOWN AS A CRASH, OR AS THE SERVER'S PROSE. Our sentence for the
//     code, and the card re-reads.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/qr_download_file.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart'
    show StandeeQrFormat;
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show ProductImageSlot;
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/catalog/publish_request_result.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/domain/entities/product_food_type.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/presentation/screens/rep/rep_catalogs_screen.dart';
import 'package:recapture/presentation/widgets/rep/rep_subscription_card.dart';

import '../catalog/catalog_entities_test.dart' as golden;
import '../catalog/subscription_entity_test.dart' show subscriptionPayload;
import 'rep_repo_catalog_defaults.dart';

const kCatalogId = 'c1';

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// A repository whose subscription state MOVES when a trial starts — the
/// list row and the card both read it, so the test can prove they agree.
class _FakeRepo with RepRepoCatalogDefaults implements RepRepository {
  bool trialStarted = false;
  CatalogFailure? trialFailure;
  int trialCalls = 0;
  int subscriptionReads = 0;
  int listReads = 0;

  Map<String, dynamic> get _summary => trialStarted
      ? {'status': 'TRIAL', 'daysLeft': 30, 'isEntitledTo3D': true}
      : {'status': 'CANCELLED', 'daysLeft': null, 'trialAvailable': true};

  @override
  Future<List<RepCatalogSummary>> catalogs() async {
    listReads++;
    return [
      RepCatalogSummary.fromMap({
        'id': kCatalogId,
        'name': 'blue_cafe',
        'businessName': 'Blue Cafe',
        'status': 'DRAFT',
        'subscription': _summary,
      }),
    ];
  }

  @override
  Future<Catalog> catalog(String catalogId) async =>
      Catalog.fromMap({...golden.catalogGolden(), 'id': catalogId});

  @override
  Future<CatalogSubscription> subscription(String catalogId) async {
    subscriptionReads++;
    return CatalogSubscription.fromMap(trialStarted
        ? subscriptionPayload(status: 'TRIAL', daysLeft: 30)
        : subscriptionPayload(
            status: 'CANCELLED',
            daysLeft: null,
            trialAvailable: true,
            isEntitledTo3D: false,
          ));
  }

  @override
  Future<CatalogSubscription> startTrial(String catalogId) async {
    trialCalls++;
    if (trialFailure != null) throw trialFailure!;
    trialStarted = true;
    return subscription(catalogId);
  }

  // ── The rest of the seam, not exercised here ──────────────────────────────

  @override
  Future<QrCodePreflight> preflight(String code) async =>
      throw UnimplementedError();

  @override
  Future<RepActivation> activate(RepActivationRequest request) async =>
      throw UnimplementedError();

  @override
  Future<List<CatalogProduct>> products(String catalogId) async => const [];

  @override
  Future<List<RepStandee>> standees() async => const [];

  @override
  Future<QrDownloadFile> standeeFile(
    String code, {
    StandeeQrFormat format = StandeeQrFormat.pdf,
    int? size,
  }) async =>
      throw UnimplementedError();

  @override
  Future<PublishRequestResult> publish(
    String catalogId, {
    String? idempotencyKey,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> attachCode(String catalogId, String code) async =>
      throw UnimplementedError();

  @override
  Future<void> retireCode(String code) async => throw UnimplementedError();

  @override
  Future<CatalogProduct> createProduct(
    String catalogId, {
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? sourceModelId,
    String? imageKey,
    String? categoryId,
    ProductFoodType? foodType,
  }) async =>
      throw UnimplementedError();

  @override
  Future<String> uploadImageBytes(
    String catalogId,
    Uint8List bytes, {
    required String contentType,
    String? productId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ProductImageSlot> createImageSlot(
    String catalogId, {
    required String contentType,
    String? productId,
  }) async =>
      throw UnimplementedError();
}

/// The list AND the card under one router, so the chip on the list can be
/// checked after the card's action.
Widget _harness(_FakeRepo repo, {bool online = true}) {
  final router = GoRouter(
    initialLocation: '/rep/catalogs/$kCatalogId',
    routes: [
      GoRoute(
        path: '/rep/catalogs',
        builder: (_, __) => const RepCatalogsScreen(),
        routes: [
          GoRoute(
            path: ':id',
            builder: (_, state) => Scaffold(
              body: RepSubscriptionCard(
                catalogId: state.pathParameters['id']!,
                restaurantName: 'Blue Cafe',
              ),
            ),
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      authProvider.overrideWith(_StubAuth.new),
      repRepositoryProvider.overrideWithValue(repo),
      isOnlineProvider.overrideWithValue(online),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

Future<void> _startTrial(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('rep_start_trial')));
  await tester.pumpAndSettle();
  expect(find.textContaining('Start a 30-day free trial for Blue Cafe?'),
      findsOneWidget);
  expect(find.textContaining('One trial per restaurant.'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('rep_trial_confirm')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the owner status line and the usage', (tester) async {
    final repo = _FakeRepo();
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    expect(find.text('Cancelled — resubscribe anytime'), findsOneWidget);
    expect(find.textContaining('3D/AR dishes 4 / 10'), findsOneWidget);
    expect(find.byKey(const ValueKey('rep_start_trial')), findsOneWidget);
  });

  testWidgets(
      'Start trial → confirm → the card AND the list chip update '
      'without a refresh', (tester) async {
    final repo = _FakeRepo();
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    await _startTrial(tester);

    expect(repo.trialCalls, 1);
    expect(find.textContaining('Free trial — 30 days left'), findsOneWidget);
    expect(find.byKey(const ValueKey('rep_start_trial')), findsNothing);
    expect(find.byKey(const ValueKey('rep_trial_unavailable')), findsOneWidget);
    expect(find.textContaining('Free trial started'), findsOneWidget);

    // The list sits under the card in the router's stack, so the invalidation
    // has ALREADY re-read it (one build, one re-read) — going back must show
    // the new chip with no further request and no pull-to-refresh.
    expect(repo.listReads, 2);
    GoRouter.of(tester.element(find.byType(RepSubscriptionCard)))
        .go('/rep/catalogs');
    await tester.pumpAndSettle();

    expect(repo.listReads, 2);
    expect(find.text('Trial 30d'), findsOneWidget);
  });

  testWidgets('"Not now" starts nothing', (tester) async {
    final repo = _FakeRepo();
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('rep_start_trial')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(repo.trialCalls, 0);
    expect(find.byKey(const ValueKey('rep_start_trial')), findsOneWidget);
  });

  testWidgets('offline: the button says so and nothing is queued (E40)',
      (tester) async {
    final repo = _FakeRepo();
    await tester.pumpWidget(_harness(repo, online: false));
    await tester.pumpAndSettle();

    expect(find.text('Needs a connection'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rep_start_trial')));
    await tester.pumpAndSettle();

    expect(repo.trialCalls, 0);
    expect(find.textContaining('Start a 30-day free trial'), findsNothing);
  });

  testWidgets('a 409 shows OUR sentence for the code and re-reads the card',
      (tester) async {
    final repo = _FakeRepo()
      ..trialFailure = const CatalogFailure(
        code: 'TRIAL_ALREADY_USED',
        message: 'SERVER PROSE THAT MUST NOT RENDER',
        statusCode: 409,
      );
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();
    final readsBefore = repo.subscriptionReads;

    await _startTrial(tester);

    expect(find.textContaining('already used its free trial'), findsOneWidget);
    expect(find.textContaining('SERVER PROSE'), findsNothing);
    expect(repo.subscriptionReads, greaterThan(readsBefore));
  });

  testWidgets('the list chip reads the summary the row carries',
      (tester) async {
    final repo = _FakeRepo();
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();
    GoRouter.of(tester.element(find.byType(RepSubscriptionCard)))
        .go('/rep/catalogs');
    await tester.pumpAndSettle();

    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.byKey(const ValueKey('rep_subscription_chip')), findsOneWidget);
  });
}
