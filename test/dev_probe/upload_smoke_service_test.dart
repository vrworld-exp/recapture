// test/dev_probe/upload_smoke_service_test.dart
//
// Drives the whole upload smoke pipeline against a fake Dio HttpClientAdapter
// (no real network): asserts the request order and shapes (method/path/body,
// Idempotency-Key present, Bearer token attached, the ETag from each S3 PUT
// threaded into the matching uploads/complete), plus a failure-injection run
// (finalize 422) proving the step list stops there and surfaces rule ids.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/dev/dev_probe/bundle_disk_store.dart';
import 'package:recapture/dev/dev_probe/dev_probe_models.dart';
import 'package:recapture/dev/dev_probe/dev_probe_service.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.onFetch);

  final Future<ResponseBody> Function(RequestOptions options) onFetch;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      onFetch(options);
}

ResponseBody _json(Object? body,
    {int status = 200, Map<String, List<String>>? headers}) {
  return ResponseBody.fromString(jsonEncode(body), status, headers: {
    Headers.contentTypeHeader: ['application/json'],
    ...?headers,
  });
}

/// Scripted backend + S3 for one pipeline run.
class _FakeBackend {
  _FakeBackend({this.finalizeResponse});

  /// Override to inject a finalize failure; null = the QUEUED happy path.
  final ResponseBody Function()? finalizeResponse;

  static const keyPrefix = 'development/u1/p1/j1/';
  static const manifestKey = '${keyPrefix}capture_manifest.json';

  final requests = <RequestOptions>[];
  int _uploadCounter = 0;

  /// uploadId â†’ the ETag the fake S3 PUT returned for it.
  final putEtags = <String, String>{};

  /// Mismatches found when uploads/complete arrived (asserted empty).
  final etagViolations = <String>[];

  Future<ResponseBody> handle(RequestOptions o) async {
    requests.add(o);
    final path = o.uri.path;

    if (o.method == 'PUT' && o.uri.host == 's3.test') {
      final uploadId = o.uri.queryParameters['uploadId']!;
      final etag = '"etag-for-$uploadId"';
      putEtags[uploadId] = etag;
      return ResponseBody.fromString('', 200, headers: {
        'etag': [etag],
      });
    }

    switch ('${o.method} $path') {
      case 'POST /auth/send-otp':
        return _json({
          'status': 'success',
          'expiresInSeconds': 300,
          'devCode': '123456',
        });
      case 'POST /auth/verify-otp':
        expect((o.data as Map)['code'], '123456');
        return _json({
          'status': 'success',
          'accessToken': 'access-token-1',
          'refreshToken': 'refresh-token-1',
        });
      case 'POST /projects':
        return _json({
          'status': 'success',
          'project': {'id': 'p1', 'name': (o.data as Map)['name']},
        });
      case 'POST /jobs':
        return _json({
          'status': 'success',
          'job': {'id': 'j1', 'state': 'CREATED'},
          'uploadPlan': {
            'keyPrefix': keyPrefix,
            'manifestKey': manifestKey,
            'levels': ['EYE', 'TOP', 'LOW'],
          },
        }, status: 201);
      case 'POST /jobs/j1/uploads/initiate':
        _uploadCounter++;
        final uploadId = 'up-$_uploadCounter';
        return _json({
          'status': 'success',
          'uploadId': uploadId,
          'key': (o.data as Map)['key'],
          'parts': [
            {
              'partNumber': 1,
              'url': 'https://s3.test/put/$_uploadCounter?uploadId=$uploadId',
            },
          ],
        }, status: 201);
      case 'POST /jobs/j1/uploads/complete':
        final data = o.data as Map;
        final uploadId = data['uploadId'] as String;
        final sentEtag =
            ((data['parts'] as List).first as Map)['etag'] as String;
        if (putEtags[uploadId] != sentEtag) {
          etagViolations
              .add('$uploadId: PUT gave ${putEtags[uploadId]}, got $sentEtag');
        }
        return _json({
          'status': 'success',
          'key': data['key'],
          'etag': '"composite"',
        });
      case 'POST /jobs/j1/finalize':
        if (finalizeResponse != null) return finalizeResponse!();
        return _json({
          'status': 'success',
          'jobId': 'j1',
          'state': 'QUEUED',
          'filesVerified': 49,
          'queuedAt': '2026-07-10T00:00:00.000Z',
        });
    }
    fail('Unexpected request: ${o.method} ${o.uri}');
  }
}

