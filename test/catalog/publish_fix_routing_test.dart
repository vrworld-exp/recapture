// test/catalog/publish_fix_routing_test.dart
//
// Where the two subscription gates' Fix goes: the owner to the Subscription
// screen, the rep to the restaurant's detail screen (whose card carries Start
// free trial). A button that renders and goes nowhere is the failure this
// catches, so both run under a REAL router.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_link_service.dart';
import 'package:recapture/application/catalog/qr_download_file.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart'
    show StandeeQrFormat;
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show ProductImageSlot;
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/catalog/publish_gate.dart';
import 'package:recapture/domain/catalog/publish_request_result.dart';
import 'package:recapture/domain/catalog/publish_status.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_food_type.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/presentation/screens/catalog/publish_screen.dart';
import 'package:recapture/presentation/screens/rep/rep_publish_screen.dart';

import '../rep/rep_repo_catalog_defaults.dart';
import 'catalog_entities_test.dart' as golden;
import 'publish_fakes.dart';

const _kCatalogId = '6a83dd464aea89d1d2d28d50';
const _kOwnerMarker = 'OWNER SUBSCRIPTION SCREEN';
const _kRepMarker = 'REP RESTAURANT DETAIL';

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

Map<String, dynamic> _blockedBy(String code) => statusPayload(
      gates: [
        gatePayload(
          code: code,
          message: 'No subscription yet — start a free trial or activate a '
              'plan to publish.',
        ),
      ],
    );

class _FakeRepRepository with RepRepoCatalogDefaults implements RepRepository {
  _FakeRepRepository(this._status);

  final Map<String, dynamic> _status;

  @override
  Future<PublishStatus> publishStatus(String catalogId) async =>
      PublishStatus.fromMap(_status);

  @override
  Future<Catalog> catalog(String catalogId) async =>
      Catalog.fromMap({...golden.catalogGolden(), 'id': catalogId});

  @override
  Future<PublishRequestResult> publish(
    String catalogId, {
    String? idempotencyKey,
  }) async =>
      throw UnimplementedError();

  @override
  Future<QrCodePreflight> preflight(String code) async =>
      throw UnimplementedError();

  @override
  Future<RepActivation> activate(RepActivationRequest request) async =>
      throw UnimplementedError();

  @override
  Future<List<CatalogProduct>> products(String catalogId) async => const [];

  @override
  Future<List<RepCatalogSummary>> catalogs() async => const [];

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
  Future<void> attachCode(String catalogId, String code) async {}

  @override
  Future<void> retireCode(String code) async {}

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

Widget _ownerHarness(FakePublishRepository repo) {
  final router = GoRouter(
    initialLocation: AppRoutes.catalogPublish,
    routes: [
      GoRoute(
        path: AppRoutes.catalogPublish,
        name: AppRouteNames.catalogPublish,
        builder: (_, __) => const PublishScreen(),
      ),
      GoRoute(
        path: AppRoutes.catalogSubscription,
        name: AppRouteNames.catalogSubscription,
        builder: (_, __) => const Scaffold(body: Text(_kOwnerMarker)),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      authProvider.overrideWith(_StubAuth.new),
      catalogRepositoryProvider.overrideWithValue(repo),
      isOnlineProvider.overrideWithValue(true),
      catalogLinkActionsProvider.overrideWithValue(FakeLinkActions()),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

Widget _repHarness(_FakeRepRepository repo) {
  final router = GoRouter(
    initialLocation: '${AppRoutes.repCatalogs}/$_kCatalogId/publish',
    routes: [
      GoRoute(
        path: '${AppRoutes.repCatalogs}/:id',
        builder: (_, __) => const Scaffold(body: Text(_kRepMarker)),
        routes: [
          GoRoute(
            path: 'publish',
            builder: (_, state) =>
                RepPublishScreen(catalogId: state.pathParameters['id']!),
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      authProvider.overrideWith(_StubAuth.new),
      repRepositoryProvider.overrideWithValue(repo),
      isOnlineProvider.overrideWithValue(true),
      catalogLinkActionsProvider.overrideWithValue(FakeLinkActions()),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  for (final code in const [
    'SUBSCRIPTION_REQUIRED',
    'SUBSCRIPTION_CAPACITY_EXCEEDED',
  ]) {
    testWidgets('owner: Fix for $code opens /catalog/subscription',
        (tester) async {
      final repo = FakePublishRepository(status: _blockedBy(code));
      await tester.pumpWidget(_ownerHarness(repo));
      await tester.pumpAndSettle();

      final label = PublishGateCodeX.fromApiValue(code).fixLabel!;
      expect(find.widgetWithText(TextButton, label), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, label));
      await tester.pumpAndSettle();

      expect(find.text(_kOwnerMarker), findsOneWidget);
    });

    testWidgets('rep: Fix for $code opens /rep/catalogs/:id', (tester) async {
      final repo = _FakeRepRepository(_blockedBy(code));
      await tester.pumpWidget(_repHarness(repo));
      await tester.pumpAndSettle();

      final label = PublishGateCodeX.fromApiValue(code).fixLabel!;
      expect(find.widgetWithText(TextButton, label), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, label));
      await tester.pumpAndSettle();

      expect(find.text(_kRepMarker), findsOneWidget);
    });
  }
}
