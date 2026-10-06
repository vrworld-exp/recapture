// test/upload/pending_capture_store_test.dart
//
// The durable pending-capture record + store (offline capture, Stage A):
// JSON round-trip, defensive parsing (corrupt → skipped, unknown enum → safe
// fallback, missing owner → rejected), owner filtering, oldest-first order, and
// the owner-scoped notifier that is the UI's single source of truth.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/application/upload/offline_capture_capability.dart';
import 'package:recapture/application/upload/pending_captures_notifier.dart';
import 'package:recapture/data/local/box_names.dart';
import 'package:recapture/data/local/pending_capture_box.dart';
import 'package:recapture/data/local/storage_providers.dart';
import 'package:recapture/domain/upload/pending_capture.dart';

PendingCapture capture(
  String id, {
  String owner = 'u1',
  String projectId = 'p1',
  PendingCaptureState state = PendingCaptureState.savedLocal,
  DateTime? capturedAt,
  String mode = 'full',
}) {
  final at = capturedAt ?? DateTime.utc(2026, 10, 1, 9);
  return PendingCapture(
    localId: id,
    projectId: projectId,
    ownerUserId: owner,
    projectName: 'Chair',
    objectSize: 'large',
    captureMode: mode,
    flowVariant: 'without_bottom',
    frameCount: 48,
    byteCount: 123456789,
    state: state,
    capturedAt: at,
    updatedAt: at,
    bundleRelPath: pendingBundleRelPathFor(id),
    perLevelCounts: const {'EYE': 24, 'TOP': 24},
  );
}

