// test/rep/rep_catalog_qr_test.dart
//
// "Show me the code" — the QR a rep pulls up standing in the restaurant.
//
// WHAT THIS FILE EXISTS TO CATCH, in order of how badly the alternative goes:
//
//   • THE BUTTON ON A RESTAURANT THAT HAS NO CODE. A QR is minted server-side
//     and never invented, so a control on a draft row sends a rep to a screen
//     whose only content is "not yet" — and they would tap it at a table, in
//     front of the owner. The gate is `status.isLive` and this pins it.
//   • A LINK THE CLIENT TOUCHED. `publicUrl` is frozen server-side and every
//     printed sticker resolves through it. A rep surface that shortened or
//     rebuilt it would break codes already on tables, silently.
//   • THE PRE-PUBLISH AND REVOKED STATES READ AS THE SAME BUG. "Publish the
//     menu" is an instruction a rep can act on; "this restaurant is no longer
//     yours" is a fact that should stop them trying; "try again" is an apology
//     for us. Three different next moves, so three different screens.
//
// Hermetic: the repository, the delivery seam and the link actions are fakes.
import 'dart:convert';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_link_service.dart';
import 'package:recapture/application/catalog/catalog_qr_service.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_repository.dart'
    show CatalogQrFormat, CatalogQrFormatX, CatalogQrImage;
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show ProductImageSlot;
import 'package:recapture/data/repositories/admin_standee_repository.dart'
    show StandeeQrFormat;
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/catalog/publish_request_result.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/catalog_status.dart';
import 'package:recapture/domain/entities/product_food_type.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/presentation/screens/rep/rep_catalog_qr_screen.dart';
import 'package:recapture/presentation/screens/rep/rep_catalogs_screen.dart';

import '../catalog/publish_fakes.dart' show FakeLinkActions, FakeQrDeliverer;
import 'rep_repo_catalog_defaults.dart';

const String kLiveId = 'cat_live_1';
const String kDraftId = 'cat_draft_1';
const String kLiveUrl = 'https://menu.example.com/6a83dd464aea89d1d2d28d51';

RepCatalogSummary _summary(String id, CatalogStatus status) =>
    RepCatalogSummary(
      id: id,
      name: 'blue_cafe',
      businessName: status.isLive ? 'Blue Cafe' : 'Green Cafe',
      status: status,
      publicUrl: status.isLive ? kLiveUrl : null,
      isProvisioned: status.isLive,
    );

Catalog _document({String? publicUrl = kLiveUrl}) => Catalog(
      id: kLiveId,
      name: 'blue_cafe',
      businessName: 'Blue Cafe',
      status: CatalogStatus.published,
      hasUnpublishedChanges: false,
      isPublishing: false,
      isProvisioned: publicUrl != null,
      publicUrl: publicUrl,
    );

class _FakeRepo with RepRepoCatalogDefaults implements RepRepository {
  _FakeRepo({this.rows = const []});

  List<RepCatalogSummary> rows;

  /// The document behind the QR screen. Null makes the read fail, which is what
  /// a revoked delegation looks like from here.
  Catalog? document = _document();

  CatalogFailure? qrFailure;

  /// Every format asked for, in order — the PNG must be fetched ONCE and reused
  /// for the download, and this is what proves it.
  final List<CatalogQrFormat> qrCalls = [];
  final List<String> qrIdsAskedFor = [];

  @override
  Future<List<RepCatalogSummary>> catalogs() async => rows;

  @override
  Future<Catalog> catalog(String catalogId) async {
    final doc = document;
    if (doc == null) {
      throw const CatalogFailure(
        code: 'CATALOG_NOT_FOUND',
        message: 'That catalog was not found.',
      );
    }
    return doc;
  }

  @override
  Future<CatalogQrImage> catalogQr(
    String catalogId, {
    CatalogQrFormat format = CatalogQrFormat.png,
    int? size,
  }) async {
    qrCalls.add(format);
    qrIdsAskedFor.add(catalogId);
    if (qrFailure != null) throw qrFailure!;
    return CatalogQrImage(
      bytes: Uint8List.fromList(utf8.encode('qr-bytes-${format.apiValue}')),
      contentType:
          format == CatalogQrFormat.png ? 'image/png' : 'application/pdf',
      fileName: 'blue-cafe-qr.${format.apiValue}',
      format: format,
    );
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

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// The QR screen on its own, mounted directly.
Widget _qrHarness(
  _FakeRepo repo, {
  FakeQrDeliverer? deliverer,
  FakeLinkActions? links,
}) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        repRepositoryProvider.overrideWithValue(repo),
        qrDelivererProvider.overrideWithValue(deliverer ?? FakeQrDeliverer()),
        catalogLinkActionsProvider.overrideWithValue(links ?? FakeLinkActions()),
      ],
      child: const MaterialApp(
        home: RepCatalogQrScreen(catalogId: kLiveId),
      ),
    );

