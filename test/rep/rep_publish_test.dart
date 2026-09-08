// test/rep/rep_publish_test.dart
//
// "Publish the menu", from the rep's side of the table.
//
// THE ASSERTION THAT CARRIES THIS SUITE is that an already-running publish is a
// SUCCESS. A rep taps Publish, a 3D dish that finished thirty seconds earlier
// has already started a run, and the API answers 409. Reporting that as a
// failure would tell a rep standing in a restaurant that the thing they wanted
// did not happen — when it is happening — and the likely reaction is to add a
// dish and try again, or to leave believing the standee is dead. Our
// concurrency control is not the rep's problem to read about.
//
// Second: a blocked catalog must keep its GATE LIST. The gates name what to fix
// while the rep is still in the room and can fix it; flattening them into one
// generic sentence is what makes the difference between a five-minute repair
// and a second visit.
//
// Hermetic: the repository is a fake, so there is no Dio and no network.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/rep/rep_publish_notifier.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show ProductImageSlot;
import 'package:recapture/application/catalog/qr_download_file.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart'
    show StandeeQrFormat;
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/catalog/publish_gate.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/rep_activation.dart';

import 'rep_repo_catalog_defaults.dart';

class _FakeRepRepository with RepRepoCatalogDefaults implements RepRepository {
  _FakeRepRepository();

  /// What `publish` should do. Defaults to a fresh, queued run.
  RepPublishResult result =
      const RepPublishResult(outcome: RepPublishOutcome.queued);
  Object? throws;

  final List<String> published = [];

