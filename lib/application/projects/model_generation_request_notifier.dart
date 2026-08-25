// lib/application/projects/model_generation_request_notifier.dart
//
// The "Generate 3D model" press, keyed by projectId (family).
//
// ── ONE SCREEN, TWO SOURCES — KEEP THEM APART ───────────────────────────────
// A generation has two halves that look alike and behave nothing alike:
//   • the REQUEST half (this notifier): six server-side steps that are all over
//     before the button's spinner has painted. They arrive COMPLETE in the POST
//     response. There is nothing to watch, nothing to stream, and no reason to
//     poll them.
//   • the WORKER half: Meshy, minutes long, reported through `record.progress`
//     and polled by [OwnerModelStateNotifier] / [ModelGenerationNotifier].
//
// They are deliberately NOT merged into one state object. Merging invites
// treating the finished steps as live (a checklist that appears to tick itself
// after the fact) or the live progress as final. This notifier owns only the
// first half; the screen composes it with the second.
//
// Not autoDisposed: the press happens on the projects list and the trace is read
// on the screen pushed afterwards, so the state has to outlive the tap.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/live_projects_repository.dart';
import '../../utils/analytics.dart';

/// What happened to one project's generation request.
class ModelGenerationRequestState {
  const ModelGenerationRequestState({
    this.isRequesting = false,
    this.request,
    this.failure,
  });

  /// The POST is in flight. There is no finer-grained progress to show — the
  /// whole thing takes well under a second.
  final bool isRequesting;

  /// The completed request: steps, selector trace, and either the enqueued
  /// record or the reason it was refused.
  final AutoGenerationRequest? request;

  /// A transport/permission/ceiling failure. Distinct from a DECLINE, which is
  /// the server working correctly and is carried on [request].
  final LiveProjectsFailure? failure;

  bool get hasResult => request != null;

  /// True once the server refused to spend on this capture.
  bool get wasDeclined =>
      request?.outcome == AutoGenerationOutcome.declined;

  ModelGenerationRequestState copyWith({
    bool? isRequesting,
    AutoGenerationRequest? request,
    LiveProjectsFailure? failure,
    bool clearFailure = false,
    bool clearRequest = false,
  }) {
    return ModelGenerationRequestState(
      isRequesting: isRequesting ?? this.isRequesting,
      request: clearRequest ? null : (request ?? this.request),
      failure: clearFailure ? null : (failure ?? this.failure),
    );
  }
}

class ModelGenerationRequestNotifier
    extends FamilyNotifier<ModelGenerationRequestState, String> {
  @override
  ModelGenerationRequestState build(String projectId) =>
      const ModelGenerationRequestState();

  /// Asks the server to pick photos and start a generation.
  ///
  /// Never throws: every outcome — including a refusal and a failure — is
  /// state, because this drives a screen rather than a control-flow decision.
  /// [force] deliberately pays for a second generation on a capture that
  /// already has one; it is staff-only and the server enforces that.
  Future<ModelGenerationRequestState> request({bool force = false}) async {
    // Double-tap guard at the state layer as well as the widget layer: the
    // request spends money, so one press must never become two.
    if (state.isRequesting) return state;
    state = state.copyWith(
      isRequesting: true,
      clearFailure: true,
      clearRequest: true,
    );

    try {
      final result = await ref
          .read(liveProjectsRepositoryProvider)
          .autoGenerateModel(arg, force: force);
      state = ModelGenerationRequestState(request: result);
      Analytics.logEvent('model_generation_requested', {
        'source': 'manual_button',
        'outcome': result.outcome.name,
        'forced': force,
        // The counters worth having a week of, to decide whether the selector's
        // thresholds are right. No keys: this is an analytics payload.
        'pool_size': result.trace?.poolSize ?? 0,
        'dropped_no_blur': result.trace?.droppedNoBlurScore ?? 0,
        'quadrants_filled': result.trace?.quadrantsFilled ?? 0,
      });
    } on LiveProjectsException catch (e) {
      state = ModelGenerationRequestState(failure: e.failure);
    } catch (_) {
      state = const ModelGenerationRequestState(
        failure: LiveProjectsFailure.server,
      );
    }
    return state;
  }

  /// Drops the last result — for leaving the screen, so a later press starts
  /// from a clean slate instead of flashing the previous run's trace.
  void clear() => state = const ModelGenerationRequestState();
}

/// One project's generation-request state (the synchronous half only).
final modelGenerationRequestProvider = NotifierProvider.family<
    ModelGenerationRequestNotifier, ModelGenerationRequestState, String>(
  ModelGenerationRequestNotifier.new,
);

/// Mapped, staff-facing copy for a request that failed outright (as opposed to
/// being declined). Never a raw code — same rule as the rest of the surface.
String modelGenerationFailureMessage(LiveProjectsFailure failure) =>
    switch (failure) {
      LiveProjectsFailure.generationDisabled =>
        '3D model generation is switched off on the server right now.',
      LiveProjectsFailure.dailyLimitReached =>
        "You've reached today's model generation limit. Try again tomorrow.",
      LiveProjectsFailure.notExportable =>
        'This project has no finished capture to build a model from.',
      LiveProjectsFailure.notFound =>
        'This project no longer exists — pull to refresh.',
      LiveProjectsFailure.forbidden =>
        'Your account no longer has staff access.',
      LiveProjectsFailure.rateLimited =>
        'Too many generation requests — try again in a few minutes.',
      LiveProjectsFailure.network =>
        "You're offline — check your connection and try again.",
      _ => 'Something went wrong. Please try again.',
    };
