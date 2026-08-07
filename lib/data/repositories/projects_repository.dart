// lib/data/repositories/projects_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/create_project_options.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_model.dart';
import '../remote/api_client.dart';

/// Data access for the Projects Hub. The interface `ProjectsNotifier` depends
/// on — it owns all projects HTTP and error translation, so the notifier is
/// pure state and never touches the network.
///
/// Backend reality (see recapture-api): `rename` and `delete` return
/// success-only shapes the notifier doesn't need, so those return
/// `Future<void>` and the notifier reconciles the in-state project locally.
/// `list` and `create` return full entities.
abstract interface class ProjectsRepository {
  /// Fetches the user's projects. Throws on network failure.
  Future<List<Project>> list();

  /// Creates a project and returns the persisted entity (initial status
  /// `draft`). Throws on network failure.
  Future<Project> create({
    required String name,
    required ObjectSize size,
    required CaptureMode mode,
  });

  /// Renames a project. Backend returns success only. Throws on network failure.
  Future<void> rename(String id, String newName);

  /// Soft-deletes a project. The backend independently enforces a
  /// [confirmName] echo of the project's exact current name; callers that
  /// have the entity MUST pass it (the repository falls back to one extra
  /// lookup when it is absent — rare stale-UI path).
  Future<void> delete(String id, {String? confirmName});

  /// Re-queues a failed project for processing (status returns to `processing`).
  /// Backend returns success only. Throws on network failure.
  Future<void> retry(String id);

  /// The project's newest finished 3D model, or null if it has none yet.
  ///
  /// Fetched ON DEMAND (one request when the user taps View) rather than being
  /// carried by `list()`: the Project DTO is identical across GET /projects,
  /// POST /projects and this entity by contract (AGENTS.md), so the model can't
  /// join it — and watching it per card would mean an N+1 across the whole list.
  Future<ProjectModelView?> fetchModel(String id);

  /// The project's model situation in ONE request: the finished model it has
  /// (if any) AND the generation it is waiting on (if any).
  ///
  /// Both, not either. Automatic generation means a project can hold a good
  /// model while a newer run is in flight, and the owner must keep seeing the
  /// former — so a caller that collapsed these into one nullable value would
  /// blank the screen every time a regenerate started.
  Future<OwnerModelState> fetchModelState(String id);

  /// Asks the server to pick this project's photos and start a 3D model —
  /// `POST /projects/:id/model`, the OWNER-facing "Generate 3D model" press.
  ///
  /// The STAFF equivalent is `LiveProjectsRepository.autoGenerateModel`, which
  /// talks to `/admin/...` and returns the selector trace. This one deliberately
  /// does not exist there: an owner gets 403 on the admin route, and the owner
  /// payload carries no steps, no trace, no key names, and no phase vocabulary.
  ///
  /// NEVER THROWS. Every outcome — started, refused, rate-limited, offline —
  /// comes back as a value with one owner-safe sentence, because this drives a
  /// full screen rather than a control-flow decision, and a refusal thrown away
  /// is the single most useful thing the server said.
  ///
  /// [regenerate] false (default) sends NO body: the server's `manual:{jobId}`
  /// idempotency key then replays a repeat press instead of paying for a second
  /// generation — this is the FIRST-generation / post-capture path. [regenerate]
  /// true is a deliberate "make a new version" spend: the server forces a fresh
  /// generation, still bounded server-side by the rate window and the per-user
  /// 24h ceiling. Only ever pass true from an explicit user "Regenerate" tap.
  Future<OwnerGenerationRequestResult> requestModelGeneration(
    String id, {
    bool regenerate,
  });
}

/// What `POST /projects/:id/model` did, as an owner may know it.
enum OwnerGenerationRequestOutcome {
  /// Accepted and queued (or replayed onto an existing run — indistinguishable
  /// to the owner by design, and identical in what happens next: watch it).
  started,

  /// 422 NOT_SELECTABLE — the selector refused to spend on these photos. The
  /// server working correctly, not a failure.
  declined,

  /// 422 NOT_READY — no finalized capture to build from yet.
  notReady,

  /// 409 DAILY_LIMIT_REACHED — the rolling 24h ceiling.
  dailyLimitReached,

  /// 409/502 GENERATION_UNAVAILABLE — switched off, or the pipeline could not
  /// be reached. Nothing the owner did.
  unavailable,

  /// 404 — the project is gone.
  notFound,

  /// 429 — too many requests from this user.
  rateLimited,

  /// Transport failure (offline, timeout).
  offline,

  /// Anything else.
  failed,
}

