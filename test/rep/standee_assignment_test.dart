// test/rep/standee_assignment_test.dart
//
// Handing a standee to a rep, from the client side: the admin's assign action,
// the rep's own list, and the recommendations on the activation screen.
//
// THE ASSERTION THAT CARRIES THIS SUITE is that the rep's standee list has NO
// assign control. Assignment is ADMIN-gated on the server, so a button there
// would be an affordance that answers 403 — and it is exactly the kind of
// control that gets copied across when two screens are built from one another,
// which these two were.
//
// Second: assigning PATCHES the row rather than reloading the list. The obvious
// implementation calls load() again, which silently restarts keyset paging at
// page one and throws away every page the admin had scrolled — to learn one
// field the server already returned.
//
// Third: a recommendation is a PREFILL. Tapping one fills the field and stops;
// it must not activate, for the same reason the scanner and the `?code=` deep
// link do not.
//
// Hermetic: repositories and the delivery seam are fakes — no Dio, no share
// sheet, no platform channel.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/admin/admin_batch_codes_notifier.dart';
import 'package:recapture/application/catalog/catalog_qr_service.dart';
import 'package:recapture/application/rep/rep_capabilities.dart';
import 'package:recapture/application/rep/rep_standees_notifier.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show ProductImageSlot;
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/domain/entities/user_role.dart';
import 'package:recapture/presentation/screens/rep/rep_activation_screen.dart';
import 'package:recapture/presentation/screens/rep/rep_standees_screen.dart';

import 'rep_repo_catalog_defaults.dart';

// ── Fixtures ───────────────────────────────────────────────────────────────

StandeeAssignee _person(String id, {String? name, String? masked}) =>
    StandeeAssignee(id: id, displayName: name, contactMasked: masked);

SalesRepSummary _rep(String id, {String? name, String? masked}) =>
    SalesRepSummary(
      person: _person(id, name: name, masked: masked),
      role: UserRole.salesRep,
    );

QrStandeeCode _code(
  String code, {
  QrCodeState state = QrCodeState.unassigned,
  StandeeAssignee? assignedTo,
}) =>
    QrStandeeCode(
      code: code,
      state: state,
      url: 'https://scan.test/r/$code',
      assignedTo: assignedTo,
    );

RepStandee _standee(String code, {QrCodeState state = QrCodeState.unassigned}) =>
    RepStandee(code: code, state: state, url: 'https://scan.test/r/$code');

// ── Fakes ──────────────────────────────────────────────────────────────────

class _FakeAdminRepo implements AdminStandeeRepository {
  _FakeAdminRepo({List<QrStandeeCode>? codes, this.reps = const []})
      : page = QrCodePage(codes: codes ?? [_code('AAAA1111')], nextAfter: 'X');

  QrCodePage page;
  List<SalesRepSummary> reps;
  CatalogFailure? assignThrows;

  final List<({String code, String repUserId})> assigned = [];
  final List<String> unassigned = [];
  int codesCalls = 0;

  @override
  Future<QrCodePage> codes(String batchId, {String? after, int? limit}) async {
    codesCalls++;
    // Only the first page is scripted; a reload would come back here with a
    // null cursor and is what the paging assertion below detects.
    return after == null ? page : const QrCodePage(codes: []);
  }

  @override
  Future<List<SalesRepSummary>> salesReps() async => reps;

  @override
  Future<StandeeAssignee> assign(
    String code, {
    required String repUserId,
  }) async {
    assigned.add((code: code, repUserId: repUserId));
    if (assignThrows != null) throw assignThrows!;
    return reps.firstWhere((r) => r.id == repUserId).person;
  }

  @override
  Future<void> unassign(String code) async {
    unassigned.add(code);
    if (assignThrows != null) throw assignThrows!;
  }

  @override
  Future<List<QrBatchSummary>> batches() async => const [];

  @override
  Future<QrMintResult> mint({
    required int count,
    required String label,
    String? assignToUserId,
  }) async =>
      const QrMintResult(batchId: 'b', minted: 0);

  @override
  Future<QrDownloadFile> standeeFile(
    String code, {
    StandeeQrFormat format = StandeeQrFormat.pdf,
    int? size,
  }) async =>
      throw UnimplementedError();

  @override
  Future<QrDownloadFile> batchCsv(String batchId) async =>
      throw UnimplementedError();
}

class _FakeRepRepo with RepRepoCatalogDefaults implements RepRepository {
  _FakeRepRepo({this.assignedStandees = const []});

  List<RepStandee> assignedStandees;
  CatalogFailure? standeesThrows;

  final List<String> filesFor = [];
  final List<RepActivationRequest> activations = [];

  @override
  Future<List<RepStandee>> standees() async {
    if (standeesThrows != null) throw standeesThrows!;
    return assignedStandees;
  }

