// test/upload/upload_flow_e2e_test.dart
//
// LIVE end-to-end test of the REAL upload pipeline against a locally running
// recapture-api (NODE_ENV=development) and real S3:
//
//   real devCode OTP login (AuthNotifier + AuthRepository) →
//   AppAuthUploadSession → buildUploadApiDio (Bearer + 401-refresh) →
//   real CaptureBundlePacker (48 images, with_bottom 16/16/16) →
//   POST /projects → POST /jobs → ChunkedUploadManager
//   (JobsMultipartUploadApi + DioS3PartClient presigned part PUTs) inside
//   ResilientUploadRunner → POST /jobs/:id/finalize → QUEUED → completed.
//
// SKIPS itself when no backend answers on localhost:3000 — it must never fail
// CI or an offline `flutter test` run. Start the backend with
// `cd recapture-api && npm run dev` to exercise it.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/progression/level_progression.dart';
import 'package:recapture/application/upload/capture_bundle_packer.dart';
import 'package:recapture/application/upload/capture_manifest_assembler.dart'
    show CaptureSidecarReader, sidecarPathForFrame;
import 'package:recapture/application/upload/chunked_upload_manager.dart';
import 'package:recapture/application/upload/jobs_multipart_upload_api.dart';
import 'package:recapture/application/upload/multipart_upload_api.dart';
import 'package:recapture/application/upload/resilient_upload_runner.dart';
import 'package:recapture/application/upload/upload_auth_session.dart';
import 'package:recapture/application/upload/upload_flow.dart';
import 'package:recapture/application/upload/upload_jobs_backend.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/auth_storage.dart';
import 'package:recapture/data/local/offline_queue_box.dart';
import 'package:recapture/data/local/projects_cache_box.dart';
import 'package:recapture/data/local/storage_providers.dart';
import 'package:recapture/data/repositories/auth_repository.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/auth_session.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/offline_action.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/domain/upload/capture_manifest.dart';

const _base = 'http://localhost:3000';
const _perLevel = 16; // with_bottom: 16-16-16 → 48 images + manifest = 49

Future<bool> _backendUp() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final req = await client.getUrl(Uri.parse('$_base/health'));
    final res = await req.close().timeout(const Duration(seconds: 3));
    await res.drain<void>();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

// ── Minimal storage doubles (no Hive / secure storage in a test process) ────
class _MemAuthStorage implements AuthStorage {
  AuthSession? _s;
  @override
  Future<void> save(AuthSession session) async => _s = session;
  @override
  Future<AuthSession?> read() async => _s;
  @override
  Future<void> clear() async => _s = null;
}

class _NoopActiveSessionBox implements ActiveSessionBox {
  @override
  Future<void> clear() async {}
  @override
  Future<void> save(ActiveSession session) async {}
  @override
  Future<ActiveSession?> read() async => null;
}

class _NoopProjectsCacheBox implements ProjectsCacheBox {
  @override
  Future<void> clear() async {}
  @override
  Future<void> save(List<Project> projects) async {}
  @override
  Future<CachedProjects?> read() async => null;
}

class _NoopOfflineQueueBox implements OfflineQueueBox {
  @override
  Future<void> clear() async {}
  @override
  Future<void> save(List<OfflineAction> actions) async {}
  @override
  Future<List<OfflineAction>> read() async => const [];
}

class _InProcessCopier implements BundleFileCopier {
  @override
  Future<int> copy(String src, String dst) async {
    final bytes = await File(src).readAsBytes();
    await File(dst).parent.create(recursive: true);
    await File(dst).writeAsBytes(bytes);
    return bytes.length;
  }
}

class _MapSidecarReader implements CaptureSidecarReader {
  _MapSidecarReader(this.byPath);
  final Map<String, Map<String, dynamic>> byPath;
  @override
  Future<Map<String, dynamic>?> read(String p) async => byPath[p];
}

Map<String, dynamic> _sidecar(String sessionId, String frameId, int index) => {
      'sessionId': sessionId,
      'frameId': frameId,
      'frameIndex': index,
      'captureTimestampNs': 1000 + index,
      'wallClockIso': '2026-07-12T10:00:01.000Z',
      'device': {'manufacturer': 'E2E', 'model': 'Test', 'osVersion': '1'},
      'resolution': {
        'width': 4032,
        'height': 3024,
        'aspectRatio': '4:3',
        'jpegQuality': 95,
        'fellBack': false,
      },
      'intrinsics': {'focalLengthMm': 4.7},
      'capture': {'afLocked': true, 'aeLocked': true, 'awbLocked': true},
      'orientationApplied': 'normal',
      'pose': null,
    };