/// One generation request's outcome plus the ONE sentence to show for it.
///
/// [message] is always owner-safe: the server's own mapped copy for the codes it
/// maps, and a local fallback otherwise. A raw error string, a response code, a
/// key name or an upstream URL never reaches this field.
class OwnerGenerationRequestResult {
  const OwnerGenerationRequestResult(
    this.outcome,
    this.message, {
    this.generation,
  });

  final OwnerGenerationRequestOutcome outcome;
  final String message;

  /// The run to watch, when the server reported one. Absent is not an error —
  /// the polling on `GET /projects/:id` finds it either way.
  final OwnerGenerationView? generation;

  bool get isStarted => outcome == OwnerGenerationRequestOutcome.started;
}

/// What `GET /projects/:id` says about a project's 3D model, as the owner sees
/// it. Both fields are independently nullable — see [ProjectsRepository.fetchModelState].
class OwnerModelState {
  const OwnerModelState({this.model, this.generation});

  /// The newest FINISHED model, or null if there has never been one.
  final ProjectModelView? model;

  /// The run currently in flight or most recently failed, or null.
  final OwnerGenerationView? generation;

  /// Whether something is happening that the user should be told about.
  bool get isGenerating => generation?.isPending ?? false;

  /// A finished model exists and can be opened.
  bool get hasViewableModel => model?.isViewable ?? false;

  /// Nothing to show and nothing coming — the pre-generation empty state.
  bool get isEmpty => model == null && generation == null;
}

/// Concrete [ProjectsRepository] backed by the recapture-api `/projects`
/// endpoints, over the app Dio (Bearer attach + 401-refresh via
/// [AuthInterceptor]). Non-2xx surfaces as a [DioException] — the notifier and
/// screens already translate throws into the offline/retry modal.
class RemoteProjectsRepository implements ProjectsRepository {
  const RemoteProjectsRepository(this._dio);

  final Dio _dio;

  @override
  Future<List<Project>> list() async {
    final res = await _dio.get<Map<String, dynamic>>('/projects');
    final items = res.data?['items'];
    if (items is! List) return const <Project>[];
    return [
      for (final item in items)
        if (item is Map<String, dynamic>) Project.fromMap(item),
    ];
  }

  @override
  Future<Project> create({
    required String name,
    required ObjectSize size,
    required CaptureMode mode,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/projects',
      data: {'name': name, 'size': size.apiValue, 'mode': mode.apiValue},
    );
    final project = res.data?['project'];
    if (project is! Map<String, dynamic>) {
      throw StateError('POST /projects returned no project');
    }
    return Project.fromMap(project);
  }

  @override
  Future<void> rename(String id, String newName) async {
    await _dio.patch<Map<String, dynamic>>(
      '/projects/$id',
      data: {'name': newName},
    );
  }

  @override
  Future<void> delete(String id, {String? confirmName}) async {
    // The backend refuses to delete without the exact current name — when the
    // caller couldn't supply it (stale UI), fetch it first.
    var name = confirmName;
    if (name == null) {
      final res = await _dio.get<Map<String, dynamic>>('/projects/$id');
      final project = res.data?['project'];
      name = project is Map ? (project['name'] ?? '').toString() : '';
    }
    await _dio.delete<Map<String, dynamic>>(
      '/projects/$id',
      data: {'confirmName': name},
    );
  }

