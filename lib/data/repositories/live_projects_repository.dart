// lib/data/repositories/live_projects_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/generation_trace.dart';
import '../../domain/entities/live_project.dart';
import '../../domain/entities/project_model.dart';
import '../remote/api_client.dart';

/// Friendly failure buckets for the staff Live-projects surface — the UI
/// renders copy per category and NEVER a raw code/URL (same mapped-only rule
/// as Screen 9F's upload categories).
enum LiveProjectsFailure {
  /// 403 — the account lost its staff role (or never had it).
  forbidden,

  /// 409 NOT_EXPORTABLE — the project has no finalized upload to export.
  notExportable,

  /// 404 — the project is gone (already hard-deleted, or never existed).
  notFound,

  /// 422 CONFIRMATION_REQUIRED — the typed project name didn't match; the
  /// server refused without touching anything.
  confirmationMismatch,

  /// 429 — export generation rate limit; [LiveProjectsException.retryAfterSeconds]
  /// may say when to retry.
  rateLimited,

  /// 409 DISABLED — server-side model generation is switched off (env gate or
  /// the live kill switch). Not a caller mistake, and not retryable by them.
  generationDisabled,

  /// 409 USER_CAP_REACHED — the rolling 24h ceiling that automatic and
  /// button-triggered generations share. Retryable tomorrow, not now.
  dailyLimitReached,

  /// 409 from an Optimize request — the server re-checked the rule and refused
  /// (already optimized, already small, size unknown, not finished yet). Never
  /// a transport problem, and never worth retrying as-is: the row is stale, so
  /// the copy tells the user to refresh rather than to try again.
  notOptimizable,

  /// Transport-level failure (offline, timeout).
  network,

  /// Anything else the server refused with.
  server,
}

/// A translated Live-projects/export failure. [failure] drives the UI copy;
/// nothing here carries raw response bodies or presigned URLs.
class LiveProjectsException implements Exception {
  const LiveProjectsException(this.failure, {this.retryAfterSeconds});

  final LiveProjectsFailure failure;
  final int? retryAfterSeconds;

  @override
  String toString() =>
      'LiveProjectsException(${failure.name}${retryAfterSeconds == null ? '' : ', retryAfter: ${retryAfterSeconds}s'})';
}

/// Data access for the staff-only Live projects surface (`/admin/*`).
/// Owns all HTTP + error translation — the notifier never touches Dio.
abstract interface class LiveProjectsRepository {
  /// One page of captured projects across all users, newest first.
  /// Throws [LiveProjectsException] on failure.
  Future<LiveProjectsPage> list({int limit, String? cursor});

  /// The export manifest for [projectId] — returned as the RAW response
  /// `export` object (the artist-facing JSON written to the share file).
  /// Throws [LiveProjectsException] (notExportable / rateLimited / …).
  Future<Map<String, dynamic>> export(String projectId);

  /// Soft-deletes the given job-root-RELATIVE [keys] (exactly as the export
  /// manifest emits them) from [projectId]'s exportable job. Returns which keys
  /// were deleted vs already missing. Throws [LiveProjectsException]
  /// (forbidden when the account is not ADMIN / notExportable / network / …).
  Future<PreviewDeleteResult> deletePhotos(String projectId, List<String> keys);

  /// Requests a Meshy AI 3D model from the 3–4 selected [keys]. Returns the
  /// QUEUED record to poll. [idempotencyKey] makes a double-tap resolve to the
  /// first request instead of a second PAID generation — always pass one.
  /// Throws [LiveProjectsException].
  Future<ProjectModelView> createModel(
    String projectId,
    List<String> keys, {
    required String idempotencyKey,
  });

  /// Runs the SERVER-side photo selection for [projectId] and enqueues the
  /// generation — the "Generate 3D model" button.
  ///
  /// Repeat calls are idempotent by default (the second returns the existing
  /// record rather than paying again); [force] mints a fresh key and
  /// deliberately pays for a second generation, and is staff-only server-side.
  ///
  /// A REFUSAL BY THE SELECTOR IS A RESULT, NOT AN EXCEPTION: it carries the
  /// counters that say why, and those are the whole point of the feature.
  /// Everything else (403/404/409/429/network) throws [LiveProjectsException].
  Future<AutoGenerationRequest> autoGenerateModel(
    String projectId, {
    bool force = false,
  });

