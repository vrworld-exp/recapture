// test/upload/pending_capture_saver_test.dart
//
// "Save — upload when online" (offline capture, Stage A): the finished capture
// is packed under a bundle folder named by its localId, recorded with its
// owner/mode/variant/size and per-ring counts, and the single ActiveSession
// slot is released — but only when it still points at this capture.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/progression/level_progression_builder.dart';
import 'package:recapture/application/upload/offline_capture_capability.dart';
import 'package:recapture/application/upload/pending_capture_saver.dart';
import 'package:recapture/application/upload/pending_captures_notifier.dart';
import 'package:recapture/application/upload/upload_flow.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/pending_capture_box.dart';
import 'package:recapture/data/local/storage_providers.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/capture/capture_mode.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/upload/capture_bundle.dart';
import 'package:recapture/domain/upload/capture_manifest.dart';
import 'package:recapture/domain/upload/pending_capture.dart';

UploadFlowContext ctx({String projectId = 'pending_42'}) => UploadFlowContext(
      localProjectId: projectId,
      projectName: 'Vase',
      captureSessionId: 'cap-1',
      config: CaptureConfig.bundledDefault,
      progression: initialProgressionFromConfig(
        CaptureConfig.bundledDefault,
        variant: CaptureFlowVariant.withoutBottom,
      ),
      registry: LevelCaptureLedgerRegistry(),
      variant: CaptureFlowVariant.withoutBottom,
      mode: CaptureMode.meshy,
      workspaceRoot: '/docs/upload_workspace',
      objectSize: 'small',
    );

void main() {
  late Directory tempDir;
  late InMemoryPendingCaptureStore store;
  late ActiveSessionBox sessionBox;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pending_saver_');
    Hive.init(tempDir.path);
    store = InMemoryPendingCaptureStore();
    sessionBox = ActiveSessionBox();
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ProviderContainer container({String? userId = 'u1', bool capable = true}) {
    final c = ProviderContainer(overrides: [
      pendingCaptureStoreProvider.overrideWithValue(store),
      activeSessionBoxProvider.overrideWithValue(sessionBox),
      currentUserIdProvider.overrideWithValue(userId),
      offlineCaptureCapabilityProvider.overrideWithValue(capable),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  PendingCaptureSaver saver(
    ProviderContainer c, {
    UploadFlowContext? context,
    List<ManifestSession>? packedSessions,
    Object? packError,
  }) {
    late PendingCaptureSaver s;
    final p = Provider<PendingCaptureSaver>((ref) => s = PendingCaptureSaver(
          ref,
          resolveContext: () async => context ?? ctx(),
          uuid: () => 'local-1',
          now: () => DateTime.utc(2026, 10, 6, 12),
          pack: ({
            required context,
            required session,
            required device,
            onProgress,
            cancelToken,
          }) async {
            packedSessions?.add(session);
            if (packError != null) throw packError;
            return CaptureBundle(
              path: '${context.workspaceRoot}/bundles/${session.jobId}',
              manifestPath: '${context.workspaceRoot}/bundles/${session.jobId}'
                  '/capture_manifest.json',
              totalImages: 6,
              totalBytes: 6000,
              perLevelCounts: const {'EYE': 6},
            );
          },
        ));
    c.read(p);
    return s;
  }

  test('packs into bundles/<localId> and records the capture', () async {
    final c = container();
    final sessions = <ManifestSession>[];
    final saved = await saver(c, packedSessions: sessions).saveFinishedCapture();

    expect(sessions.single.jobId, 'local-1');
    expect(sessions.single.projectId, 'pending_42');
    expect(saved.localId, 'local-1');
    expect(saved.ownerUserId, 'u1');
    expect(saved.projectId, 'pending_42');
    expect(saved.captureMode, 'meshy'); // a Meshy capture uploads as Meshy
    expect(saved.flowVariant, 'without_bottom');
    expect(saved.objectSize, 'small');
    expect(saved.frameCount, 6);
    expect(saved.perLevelCounts, {'EYE': 6});
    expect(saved.state, PendingCaptureState.savedLocal);
    expect(saved.bundleRelPath, 'upload_workspace/bundles/local-1');

    expect((await store.get('local-1'))!.projectName, 'Vase');
    expect(c.read(pendingCapturesProvider).single.localId, 'local-1');
  });

  test('releases the ActiveSession slot pointing at this capture', () async {
    await sessionBox.save(ActiveSession(
        projectId: 'pending_42', updatedAt: DateTime.utc(2026)));
    await saver(container()).saveFinishedCapture();
    expect(await sessionBox.read(), isNull);
  });

  test('leaves a slot that points at a DIFFERENT capture alone', () async {
    await sessionBox.save(
        ActiveSession(projectId: 'other', updatedAt: DateTime.utc(2026)));
    await saver(container()).saveFinishedCapture();
    expect((await sessionBox.read())!.projectId, 'other');
  });

  test('the online Upload path records it as uploading', () async {
    final saved = await saver(container())
        .saveFinishedCapture(initialState: PendingCaptureState.uploading);
    expect(saved.state, PendingCaptureState.uploading);
  });

  test('refuses without a signed-in owner — nothing packed or stored',
      () async {
    final sessions = <ManifestSession>[];
    await expectLater(
      saver(container(userId: null), packedSessions: sessions)
          .saveFinishedCapture(),
      throwsA(isA<PendingCaptureSaveException>().having(
          (e) => e.reason, 'reason', PendingCaptureSaveFailure.notSignedIn)),
    );
    expect(sessions, isEmpty);
    expect(await store.listFor('u1'), isEmpty);
  });

  test('refuses on a build without the capability (web)', () async {
    await expectLater(
      saver(container(capable: false)).saveFinishedCapture(),
      throwsA(isA<PendingCaptureSaveException>().having(
          (e) => e.reason, 'reason', PendingCaptureSaveFailure.unsupported)),
    );
  });

  test('refuses a capture attached to no project', () async {
    await expectLater(
      saver(container(), context: ctx(projectId: '')).saveFinishedCapture(),
      throwsA(isA<PendingCaptureSaveException>().having(
          (e) => e.reason, 'reason', PendingCaptureSaveFailure.noProject)),
    );
  });

  test('a pack failure stores nothing and keeps the draft slot', () async {
    await sessionBox.save(ActiveSession(
        projectId: 'pending_42', updatedAt: DateTime.utc(2026)));
    await expectLater(
      saver(container(),
              packError: BundlePackException(
                  BundlePackFailureReason.insufficientStorage))
          .saveFinishedCapture(),
      throwsA(isA<BundlePackException>()),
    );
    expect(await store.listFor('u1'), isEmpty);
    expect((await sessionBox.read())!.projectId, 'pending_42');
  });
}
