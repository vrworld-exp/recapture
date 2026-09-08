// test/admin/admin_standees_test.dart
//
// The admin standee notifiers: minting, paging, and getting a file out.
//
// THE ASSERTIONS THAT CARRY THIS SUITE are the two "a failure must not destroy
// what is on screen" cases. An admin is usually on these screens because a rep
// is waiting; a failed mint that also blanked the batch list, or a failed
// second page that dropped the first, turns a recoverable moment into a reload
// and a lost place. Both are easy to regress, because the obvious way to write
// either notifier is to push the error into the AsyncValue the list renders.
//
// Hermetic: the repository and the delivery seam are both fakes, so there is no
// Dio, no share sheet and no platform channel anywhere in here.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/admin/admin_batch_codes_notifier.dart';
import 'package:recapture/application/admin/admin_standees_notifier.dart';
import 'package:recapture/application/catalog/catalog_qr_service.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/domain/entities/qr_standee.dart';

QrBatchSummary _batch({String id = 'b1', int unassigned = 5}) => QrBatchSummary(
      id: id,
      label: 'Vendor A — run 1',
      count: 5,
      createdAt: DateTime(2026, 9, 5),
      unassigned: unassigned,
      active: 0,
      retired: 0,
    );

QrStandeeCode _code(String code) => QrStandeeCode(
      code: code,
      state: QrCodeState.unassigned,
      url: 'https://scan.test/r/$code',
    );

/// Records what it was asked for and answers with whatever the test scripted.
class _FakeRepo implements AdminStandeeRepository {
  _FakeRepo();

  List<QrBatchSummary> batchList = [_batch()];
  CatalogFailure? mintThrows;
  CatalogFailure? codesThrows;
  CatalogFailure? fileThrows;

  /// Keyed by the `after` cursor — null for the first page.
  Map<String?, QrCodePage> pages = {
    null: QrCodePage(codes: [_code('AAAA1111')], nextAfter: null),
  };

  final List<({int count, String label, String? assignToUserId})> minted = [];
  final List<String> filesFor = [];

  @override
  Future<List<QrBatchSummary>> batches() async => batchList;

  @override
  Future<QrMintResult> mint({
    required int count,
    required String label,
    String? assignToUserId,
  }) async {
    minted.add((count: count, label: label, assignToUserId: assignToUserId));
    if (mintThrows != null) throw mintThrows!;
    // ECHOES the requested count rather than a fixed number, so an assertion
    // about what the confirmation says is about the code under test and not
    // about a constant buried in this fake.
    return QrMintResult(batchId: 'b-new', minted: count, assignedTo: mintAssignee);
  }

  /// Who the server reports the run went to. Null unless a test says
  /// otherwise, because a mint that assigns nobody is the ordinary case.
  StandeeAssignee? mintAssignee;

  @override
  Future<BatchAssignmentResult> assignBatch(
    String batchId, {
    required String repUserId,
  }) async {
    assignedBatches.add((batchId: batchId, repUserId: repUserId));
    if (bulkThrows != null) throw bulkThrows!;
    return BatchAssignmentResult(
      assigned: bulkAssigned,
      skippedRetired: bulkSkippedRetired,
      assignedTo: bulkHolder,
    );
  }

  @override
  Future<int> unassignBatch(String batchId) async {
    unassignedBatches.add(batchId);
    if (bulkThrows != null) throw bulkThrows!;
    return bulkUnassigned;
  }