void main() {
  test(
    'E2E: real login → pack → create project/job → S3 multipart → finalize '
    '→ QUEUED → completed',
    () async {
      if (!await _backendUp()) {
        markTestSkipped(
            'recapture-api not running on $_base — start it with npm run dev');
        return;
      }

      final tmp = Directory.systemTemp.createTempSync('upload_e2e_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      // ── Real login exactly like the device: send-otp devCode → verify ──────
      final authRepo =
          AuthRepository(dio: () => Dio(BaseOptions(baseUrl: _base)));
      final container = ProviderContainer(overrides: [
        authStorageProvider.overrideWithValue(_MemAuthStorage()),
        authRepositoryProvider.overrideWithValue(authRepo),
        activeSessionBoxProvider.overrideWithValue(_NoopActiveSessionBox()),
        projectsCacheBoxProvider.overrideWithValue(_NoopProjectsCacheBox()),
        offlineQueueBoxProvider.overrideWithValue(_NoopOfflineQueueBox()),
      ]);
      addTearDown(container.dispose);

      const email = 'e2e-upload@recapture.test';
      final sent = await authRepo.sendOtp(channel: 'email', identifier: email);
      expect(sent.devCode, isNotNull,
          reason: 'backend must run NODE_ENV=development to echo devCode');
      final session = await authRepo.verifyOtp(
          channel: 'email', identifier: email, code: sent.devCode!);
      expect(session, isNotNull, reason: 'devCode verify must succeed');
      await container.read(authProvider.notifier).login(session!);

      // The PRODUCTION auth seam + authed Dio (Bearer attach + 401 refresh).
      final uploadDio = buildUploadApiDio(
        container.read(uploadAuthSessionProvider),
        baseUrl: _base,
      );

      // ── A real 48-image capture session on disk (with_bottom 16/16/16) ─────
      const sessionId = 'e2e-sess-1';
      final srcRoot = Directory('${tmp.path}/src')..createSync(recursive: true);
      final registry = LevelCaptureLedgerRegistry();
      final sidecars = <String, Map<String, dynamic>>{};
      final levelIds = ['mid', 'high', 'low'];
      for (final levelId in levelIds) {
        for (var i = 0; i < _perLevel; i++) {
          final f = File('${srcRoot.path}/$levelId/frame_$i.jpg')
            ..parent.createSync(recursive: true)
            // Unique small payload per frame (content is not format-checked).
            ..writeAsBytesSync(
                List<int>.generate(64, (b) => (b + i + levelId.length) & 0xFF));
          registry.ledgerFor(levelId).recordAccepted(CapturedPhotoRecord(
                segmentIndex: i,
                framePath: f.path,
                blurScore: 120,
                meanLuminance: 128,
                yawDegrees: i * 30.0,
                pitchDegrees: 0,
                sensorTimestampNs: 1000 + i,
              ));
          sidecars[sidecarPathForFrame(f.path)] =
              _sidecar(sessionId, '$levelId-$i', i);
        }
      }
      final progression = LevelProgression.of([
        for (final (code, levelId) in [('A', 'mid'), ('B', 'high'), ('C', 'low')])
          LevelProgressState(
            levelId: levelId,
            levelCode: code,
            segmentCount: _perLevel,
            filledCount: _perLevel,
            acceptedCount: _perLevel,
          ),
      ]);

      final ctx = UploadFlowContext(
        // Empty id → the create-project FALLBACK path, so this E2E still
        // mints a real project against the live API (reuse would need a
        // pre-existing server project id). The duplicate-project fix only
        // skips creation when a REAL project id is present.
        localProjectId: '',
        projectName: 'E2E Upload Test (auto)',
        captureSessionId: sessionId,
        config: CaptureConfig.bundledDefault,
        progression: progression,
        registry: registry,
        variant: CaptureFlowVariant.withBottom,
        workspaceRoot: '${tmp.path}/workspace',
      );

      // ── The REAL orchestrator over the REAL transport stack ────────────────
      final orchestrator = UploadFlowOrchestrator(
        resolveContext: () async => ctx,
        pack: ({
          required UploadFlowContext context,
          required ManifestSession session,
          required ManifestDevice device,
          BundleCancelToken? cancelToken,
        }) =>
            CaptureBundlePacker(
              workspaceRoot: context.workspaceRoot,
              copier: _InProcessCopier(),
              sidecarReader: _MapSidecarReader(sidecars),
            ).pack(
              session: session,
              device: device,
              config: context.config,
              progression: context.progression,
              registry: context.registry,
              flowVariantId: context.variant.id,
              cancelToken: cancelToken,
            ),
        backend: () => DioUploadJobsBackend(uploadDio),
        engineFactory: (jobId) {
          final manager = ChunkedUploadManager(
            api: JobsMultipartUploadApi(dio: uploadDio, jobId: jobId),
            s3: DioS3PartClient(),
            isOnline: () => true,
            deviceType: 'e2e',
          );
          return RunnerUploadEngine(
            manager: manager,
            runner: ResilientUploadRunner(
              attempt: ManagerUploadAttempt(manager),
              deviceType: 'e2e',
            ),
          );
        },
      );

      final errors = <Object>[];
      final sub = orchestrator.progress
          .watch()
          .listen((_) {}, onError: errors.add);
      addTearDown(sub.cancel);

      await orchestrator.run();

      expect(errors, isEmpty,
          reason: 'flow must not fail: ${errors.join('; ')}');
      expect(orchestrator.progress.current.status, UploadStatus.completed,
          reason: 'finalize must return QUEUED and release completed');
      expect(orchestrator.progress.current.filesUploaded,
          _perLevel * levelIds.length + 1); // 48 images + manifest
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
