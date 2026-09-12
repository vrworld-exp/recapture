// test/rep/rep_publish_test.dart
//
// "Publish the menu", from the rep's side of the table — on the OWNER's
// publish screen, delegated.
//
// THE ASSERTION THAT CARRIES THIS SUITE is parity. The owner's publish screen
// (test/catalog/publish_screen_test.dart) is built around partial failure: a
// live progress line, a per-product failure list with OUR sentences, a
// one-tap retry, a gate checklist that goes to the fix, and a 409 treated as
// the run the user wanted. The rep used to get a button and a toast. Every
// test below pins one of those behaviours on the REP's screen, driven through
// the REP's repository — so the two doors cannot drift apart again without a
// test noticing.
//
// And the two things that are deliberately NOT parity:
//   • a rep cannot take the page offline — the control is absent, not 404ing;
//   • a gate's "Fix" goes to the rep's own screens, resolved from the catalog
//     id in the path rather than from a token.
//
// Hermetic: the repository is a fake, connectivity is faked, and every timer
// is drained before a test ends.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_link_service.dart';
import 'package:recapture/application/catalog/qr_download_file.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/application/rep/rep_publish_notifier.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart'
    show StandeeQrFormat;
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show ProductImageSlot;
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/catalog/publish_request_result.dart';
import 'package:recapture/domain/catalog/publish_status.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/presentation/screens/rep/rep_publish_screen.dart';

import '../catalog/catalog_entities_test.dart' as golden;
import '../catalog/publish_fakes.dart'
    show FakeLinkActions, gatePayload, productPayload, runPayload, statusPayload;
import 'rep_repo_catalog_defaults.dart';

const kCatalogId = '6a83dd464aea89d1d2d28d50';

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// The rep repository, with its publish surface scripted.
class _FakeRepRepository with RepRepoCatalogDefaults implements RepRepository {
  _FakeRepRepository({Map<String, dynamic>? status})
      : _status = status ?? statusPayload();

  Map<String, dynamic> _status;

  /// Every status read, counted — the poll-loop tests are about this number.
  int statusCalls = 0;
  int publishCalls = 0;
  int retryCalls = 0;
  int documentReads = 0;
  final List<String?> idempotencyKeys = [];
  final List<String?> renames = [];

  /// Which catalog every publish-surface call was made for.
  final List<String> catalogIds = [];

  PublishRequestResult publishResult = const PublishQueued(runId: 'run-1');
  CatalogFailure? statusFailure;
  CatalogFailure? publishFailure;

  void setStatus(Map<String, dynamic> status) => _status = status;

  @override
  Future<PublishStatus> publishStatus(String catalogId) async {
    catalogIds.add(catalogId);
    statusCalls++;
    if (statusFailure != null) throw statusFailure!;
    return PublishStatus.fromMap(_status);
  }

  @override
  Future<PublishRequestResult> publish(
    String catalogId, {
    String? idempotencyKey,
  }) async {
    catalogIds.add(catalogId);
    publishCalls++;
    idempotencyKeys.add(idempotencyKey);
    if (publishFailure != null) throw publishFailure!;
    return publishResult;
  }

  @override
  Future<PublishRequestResult> retryFailedPublish(String catalogId) async {
    catalogIds.add(catalogId);
    retryCalls++;
    if (publishFailure != null) throw publishFailure!;
    return publishResult;
  }

  @override
  Future<Catalog> catalog(String catalogId) async {
    documentReads++;
    return Catalog.fromMap({...golden.catalogGolden(), 'id': catalogId});
  }

  @override
  Future<BusinessProfile> updateProfile(
    String catalogId, {
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) async {
    catalogIds.add(catalogId);
    renames.add(name);
    return BusinessProfile.fromMap({
      ...golden.profileGolden(),
      if (name != null) 'name': name,
    });
  }

  // ── The rest of the seam, not exercised here ──────────────────────────────

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

  @override
  Future<List<RepStandee>> standees() async => const [];

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

Widget _harness(_FakeRepRepository repo, {bool online = true}) => ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        repRepositoryProvider.overrideWithValue(repo),
        isOnlineProvider.overrideWithValue(online),
        catalogLinkActionsProvider.overrideWithValue(FakeLinkActions()),
      ],
      child: const MaterialApp(
        home: RepPublishScreen(catalogId: kCatalogId),
      ),
    );