  final List<({String batchId, String repUserId})> assignedBatches = [];
  final List<String> unassignedBatches = [];
  CatalogFailure? bulkThrows;
  int bulkAssigned = 0;
  int bulkSkippedRetired = 0;
  int bulkUnassigned = 0;
  StandeeAssignee? bulkHolder;
  @override
  Future<QrCodePage> codes(String batchId, {String? after, int? limit}) async {
    if (codesThrows != null) throw codesThrows!;
    return pages[after] ?? const QrCodePage(codes: []);
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
  Future<QrDownloadFile> batchCsv(String batchId) async {
    filesFor.add('csv:$batchId');
    if (fileThrows != null) throw fileThrows!;
    return QrDownloadFile(
      bytes: Uint8List.fromList([4, 5]),
      fileName: 'qr-batch.csv',
      mimeType: 'text/csv',
    );
  }

  // ── Assignment ───────────────────────────────────────────────────────────
  List<SalesRepSummary> repList = const [];
  CatalogFailure? assignThrows;

  /// Every assignment asked for, in order, so a test can assert the code AND
  /// the rep rather than just that something happened.
  final List<({String code, String repUserId})> assigned = [];
  final List<String> unassigned = [];

  @override
  Future<List<SalesRepSummary>> salesReps() async => repList;

  @override
  Future<StandeeAssignee> assign(
    String code, {
    required String repUserId,
  }) async {
    assigned.add((code: code, repUserId: repUserId));
    if (assignThrows != null) throw assignThrows!;
    return repList
        .firstWhere((r) => r.id == repUserId)
        .person;
  }

  @override
  Future<void> unassign(String code) async {
    unassigned.add(code);
    if (assignThrows != null) throw assignThrows!;
  }
}

/// Captures what the platform would have been handed.
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
    adminStandeeRepositoryProvider.overrideWithValue(repo),
    qrDelivererProvider.overrideWithValue(deliverer),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('the inventory list', () {
    test('loads the batches on build', () async {
      final repo = _FakeRepo();
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(adminStandeesProvider, (_, __) {});
      await pumpEventQueue();

      final state = container.read(adminStandeesProvider);
      expect(state.batches.valueOrNull, hasLength(1));
    });

    test('a mint returns the new batch id so the screen can go straight in',
        () async {
      final repo = _FakeRepo();
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(adminStandeesProvider, (_, __) {});
      await pumpEventQueue();

      final id = await container
          .read(adminStandeesProvider.notifier)
          .mint(count: 25, label: 'run 2');

      expect(id, 'b-new');
      expect(repo.minted.single.count, 25);
      expect(repo.minted.single.label, 'run 2');
      expect(container.read(adminStandeesProvider).notice, contains('25'));
    });

    test('a failed mint leaves the list on screen', () async {
      final repo = _FakeRepo()
        ..mintThrows = const CatalogFailure(
          code: 'RESOLVER_NOT_CONFIGURED',
          message: 'not configured',
        );
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(adminStandeesProvider, (_, __) {});
      await pumpEventQueue();

      final id = await container
          .read(adminStandeesProvider.notifier)
          .mint(count: 25, label: 'run 2');

      final state = container.read(adminStandeesProvider);
      expect(id, isNull);
      expect(state.failure?.code, 'RESOLVER_NOT_CONFIGURED');
      // The batches the admin was looking at are untouched.
      expect(state.batches.valueOrNull, hasLength(1));
      expect(state.minting, isFalse);
    });

    test('a second mint cannot start while one is in flight', () async {
      // A double tap on this button is a second physical print run.
      final repo = _FakeRepo();
      final container = _containerWith(repo, _FakeDeliverer());
      final notifier = container.read(adminStandeesProvider.notifier);
      container.listen(adminStandeesProvider, (_, __) {});
      await pumpEventQueue();

      await Future.wait([
        notifier.mint(count: 1, label: 'a'),
        notifier.mint(count: 1, label: 'b'),
      ]);

      expect(repo.minted, hasLength(1));
    });
  });

  group('paging one batch', () {
    test('appends the next page rather than replacing what is loaded', () async {
      final repo = _FakeRepo()
        ..pages = {
          null: QrCodePage(codes: [_code('AAAA1111')], nextAfter: 'AAAA1111'),
          'AAAA1111': QrCodePage(codes: [_code('BBBB2222')], nextAfter: null),
        };
      final container = _containerWith(repo, _FakeDeliverer());
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      expect(container.read(provider).hasMore, isTrue);
      await container.read(provider.notifier).loadMore();

      final state = container.read(provider);
      expect(
        state.codes.valueOrNull?.map((c) => c.code),
        ['AAAA1111', 'BBBB2222'],
      );
      // A short page is the only end-of-list signal.
      expect(state.hasMore, isFalse);
    });

    test('a failed next page keeps the pages already loaded', () async {
      final repo = _FakeRepo()
        ..pages = {
          null: QrCodePage(codes: [_code('AAAA1111')], nextAfter: 'AAAA1111'),
        };
      final container = _containerWith(repo, _FakeDeliverer());
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      repo.codesThrows =
          const CatalogFailure(code: 'NOT_FOUND', message: 'gone');
      await container.read(provider.notifier).loadMore();

      final state = container.read(provider);
      expect(state.failure?.code, 'NOT_FOUND');
      expect(state.codes.valueOrNull, hasLength(1));
      expect(state.loadingMore, isFalse);
    });
  });