  @override
  Future<void> retry(String id) async {
    // TODO(api): the backend has no reprocess route yet (FAILED → QUEUED is a
    // worker/admin concern). Keep the optimistic UI flow alive; the next list
    // refresh reconciles the real status.
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  @override
  Future<ProjectModelView?> fetchModel(String id) async {
    final res = await _dio.get<Map<String, dynamic>>('/projects/$id');
    // `model` rides alongside the project DTO and is null until a generation
    // finishes — an absent/unparsable model is "none yet", never an error.
    return ProjectModelView.tryFromOwnerMap(res.data?['model']);
  }

  @override
  Future<OwnerModelState> fetchModelState(String id) async {
    final res = await _dio.get<Map<String, dynamic>>('/projects/$id');
    // Both keys are optional and independently absent: `model` until a
    // generation has ever finished, `generation` when none is in flight. An
    // unparsable value is "none", never an error — this drives a status
    // surface, and a malformed field must not dead-end the user's tap.
    return OwnerModelState(
      model: ProjectModelView.tryFromOwnerMap(res.data?['model']),
      generation: OwnerGenerationView.tryParse(res.data?['generation']),
    );
  }

  @override
  Future<OwnerGenerationRequestResult> requestModelGeneration(
    String id, {
    bool regenerate = false,
  }) async {
    try {
      // First generation: no body, so the server derives `manual:{jobId}` and a
      // repeat replays instead of paying twice. Regenerate: send the explicit
      // flag so the server forces a NEW version (still capped server-side). The
      // client never sends `force` directly — only this intent-carrying flag.
      final res = await _dio.post<Map<String, dynamic>>(
        '/projects/$id/model',
        data: regenerate ? {'regenerate': true} : null,
      );
      return OwnerGenerationRequestResult(
        OwnerGenerationRequestOutcome.started,
        // Not shown anywhere — the started state is a screen, not a sentence.
        'Creating your 3D model.',
        generation: OwnerGenerationView.tryParse(res.data?['generation']),
      );
    } on DioException catch (e) {
      return _translateGenerationFailure(e);
    } catch (_) {
      // A parse/shape surprise must not dead-end the tap either.
      return const OwnerGenerationRequestResult(
        OwnerGenerationRequestOutcome.failed,
        'Something went wrong. Please try again.',
      );
    }
  }

  /// Maps one refused request onto an outcome + one owner-safe sentence.
  ///
  /// The server already authors owner-facing copy for every code below (it is
  /// the same copy an owner would get from any other client), and for a decline
  /// it is strictly better than anything decided here — there are three distinct
  /// reasons and each names what to DO about it. So the server's message wins
  /// for a code we recognise, and the local fallback covers everything else,
  /// including a body with no message at all.
  static OwnerGenerationRequestResult _translateGenerationFailure(
    DioException e,
  ) {
    if (e.response == null) {
      return const OwnerGenerationRequestResult(
        OwnerGenerationRequestOutcome.offline,
        "You're offline — check your connection and try again.",
      );
    }
    final body = e.response?.data;
    final code = body is Map ? (body['code'] ?? '').toString() : '';
    final outcome = switch (code) {
      'NOT_SELECTABLE' => OwnerGenerationRequestOutcome.declined,
      'NOT_READY' => OwnerGenerationRequestOutcome.notReady,
      'DAILY_LIMIT_REACHED' => OwnerGenerationRequestOutcome.dailyLimitReached,
      'GENERATION_UNAVAILABLE' => OwnerGenerationRequestOutcome.unavailable,
      'NOT_FOUND' => OwnerGenerationRequestOutcome.notFound,
      'RATE_LIMITED' => OwnerGenerationRequestOutcome.rateLimited,
      // An unrecognised code is NOT trusted to carry owner-safe copy.
      _ => e.response?.statusCode == 404
          ? OwnerGenerationRequestOutcome.notFound
          : e.response?.statusCode == 429
              ? OwnerGenerationRequestOutcome.rateLimited
              : OwnerGenerationRequestOutcome.failed,
    };
    final fallback = ownerGenerationFallbackMessage(outcome);
    final serverMessage = body is Map ? (body['message'] ?? '').toString() : '';
    final trusted = outcome != OwnerGenerationRequestOutcome.failed &&
        serverMessage.isNotEmpty &&
        serverMessage.length <= 300;
    return OwnerGenerationRequestResult(
      outcome,
      trusted ? serverMessage : fallback,
    );
  }
}

/// The copy shown when the server sent none we trust. Mapped only — same rule
/// as Screen 9F's upload categories: never a code, never raw text.
String ownerGenerationFallbackMessage(OwnerGenerationRequestOutcome outcome) =>
    switch (outcome) {
      OwnerGenerationRequestOutcome.started => 'Creating your 3D model.',
      OwnerGenerationRequestOutcome.declined =>
        "We couldn't build a 3D model from these photos. Try capturing the "
            'object again, walking all the way around it.',
      OwnerGenerationRequestOutcome.notReady =>
        'Finish uploading this capture before creating a 3D model.',
      OwnerGenerationRequestOutcome.dailyLimitReached =>
        "You've reached today's limit for creating 3D models. Try again "
            'tomorrow.',
      OwnerGenerationRequestOutcome.unavailable =>
        '3D model creation is not available right now.',
      OwnerGenerationRequestOutcome.notFound =>
        "We couldn't find this project.",
      OwnerGenerationRequestOutcome.rateLimited =>
        'Too many requests. Please try again in a few minutes.',
      OwnerGenerationRequestOutcome.offline =>
        "You're offline — check your connection and try again.",
      OwnerGenerationRequestOutcome.failed =>
        'Something went wrong. Please try again.',
    };

/// App-wide projects repository.
final projectsRepositoryProvider = Provider<ProjectsRepository>(
  (ref) => RemoteProjectsRepository(ref.watch(dioProvider)),
);
