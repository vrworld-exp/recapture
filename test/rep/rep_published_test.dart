// test/rep/rep_published_test.dart
//
// "What have I put live" — the rep's own history.
//
// THE ASSERTION THAT CARRIES THIS SUITE is that the total does not move when the
// window does. The count is the reason the screen exists, and the obvious
// implementation — `standees.length` — makes tapping "Last 7 days" look like it
// deleted most of somebody's career. It comes from the server, unfiltered, and
// this file pins that.
//
// Second: the window is sent as `days` and nothing else is inferred client-side.
// A list that filtered locally would quietly disagree with the count beside it.
//
// Hermetic: the repository and the delivery seam are fakes, so no Dio, no share
// sheet, no platform channel.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/catalog_qr_service.dart';
import 'package:recapture/application/rep/rep_published_notifier.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart'
    show StandeeQrFormat;
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/catalog/publish_request_result.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_food_type.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show ProductImageSlot;

import 'rep_repo_catalog_defaults.dart';

RepPublishedStandee _row(String code, {String? business}) =>
    RepPublishedStandee(
      code: code,
      url: 'https://scan.test/r/$code',
      name: 'blue_cafe',
      businessName: business,
      catalogId: 'cat-$code',
    );

class _FakeRepo with RepRepoCatalogDefaults implements RepRepository {
  _FakeRepo();

  RepPublishedPage page = const RepPublishedPage(standees: [], total: 0);
  CatalogFailure? throws;
  Object? fileThrows;

  /// Every `days` value asked for, in order. Null is "all time".
  final List<int?> windows = [];
  final List<String> filesFor = [];

  @override
  Future<RepPublishedPage> publishedStandees({int? days}) async {
    windows.add(days);
    if (throws != null) throw throws!;
    return page;
  }

  @override
  Future<QrDownloadFile> standeeFile(
    String code, {
    StandeeQrFormat format = StandeeQrFormat.pdf,
    int? size,
  }) async {
    filesFor.add(code);
    if (fileThrows != null) throw fileThrows!;
    return QrDownloadFile(
      bytes: Uint8List.fromList([1, 2, 3]),
      fileName: 'standee-$code.pdf',
      mimeType: 'application/pdf',
    );
  }

  @override
  Future<QrCodePreflight> preflight(String code) async =>
      QrCodePreflight(code: code, state: 'UNASSIGNED', isAvailable: true);

  @override
  Future<RepActivation> activate(RepActivationRequest request) async =>
      throw UnimplementedError();

  @override
  Future<List<RepCatalogSummary>> catalogs() async => const [];

  @override
  Future<List<CatalogProduct>> products(String catalogId) async => const [];

  @override
  Future<List<RepStandee>> standees() async => const [];

  @override
  Future<PublishRequestResult> publish(
    String catalogId, {
    String? idempotencyKey,
  }) async =>
      const PublishQueued(runId: 'run-1');

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
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> attachCode(String catalogId, String code) async {}

  @override
  Future<void> retireCode(String code) async {}
}

class _FakeDeliverer implements QrDeliverer {
  final List<QrDownloadFile> delivered = [];
  bool throws = false;

  @override
  Future<void> deliver(QrDownloadFile file) async {
    if (throws) throw StateError('share sheet dismissed');
    delivered.add(file);
  }
}