/// 'My restaurants' with a REAL router under it, because the thing being tested
/// on that screen is a navigation — a button that renders and goes nowhere is
/// the failure this catches, and a MaterialApp with a bare `home:` cannot tell
/// the two apart.
Widget _listHarness(_FakeRepo repo) {
  final router = GoRouter(
    initialLocation: '/rep/catalogs',
    routes: [
      GoRoute(
        path: '/rep/catalogs',
        builder: (_, __) => const RepCatalogsScreen(),
        routes: [
          GoRoute(
            path: ':id/qr',
            builder: (_, state) => RepCatalogQrScreen(
              catalogId: state.pathParameters['id'] ?? '',
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
      qrDelivererProvider.overrideWithValue(FakeQrDeliverer()),
      catalogLinkActionsProvider.overrideWithValue(FakeLinkActions()),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  group('the QR button on My restaurants', () {
    testWidgets('is on the live restaurant and NOT on the draft one',
        (tester) async {
      final repo = _FakeRepo(rows: [
        _summary(kLiveId, CatalogStatus.published),
        _summary(kDraftId, CatalogStatus.draft),
      ]);
      await tester.pumpWidget(_listHarness(repo));
      await tester.pumpAndSettle();

      // A code exists from provisioning and is never invented, so the control
      // exists exactly where the code does.
      expect(
        find.byKey(const ValueKey('rep_catalog_qr_$kLiveId')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('rep_catalog_qr_$kDraftId')),
        findsNothing,
      );
    });

    testWidgets('opens the QR screen for THAT restaurant', (tester) async {
      final repo = _FakeRepo(rows: [
        _summary(kLiveId, CatalogStatus.published),
        _summary(kDraftId, CatalogStatus.draft),
      ]);
      await tester.pumpWidget(_listHarness(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('rep_catalog_qr_$kLiveId')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('qr_image')), findsOneWidget);
      // The id from the row that was tapped, not the first in the list and not
      // whatever the detail screen was last looking at.
      expect(repo.qrIdsAskedFor, [kLiveId]);
    });

    testWidgets('a live row still opens the restaurant when the row is tapped',
        (tester) async {
      // The QR is an ADDITION to the row, not a replacement for it: the button
      // sits inside the same InkWell, and an icon that swallowed the row tap
      // would take the rep's way into the dishes with it.
      final repo = _FakeRepo(rows: [_summary(kLiveId, CatalogStatus.published)]);
      await tester.pumpWidget(_listHarness(repo));
      await tester.pumpAndSettle();

      final row = tester.widget<InkWell>(
        find.ancestor(
          of: find.text('Blue Cafe'),
          matching: find.byType(InkWell),
        ),
      );
      expect(row.onTap, isNotNull);
    });
  });

  group('the rep QR screen', () {
    testWidgets('renders the square and the frozen link, verbatim',
        (tester) async {
      final repo = _FakeRepo();
      await tester.pumpWidget(_qrHarness(repo));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('qr_image')), findsOneWidget);
      // Character for character. Nothing here composes, shortens or re-cases it.
      expect(find.text(kLiveUrl), findsOneWidget);
      expect(find.textContaining('Print it once'), findsOneWidget);
    });

    testWidgets('saves the PNG through the delivery seam, without refetching',
        (tester) async {
      final repo = _FakeRepo();
      final deliverer = FakeQrDeliverer();
      await tester.pumpWidget(_qrHarness(repo, deliverer: deliverer));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('qr_save_png')));
      await tester.pumpAndSettle();

      // ONE fetch, for the render. The bytes on screen ARE the download — the
      // endpoint is rate-limited and the image is a pure function of a URL that
      // never changes, so a second request would buy nothing.
      expect(repo.qrCalls, [CatalogQrFormat.png]);
      expect(deliverer.delivered.single.fileName, 'blue-cafe-qr.png');
    });

    testWidgets('the PDF is a second render, so it IS fetched', (tester) async {
      final repo = _FakeRepo();
      final deliverer = FakeQrDeliverer();
      await tester.pumpWidget(_qrHarness(repo, deliverer: deliverer));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('qr_save_pdf')));
      await tester.pumpAndSettle();

      expect(repo.qrCalls, [CatalogQrFormat.png, CatalogQrFormat.pdf]);
      expect(deliverer.delivered.single.mimeType, 'application/pdf');
    });

    testWidgets('before the menu is live it instructs, it does not apologise',
        (tester) async {
      final repo = _FakeRepo()
        ..qrFailure = const CatalogFailure(
          code: 'CATALOG_NOT_PUBLISHED',
          message: 'Publish this menu first.',
        );
      await tester.pumpWidget(_qrHarness(repo));
      await tester.pumpAndSettle();

      expect(
        find.text('The QR code is created when the menu goes live'),
        findsOneWidget,
      );
      expect(find.textContaining('permanent link'), findsOneWidget);
      // Nothing to retry — the rep has to go and publish, and a button that
      // just re-fails would send them round the same loop.
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a revoked delegation says so, rather than offering a retry',
        (tester) async {
      final repo = _FakeRepo()
        ..qrFailure = const CatalogFailure(
          code: 'CATALOG_NOT_FOUND',
          message: 'That catalog was not found.',
        );
      await tester.pumpWidget(_qrHarness(repo));
      await tester.pumpAndSettle();

      expect(
        find.text('This restaurant is no longer assigned to you'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a genuine failure offers the retry, and it refetches',
        (tester) async {
      final repo = _FakeRepo()
        ..qrFailure = const CatalogFailure(
          code: 'NETWORK',
          message: 'Something went wrong. Please try again.',
        );
      await tester.pumpWidget(_qrHarness(repo));
      await tester.pumpAndSettle();

      expect(find.text("We couldn't load this QR code"), findsOneWidget);

      repo.qrFailure = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('qr_image')), findsOneWidget);
    });
  });
}
