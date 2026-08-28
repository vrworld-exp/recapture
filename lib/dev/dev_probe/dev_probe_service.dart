// lib/dev/dev_probe/dev_probe_service.dart
//
// ── Dev Tools probe (dev flavors only — see dev_tools_section.dart) ──────────
//
// Self-contained services behind the Home-page Dev Tools buttons. These are
// the app's FIRST real client→backend calls; the production repositories stay
// stubbed. The module deliberately touches no repositories, notifiers, auth
// state, Hive, or analytics — it performs its OWN auth handshake against the
// backend (the app's stub tokens would 401) and keeps tokens in memory only.
//
// HOW TO RUN THE PROBE END-TO-END:
//   1. Backend up: `docker compose up -d` (Mongo), then
//      `cd recapture-api && npm run dev` with real AWS credentials in its
//      `.env` (buckets live in us-east-1).
//   2. Client `API_BASE_URL` in `.env.dev`:
//        Android emulator          → http://10.0.2.2:3000
//        physical device           → http://<LAN-IP>:3000
//        Windows desktop / web     → http://127.0.0.1:3000
//   3. Dev flavor run → Projects screen → DEV TOOLS section.
//
// FLUTTER WEB CAVEAT: the S3 part PUT + reading its ETag header require S3
// bucket CORS (PUT origin + ExposeHeaders: ETag). Primary target is a real
// device/emulator (no CORS there); on web, expect the upload step to fail
// until bucket CORS is configured.
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../data/remote/dev_otp_handshake.dart';
import 'bundle_disk_store.dart';
import 'dev_probe_models.dart';
import 'dummy_bundle.dart';

/// Fixed dev identity for the probe's own OTP handshake (the shared service's).
const String kProbePhone = kDevOtpPhone;

/// GET /health with a short timeout, measuring wall latency. Never throws —
/// unreachable/timeout comes back as an error-state [HealthCheckResult].
class HealthProbeService {
  HealthProbeService({required this.dio});

  final Dio dio;

  Future<HealthCheckResult> check() async {
    final stopwatch = Stopwatch()..start();
    try {
      final res = await dio.get<Object?>(
        '/health',
        options: Options(
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
          // Any status code is a displayable result, not an exception.
          validateStatus: (_) => true,
        ),
      );
      stopwatch.stop();
      return HealthCheckResult(
        ok: true,
        statusCode: res.statusCode,
        latencyMs: stopwatch.elapsedMilliseconds,
        body: prettyJson(res.data),
        baseUrl: dio.options.baseUrl,
      );
    } on DioException catch (e) {
      stopwatch.stop();
      return HealthCheckResult(
        ok: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        baseUrl: dio.options.baseUrl,
        errorType: e.type.name,
        errorMessage: e.message,
      );
    }
  }
}

/// Signals a step failure with a display-ready detail message; aborts the
/// pipeline at the failing step.
class _StepFailure implements Exception {
  _StepFailure(this.detail);

  final String detail;
}

/// The Upload smoke pipeline: auth → project → job → bundle → 49 uploads →
/// finalize, all against the real backend (and through it, real S3).
class UploadSmokeService {
  UploadSmokeService({
    required this.api,
    required this.s3,
    this.store,
    String Function()? uuid,
    DevOtpHandshake? handshake,
  })  : _uuid = uuid ?? _randomUuidV4,
        _handshake = handshake;

  /// Dio bound to the API base URL. The probe's OWN instance — never the
  /// app-wide client (its AuthInterceptor is wired to the stubbed auth state).
  final Dio api;

  /// Bare Dio for the presigned S3 part PUT (absolute URL, no auth header).
  final Dio s3;

  /// When present, the bundle is written to a dedicated on-device folder and
  /// each upload reads its bytes back FROM DISK — same shape as the real
  /// post-capture flow. Null (web, unit tests) keeps the in-memory bundle.
  final BundleDiskStore? store;

  final String Function() _uuid;

  /// The shared dev OTP handshake (its session cache is static — tokens
  /// survive across runs within one app session, avoiding the send-otp rate
  /// window; memory only, by design). Lazily bound to [api] when not injected.
  DevOtpHandshake? _handshake;

  DevOtpHandshake get _auth => _handshake ??= DevOtpHandshake(api: api);

  @visibleForTesting
  static void resetCachedSession() => DevOtpHandshake.resetCachedSession();

  static const _stepAuth = 'auth';
  static const _stepProject = 'project';
  static const _stepJob = 'job';
  static const _stepBundle = 'bundle';
  static const _stepUpload = 'upload';
  static const _stepFinalize = 'finalize';

