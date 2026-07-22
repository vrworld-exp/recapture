// lib/application/projects/owner_generation_request_notifier.dart
//
// The OWNER's "Generate 3D model" press, keyed by projectId (family).
//
// Why this sits next to [ModelGenerationRequestNotifier] rather than reusing it:
// that one posts to `/admin/projects/:id/model/auto`, a STAFF route an owner is
// forbidden from calling (403), and it holds the selector trace — steps,
// counters, key names — that the owner payload deliberately does not carry. Same
// shape of problem, different audience, different route, different payload.
//
// Everything here is a VALUE, including a refusal: the repository never throws,
// so this notifier never catches. A decline is the server working correctly and
// is the most useful thing it can say — turning it into an exception would
// discard the one sentence worth showing.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/projects_repository.dart';
import '../../utils/analytics.dart';

/// What the owner's generation request is doing / did.
class OwnerGenerationRequestState {
  const OwnerGenerationRequestState({this.isRequesting = false, this.result});

  /// The POST is in flight. Sub-second — the server's whole selection runs
  /// inside it — so there is no finer progress to report.
  final bool isRequesting;

  /// The outcome, once there is one.
  final OwnerGenerationRequestResult? result;

  /// A press has been made and has not been cleared — the guard that stops a
  /// second (PAID) generation from a double tap or a re-entry.
  bool get hasStarted => isRequesting || result != null;

  /// The server accepted it and something is now being built.
  bool get isBuilding => result?.isStarted ?? false;

  /// The request resolved to something that is NOT a build — a refusal, a
  /// ceiling, a network failure. One sentence, never a code.
  String? get refusalMessage {
    final r = result;
    if (r == null || r.isStarted) return null;
    return r.message;
  }
}

class OwnerGenerationRequestNotifier
    extends FamilyNotifier<OwnerGenerationRequestState, String> {
  @override
  OwnerGenerationRequestState build(String projectId) =>
      const OwnerGenerationRequestState();

  /// Asks the server to pick photos and start a generation.
  ///
  /// Guarded at the state layer as well as at the widget layer, because the two
  /// protect against different things: the widget stops a fast double tap, this
  /// stops a re-entry from anywhere else while one is still in flight. Both
  /// matter — the request spends credits.
  Future<OwnerGenerationRequestState> request() async {
    if (state.hasStarted) return state;
    state = const OwnerGenerationRequestState(isRequesting: true);

    final result =
        await ref.read(projectsRepositoryProvider).requestModelGeneration(arg);
    state = OwnerGenerationRequestState(result: result);

    Analytics.logEvent('model_generation_requested', {
      'source': 'post_capture_button',
      'outcome': result.outcome.name,
      'forced': false,
    });
    return state;
  }

  /// Drops the last result so a later press starts clean. Not called on leaving
  /// the build screen — the press must outlive it (see the provider note).
  void clear() => state = const OwnerGenerationRequestState();
}

/// One project's owner-side generation-request state.
///
/// NOT autoDisposed, and that is the double-spend guard doing its job: the press
/// happens on the post-upload screen and is read on the build screen pushed
/// after it, and backing out to press again must find the request already made
/// rather than a clean slate.
final ownerGenerationRequestProvider = NotifierProvider.family<
    OwnerGenerationRequestNotifier, OwnerGenerationRequestState, String>(
  OwnerGenerationRequestNotifier.new,
);
