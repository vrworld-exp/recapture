// lib/data/repositories/publish_request_mapping.dart
//
// The ONE mapping from a publish/retry POST to a [PublishRequestResult],
// shared by the owner's `/catalog/publish*` and the rep's
// `/rep/catalogs/:id/publish*`.
//
// It is shared rather than copied because the two routes answer with the SAME
// shapes on purpose — the backend's rep route delegates to the owner's
// service and `rep-publish.test.ts` asserts the payloads equal byte for byte.
// A second copy of this switch is how a 409 starts reading as an error on one
// surface and as "already running" on the other.
//
// Also the one place the status read is decoded, for the same reason: both
// doors hand back the identical `publish` DTO.
import 'package:dio/dio.dart';

import '../../domain/catalog/publish_gate.dart';
import '../../domain/catalog/publish_request_result.dart';
import '../../domain/catalog/publish_status.dart';
import '../../domain/entities/catalog_json.dart';
import 'catalog_failure.dart';

/// POSTs a publish (or retry) and maps the answer. Genuine failures throw
/// [CatalogFailure]; the EXPECTED refusals (409 in progress, 422 blocked, 409
/// name taken) come back as values, because each carries what the screen
/// renders next.
Future<PublishRequestResult> postPublishRequest(
  Dio dio,
  String path, {
  String? idempotencyKey,
}) async {
  try {
    final res = await dio.post<Map<String, dynamic>>(
      path,
      options: idempotencyKey == null
          ? null
          : Options(headers: {'Idempotency-Key': idempotencyKey}),
    );

    final body = res.data;
    final runId = body?['runId'];
    if (runId is! String || runId.isEmpty) {
      // 200 with `queued: false` — a retry that found nothing failed. The
      // outcome the user asked for, so it is not a broken contract.
      return const PublishNothingToRetry();
    }
    return PublishQueued(
      runId: runId,
      publicUrl: catalogText(body?['publicUrl']),
    );
  } on DioException catch (error) {
    final result = publishRefusalFrom(error);
    if (result != null) return result;
    throw CatalogFailure.fromDio(error);
  }
}

/// Maps the EXPECTED refusals onto values. Returns null for anything else,
/// which the caller turns into a [CatalogFailure].
PublishRequestResult? publishRefusalFrom(DioException error) {
  final body = error.response?.data;
  if (body is! Map) return null;

  switch (body['code']) {
    case 'PUBLISH_IN_PROGRESS':
      final runId = body['runId'];
      // Without an id there is nothing to poll, so this degrades to a plain
      // failure rather than a screen watching a run it cannot name.
      return runId is String && runId.isNotEmpty
          ? PublishAlreadyRunning(runId)
          : null;

    case 'PUBLISH_BLOCKED':
      return PublishBlocked(PublishGate.listFrom(body['gates']));

    case 'CATALOG_NAME_TAKEN':
      final fields = body['fields'];
      final suggested = fields is Map ? fields['name'] : null;
      return suggested is String && suggested.isNotEmpty
          ? PublishNameTaken(suggested)
          : null;

    default:
      return null;
  }
}

/// GETs a publish status and decodes its `publish` envelope key.
Future<PublishStatus> getPublishStatus(Dio dio, String path) =>
    mapCatalogErrors(() async {
      final res = await dio.get<Map<String, dynamic>>(path);
      final publish = res.data?['publish'];
      if (publish is! Map<String, dynamic>) {
        throw const CatalogFailure(
          code: 'MALFORMED_RESPONSE',
          message: 'Something went wrong. Please try again.',
        );
      }
      return PublishStatus.fromMap(publish);
    });