  /// Runs the full pipeline once. Always returns the run (never throws); a
  /// failure stops the pipeline with the failing step marked, prior steps'
  /// results left intact. [onUpdate] fires with the (mutating) run after
  /// every state change so the UI can render live progress.
  Future<UploadSmokeRun> run(
      {void Function(UploadSmokeRun run)? onUpdate}) async {
    final run = UploadSmokeRun(
      totalFiles: kSmokeExpectedFilesCount,
      steps: [
        ProbeStep(id: _stepAuth, title: 'Auth (dev OTP handshake)'),
        ProbeStep(id: _stepProject, title: 'Create project'),
        ProbeStep(id: _stepJob, title: 'Create job'),
        ProbeStep(id: _stepBundle, title: 'Generate dummy bundle'),
        ProbeStep(
            id: _stepUpload, title: 'Upload files 0/$kSmokeExpectedFilesCount'),
        ProbeStep(id: _stepFinalize, title: 'Finalize → QUEUED'),
      ],
    );
    void notify() => onUpdate?.call(run);
    final stopwatch = Stopwatch()..start();

    ProbeStep step(String id) => run.steps.firstWhere((s) => s.id == id);

    Future<void> runStep(
        String id, Future<String?> Function(ProbeStep) body) async {
      final s = step(id);
      s.state = ProbeStepState.running;
      notify();
      try {
        s.detail = await body(s);
        s.state = ProbeStepState.success;
      } on _StepFailure catch (f) {
        s.detail = f.detail;
        s.state = ProbeStepState.failure;
        rethrow;
      } on DioException catch (e) {
        s.detail = _describeDioError(e);
        s.state = ProbeStepState.failure;
        rethrow;
      } catch (e) {
        s.detail = e.toString();
        s.state = ProbeStepState.failure;
        rethrow;
      } finally {
        notify();
      }
    }

    try {
      // 1) Auth — reuse the cached in-memory session when present.
      await runStep(_stepAuth, (s) async {
        if (_auth.hasCachedSession) {
          return 'Reused cached session from an earlier run.';
        }
        try {
          await _auth.session();
        } on DevOtpHandshakeException catch (e) {
          throw _StepFailure(e.detail);
        }
        return 'Handshake complete — session cached for this app session.';
      });

      // 2) Create project.
      late String projectId;
      await runStep(_stepProject, (s) async {
        final now = DateTime.now();
        final hh = now.hour.toString().padLeft(2, '0');
        final mm = now.minute.toString().padLeft(2, '0');
        final ss = now.second.toString().padLeft(2, '0');
        // NB: /projects takes `size`; /jobs takes `objectSize` (same enum).
        final body = await _authedPost('/projects', {
          'name': 'Dev Upload Smoke $hh:$mm:$ss',
          'size': 'medium',
          'mode': 'guided',
        });
        projectId = _objectField(body, 'project')['id'] as String;
        return prettyJson(body);
      });

      // 3) Create job — fresh Idempotency-Key per run.
      late String jobId;
      late String keyPrefix;
      late String manifestKey;
      await runStep(_stepJob, (s) async {
        final body = await _authedPost(
          '/jobs',
          {
            'projectId': projectId,
            'objectSize': 'medium',
            'captureVariant': kSmokeFlowVariant,
            'expectedFilesCount': kSmokeExpectedFilesCount,
          },
          headers: {'Idempotency-Key': _uuid()},
        );
        jobId = _objectField(body, 'job')['id'] as String;
        final plan = _objectField(body, 'uploadPlan');
        keyPrefix = plan['keyPrefix'] as String;
        manifestKey = plan['manifestKey'] as String;
        return prettyJson(body);
      });

      // 4) Generate the bundle — and, with a disk store, write it out as real
      // files (images/{RING}/… + capture_manifest.json) like a capture would.
      late DummyBundle bundle;
      WrittenBundle? written;
      await runStep(_stepBundle, (s) async {
        bundle =
            buildDummyBundle(keyPrefix: keyPrefix, manifestKey: manifestKey);
        run.totalBytes = bundle.totalBytes;
        if (store == null) {
          return '${bundle.files.length} files, ${bundle.totalBytes} bytes '
              'under $keyPrefix (in-memory — no disk store on this platform)';
        }
        written = await store!.write(bundle, keyPrefix: keyPrefix);
        return '${bundle.files.length} files (${bundle.totalBytes} bytes) '
            'written to:\n${written!.directory}\n\n'
            'Use "Clear test files" below to delete them after testing.';
      });

      // 5) Upload all 49 files sequentially (initiate → PUT → complete),
      // reading each file's bytes back from disk when the bundle was written.
      await runStep(_stepUpload, (s) async {
        for (final file in bundle.files) {
          final bytes = written == null
              ? file.bytes
              : await store!.read(written!.pathFor(file.key));
          await _uploadOne(jobId, file.key, bytes);
          run.filesCompleted++;
          s.title = 'Upload files ${run.filesCompleted}/${run.totalFiles}';
          notify();
        }
        return 'All ${run.totalFiles} files uploaded and completed.';
      });

      // 6) Finalize — the whole point: QUEUED + filesVerified.
      await runStep(_stepFinalize, (s) async {
        final body = await _authedPost('/jobs/$jobId/finalize', {
          'reportedFilesCount': kSmokeExpectedFilesCount,
        });
        if (body['state'] != 'QUEUED') {
          throw _StepFailure(
              'Expected state QUEUED, got:\n${prettyJson(body)}');
        }
        return prettyJson(body);
      });
    } catch (_) {
      // The failing step already carries its detail; the pipeline just stops.
    }

    stopwatch.stop();
    run.elapsed = stopwatch.elapsed;
    notify();
    return run;
  }