  @override
  Future<RepPublishResult> publish(String catalogId) async {
    published.add(catalogId);
    if (throws != null) throw throws!;
    return result;
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
  Future<CatalogProduct> createProduct(
    String catalogId, {
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? sourceModelId,
    String? imageKey,
    String? categoryId,
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

  /// The rep's assigned stock. Empty by default, so a test that does not care
  /// about the recommendations renders exactly the screen it did before.
  List<RepStandee> assignedStandees = const [];

  @override
  Future<List<RepStandee>> standees() async => assignedStandees;

  @override
  Future<QrDownloadFile> standeeFile(
    String code, {
    StandeeQrFormat format = StandeeQrFormat.pdf,
    int? size,
  }) async =>
      QrDownloadFile(
        bytes: Uint8List.fromList([1, 2, 3]),
        fileName: 'standee-$code.pdf',
        mimeType: 'application/pdf',
      );

}

ProviderContainer _containerWith(_FakeRepRepository repo) {
  final container = ProviderContainer(
    overrides: [repRepositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  return container;
}

const _gates = [
  PublishGate(
    code: PublishGateCode.productAssetMissing,
    message: 'Paneer Tikka has no photo.',
  ),
  PublishGate(
    code: PublishGateCode.catalogNameMissing,
    message: 'The restaurant needs a name.',
  ),
];

void main() {
  group('the happy path', () {
    test('asks for the right catalog and confirms', () async {
      final repo = _FakeRepRepository();
      final container = _containerWith(repo);
      final provider = repPublishProvider('cat-1');
      container.listen(provider, (_, __) {});

      await container.read(provider.notifier).publish();

      expect(repo.published, ['cat-1']);
      final state = container.read(provider);
      expect(state.outcome, RepPublishOutcome.queued);
      expect(state.notice, isNotNull);
      expect(state.publishing, isFalse);
      expect(state.failure, isNull);
    });

    test('an already-running publish is a SUCCESS, not an error', () async {
      // THE ONE THAT MATTERS. A 3D dish that finished a moment ago has already
      // started a run; the rep's question was "is this menu going up", and the
      // answer is yes. Surfacing our lock as a failure would send a rep out of
      // the building believing the standee is dead.
      final repo = _FakeRepRepository()
        ..result = const RepPublishResult(
          outcome: RepPublishOutcome.alreadyRunning,
          runId: 'run-9',
        );
      final container = _containerWith(repo);
      final provider = repPublishProvider('cat-1');
      container.listen(provider, (_, __) {});

      await container.read(provider.notifier).publish();

      final state = container.read(provider);
      expect(state.outcome, RepPublishOutcome.alreadyRunning);
      expect(state.failure, isNull);
      expect(state.isBlocked, isFalse);
      // The same confirmation as a fresh run — the rep cannot act on the
      // difference, so the difference is not shown.
      expect(state.notice, isNotNull);
    });

    test('a second tap cannot start a second request', () async {
      final repo = _FakeRepRepository();
      final container = _containerWith(repo);
      final provider = repPublishProvider('cat-1');
      final notifier = container.read(provider.notifier);
      container.listen(provider, (_, __) {});

      await Future.wait([notifier.publish(), notifier.publish()]);

      expect(repo.published, hasLength(1));
    });
  });

  group('when the menu is not ready', () {
    test('keeps every gate, not just the first', () async {
      final repo = _FakeRepRepository()..throws = const RepPublishBlocked(_gates);
      final container = _containerWith(repo);
      final provider = repPublishProvider('cat-1');
      container.listen(provider, (_, __) {});

      await container.read(provider.notifier).publish();

      final state = container.read(provider);
      expect(state.isBlocked, isTrue);
      expect(state.gates, hasLength(2));
      // Fixing one problem per round trip is three trips and three
      // disappointments while a rep stands at a table.
      expect(
        state.gates.map((g) => g.code),
        contains(PublishGateCode.catalogNameMissing),
      );
      expect(state.publishing, isFalse);
    });

    test('a blocked result is still a CatalogFailure a plain screen can show',
        () async {
      final repo = _FakeRepRepository()..throws = const RepPublishBlocked(_gates);
      final container = _containerWith(repo);
      final provider = repPublishProvider('cat-1');
      container.listen(provider, (_, __) {});

      await container.read(provider.notifier).publish();

      // The subclass exists so the ONE screen that renders a checklist gets the
      // gates; every other surface still gets a usable failure.
      final failure = container.read(provider).failure;
      expect(failure, isA<RepPublishBlocked>());
      expect(failure?.code, RepErrorCodes.publishBlocked);
    });

    test('retrying after a fix clears the previous gates', () async {
      final repo = _FakeRepRepository()..throws = const RepPublishBlocked(_gates);
      final container = _containerWith(repo);
      final provider = repPublishProvider('cat-1');
      container.listen(provider, (_, __) {});
      await container.read(provider.notifier).publish();
      expect(container.read(provider).isBlocked, isTrue);

      repo.throws = null;
      await container.read(provider.notifier).publish();

      // Stale gates left on screen would name a problem the rep has already
      // fixed, which is worse than showing none.
      final state = container.read(provider);
      expect(state.isBlocked, isFalse);
      expect(state.gates, isEmpty);
      expect(state.outcome, RepPublishOutcome.queued);
    });
  });

  group('other failures', () {
    test('a revoked delegation surfaces its typed code', () async {
      final repo = _FakeRepRepository()
        ..throws = const CatalogFailure(
          code: RepErrorCodes.catalogNotFound,
          message: 'That catalog was not found.',
        );
      final container = _containerWith(repo);
      final provider = repPublishProvider('cat-1');
      container.listen(provider, (_, __) {});

      await container.read(provider.notifier).publish();

      final state = container.read(provider);
      expect(state.failure?.code, RepErrorCodes.catalogNotFound);
      expect(state.isBlocked, isFalse);
      // The button must come back, not stay stuck spinning.
      expect(state.publishing, isFalse);
    });

    test('dismissing clears the failure and the gates together', () async {
      final repo = _FakeRepRepository()..throws = const RepPublishBlocked(_gates);
      final container = _containerWith(repo);
      final provider = repPublishProvider('cat-1');
      container.listen(provider, (_, __) {});
      await container.read(provider.notifier).publish();

      container.read(provider.notifier).dismissNotice();

      final state = container.read(provider);
      expect(state.failure, isNull);
      expect(state.gates, isEmpty);
    });
  });
}