  /// STAFF: the project's generation history, newest first, in the staff shape
  /// (trace, selected keys, actor data). Throws [LiveProjectsException].
  Future<List<ProjectModelView>> listModels(String projectId);

  /// OWNER: the same history for a project the caller OWNS, newest first, in
  /// the owner-safe shape — no trace, no selected keys, no actor ids.
  ///
  /// A separate call rather than a role flag on [listModels] because they are
  /// different routes returning different payloads; collapsing them would mean
  /// one of the two parsers silently reading fields the other never sends.
  /// Throws [LiveProjectsException].
  Future<List<ProjectModelView>> listOwnerModels(String projectId);

  /// Marks [modelId] approved ("we're satisfied — skip manual creation").
  /// Throws [LiveProjectsException].
  Future<ProjectModelView> approveModel(String projectId, String modelId);

  /// STAFF: asks the backend to shrink [modelId] and add the result to this
  /// project's model list as its own `OPT` record. Returns that record —
  /// QUEUED on the first call, and the EXISTING one on a repeat (the server
  /// replays rather than creating a second).
  ///
  /// Costs no generation credits, so unlike [createModel] it carries no
  /// idempotency key: the server's unique index on the source model is what
  /// makes a double-tap a replay. Throws [LiveProjectsException] —
  /// [LiveProjectsFailure.notOptimizable] when the server refuses the rule.
  Future<ProjectModelView> optimizeModel(String projectId, String modelId);

  /// OWNER: the same request against the owner-scoped route, for the owner's
  /// Optimize action on the viewer and the model list.
  ///
  /// Returns nothing, unlike [optimizeModel]: the owner route answers with a
  /// minimal `{id, status}` rather than a model DTO, so callers re-read the
  /// list (see OwnerModelHistoryNotifier.optimize) instead of splicing a row.
  /// Throws [LiveProjectsException].
  Future<void> optimizeOwnerModel(String projectId, String modelId);

  /// ADMIN-only: deletes [projectId] — [AdminDeleteMode.soft] hides it
  /// (recoverable), [AdminDeleteMode.hard] permanently erases the project,
  /// its photos and its models. [confirmName] must echo the project's exact
  /// name; the server independently enforces it (confirmationMismatch).
  /// Throws [LiveProjectsException] (forbidden / notFound /
  /// confirmationMismatch / network / …).
  Future<void> deleteProject(
    String projectId, {
    required AdminDeleteMode mode,
    required String confirmName,
  });
}

/// How an admin project delete behaves — mirrors the backend's SOFT/HARD enum.
enum AdminDeleteMode {
  /// Flag-only: hidden from every list, every byte kept, restorable by the team.
  soft('SOFT'),

  /// Permanently erases the project, its photos, and its 3D models.
  hard('HARD');

  const AdminDeleteMode(this.wire);

  /// The exact value the API expects.
  final String wire;
}

/// What the server did with a "Generate 3D model" press.
enum AutoGenerationOutcome {
  /// A new generation was enqueued (and paid for).
  enqueued,

  /// A generation for this capture already existed — nothing new was charged.
  replayed,

  /// The selector refused. Nothing was charged, and [AutoGenerationRequest.trace]
  /// says why.
  declined,
}

/// The completed request trace, as `POST /admin/projects/:id/model/auto`
/// returns it.
///
/// Every step in [steps] has ALREADY happened by the time this exists — the
/// whole selection runs inside the one request, in well under a second. Render
/// it as a finished checklist, never as live progress.
class AutoGenerationRequest {
  const AutoGenerationRequest({
    required this.outcome,
    this.model,
    this.steps = const [],
    this.trace,
    this.declineReason,
  });

  final AutoGenerationOutcome outcome;

  /// The QUEUED record to watch, for [AutoGenerationOutcome.enqueued] and
  /// [AutoGenerationOutcome.replayed]. Null on a decline.
  final ProjectModelView? model;

  final List<GenerationStep> steps;