void main() {
  group('PendingCapture codec', () {
    test('round-trips every field through JSON', () {
      final original = capture('a').copyWith(
        state: PendingCaptureState.failed,
        uploadSessionId: 'job_1',
        lastErrorCode: 'QUOTA',
        attempts: 3,
        mobileDataApproved: true,
      );

      final decoded = PendingCapture.fromJson(
        Map<String, Object?>.from(
            jsonDecode(jsonEncode(original.toJson())) as Map),
      )!;

      expect(decoded.localId, 'a');
      expect(decoded.projectId, 'p1');
      expect(decoded.ownerUserId, 'u1');
      expect(decoded.projectName, 'Chair');
      expect(decoded.objectSize, 'large');
      expect(decoded.captureMode, 'full');
      expect(decoded.flowVariant, 'without_bottom');
      expect(decoded.frameCount, 48);
      expect(decoded.byteCount, 123456789);
      expect(decoded.state, PendingCaptureState.failed);
      expect(decoded.uploadSessionId, 'job_1');
      expect(decoded.lastErrorCode, 'QUOTA');
      expect(decoded.attempts, 3);
      expect(decoded.capturedAt, original.capturedAt);
      expect(decoded.bundleRelPath, 'upload_workspace/bundles/a');
      expect(decoded.perLevelCounts, {'EYE': 24, 'TOP': 24});
      expect(decoded.mobileDataApproved, isTrue);
    });

    test('the bundle path is stored relative, never absolute', () {
      // iOS moves the app container on update; an absolute path persisted
      // before an update would point at nothing afterwards.
      expect(capture('a').bundleRelPath.startsWith('/'), isFalse);
    });

    test('an unknown state falls back to savedLocal', () {
      final json = capture('a').toJson()..['state'] = 'teleporting';
      expect(PendingCapture.fromJson(json)!.state,
          PendingCaptureState.savedLocal);
    });

    test('a record without an owner is rejected, not adopted', () {
      final json = capture('a').toJson()..remove('ownerUserId');
      expect(PendingCapture.fromJson(json), isNull);
      final blank = capture('a').toJson()..['ownerUserId'] = '';
      expect(PendingCapture.fromJson(blank), isNull);
    });

    test('a record from an older/newer version parses with defaults', () {
      // Only the load-bearing ids: everything else defaults.
      final minimal = <String, Object?>{
        'localId': 'old',
        'projectId': 'p9',
        'ownerUserId': 'u1',
        'perLevelCounts': {'EYE': 6},
        'someFutureField': {'x': 1},
      };
      final c = PendingCapture.fromJson(minimal)!;
      expect(c.captureMode, 'full');
      expect(c.flowVariant, 'with_bottom');
      expect(c.objectSize, 'medium');
      expect(c.frameCount, 6); // derived from the per-ring counts
      expect(c.bundleRelPath, pendingBundleRelPathFor('old'));
      expect(c.state, PendingCaptureState.savedLocal);
    });

    test('hasPendingProject matches the projects notifier prefix', () {
      expect(capture('a', projectId: '${kPendingProjectIdPrefix}123')
          .hasPendingProject, isTrue);
      expect(capture('a', projectId: '66f0c0ffee').hasPendingProject, isFalse);
    });
  });

  group('HivePendingCaptureStore', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('pending_capture_hive_');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      await Hive.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('survives a restart (new store instance, same box)', () async {
      await HivePendingCaptureStore().put(capture('a'));
      await HivePendingCaptureStore().put(capture('b',
          capturedAt: DateTime.utc(2026, 10, 2)));

      final reopened = HivePendingCaptureStore();
      final list = await reopened.listFor('u1');
      expect(list.map((c) => c.localId), ['a', 'b']);
      expect((await reopened.get('a'))!.frameCount, 48);
    });

    test('lists only the owner\'s captures, oldest first', () async {
      final store = HivePendingCaptureStore();
      await store.put(capture('new', capturedAt: DateTime.utc(2026, 10, 3)));
      await store.put(capture('other', owner: 'u2'));
      await store.put(capture('old', capturedAt: DateTime.utc(2026, 9, 30)));

      expect((await store.listFor('u1')).map((c) => c.localId), ['old', 'new']);
      expect((await store.listFor('u2')).map((c) => c.localId), ['other']);
      expect(await store.listFor(null), isEmpty);
      expect(await store.listFor(''), isEmpty);
    });

    test('corrupt records are skipped, never thrown', () async {
      final store = HivePendingCaptureStore();
      await store.put(capture('good'));
      final box = await Hive.openBox<String>(BoxNames.pendingCaptures);
      await box.put('broken', '{not json');
      await box.put('wrong_shape', jsonEncode([1, 2, 3]));
      await box.put('no_owner', jsonEncode({'localId': 'x', 'projectId': 'p'}));

      final list = await store.listFor('u1');
      expect(list.map((c) => c.localId), ['good']);
      expect(await store.get('broken'), isNull);
    });

    test('remove is idempotent', () async {
      final store = HivePendingCaptureStore();
      await store.put(capture('a'));
      await store.remove('a');
      await store.remove('a');
      expect(await store.listFor('u1'), isEmpty);
    });
  });

  group('pendingCapturesProvider', () {
    ProviderContainer container({
      required PendingCaptureStore store,
      String? userId = 'u1',
      bool capable = true,
    }) {
      final c = ProviderContainer(overrides: [
        pendingCaptureStoreProvider.overrideWithValue(store),
        currentUserIdProvider.overrideWithValue(userId),
        offlineCaptureCapabilityProvider.overrideWithValue(capable),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('loads only the signed-in user\'s captures', () async {
      final store = InMemoryPendingCaptureStore();
      await store.put(capture('mine'));
      await store.put(capture('theirs', owner: 'u2'));
      final c = container(store: store);

      c.read(pendingCapturesProvider);
      await c.read(pendingCapturesProvider.notifier).whenLoaded();
      expect(c.read(pendingCapturesProvider).map((p) => p.localId), ['mine']);
    });

    test('signed out → empty, records kept on disk', () async {
      final store = InMemoryPendingCaptureStore();
      await store.put(capture('mine'));
      final c = container(store: store, userId: null);

      expect(c.read(pendingCapturesProvider), isEmpty);
      expect(await store.listFor('u1'), hasLength(1));
    });

    test('web (no capability) → always empty, store never read', () async {
      final store = _ThrowingStore();
      final c = container(store: store, capable: false);
      expect(c.read(pendingCapturesProvider), isEmpty);
      await c.read(pendingCapturesProvider.notifier).whenLoaded();
      expect(store.touched, isFalse);
    });

    test('refuses to store another user\'s capture', () async {
      final c = container(store: InMemoryPendingCaptureStore());
      c.read(pendingCapturesProvider);
      expect(
        () => c.read(pendingCapturesProvider.notifier)
            .upsert(capture('x', owner: 'u2')),
        throwsStateError,
      );
    });

    test('upsert / mutate / remove keep the list and the store in step',
        () async {
      final store = InMemoryPendingCaptureStore();
      final c = container(store: store);
      final n = c.read(pendingCapturesProvider.notifier);
      await n.whenLoaded();

      await n.upsert(capture('b', capturedAt: DateTime.utc(2026, 10, 2)));
      await n.upsert(capture('a', capturedAt: DateTime.utc(2026, 10, 1)));
      expect(c.read(pendingCapturesProvider).map((p) => p.localId), ['a', 'b']);

      await n.mutate('a', (p) => p.copyWith(state: PendingCaptureState.failed));
      expect((await store.get('a'))!.state, PendingCaptureState.failed);
      expect(n.byLocalId('a')!.state, PendingCaptureState.failed);
      expect(n.forProject('p1')!.localId, 'b'); // newest for the project

      await n.remove('a');
      expect(c.read(pendingCapturesProvider).map((p) => p.localId), ['b']);
      expect(await store.get('a'), isNull);
      expect(await n.mutate('a', (p) => p), isNull); // gone → no-op
    });
  });
}

class _ThrowingStore implements PendingCaptureStore {
  bool touched = false;

  Never _touch() {
    touched = true;
    throw StateError('store must not be opened on web');
  }

  @override
  Future<PendingCapture?> get(String localId) async => _touch();

  @override
  Future<List<PendingCapture>> listFor(String? ownerUserId) async => _touch();

  @override
  Future<void> put(PendingCapture capture) async => _touch();

  @override
  Future<void> remove(String localId) async => _touch();
}