UploadSmokeService _service(_FakeBackend backend) {
  final api = Dio(BaseOptions(baseUrl: 'http://api.test'))
    ..httpClientAdapter = _FakeAdapter(backend.handle);
  final s3 = Dio()..httpClientAdapter = _FakeAdapter(backend.handle);
  return UploadSmokeService(api: api, s3: s3, uuid: () => 'fixed-uuid-1234');
}

void main() {
  setUp(UploadSmokeService.resetCachedSession);

  test('happy path walks every step in order with the right shapes', () async {
    final backend = _FakeBackend();
    final run = await _service(backend).run();

    // Every step succeeded; the run finished.
    expect(run.succeeded, isTrue,
        reason: run.steps
            .map((s) => '${s.id}=${s.state.name}: ${s.detail}')
            .join('\n'));
    expect(run.filesCompleted, 49);
    expect(run.totalFiles, 49);
    expect(run.elapsed, isNotNull);
    expect(run.totalBytes, greaterThan(0));

    // Request order: handshake, project, job, then 37Ã—(initiateâ†’PUTâ†’complete),
    // then finalize.
    final signatures = backend.requests
        .map((o) =>
            o.uri.host == 's3.test' ? 'PUT s3' : '${o.method} ${o.uri.path}')
        .toList();
    expect(signatures.take(4).toList(), [
      'POST /auth/send-otp',
      'POST /auth/verify-otp',
      'POST /projects',
      'POST /jobs',
    ]);
    for (var i = 0; i < 49; i++) {
      expect(signatures[4 + i * 3], 'POST /jobs/j1/uploads/initiate');
      expect(signatures[5 + i * 3], 'PUT s3');
      expect(signatures[6 + i * 3], 'POST /jobs/j1/uploads/complete');
    }
    expect(signatures.last, 'POST /jobs/j1/finalize');
    expect(signatures, hasLength(4 + 49 * 3 + 1));

    // Body shapes.
    final projectReq =
        backend.requests.firstWhere((o) => o.uri.path == '/projects');
    // /projects takes `size` (POST /jobs is the one that takes `objectSize`).
    expect((projectReq.data as Map)['size'], 'medium');
    expect((projectReq.data as Map)['mode'], 'guided');
    expect((projectReq.data as Map)['name'], startsWith('Dev Upload Smoke '));
    expect(projectReq.headers['Authorization'], 'Bearer access-token-1');

    final jobReq = backend.requests.firstWhere((o) => o.uri.path == '/jobs');
    expect((jobReq.data as Map)['captureVariant'], 'with_bottom');
    expect((jobReq.data as Map)['expectedFilesCount'], 49);
    expect(jobReq.headers['Idempotency-Key'], 'fixed-uuid-1234');

    final finalizeReq = backend.requests
        .firstWhere((o) => o.uri.path == '/jobs/j1/finalize');
    expect((finalizeReq.data as Map)['reportedFilesCount'], 49);

    // The ETag each S3 PUT returned was threaded into that file's complete.
    expect(backend.etagViolations, isEmpty);
    expect(backend.putEtags, hasLength(49));

    // The S3 PUTs carried no Authorization header (presigned URL is the auth).
    for (final put in backend.requests.where((o) => o.uri.host == 's3.test')) {
      expect(put.headers['Authorization'], isNull);
    }
  });

  test('with a disk store the bundle is written as real files and uploaded',
      () async {
    final tempRoot =
        Directory.systemTemp.createTempSync('dev_probe_smoke_test');
    addTearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });
    final store = BundleDiskStore(rootProvider: () async => tempRoot);

    final backend = _FakeBackend();
    final api = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = _FakeAdapter(backend.handle);
    final s3 = Dio()..httpClientAdapter = _FakeAdapter(backend.handle);
    final run = await UploadSmokeService(
      api: api,
      s3: s3,
      store: store,
      uuid: () => 'fixed-uuid-1234',
    ).run();

    expect(run.succeeded, isTrue,
        reason: run.steps
            .map((s) => '${s.id}=${s.state.name}: ${s.detail}')
            .join('\n'));
    expect(run.filesCompleted, 49);

    // The bundle landed on disk in the capture layout, 49 files total.
    final files = tempRoot
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path.replaceAll(Platform.pathSeparator, '/'))
        .toList();
    expect(files, hasLength(49));
    expect(files.where((p) => p.contains('/images/EYE/')), hasLength(16));
    expect(files.where((p) => p.contains('/images/TOP/')), hasLength(16));
    expect(files.where((p) => p.contains('/images/LOW/')), hasLength(16));
    expect(files.where((p) => p.endsWith('/capture_manifest.json')),
        hasLength(1));

    // The bundle step's detail points the user at the folder + cleanup.
    final bundleStep = run.steps.firstWhere((s) => s.id == 'bundle');
    expect(bundleStep.detail, contains(tempRoot.path));
    expect(bundleStep.detail, contains('Clear test files'));

    // The full upload conversation still happened (49 initiate/PUT/complete).
    expect(backend.putEtags, hasLength(49));
    expect(backend.etagViolations, isEmpty);
  });

  test('a second run reuses the cached session (no second send-otp)', () async {
    final backend = _FakeBackend();
    final service = _service(backend);
    await service.run();
    await service.run();

    final sendOtps =
        backend.requests.where((o) => o.uri.path == '/auth/send-otp');
    expect(sendOtps, hasLength(1));
  });

  test('devCode absent â†’ auth step fails with a clear message', () async {
    final backend = _FakeBackend();
    final api = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = _FakeAdapter((o) async {
        if (o.uri.path == '/auth/send-otp') {
          return _json({'status': 'success', 'expiresInSeconds': 300});
        }
        return backend.handle(o);
      });
    final s3 = Dio()..httpClientAdapter = _FakeAdapter(backend.handle);
    final run =
        await UploadSmokeService(api: api, s3: s3, uuid: () => 'u').run();

    expect(run.failed, isTrue);
    final auth = run.steps.first;
    expect(auth.state, ProbeStepState.failure);
    expect(auth.detail, contains('devCode'));
    // Nothing after auth ran.
    expect(run.steps.skip(1).every((s) => s.state == ProbeStepState.pending),
        isTrue);
  });

  test('finalize 422 stops the pipeline and surfaces the rule ids', () async {
    final backend = _FakeBackend(
      finalizeResponse: () => _json({
        'status': 'error',
        'code': 'VERIFICATION_FAILED',
        'reason': 'manifest_invalid',
        'message': 'The capture manifest failed validation.',
        'expectedFilesCount': 49,
        'actualFilesCount': 49,
        'validationErrors': [
          {
            'rule': 'RING_PHOTO_COUNT_BELOW_MINIMUM',
            'detail': {'ring': 'LOW', 'found': 11, 'minimum': 12},
          },
          {'rule': 'UNEXPECTED_LEVELS'},
        ],
      }, status: 422),
    );
    final run = await _service(backend).run();

    expect(run.failed, isTrue);
    expect(run.succeeded, isFalse);

    // Every step before finalize kept its success + detail.
    final finalize = run.steps.last;
    expect(finalize.id, 'finalize');
    expect(finalize.state, ProbeStepState.failure);
    for (final step in run.steps.take(run.steps.length - 1)) {
      expect(step.state, ProbeStepState.success, reason: step.id);
      expect(step.detail, isNotNull, reason: step.id);
    }
    expect(run.filesCompleted, 49); // uploads finished before the 422

    // The envelope surfaced verbatim: code, message, and the rule ids.
    expect(finalize.detail, contains('VERIFICATION_FAILED'));
    expect(finalize.detail, contains('The capture manifest failed validation.'));
    expect(finalize.detail, contains('RING_PHOTO_COUNT_BELOW_MINIMUM'));
    expect(finalize.detail, contains('UNEXPECTED_LEVELS'));
    expect(finalize.detail, contains('422'));
  });
}