  @override
  Future<QrDownloadFile> standeeFile(
    String code, {
    StandeeQrFormat format = StandeeQrFormat.pdf,
    int? size,
  }) async {
    filesFor.add(code);
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
  Future<RepActivation> activate(RepActivationRequest request) async {
    activations.add(request);
    return const RepActivation(
      outcome: RepActivationOutcome.activated,
      catalogId: 'c1',
      publicUrl: 'https://scan.test/r/ABCD2345',
    );
  }

  @override
  Future<List<RepCatalogSummary>> catalogs() async => const [];

  @override
  Future<List<CatalogProduct>> products(String catalogId) async => const [];

  @override
  Future<RepPublishResult> publish(String catalogId) async =>
      const RepPublishResult(outcome: RepPublishOutcome.queued);

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
}

class _FakeDeliverer implements QrDeliverer {
  final List<QrDownloadFile> delivered = [];

  @override
  Future<void> deliver(QrDownloadFile file) async => delivered.add(file);
}

// ── Harnesses ──────────────────────────────────────────────────────────────

ProviderContainer _adminContainer(_FakeAdminRepo repo) {
  final container = ProviderContainer(overrides: [
    adminStandeeRepositoryProvider.overrideWithValue(repo),
    qrDelivererProvider.overrideWithValue(_FakeDeliverer()),
  ]);
  addTearDown(container.dispose);
  return container;
}

Widget _repStandeesApp(_FakeRepRepo repo, {QrDeliverer? deliverer}) =>
    ProviderScope(
      overrides: [
        repRepositoryProvider.overrideWithValue(repo),
        if (deliverer != null) qrDelivererProvider.overrideWithValue(deliverer),
      ],
      child: const MaterialApp(home: RepStandeesScreen()),
    );

Widget _activationApp(_FakeRepRepo repo) => ProviderScope(
      overrides: [
        repRepositoryProvider.overrideWithValue(repo),
        repCapabilitiesProvider.overrideWithValue(
          const RepCapabilities(canScan: false, canCaptureDish: false),
        ),
      ],
      child: const MaterialApp(home: RepActivationScreen()),
    );

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  group('admin assigns a standee', () {
    test('patches the row in place and does NOT re-page the list', () async {
      final repo = _FakeAdminRepo(
        codes: [_code('AAAA1111'), _code('BBBB2222')],
        reps: [_rep('r1', name: 'Field Rep')],
      );
      final container = _adminContainer(repo);
      final provider = adminBatchCodesProvider('b1');
      final notifier = container.read(provider.notifier);

      await notifier.load();
      final callsBefore = repo.codesCalls;

      await notifier.assign('AAAA1111', repUserId: 'r1');

      final rows = container.read(provider).codes.valueOrNull!;
      expect(rows.first.assignedTo?.id, 'r1');
      // The OTHER row is untouched — a reload would have rebuilt both.
      expect(rows[1].assignedTo, isNull);
      // THE assertion: no second fetch. A reload here restarts keyset paging at
      // page one and drops everything the admin had scrolled to.
      expect(repo.codesCalls, callsBefore);
      // The cursor survives too, so "Load more" still works after assigning.
      expect(container.read(provider).nextAfter, 'X');
    });

    test('unassign clears the holder on that row alone', () async {
      final repo = _FakeAdminRepo(
        codes: [_code('AAAA1111', assignedTo: _person('r1', name: 'Rep'))],
        reps: [_rep('r1', name: 'Rep')],
      );
      final container = _adminContainer(repo);
      final provider = adminBatchCodesProvider('b1');
      final notifier = container.read(provider.notifier);
      await notifier.load();

      await notifier.unassign('AAAA1111');

      expect(repo.unassigned, ['AAAA1111']);
      expect(container.read(provider).codes.valueOrNull!.first.assignedTo,
          isNull);
    });

    test('a failed assign leaves the list on screen', () async {
      final repo = _FakeAdminRepo(reps: [_rep('r1')])
        ..assignThrows = const CatalogFailure(
          code: 'REP_NOT_FOUND',
          message: 'That account cannot hold a standee.',
        );
      final container = _adminContainer(repo);
      final provider = adminBatchCodesProvider('b1');
      final notifier = container.read(provider.notifier);
      await notifier.load();

      await notifier.assign('AAAA1111', repUserId: 'r1');

      final state = container.read(provider);
      expect(state.failure?.code, 'REP_NOT_FOUND');
      // The row is still there and still unassigned — the admin's next move is
      // usually to pick a different rep, which needs the list.
      expect(state.codes.valueOrNull, isNotEmpty);
      expect(state.codes.valueOrNull!.first.assignedTo, isNull);
    });
  });

  group('the assignee label', () {
    test('prefers a display name, falls back to the masked contact', () {
      expect(_person('r', name: 'Asha', masked: '+91 ••••• ••210').label,
          'Asha');
      expect(_person('r', masked: '+91 ••••• ••210').label, '+91 ••••• ••210');
      // Never blank: an admin picking from a list of empty rows cannot choose.
      expect(_person('r').label, 'Unnamed account');
    });

    test('the second line appears only when it adds something', () {
      expect(_person('r', name: 'Asha', masked: '+91 ••••• ••210').secondaryLabel,
          '+91 ••••• ••210');
      // The mask is already the title here, so repeating it would be noise.
      expect(_person('r', masked: '+91 ••••• ••210').secondaryLabel, isNull);
    });
  });