  group('getting a file out', () {
    test('hands the standee to the delivery seam', () async {
      final repo = _FakeRepo();
      final deliverer = _FakeDeliverer();
      final container = _containerWith(repo, deliverer);
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      await container.read(provider.notifier).deliverStandee('AAAA1111');

      expect(repo.filesFor, ['AAAA1111']);
      expect(deliverer.delivered.single.fileName, 'standee-AAAA1111.pdf');
      expect(container.read(provider).busyCode, isNull);
    });

    test('the batch CSV goes through the same seam', () async {
      final repo = _FakeRepo();
      final deliverer = _FakeDeliverer();
      final container = _containerWith(repo, deliverer);
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      await container.read(provider.notifier).deliverCsv();

      expect(deliverer.delivered.single.mimeType, 'text/csv');
      expect(container.read(provider).downloadingCsv, isFalse);
    });

    test('a refused render surfaces its typed code', () async {
      final repo = _FakeRepo()
        ..fileThrows = const CatalogFailure(
          code: 'CODE_RETIRED',
          message: 'retired',
        );
      final container = _containerWith(repo, _FakeDeliverer());
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      await container.read(provider.notifier).deliverStandee('AAAA1111');

      // The screen branches on the code, so it has to survive the round trip.
      expect(container.read(provider).failure?.code, 'CODE_RETIRED');
    });

    test('a dismissed share sheet becomes one mapped sentence, not a raw error',
        () async {
      final deliverer = _FakeDeliverer()..throws = true;
      final container = _containerWith(_FakeRepo(), deliverer);
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      await container.read(provider.notifier).deliverStandee('AAAA1111');

      final failure = container.read(provider).failure;
      expect(failure?.code, 'QR_SAVE_FAILED');
      // A platform exception's own text is never fit to show anyone.
      expect(failure?.message, isNot(contains('StateError')));
      expect(container.read(provider).busyCode, isNull);
    });
  });

group('bulk assignment at mint time', () {
    test('passes the chosen holder through to the repository', () async {
      final repo = _FakeRepo()
        ..mintAssignee = const StandeeAssignee(id: 'rep-1', displayName: 'Ravi');
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(adminStandeesProvider, (_, __) {});
      await pumpEventQueue();

      await container
          .read(adminStandeesProvider.notifier)
          .mint(count: 20, label: 'Ravi run', assignToUserId: 'rep-1');

      expect(repo.minted.single.assignToUserId, 'rep-1');
    });

    test('omits the holder entirely when nobody was picked', () async {
      final repo = _FakeRepo();
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(adminStandeesProvider, (_, __) {});
      await pumpEventQueue();

      await container
          .read(adminStandeesProvider.notifier)
          .mint(count: 5, label: 'stock');

      // Null, not an empty string: the request body is strict server-side and
      // minting unassigned stock is an ordinary thing to want.
      expect(repo.minted.single.assignToUserId, isNull);
    });

    test('names the holder in the confirmation', () async {
      final repo = _FakeRepo()
        ..mintAssignee = const StandeeAssignee(id: 'rep-1', displayName: 'Ravi');
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(adminStandeesProvider, (_, __) {});
      await pumpEventQueue();

      await container
          .read(adminStandeesProvider.notifier)
          .mint(count: 20, label: 'Ravi run', assignToUserId: 'rep-1');

      expect(container.read(adminStandeesProvider).notice, contains('Ravi'));
    });

    test('does NOT claim a holder the server did not confirm', () async {
      // THE ONE THAT MATTERS. The mint deliberately survives a failed
      // assignment — the codes are correct and can be handed out later — so the
      // server answers with no holder. Saying "for Ravi" off the back of what
      // was ASKED FOR would tell an admin the folder is on its way to someone
      // when it is sitting in unassigned stock.
      final repo = _FakeRepo()..mintAssignee = null;
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(adminStandeesProvider, (_, __) {});
      await pumpEventQueue();

      await container
          .read(adminStandeesProvider.notifier)
          .mint(count: 20, label: 'Ravi run', assignToUserId: 'rep-1');

      final notice = container.read(adminStandeesProvider).notice;
      expect(notice, contains('20'));
      expect(notice, isNot(contains('for')));
    });

    test('a failed mint still reports nothing about a holder', () async {
      final repo = _FakeRepo()
        ..mintThrows = const CatalogFailure(
          code: 'REP_NOT_FOUND',
          message: 'no such staff member',
        );
      final container = _containerWith(repo, _FakeDeliverer());
      container.listen(adminStandeesProvider, (_, __) {});
      await pumpEventQueue();

      final id = await container
          .read(adminStandeesProvider.notifier)
          .mint(count: 20, label: 'Ravi run', assignToUserId: 'gone');

      final state = container.read(adminStandeesProvider);
      expect(id, isNull);
      expect(state.failure?.code, 'REP_NOT_FOUND');
      expect(state.notice, isNull);
    });
  });


group('assigning a whole batch', () {
    QrStandeeCode held(String code, {QrCodeState state = QrCodeState.unassigned}) =>
        QrStandeeCode(
          code: code,
          state: state,
          url: 'https://scan.test/r/$code',
          assignedTo: const StandeeAssignee(id: 'old', displayName: 'Old Holder'),
        );

    test('sends the batch id and the chosen rep', () async {
      final repo = _FakeRepo()
        ..bulkAssigned = 2
        ..bulkHolder = const StandeeAssignee(id: 'rep-1', displayName: 'Ravi');
      final container = _containerWith(repo, _FakeDeliverer());
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      await container.read(provider.notifier).assignAll(repUserId: 'rep-1');

      expect(repo.assignedBatches.single.batchId, 'b1');
      expect(repo.assignedBatches.single.repUserId, 'rep-1');
    });

    test('patches every loaded row instead of reloading the list', () async {
      final repo = _FakeRepo()
        ..pages = {
          null: QrCodePage(
            codes: [_code('AAAA1111'), _code('BBBB2222')],
            nextAfter: 'BBBB2222',
          ),
        }
        ..bulkAssigned = 2
        ..bulkHolder = const StandeeAssignee(id: 'rep-1', displayName: 'Ravi');
      final container = _containerWith(repo, _FakeDeliverer());
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      await container.read(provider.notifier).assignAll(repUserId: 'rep-1');

      final state = container.read(provider);
      // Every visible row now shows the new holder...
      expect(
        state.codes.valueOrNull?.map((c) => c.assignedTo?.id),
        ['rep-1', 'rep-1'],
      );
      // ...and the paging cursor survived, so the admin did not get thrown back
      // to page one to learn something the server already told us.
      expect(state.nextAfter, 'BBBB2222');
      expect(state.bulkBusy, isFalse);
    });

    test('leaves RETIRED rows alone, mirroring the endpoint', () async {
      final repo = _FakeRepo()
        ..pages = {
          null: QrCodePage(
            codes: [
              _code('AAAA1111'),
              QrStandeeCode(
                code: 'DEAD0000',
                state: QrCodeState.retired,
                url: 'https://scan.test/r/DEAD0000',
              ),
            ],
          ),
        }
        ..bulkAssigned = 1
        ..bulkSkippedRetired = 1
        ..bulkHolder = const StandeeAssignee(id: 'rep-1', displayName: 'Ravi');
      final container = _containerWith(repo, _FakeDeliverer());
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      await container.read(provider.notifier).assignAll(repUserId: 'rep-1');

      final rows = container.read(provider).codes.valueOrNull!;
      // A retired sheet cannot be printed or activated, so putting it on a rep
      // list gives them a row they can do nothing with. If the local patch
      // claimed otherwise, the screen would disagree with the server the moment
      // anything refetched.
      expect(rows.firstWhere((c) => c.code == 'AAAA1111').assignedTo?.id, 'rep-1');
      expect(rows.firstWhere((c) => c.code == 'DEAD0000').assignedTo, isNull);
    });

    test('says how many were skipped, so a short count explains itself', () async {
      final repo = _FakeRepo()
        ..bulkAssigned = 18
        ..bulkSkippedRetired = 2
        ..bulkHolder = const StandeeAssignee(id: 'rep-1', displayName: 'Ravi');
      final container = _containerWith(repo, _FakeDeliverer());
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      await container.read(provider.notifier).assignAll(repUserId: 'rep-1');

      final notice = container.read(provider).notice!;
      expect(notice, contains('18'));
      expect(notice, contains('Ravi'));
      // "Assigned 18" against a batch of 20 reads as a bug on its own.
      expect(notice, contains('2 retired'));
    });

    test('omits the skipped clause when nothing was skipped', () async {
      final repo = _FakeRepo()
        ..bulkAssigned = 5
        ..bulkHolder = const StandeeAssignee(id: 'rep-1', displayName: 'Ravi');
      final container = _containerWith(repo, _FakeDeliverer());
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      await container.read(provider.notifier).assignAll(repUserId: 'rep-1');

      expect(container.read(provider).notice, isNot(contains('retired')));
    });

    test('a failure leaves the rows exactly as they were', () async {
      final repo = _FakeRepo()
        ..pages = {
          null: QrCodePage(codes: [held('AAAA1111')]),
        }
        ..bulkThrows = const CatalogFailure(
          code: 'REP_NOT_FOUND',
          message: 'gone',
        );
      final container = _containerWith(repo, _FakeDeliverer());
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      await container.read(provider.notifier).assignAll(repUserId: 'ghost');

      final state = container.read(provider);
      expect(state.failure?.code, 'REP_NOT_FOUND');
      // The server wrote nothing, so the screen must show nothing changed.
      expect(state.codes.valueOrNull?.single.assignedTo?.id, 'old');
      expect(state.bulkBusy, isFalse);
    });

    test('a second batch action cannot start while one is in flight', () async {
      final repo = _FakeRepo()..bulkAssigned = 1;
      final container = _containerWith(repo, _FakeDeliverer());
      final provider = adminBatchCodesProvider('b1');
      final notifier = container.read(provider.notifier);
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      await Future.wait([
        notifier.assignAll(repUserId: 'rep-1'),
        notifier.assignAll(repUserId: 'rep-2'),
      ]);

      expect(repo.assignedBatches, hasLength(1));
    });
  });