  /// The selector's counters. Present on an enqueue and on a decline — a
  /// decline without them is uninterpretable.
  final GenerationSelectionTrace? trace;

  /// Set only when [outcome] is [AutoGenerationOutcome.declined].
  final GenerationDeclineReason? declineReason;
}

/// Outcome of a soft-delete: the keys that were moved out vs those already gone.
class PreviewDeleteResult {
  const PreviewDeleteResult({required this.deleted, required this.missing});

  final List<String> deleted;
  final List<String> missing;
}

/// The stable `code`s the backend's optimize routes answer a refused rule
/// with. Hand-synced with NOT_OPTIMIZABLE_CODES in
/// recapture-api/src/services/projectModelsService.ts.
const _kNotOptimizableCodes = {
  'MODEL_NOT_READY',
  'MODEL_SIZE_UNKNOWN',
  'MODEL_ALREADY_SMALL',
  'ALREADY_OPTIMIZED',
};

class RemoteLiveProjectsRepository implements LiveProjectsRepository {
  const RemoteLiveProjectsRepository(this._dio);

  final Dio _dio;

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/admin/projects',
        queryParameters: {
          'limit': limit,
          if (cursor != null) 'cursor': cursor,
        },
      );
      final data = res.data ?? const {};
      final items = data['items'];
      return LiveProjectsPage(
        items: [
          if (items is List)
            for (final item in items)
              if (item is Map<String, dynamic>) LiveProject.fromMap(item),
        ],
        nextCursor:
            data['nextCursor'] is String ? data['nextCursor'] as String : null,
      );
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<Map<String, dynamic>> export(String projectId) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/admin/projects/$projectId/export',
      );
      final export = res.data?['export'];
      if (export is! Map<String, dynamic>) {
        throw const LiveProjectsException(LiveProjectsFailure.server);
      }
      return export;
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<PreviewDeleteResult> deletePhotos(
    String projectId,
    List<String> keys,
  ) async {
    try {
      final res = await _dio.delete<Map<String, dynamic>>(
        '/admin/projects/$projectId/photos',
        data: {'keys': keys},
      );
      final data = res.data ?? const {};
      List<String> asStrings(Object? v) => [
            if (v is List)
              for (final e in v) e.toString(),
          ];
      return PreviewDeleteResult(
        deleted: asStrings(data['deleted']),
        missing: asStrings(data['missing']),
      );
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<ProjectModelView> createModel(
    String projectId,
    List<String> keys, {
    required String idempotencyKey,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/admin/projects/$projectId/model',
        data: {'keys': keys},
        // The server's replay guard: without this a retried/double-tapped
        // request enqueues (and pays for) a second generation.
        options: Options(headers: {'Idempotency-Key': idempotencyKey}),
      );
      final model = ProjectModelView.tryFromStaffMap(res.data?['model']);
      if (model == null) {
        throw const LiveProjectsException(LiveProjectsFailure.server);
      }
      return model;
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<AutoGenerationRequest> autoGenerateModel(
    String projectId, {
    bool force = false,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/admin/projects/$projectId/model/auto',
        data: {if (force) 'force': true},
      );
      final data = res.data ?? const <String, dynamic>{};
      return AutoGenerationRequest(
        // 201 enqueued a generation; 200 replayed one that already existed.
        outcome: res.statusCode == 200
            ? AutoGenerationOutcome.replayed
            : AutoGenerationOutcome.enqueued,
        model: ProjectModelView.tryFromStaffMap(data['model']),
        steps: GenerationStep.parseList(data['steps']),
        trace: GenerationSelectionTrace.tryParse(data['trace']),
      );
    } on DioException catch (e) {
      // A selector refusal is the single most informative outcome this endpoint
      // has, and it arrives as a 422. Turning it into a bare exception would
      // throw away the counters that explain it, so it is unwrapped into a
      // result here rather than propagating as a failure.
      final body = e.response?.data;
      if (e.response?.statusCode == 422 &&
          body is Map &&
          body['code'] == 'NOT_SELECTABLE') {
        return AutoGenerationRequest(
          outcome: AutoGenerationOutcome.declined,
          steps: GenerationStep.parseList(body['steps']),
          trace: GenerationSelectionTrace.tryParse(body['trace']),
          declineReason: GenerationDeclineReason.parse(body['reason']),
        );
      }
      throw _translate(e);
    }
  }

  @override
  Future<List<ProjectModelView>> listModels(String projectId) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/admin/projects/$projectId/models',
      );
      final models = res.data?['models'];
      return [
        if (models is List)
          for (final m in models)
            if (ProjectModelView.tryFromStaffMap(m) case final model?) model,
      ];
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<List<ProjectModelView>> listOwnerModels(String projectId) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/projects/$projectId/models',
      );
      final models = res.data?['models'];
      return [
        if (models is List)
          for (final m in models)
            if (ProjectModelView.tryFromOwnerListMap(m) case final model?)
              model,
      ];
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<ProjectModelView> approveModel(
      String projectId, String modelId) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/admin/projects/$projectId/models/$modelId/approve',
      );
      final model = ProjectModelView.tryFromStaffMap(res.data?['model']);
      if (model == null) {
        throw const LiveProjectsException(LiveProjectsFailure.server);
      }
      return model;
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<ProjectModelView> optimizeModel(
      String projectId, String modelId) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/admin/projects/$projectId/models/$modelId/optimize',
      );
      final model = ProjectModelView.tryFromStaffMap(res.data?['model']);
      if (model == null) {
        throw const LiveProjectsException(LiveProjectsFailure.server);
      }
      return model;
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<void> optimizeOwnerModel(String projectId, String modelId) async {
    try {
      await _dio.post<Map<String, dynamic>>(
        '/projects/$projectId/models/$modelId/optimize',
      );
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<void> deleteProject(
    String projectId, {
    required AdminDeleteMode mode,
    required String confirmName,
  }) async {
    try {
      await _dio.delete<Map<String, dynamic>>(
        '/admin/projects/$projectId',
        data: {'mode': mode.wire, 'confirmName': confirmName},
      );
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  static LiveProjectsException _translate(DioException e) {
    final status = e.response?.statusCode;
    if (status == null) {
      return const LiveProjectsException(LiveProjectsFailure.network);
    }
    if (status == 403) {
      return const LiveProjectsException(LiveProjectsFailure.forbidden);
    }
    if (status == 404) {
      return const LiveProjectsException(LiveProjectsFailure.notFound);
    }
    final body = e.response?.data;
    final code = body is Map ? body['code'] : null;
    // NOT_EXPORTABLE arrives as 409 from the explicit-keys routes and as 422
    // from the auto-generate route (where "this project has no capture" is a
    // property of the request, not a conflicting state).
    if ((status == 409 || status == 422) && code == 'NOT_EXPORTABLE') {
      return const LiveProjectsException(LiveProjectsFailure.notExportable);
    }
    if (status == 409 && code == 'DISABLED') {
      return const LiveProjectsException(LiveProjectsFailure.generationDisabled);
    }
    if (status == 409 && code == 'USER_CAP_REACHED') {
      return const LiveProjectsException(LiveProjectsFailure.dailyLimitReached);
    }
    // The Optimize route's refusals. Matched on the CODE rather than on 409
    // alone so a future 409 from another route can't silently inherit this
    // copy — and the raw code never reaches the UI either way.
    if (status == 409 && _kNotOptimizableCodes.contains(code)) {
      return const LiveProjectsException(LiveProjectsFailure.notOptimizable);
    }
    if (status == 422 && code == 'CONFIRMATION_REQUIRED') {
      return const LiveProjectsException(
          LiveProjectsFailure.confirmationMismatch);
    }
    if (status == 429) {
      final retryAfter = body is Map ? body['retryAfter'] : null;
      return LiveProjectsException(
        LiveProjectsFailure.rateLimited,
        retryAfterSeconds: retryAfter is num ? retryAfter.toInt() : null,
      );
    }
    return const LiveProjectsException(LiveProjectsFailure.server);
  }
}

/// App-wide live-projects repository (staff-only surface).
final liveProjectsRepositoryProvider = Provider<LiveProjectsRepository>(
  (ref) => RemoteLiveProjectsRepository(ref.watch(dioProvider)),
);