  /// One file: initiate (single part) → presigned PUT to S3 → complete with
  /// the ETag the PUT returned.
  Future<void> _uploadOne(String jobId, String key, Uint8List bytes) async {
    final initiate = await _authedPost('/jobs/$jobId/uploads/initiate', {
      'key': key,
      'fileSize': bytes.length,
      'partCount': 1,
    });
    final uploadId = initiate['uploadId'] as String;
    final parts = initiate['parts'] as List<dynamic>;
    final partUrl = (parts.first as Map<String, dynamic>)['url'] as String;

    final etag = await _putToS3(partUrl, bytes);

    await _authedPost('/jobs/$jobId/uploads/complete', {
      'key': key,
      'uploadId': uploadId,
      'parts': [
        {'partNumber': 1, 'etag': etag},
      ],
    });
  }

  /// Plain PUT of the raw bytes to the presigned URL — no auth header (the
  /// signature IS the auth). Returns the ETag response header.
  Future<String> _putToS3(String url, Uint8List bytes) async {
    final res = await s3.put<Object?>(
      url,
      data: Stream<Uint8List>.fromIterable([bytes]),
      options: Options(
        headers: {Headers.contentLengthHeader: bytes.length},
        responseType: ResponseType.plain,
      ),
    );
    if (res.statusCode == null || res.statusCode! >= 300) {
      throw _StepFailure('S3 PUT failed with HTTP ${res.statusCode}.');
    }
    final etag = res.headers.value('etag');
    if (etag == null || etag.isEmpty) {
      throw _StepFailure(
          'S3 PUT succeeded but no ETag header was readable. On Flutter web '
          'this needs S3 bucket CORS (PUT origin + ExposeHeaders: ETag); use '
          'a real device/emulator instead.');
    }
    return etag;
  }

  // ── Auth plumbing ──────────────────────────────────────────────────────────

  /// POST with the probe's Bearer token (via the shared [DevOtpHandshake]). On
  /// a 401 (expired cached session), redoes the handshake ONCE and retries.
  /// Non-2xx responses become [_StepFailure]s carrying the envelope verbatim.
  /// A handshake failure (no devCode) surfaces its display detail.
  Future<Map<String, dynamic>> _authedPost(
    String path,
    Map<String, Object?> body, {
    Map<String, String>? headers,
    bool retryOn401 = true,
  }) async {
    final DevOtpSession session;
    try {
      session = await _auth.session();
    } on DevOtpHandshakeException catch (e) {
      throw _StepFailure(e.detail);
    }
    final res = await api.post<Object?>(
      path,
      data: body,
      options: Options(
        headers: {
          'Authorization': 'Bearer ${session.accessToken}',
          ...?headers,
        },
        validateStatus: (_) => true,
      ),
    );
    if (res.statusCode == 401 && retryOn401) {
      _auth.invalidate();
      return _authedPost(path, body, headers: headers, retryOn401: false);
    }
    if (res.statusCode == null || res.statusCode! >= 300) {
      throw _StepFailure(_describeEnvelope(res.statusCode, res.data));
    }
    return _asJsonMap(res.data);
  }

  // ── Formatting helpers ─────────────────────────────────────────────────────

  /// Headline (HTTP status, envelope code/message, validationErrors rule ids
  /// verbatim) + the full raw body.
  static String _describeEnvelope(int? statusCode, Object? data) {
    final buffer = StringBuffer('HTTP ${statusCode ?? '?'}');
    if (data is Map) {
      final code = data['code'];
      final message = data['message'];
      if (code != null) buffer.write(' $code');
      if (message != null) buffer.write(' — $message');
      final validationErrors = data['validationErrors'];
      if (validationErrors is List) {
        final rules = validationErrors
            .whereType<Map>()
            .map((e) => e['rule'])
            .whereType<Object>()
            .join(', ');
        if (rules.isNotEmpty) buffer.write('\nrules: $rules');
      }
    }
    buffer.write('\n${prettyJson(data)}');
    return buffer.toString();
  }

  static String _describeDioError(DioException e) {
    if (e.response != null) {
      return _describeEnvelope(e.response!.statusCode, e.response!.data);
    }
    return 'Backend unreachable (${e.type.name}): ${e.message}';
  }

  static Map<String, dynamic> _asJsonMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw _StepFailure('Expected a JSON object, got: ${prettyJson(data)}');
  }

  static Map<String, dynamic> _objectField(
      Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is Map) return Map<String, dynamic>.from(value);
    throw _StepFailure("Response is missing '$key':\n${prettyJson(body)}");
  }
}

/// RFC-4122 v4 UUID from a CSPRNG — avoids adding a uuid package for a
/// dev-only idempotency key.
String _randomUuidV4() {
  final rng = Random.secure();
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = rng.nextInt(256);
  }
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