  group('emptying a whole batch', () {
    test('clears every loaded row, retired ones included', () async {
      final repo = _FakeRepo()
        ..pages = {
          null: QrCodePage(
            codes: [
              QrStandeeCode(
                code: 'AAAA1111',
                state: QrCodeState.unassigned,
                url: 'u',
                assignedTo: const StandeeAssignee(id: 'r', displayName: 'R'),
              ),
              QrStandeeCode(
                code: 'DEAD0000',
                state: QrCodeState.retired,
                url: 'u',
                assignedTo: const StandeeAssignee(id: 'r', displayName: 'R'),
              ),
            ],
          ),
        }
        ..bulkUnassigned = 2;
      final container = _containerWith(repo, _FakeDeliverer());
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      await container.read(provider.notifier).unassignAll();

      // The asymmetry with assign is deliberate: clearing a stale holder off a
      // sheet nobody can use is exactly the tidy-up being done here.
      expect(
        container.read(provider).codes.valueOrNull?.every((c) => c.assignedTo == null),
        isTrue,
      );
      expect(repo.unassignedBatches, ['b1']);
    });

    test('says so plainly when nobody was holding it', () async {
      final repo = _FakeRepo()..bulkUnassigned = 0;
      final container = _containerWith(repo, _FakeDeliverer());
      final provider = adminBatchCodesProvider('b1');
      container.listen(provider, (_, __) {});
      await pumpEventQueue();

      await container.read(provider.notifier).unassignAll();

      // Idempotent by design, so this is a confirmation and not an error.
      expect(container.read(provider).notice, contains('Nobody'));
      expect(container.read(provider).failure, isNull);
    });
  });


  group('the state vocabulary', () {
    test('only an unassigned code counts as available', () {
      expect(QrCodeState.unassigned.isAvailable, isTrue);
      expect(QrCodeState.active.isAvailable, isFalse);
      expect(QrCodeState.retired.isAvailable, isFalse);
    });

    test('an unrecognised state fails CLOSED rather than reading as free', () {
      // THE POINT OF THE `unknown` MEMBER. Folding an unknown state into
      // `unassigned` — the obvious default — is how an admin hands out a code
      // that is already taken and the rep discovers it standing at a table.
      final state = QrCodeState.fromApiValue('RESERVED');
      expect(state, QrCodeState.unknown);
      expect(state.isAvailable, isFalse);
      expect(state.isPrintable, isFalse);
    });

    test('an active code may still be reprinted, a retired one may not', () {
      // A damaged standee for a live restaurant keeps its code — that is the
      // whole reason the mapping lives on the QrCode row.
      expect(QrCodeState.active.isPrintable, isTrue);
      expect(QrCodeState.retired.isPrintable, isFalse);
    });
  });
}
