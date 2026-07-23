// test/upload/jobs_multipart_upload_api_test.dart
//
// The REAL backend adapters against a mocked Dio (fake HttpClientAdapter — no
// network): the per-file multipart broker [JobsMultipartUploadApi] (paths under
// /jobs/:jobId/uploads/*, camelCase bodies, parts in ascending order on
// complete, abort = local no-op) and the flow gateway [DioUploadJobsBackend]
// (Idempotency-Key on POST /jobs, envelope parsing).
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/upload/jobs_multipart_upload_api.dart';
import 'package:recapture/application/upload/multipart_upload_api.dart';
import 'package:recapture/application/upload/upload_jobs_backend.dart';

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

ResponseBody _json(Object? body, {int status = 200}) =>
    ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });

void main() {
  late List<RequestOptions> requests;
  late Dio dio;

  Dio buildDio(Future<ResponseBody> Function(RequestOptions) handle) {
    requests = [];
    return Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = _FakeAdapter((o) {
        requests.add(o);
        return handle(o);
      });
  }

  group('JobsMultipartUploadApi', () {
    late JobsMultipartUploadApi api;

    setUp(() {
      dio = buildDio((o) async {
        switch (o.uri.path) {
          case '/jobs/job-1/uploads/initiate':
            return _json({
              'status': 'success',
              'uploadId': 'up-1',
              'key': (o.data as Map)['key'],
              'parts': [
                {'partNumber': 1, 'url': 'https://s3/p1'},
                {'partNumber': 2, 'url': 'https://s3/p2'},
              ],
              'urlsExpireAt': '2026-07-11T00:00:00.000Z',
            }, status: 201);
          case '/jobs/job-1/uploads/part-url':
            return _json({'status': 'success', 'url': 'https://s3/fresh'});
          case '/jobs/job-1/uploads/complete':
            return _json({'status': 'success', 'key': 'k', 'etag': '"e"'});
        }
        fail('Unexpected request: ${o.method} ${o.uri}');
      });
      api = JobsMultipartUploadApi(dio: dio, jobId: 'job-1');
    });

    test('initiate posts the contract path + camelCase body and parses parts',
        () async {
      final init = await api.initiate(
        sessionId: 'engine-session', // engine bookkeeping — not on the wire
        fileKey: 'dev/u/p/j/images/EYE/eye_0001.jpg',
        fileSize: 5 * 1024 * 1024 + 1,
        partCount: 2,
      );

      final req = requests.single;
      expect(req.method, 'POST');
      expect(req.uri.path, '/jobs/job-1/uploads/initiate');
      expect(req.data, {
        'key': 'dev/u/p/j/images/EYE/eye_0001.jpg',
        'fileSize': 5 * 1024 * 1024 + 1,
        'partCount': 2,
      });

      expect(init.uploadId, 'up-1');
      expect(init.key, 'dev/u/p/j/images/EYE/eye_0001.jpg');
      expect(init.urlForPart(1), 'https://s3/p1');
      expect(init.urlForPart(2), 'https://s3/p2');
    });

    test('refreshPartUrl posts camelCase body and returns the fresh url',
        () async {
      final url = await api.refreshPartUrl(
        uploadId: 'up-1',
        key: 'k1',
        partNumber: 3,
      );

      final req = requests.single;
      expect(req.uri.path, '/jobs/job-1/uploads/part-url');
      expect(req.data, {'key': 'k1', 'uploadId': 'up-1', 'partNumber': 3});
      expect(url, 'https://s3/fresh');
    });

    test('complete posts parts in the given (ascending) order, camelCase',
        () async {
      await api.complete(
        uploadId: 'up-1',
        key: 'k1',
        parts: const [
          CompletedPart(partNumber: 1, etag: '"e1"'),
          CompletedPart(partNumber: 2, etag: '"e2"'),
          CompletedPart(partNumber: 3, etag: '"e3"'),
        ],
      );

      final req = requests.single;
      expect(req.uri.path, '/jobs/job-1/uploads/complete');
      expect(req.data, {
        'key': 'k1',
        'uploadId': 'up-1',
        'parts': [
          {'partNumber': 1, 'etag': '"e1"'},
          {'partNumber': 2, 'etag': '"e2"'},
          {'partNumber': 3, 'etag': '"e3"'},
        ],
      });
      // Ascending order preserved on the wire.
      final numbers = [
        for (final p in (req.data as Map)['parts'] as List)
          (p as Map)['partNumber'] as int,
      ];
      expect(numbers, [1, 2, 3]);
    });

    test('abort is a local no-op (the backend has no abort route)', () async {
      await api.abort(uploadId: 'up-1', key: 'k1');
      expect(requests, isEmpty);
    });
  });

  group('DioUploadJobsBackend', () {
    late DioUploadJobsBackend backend;

    setUp(() {
      dio = buildDio((o) async {
        switch (o.uri.path) {
          case '/projects':
            return _json({
              'status': 'success',
              'project': {'id': 'proj-9', 'name': (o.data as Map)['name']},
            }, status: 201);
          case '/jobs':
            return _json({
              'status': 'success',
              'job': {'id': 'job-9', 'state': 'CREATED'},
              'uploadPlan': {
                'keyPrefix': 'dev/u/proj-9/job-9/',
                'manifestKey': 'dev/u/proj-9/job-9/capture_manifest.json',
              },
            }, status: 201);
          case '/jobs/job-9/finalize':
            return _json({
              'status': 'success',
              'jobId': 'job-9',
              'state': 'QUEUED',
            });
        }
        fail('Unexpected request: ${o.method} ${o.uri}');
      });
      backend = DioUploadJobsBackend(dio);
    });

    test('createProject posts name/size/mode and returns the id', () async {
      final id = await backend.createProject(
          name: 'My scan', size: 'medium', mode: 'guided');
      expect(id, 'proj-9');
      expect(requests.single.data,
          {'name': 'My scan', 'size': 'medium', 'mode': 'guided'});
    });

    test('createJob carries the Idempotency-Key header + camelCase body',
        () async {
      final job = await backend.createJob(
        projectId: 'proj-9',
        objectSize: 'medium',
        captureVariant: 'with_bottom',
        captureMode: 'full',
        expectedFilesCount: 37,
        idempotencyKey: 'uuid-1234',
      );

      final req = requests.single;
      expect(req.headers['Idempotency-Key'], 'uuid-1234');
      expect(req.data, {
        'projectId': 'proj-9',
        'objectSize': 'medium',
        'captureVariant': 'with_bottom',
        'captureMode': 'full',
        'expectedFilesCount': 37,
      });
      expect(job.jobId, 'job-9');
      expect(job.keyPrefix, 'dev/u/proj-9/job-9/');
      expect(job.manifestKey, 'dev/u/proj-9/job-9/capture_manifest.json');
    });

    test('finalizeJob posts reportedFilesCount and returns the state',
        () async {
      final state =
          await backend.finalizeJob(jobId: 'job-9', reportedFilesCount: 37);
      expect(state, 'QUEUED');
      expect(requests.single.uri.path, '/jobs/job-9/finalize');
      expect(requests.single.data, {'reportedFilesCount': 37});
    });

    test('a non-2xx envelope surfaces as a DioException (classified by 9F)',
        () async {
      dio = buildDio((o) async => _json({
            'status': 'error',
            'code': 'VERIFICATION_FAILED',
            'message': 'count mismatch',
          }, status: 422));
      backend = DioUploadJobsBackend(dio);

      await expectLater(
        backend.finalizeJob(jobId: 'job-9', reportedFilesCount: 37),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'statusCode', 422)),
      );
    });
  });
}