ProviderContainer _containerWith(_FakeRepo repo, _FakeDeliverer deliverer) {
  final container = ProviderContainer(overrides: [
    repRepositoryProvider.overrideWithValue(repo),
    qrDelivererProvider.overrideWithValue(deliverer),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('the list', () {
    test('loads all time on open', () async {
      final repo = _FakeRepo()
        ..page = RepPublishedPage(standees: [_row('AAAA1111')], total: 1);
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(repPublishedProvider, (_, __) {});
      await pumpEventQueue();

      // No window on the first load: a rep opening the screen wants their whole
      // record, not an arbitrary slice of it.
      expect(repo.windows, [null]);
      expect(container.read(repPublishedProvider).standees, hasLength(1));
    });

    test('prefers the business name and falls back to the readable catalog name',
        () {
      expect(_row('A', business: 'Blue Cafe').displayName, 'Blue Cafe');
      // `name` is slugged server-side because it doubles as the Mirage key, so
      // rows created before the app sent a business name fall back to it — but
      // DE-SLUGGED, the way the public menu prints it. The underscore is an
      // internal detail and must never reach a screen.
      expect(_row('A').displayName, 'blue cafe');
    });

    test('a failure shows an error state rather than an empty list', () async {
      final repo = _FakeRepo()
        ..throws = const CatalogFailure(code: 'OFFLINE', message: 'offline');
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(repPublishedProvider, (_, __) {});
      await pumpEventQueue();

      // "Nothing published yet" for a network failure would tell a rep their
      // work had vanished.
      expect(container.read(repPublishedProvider).page.hasError, isTrue);
    });
  });

  group('the window', () {
    test('is sent to the server as days', () async {
      final repo = _FakeRepo();
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(repPublishedProvider, (_, __) {});
      await pumpEventQueue();

      await container
          .read(repPublishedProvider.notifier)
          .setWindow(PublishedWindow.last7);

      // Filtered SERVER-side. A local filter would disagree with the count
      // beside it the moment the two were derived differently.
      expect(repo.windows, [null, 7]);
    });

    test('THE TOTAL DOES NOT MOVE when the window narrows', () async {
      final repo = _FakeRepo()
        ..page = RepPublishedPage(
          standees: [_row('AAAA1111'), _row('BBBB2222')],
          total: 12,
        );
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(repPublishedProvider, (_, __) {});
      await pumpEventQueue();

      repo.page = RepPublishedPage(standees: [_row('AAAA1111')], total: 12);
      await container
          .read(repPublishedProvider.notifier)
          .setWindow(PublishedWindow.last7);

      final state = container.read(repPublishedProvider);
      expect(state.standees, hasLength(1));
      // The count is the reason the screen exists. `standees.length` here would
      // make a filter look like it deleted most of somebody's career.
      expect(state.total, 12);
    });

    test('re-tapping the current window does not refetch', () async {
      final repo = _FakeRepo();
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(repPublishedProvider, (_, __) {});
      await pumpEventQueue();

      await container
          .read(repPublishedProvider.notifier)
          .setWindow(PublishedWindow.all);

      expect(repo.windows, [null]);
    });
  });

  group('saving a sheet', () {
    test('hands the file to the delivery seam', () async {
      final repo = _FakeRepo();
      final deliverer = _FakeDeliverer();
      final container = _containerWith(repo, deliverer);
      container.listen(repPublishedProvider, (_, __) {});
      await pumpEventQueue();

      await container
          .read(repPublishedProvider.notifier)
          .deliverSheet('AAAA1111');

      expect(repo.filesFor, ['AAAA1111']);
      expect(deliverer.delivered.single.fileName, 'standee-AAAA1111.pdf');
      expect(container.read(repPublishedProvider).busyCode, isNull);
    });

    test('a refused download keeps the list on screen', () async {
      final repo = _FakeRepo()
        ..page = RepPublishedPage(standees: [_row('AAAA1111')], total: 1)
        ..fileThrows =
            const CatalogFailure(code: 'CODE_RETIRED', message: 'retired');
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(repPublishedProvider, (_, __) {});
      await pumpEventQueue();

      await container
          .read(repPublishedProvider.notifier)
          .deliverSheet('AAAA1111');

      final state = container.read(repPublishedProvider);
      expect(state.failure?.code, 'CODE_RETIRED');
      // The rep's next move is usually a different row, so the list stays.
      expect(state.standees, hasLength(1));
    });

    test('a dismissed share sheet becomes one mapped sentence', () async {
      final deliverer = _FakeDeliverer()..throws = true;
      final container = _containerWith(_FakeRepo(), deliverer);
      container.listen(repPublishedProvider, (_, __) {});
      await pumpEventQueue();

      await container
          .read(repPublishedProvider.notifier)
          .deliverSheet('AAAA1111');

      final failure = container.read(repPublishedProvider).failure;
      expect(failure?.code, 'QR_SAVE_FAILED');
      expect(failure?.message, isNot(contains('StateError')));
    });
  });
}