  group("the rep's own standee list", () {
    testWidgets('shows the code and a save control — and NO assign control',
        (tester) async {
      final repo = _FakeRepRepo(assignedStandees: [_standee('ABCD2345')]);
      await tester.pumpWidget(_repStandeesApp(repo));
      await tester.pumpAndSettle();

      expect(find.text('ABCD2345'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('rep_standee_save_ABCD2345')),
        findsOneWidget,
      );

      // THE assertion of this file. Assignment is ADMIN-gated on the server, so
      // an assign control here would answer 403 — and this screen was built
      // from the admin one, which is exactly how such a control gets copied
      // across. findsNothing, not "is disabled".
      expect(find.byKey(const ValueKey('assign_ABCD2345')), findsNothing);
      expect(find.byIcon(Icons.person_add_alt_1_outlined), findsNothing);
      expect(find.text('Return to stock'), findsNothing);
    });

    testWidgets('a retired standee offers no save', (tester) async {
      final repo = _FakeRepRepo(
        assignedStandees: [_standee('DEAD0000', state: QrCodeState.retired)],
      );
      await tester.pumpWidget(_repStandeesApp(repo));
      await tester.pumpAndSettle();

      expect(find.text('DEAD0000'), findsOneWidget);
      expect(find.text('Retired'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('rep_standee_save_DEAD0000')),
        findsNothing,
      );
    });

    testWidgets('saving hands the file to the platform seam', (tester) async {
      final repo = _FakeRepRepo(assignedStandees: [_standee('ABCD2345')]);
      final deliverer = _FakeDeliverer();
      await tester.pumpWidget(_repStandeesApp(repo, deliverer: deliverer));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('rep_standee_save_ABCD2345')));
      await tester.pumpAndSettle();

      expect(repo.filesFor, ['ABCD2345']);
      expect(deliverer.delivered.single.fileName, 'standee-ABCD2345.pdf');
    });

    test('only activatable standees are recommended', () async {
      final container = ProviderContainer(overrides: [
        repRepositoryProvider.overrideWithValue(
          _FakeRepRepo(assignedStandees: [
            _standee('AAAA1111'),
            _standee('BBBB2222', state: QrCodeState.active),
            _standee('CCCC3333', state: QrCodeState.retired),
            // Fails CLOSED: a state this build does not know must never be
            // offered as ready to use.
            _standee('DDDD4444', state: QrCodeState.unknown),
          ]),
        ),
      ]);
      addTearDown(container.dispose);

      final notifier = container.read(repStandeesProvider.notifier);
      await notifier.load();

      expect(
        container.read(repStandeesProvider).available.map((s) => s.code),
        ['AAAA1111'],
      );
    });
  });

  group('recommendations on the activation screen', () {
    testWidgets('a rep with assigned stock sees it beside the code field',
        (tester) async {
      final repo = _FakeRepRepo(
        assignedStandees: [_standee('AAAA1111'), _standee('BBBB2222')],
      );
      await tester.pumpWidget(_activationApp(repo));
      await tester.pumpAndSettle();

      expect(find.text('Your standees (2)'), findsOneWidget);
      expect(find.text('AAAA1111'), findsOneWidget);
      expect(find.text('BBBB2222'), findsOneWidget);
    });

    testWidgets('a rep with none sees no section at all', (tester) async {
      await tester.pumpWidget(_activationApp(_FakeRepRepo()));
      await tester.pumpAndSettle();

      // Not an empty state and not a spinner: this is a shortcut past the text
      // field, and a shortcut that announces its own absence is worse than one
      // that is simply not there.
      expect(find.textContaining('Your standee'), findsNothing);
      expect(find.byKey(const ValueKey('rep_code_field')), findsOneWidget);
    });

    testWidgets('a failed load costs the shortcut, never the activation',
        (tester) async {
      final repo = _FakeRepRepo()
        ..standeesThrows = const CatalogFailure(
          code: 'NETWORK',
          message: 'offline',
        );
      await tester.pumpWidget(_activationApp(repo));
      await tester.pumpAndSettle();

      expect(find.textContaining('Your standee'), findsNothing);
      // The screen still works — the rep types the code as they always did.
      expect(find.byKey(const ValueKey('rep_code_field')), findsOneWidget);
      expect(find.byKey(const ValueKey('rep_code_continue')), findsOneWidget);
    });

    testWidgets('tapping one PREFILLS the field and does not activate',
        (tester) async {
      final repo = _FakeRepRepo(assignedStandees: [_standee('AAAA1111')]);
      await tester.pumpWidget(_activationApp(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('rep_standee_chip_AAAA1111')));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('rep_code_field')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller?.text, 'AAAA1111');

      // THE contract a recommendation keeps, and the same one the scanner and
      // the `?code=` deep link keep: a scan of the WRONG standee is the mistake
      // this flow cannot take back, so the rep's own eyes on the filled field
      // are the check. Still on step one, nothing activated.
      expect(repo.activations, isEmpty);
      expect(find.byKey(const ValueKey('rep_code_continue')), findsOneWidget);
    });
  });
}
