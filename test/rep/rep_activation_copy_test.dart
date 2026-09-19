// test/rep/rep_activation_copy_test.dart
//
// The CONFIRM step's payment sentence (stage-04, A2): under the number the
// rep reads back, "The owner will log in and pay using this number."
//
// One sentence, one test — but it is the sentence that stops a rep expecting
// to take the money themselves, and it has to sit UNDER the number so the
// digits get a second look for the right reason.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/qr_download_file.dart';
import 'package:recapture/application/rep/rep_capabilities.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart'
    show StandeeQrFormat;
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show ProductImageSlot;
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/catalog/publish_request_result.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_food_type.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/presentation/screens/rep/rep_activation_screen.dart';

import 'rep_repo_catalog_defaults.dart';

/// Preflight says "available"; nothing else is reached before CONFIRM.
class _FakeRepRepository with RepRepoCatalogDefaults implements RepRepository {
  @override
  Future<QrCodePreflight> preflight(String code) async =>
      QrCodePreflight(code: code, state: 'UNASSIGNED', isAvailable: true);

  @override
  Future<RepActivation> activate(RepActivationRequest request) async =>
      throw UnimplementedError('activation is not reached by this test');

  @override
  Future<List<RepCatalogSummary>> catalogs() async => const [];

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

Widget _app(RepRepository repo) => ProviderScope(
      overrides: [
        repRepositoryProvider.overrideWithValue(repo),
        repCapabilitiesProvider.overrideWithValue(
          const RepCapabilities(canScan: false, canCaptureDish: false),
        ),
      ],
      child: const MaterialApp(home: RepActivationScreen()),
    );

/// Walks the flow as far as the confirmation step.
Future<void> _reachConfirm(WidgetTester tester) async {
  await tester.enterText(
      find.byKey(const ValueKey('rep_code_field')), 'ABCD2345');
  await tester.tap(find.byKey(const ValueKey('rep_code_continue')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('rep_name_field')),
    'Green Chilli Kitchen',
  );
  await tester.enterText(
      find.byKey(const ValueKey('rep_phone_field')), '9876543210');
  await tester.tap(find.byKey(const ValueKey('rep_details_continue')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'the CONFIRM step says the owner will log in and pay on this number',
      (tester) async {
    await tester.pumpWidget(_app(_FakeRepRepository()));
    await _reachConfirm(tester);

    final note = find.byKey(const ValueKey('rep_confirm_pay_note'));
    expect(note, findsOneWidget);
    final noteText = tester.widget<Text>(
      find.descendant(of: note, matching: find.byType(Text)),
    );
    expect(noteText.data, 'The owner will log in and pay using this number.');

    // UNDER the number, not above it: the sentence explains the digits the
    // rep has just read back.
    final phoneY =
        tester.getTopLeft(find.byKey(const ValueKey('rep_confirm_phone'))).dy;
    expect(tester.getTopLeft(note).dy, greaterThan(phoneY));

    // Same style as the step's existing hint line — a note, not a warning.
    final hint = tester.widget<Text>(
      find.text(
          'The owner will sign in with this number. Read it back to them.'),
    );
    expect(noteText.style, hint.style);
  });
}
