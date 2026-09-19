// test/rep/rep_catalogs_ordering_test.dart
//
// 'My restaurants' orders for attention (stage-04): overdue first, then
// whoever needs a nudge soonest — never the order the rep signed them up in.
//
// The row a rep must act on today is the GRACE one whose 3D menu pauses in
// two days; buried under twenty ACTIVE rows it is the row nobody scrolls to.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/theme/app_colors.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/qr_download_file.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart'
    show StandeeQrFormat;
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show ProductImageSlot;
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/catalog/publish_request_result.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_food_type.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/domain/rep/rep_catalog_ordering.dart';
import 'package:recapture/presentation/screens/rep/rep_catalogs_screen.dart';

import 'rep_repo_catalog_defaults.dart';

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

RepCatalogSummary _row(
  String id,
  String name, {
  String? status,
  int? daysLeft,
}) =>
    RepCatalogSummary.fromMap({
      'id': id,
      'name': name,
      'businessName': name,
      'status': 'DRAFT',
      if (status != null)
        'subscription': {'status': status, 'daysLeft': daysLeft},
    });

/// The server's order — delegation order — with the urgent rows buried.
final _fixtures = [
  _row('a', 'Active Thirty', status: 'ACTIVE', daysLeft: 30),
  _row('b', 'Trial Twelve', status: 'TRIAL', daysLeft: 12),
  _row('c', 'No Plan'),
  _row('d', 'Overdue Three', status: 'GRACE', daysLeft: 3),
  _row('e', 'Comped', status: 'COMPED', daysLeft: 300),
  _row('f', 'Cancelled', status: 'CANCELLED'),
  _row('g', 'Paused', status: 'PAUSED'),
  _row('h', 'Overdue One', status: 'GRACE', daysLeft: 1),
  _row('i', 'Active Five', status: 'ACTIVE', daysLeft: 5),
  _row('j', 'Trial Two', status: 'TRIAL', daysLeft: 2),
];

class _FakeRepo with RepRepoCatalogDefaults implements RepRepository {
  @override
  Future<List<RepCatalogSummary>> catalogs() async => _fixtures;

  // ── Not exercised ─────────────────────────────────────────────────────────

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

void main() {
  test(
      'orderRepCatalogsForAttention: GRACE, PAUSED, none, TRIAL, ACTIVE, '
      'COMPED, CANCELLED — then fewest days left, stable', () {
    final ordered = orderRepCatalogsForAttention(_fixtures);
    expect(ordered.map((r) => r.id).toList(), [
      'h', // GRACE 1d
      'd', // GRACE 3d
      'g', // PAUSED
      'c', // no plan
      'j', // TRIAL 2d
      'b', // TRIAL 12d
      'i', // ACTIVE 5d
      'a', // ACTIVE 30d
      'e', // COMPED
      'f', // CANCELLED
    ]);
    // Pure: the input is untouched.
    expect(_fixtures.first.id, 'a');
  });

  test('is stable for rows that tie', () {
    final rows = [
      _row('x', 'X', status: 'ACTIVE', daysLeft: 10),
      _row('y', 'Y', status: 'ACTIVE', daysLeft: 10),
      _row('z', 'Z', status: 'ACTIVE'),
    ];
    expect(
      orderRepCatalogsForAttention(rows).map((r) => r.id).toList(),
      ['x', 'y', 'z'],
    );
  });

  testWidgets(
      'the list puts an overdue restaurant above an active one, '
      'in the error colour', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(_StubAuth.new),
          repRepositoryProvider.overrideWithValue(_FakeRepo()),
        ],
        child: const MaterialApp(home: RepCatalogsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Ten rows do not all fit the test viewport; the ones that matter are at
    // the top — which is the point.
    final overdueOne = find.text('Overdue One');
    final overdueThree = find.text('Overdue Three');
    final paused = find.text('Paused');
    expect(overdueOne, findsOneWidget);
    expect(overdueThree, findsOneWidget);
    expect(paused, findsOneWidget);
    expect(
      tester.getTopLeft(overdueOne).dy,
      lessThan(tester.getTopLeft(overdueThree).dy),
    );
    expect(
      tester.getTopLeft(overdueThree).dy,
      lessThan(tester.getTopLeft(paused).dy),
    );
    // ACTIVE rows are somewhere below (or off the bottom) — never above.
    for (final name in ['Active Thirty', 'Active Five']) {
      final active = find.text(name);
      if (active.evaluate().isNotEmpty) {
        expect(
          tester.getTopLeft(active).dy,
          greaterThan(tester.getTopLeft(paused).dy),
        );
      }
    }

    // The GRACE chip is the red one.
    final chip = tester.widget<Text>(find.text('Overdue 1d'));
    expect(chip.style?.color, AppColors.error);
    final trialChip = tester.widget<Text>(find.text('Trial 2d'));
    expect(trialChip.style?.color, isNot(AppColors.error));
  });
}