/// The Publish button itself — `publish_cta` is a wrapper, and `onPressed` is
/// what says whether the press would do anything.
ElevatedButton _ctaOf(WidgetTester tester) => tester.widget<ElevatedButton>(
      find.descendant(
        of: find.byKey(const ValueKey('publish_cta')),
        matching: find.byType(ElevatedButton),
      ),
    );

/// The notifier behind the screen currently on `tester`.
RepPublishNotifier _notifierOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(RepPublishScreen)))
        .read(repPublishProvider(kCatalogId).notifier);

Map<String, dynamic> _inFlight({int synced = 0, bool stale = false}) =>
    statusPayload(
      activeRunId: 'run-1',
      run: runPayload(state: 'RUNNING', total: 10, synced: synced),
    )..['hasChangesSincePublishStarted'] = stale;

void main() {
  group('the rep reads the same run the owner does', () {
    testWidgets('asks for the restaurant in the path, not the rep\'s own',
        (tester) async {
      final repo = _FakeRepRepository();
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      expect(repo.statusCalls, 1);
      expect(repo.catalogIds, everyElement(kCatalogId));
    });

    testWidgets('renders progress with the owner\'s numbers', (tester) async {
      final repo = _FakeRepRepository(status: _inFlight(synced: 7));
      await tester.pumpWidget(_harness(repo));
      await tester.pump();

      expect(find.text('7 of 10 published'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        publicUrl: 'https://menu.example.com/abc',
        run: runPayload(state: 'SUCCEEDED', total: 10, synced: 10),
      ));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('a failure renders OUR sentence, never the server message',
        (tester) async {
      const miragePose =
          'E11000 duplicate key error collection: mirage.items index: name_1';
      final repo = _FakeRepRepository(
        status: statusPayload(
          status: 'PUBLISHED',
          publicUrl: 'https://menu.example.com/abc',
          lastPublishedAt: '2026-09-12T09:00:00.000Z',
          run: runPayload(state: 'PARTIAL', total: 2, synced: 1, failed: 1),
          products: [
            productPayload(id: 'p1', name: 'soup'),
            productPayload(
              id: 'p2',
              name: 'steak',
              syncStatus: 'FAILED',
              code: 'PUBLISH_DUPLICATE_NAME',
              message: miragePose,
            ),
          ],
        ),
      );

      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      expect(find.textContaining(miragePose), findsNothing);
      expect(find.textContaining('E11000'), findsNothing);
      expect(find.textContaining('already uses this name'), findsOneWidget);
      // The rep's words for the rep's things.
      expect(find.text('1 of 2 published · 1 failed'), findsOneWidget);
      expect(find.text('Only the failed dishes are tried again.'), findsOneWidget);
      expect(find.text('Dishes'), findsOneWidget);
    });

    testWidgets('"Retry failed" retries through the rep door', (tester) async {
      final repo = _FakeRepRepository(
        status: statusPayload(
          status: 'PUBLISHED',
          run: runPayload(state: 'PARTIAL', total: 2, synced: 1, failed: 1),
          products: [
            productPayload(id: 'p1', name: 'soup'),
            productPayload(
              id: 'p2',
              name: 'steak',
              syncStatus: 'FAILED',
              code: 'PUBLISH_UPSTREAM_TIMEOUT',
            ),
          ],
        ),
      )..publishResult = const PublishQueued(runId: 'run-2');

      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      repo.setStatus(_inFlight(synced: 0));
      await tester.tap(find.byKey(const ValueKey('publish_retry_failed')));
      await tester.pump();
      await tester.pump();

      expect(repo.retryCalls, 1);
      expect(repo.publishCalls, 0, reason: 'retry must not be a full publish');
      expect(find.text('Publishing…'), findsWidgets);

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        run: runPayload(state: 'SUCCEEDED', total: 1, synced: 1),
      ));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });
  });

  group('pressing Publish', () {
    _FakeRepRepository ready() => _FakeRepRepository(
          status: statusPayload(
            products: [productPayload(id: 'p1', name: 'soup')],
          ),
        );

    testWidgets('publishes the restaurant in the path and watches the run',
        (tester) async {
      final repo = ready();
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();
      expect(find.text('Publish menu'), findsOneWidget);

      repo.setStatus(_inFlight());
      await tester.tap(find.byKey(const ValueKey('publish_cta')));
      await tester.pump();
      await tester.pump();

      expect(repo.publishCalls, 1);
      expect(repo.catalogIds, everyElement(kCatalogId));
      expect(find.text('Publishing…'), findsWidgets);
      // The dish list's bar reads the delegated document; a status read is
      // what re-reads it, and only after the screen has learned something.
      expect(repo.documentReads, greaterThanOrEqualTo(1));

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        run: runPayload(state: 'SUCCEEDED', total: 1, synced: 1),
      ));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('a second press gets 409 and shows the run, not an error',
        (tester) async {
      // THE ONE THAT MATTERS. A 3D dish that finished a moment ago has already
      // started a run; the rep's question was "is this menu going up", and
      // the answer is yes. Surfacing our lock as a failure would send a rep
      // out of the building believing the standee is dead.
      final repo = ready()..publishResult = const PublishAlreadyRunning('run-9');
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      repo.setStatus(_inFlight());
      await tester.tap(find.byKey(const ValueKey('publish_cta')));
      await tester.pump();
      await tester.pump();

      expect(find.text('Publishing…'), findsWidgets);
      expect(find.textContaining('already running'), findsNothing);
      expect(find.textContaining('could not be published'), findsNothing);

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        run: runPayload(state: 'SUCCEEDED', total: 1, synced: 1),
      ));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('REUSES its idempotency key after a lost response',
        (tester) async {
      final repo = ready()
        ..publishFailure = const CatalogFailure(
          code: 'OFFLINE',
          message: 'offline',
          isOffline: true,
        );
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('publish_cta')));
      await tester.pumpAndSettle();
      repo.publishFailure = null;
      await tester.tap(find.byKey(const ValueKey('publish_cta')));
      await tester.pumpAndSettle();

      expect(repo.idempotencyKeys, hasLength(2));
      expect(repo.idempotencyKeys.first, isNotNull);
      expect(repo.idempotencyKeys.first, repo.idempotencyKeys.last);

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        run: runPayload(state: 'SUCCEEDED', total: 1, synced: 1),
      ));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('a name clash offers the rename and renames the RESTAURANT',
        (tester) async {
      final repo = ready()
        ..publishResult = const PublishNameTaken('blue_cafe_2');
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('publish_cta')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('publish_name_taken')), findsOneWidget);
      expect(find.textContaining('restaurant name'), findsOneWidget);

      repo.publishResult = const PublishQueued(runId: 'run-3');
      repo.setStatus(_inFlight());
      await tester
          .tap(find.byKey(const ValueKey('publish_accept_suggested_name')));
      await tester.pump();
      await tester.pump();

      // The rename went through the rep's profile PATCH, then a publish.
      expect(repo.renames, ['blue_cafe_2']);
      expect(repo.publishCalls, 2);

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        run: runPayload(state: 'SUCCEEDED', total: 1, synced: 1),
      ));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('never fires into a guaranteed 422', (tester) async {
      final repo = _FakeRepRepository(
        status: statusPayload(
          gates: [
            gatePayload(
              code: 'CATALOG_EMPTY',
              message: 'Add at least one product before publishing.',
            ),
          ],
        ),
      );
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      expect(_ctaOf(tester).onPressed, isNull);
      expect(
        find.byKey(const ValueKey('publish_gate_checklist')),
        findsOneWidget,
      );
      // The checklist's own sentence, and a way to the fix.
      expect(find.text('Add a product'), findsOneWidget);
    });

    testWidgets('offers no fix for a section name the rep cannot edit',
        (tester) async {
      final repo = _FakeRepRepository(
        status: statusPayload(
          gates: [
            gatePayload(
              code: 'CATEGORY_NAME_INVALID',
              message: 'A category has a name that cannot be published.',
            ),
          ],
        ),
      );
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      // The sentence stays; the button that would open nothing does not.
      expect(find.textContaining('cannot be published'), findsOneWidget);
      expect(find.text('Rename category'), findsNothing);
    });
  });

  group('what the rep is not offered', () {
    testWidgets('no "take offline", even on a live menu', (tester) async {
      final repo = _FakeRepRepository(
        status: statusPayload(
          status: 'PUBLISHED',
          hasDraftChanges: false,
          publicUrl: 'https://menu.example.com/abc',
          lastPublishedAt: '2026-09-12T09:00:00.000Z',
          run: runPayload(state: 'SUCCEEDED', total: 1, synced: 1),
          products: [productPayload(id: 'p1', name: 'soup')],
        ),
      );
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      // Live, with the link and the QR — the owner's success card.
      expect(find.text('Live on Mirage'), findsOneWidget);
      expect(find.byKey(const ValueKey('publish_public_url')), findsOneWidget);
      expect(find.byKey(const ValueKey('publish_open_qr')), findsOneWidget);
      // …and NOT the owner's way to take it down.
      expect(find.byKey(const ValueKey('publish_unpublish')), findsNothing);
    });
  });

  group('the poll loop', () {
    testWidgets('polls a run in flight and stops on a terminal state',
        (tester) async {
      final repo = _FakeRepRepository(status: _inFlight());
      await tester.pumpWidget(_harness(repo));
      await tester.pump();
      expect(repo.statusCalls, 1);

      await tester.pump(const Duration(seconds: 1));
      expect(repo.statusCalls, 2);

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        publicUrl: 'https://menu.example.com/abc',
        run: runPayload(state: 'SUCCEEDED', total: 10, synced: 10),
      ));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      final settled = repo.statusCalls;
      await tester.pump(const Duration(minutes: 2));
      expect(repo.statusCalls, settled,
          reason: 'a finished run must not keep being polled');
    });

    testWidgets('stops when the screen is disposed', (tester) async {
      final repo = _FakeRepRepository(status: _inFlight());
      await tester.pumpWidget(_harness(repo));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final beforeLeaving = repo.statusCalls;

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump(const Duration(minutes: 2));

      expect(repo.statusCalls, beforeLeaving);
    });

    testWidgets('pauses in a hidden tab and catches up on return',
        (tester) async {
      final repo = _FakeRepRepository(status: _inFlight());
      await tester.pumpWidget(_harness(repo));
      await tester.pump();

      _notifierOf(tester).debugSetHidden(true);
      await tester.pump();
      final whileHidden = repo.statusCalls;
      await tester.pump(const Duration(seconds: 30));
      expect(repo.statusCalls, whileHidden);
      expect(find.byKey(const ValueKey('publish_paused_note')), findsOneWidget);

      _notifierOf(tester).debugSetHidden(false);
      await tester.pump();
      expect(repo.statusCalls, whileHidden + 1, reason: 'immediate catch-up');

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        run: runPayload(state: 'SUCCEEDED', total: 10, synced: 10),
      ));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('says when the run does not carry the latest edits',
        (tester) async {
      // NOT reassurance. A run plans from a snapshot; a price fixed since is
      // genuinely not in it, and a rep reading "Publishing…" would leave
      // believing it was.
      final repo = _FakeRepRepository(status: _inFlight(stale: true));
      await tester.pumpWidget(_harness(repo));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('publish_stale_run_note')),
        findsOneWidget,
      );

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        run: runPayload(state: 'SUCCEEDED', total: 10, synced: 10),
      ));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });
  });

  group('how it ended, said out loud', () {
    testWidgets('a run this screen watched finish says which ending it was',
        (tester) async {
      final repo = _FakeRepRepository(status: _inFlight());
      await tester.pumpWidget(_harness(repo));
      await tester.pump();

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        publicUrl: 'https://menu.example.com/abc',
        run: runPayload(state: 'PARTIAL', total: 10, synced: 7, failed: 3),
        products: [
          productPayload(id: 'p1', name: 'soup'),
          productPayload(
            id: 'p2',
            name: 'steak',
            syncStatus: 'FAILED',
            code: 'PUBLISH_UPSTREAM_TIMEOUT',
          ),
        ],
      ));
      // The poll lands, the status resolves, the listener speaks, the toast
      // animates in — one frame each.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // "done" over a run that failed three dishes is the message that stops
      // someone ever looking at the list below.
      expect(
        find.textContaining('3 of 10 could not be published'),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    });
  });
}
