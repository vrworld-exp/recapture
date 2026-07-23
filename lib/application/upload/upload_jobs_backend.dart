// lib/application/upload/upload_jobs_backend.dart
//
// The upload flow's thin backend gateway for the NON-file-transfer calls:
// create the remote project, create the upload job (idempotent via
// `Idempotency-Key`), and finalize after every file uploaded. Response
// envelopes are `{ "status": "success", ... }`; non-2xx surfaces as a
// DioException (classified downstream by [classifyUploadFailure] for 9F).
// Interface + Dio impl so the orchestrator is unit-testable with fakes.
import 'package:dio/dio.dart';

/// The plan returned by `POST /jobs` — where this job's files must live.
class CreatedUploadJob {
  const CreatedUploadJob({
    required this.jobId,
    required this.keyPrefix,
    required this.manifestKey,
  });

  final String jobId;

  /// Every uploaded object key MUST stay under this prefix (server-enforced
  /// containment, 400 otherwise).
  final String keyPrefix;

  /// The exact key `capture_manifest.json` uploads to.
  final String manifestKey;
}

/// Backend calls the upload orchestrator makes around the file transfer.
abstract interface class UploadJobsBackend {
  /// `POST /projects` → the remote project id.
  Future<String> createProject({
    required String name,
    required String size,
    required String mode,
  });

  /// `POST /jobs` (with `Idempotency-Key`) → job id + upload plan.
  Future<CreatedUploadJob> createJob({
    required String projectId,
    required String objectSize,
    required String captureVariant,
    required String captureMode,
    required int expectedFilesCount,
    required String idempotencyKey,
  });

  /// `POST /jobs/:jobId/finalize` → the job's resulting state
  /// ("QUEUED" on success).
  Future<String> finalizeJob({
    required String jobId,
    required int reportedFilesCount,
  });
}

/// Dio-backed [UploadJobsBackend] over the authed upload Dio.
class DioUploadJobsBackend implements UploadJobsBackend {
  const DioUploadJobsBackend(this._dio);

  final Dio _dio;

  @override
  Future<String> createProject({
    required String name,
    required String size,
    required String mode,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/projects',
      data: {'name': name, 'size': size, 'mode': mode},
    );
    final project = res.data?['project'];
    if (project is! Map || project['id'] is! String) {
      throw StateError('POST /projects returned no project id');
    }
    return project['id'] as String;
  }

  @override
  Future<CreatedUploadJob> createJob({
    required String projectId,
    required String objectSize,
    required String captureVariant,
    required String captureMode,
    required int expectedFilesCount,
    required String idempotencyKey,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/jobs',
      data: {
        'projectId': projectId,
        'objectSize': objectSize,
        'captureVariant': captureVariant,
        'captureMode': captureMode,
        'expectedFilesCount': expectedFilesCount,
      },
      options: Options(headers: {'Idempotency-Key': idempotencyKey}),
    );
    final data = res.data ?? const {};
    final job = data['job'];
    final plan = data['uploadPlan'];
    if (job is! Map || job['id'] is! String || plan is! Map) {
      throw StateError('POST /jobs returned no job/uploadPlan');
    }
    return CreatedUploadJob(
      jobId: job['id'] as String,
      keyPrefix: plan['keyPrefix'] as String,
      manifestKey: plan['manifestKey'] as String,
    );
  }

  @override
  Future<String> finalizeJob({
    required String jobId,
    required int reportedFilesCount,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/jobs/$jobId/finalize',
      data: {'reportedFilesCount': reportedFilesCount},
    );
    return (res.data?['state'] as String?) ?? '';
  }
}
