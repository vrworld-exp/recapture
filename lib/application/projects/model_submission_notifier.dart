// lib/application/projects/model_submission_notifier.dart
//
// The staff "Submit model" flow for ONE project (family, keyed by projectId):
// pick a `.glb`, upload it to a presigned slot, commit it as a model on someone
// else's project.
//
// ── THREE CALLS, ONE USER-VISIBLE ACTION ────────────────────────────────────
// Submitting is a slot request, a direct-to-S3 PUT and a commit. The person
// pressing the button is doing ONE thing, so the three are one state machine
// here rather than three things a screen has to sequence — and the phase names
// are what the user is told, not what the network is doing.
//
// ── NEVER THROWS ────────────────────────────────────────────────────────────
// Every outcome is state, because this drives a screen. Same stance as
// [ModelGenerationRequestNotifier].
//
// ── THE SUCCESS IS SOMEONE ELSE'S ───────────────────────────────────────────
// The model lands in the OWNER's project, not the submitter's. Nothing in this
// app can show the submitter that owner's screen, so the success state is
// deliberately explicit about where the model went — that sentence is the only
// confirmation the artist gets.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/model_file_picker.dart';
import '../../data/remote/model_upload_client.dart';
import '../../data/repositories/live_projects_repository.dart';
import '../../utils/analytics.dart';

/// Where a submission has got to.
enum ModelSubmissionPhase {
  /// Nothing chosen yet, or the last attempt was cleared.
  idle,

  /// A file is chosen and waiting for the user to press Submit.
  ready,

  /// The bytes are going to S3 — the long part, with real progress.
  uploading,

  /// The bytes are up; the server is committing the record. Sub-second, but a
  /// distinct phase because the progress bar has nothing left to report and a
  /// bar frozen at 100% reads as a hang.
  finalizing,

  /// Committed. The owner can see the model now.
  submitted,
}

/// One project's submission state.
class ModelSubmissionState {
  const ModelSubmissionState({
    this.phase = ModelSubmissionPhase.idle,
    this.file,
    this.progress = 0,
    this.failure,
    this.oversized = false,
  });

  final ModelSubmissionPhase phase;

  /// The chosen file, kept across phases so the screen can keep showing WHICH
  /// model is being submitted.
  final PickedModelFile? file;

  /// Upload progress, 0..1. Meaningful only while [ModelSubmissionPhase.uploading].
  final double progress;

  /// The last failure, or null. Cleared the moment a new attempt starts.
  final LiveProjectsFailure? failure;

  /// The picked file is over the server's ceiling, refused BEFORE uploading.
  /// Not a [failure]: nothing went wrong, the file is simply too big, and the
  /// copy for it names a size rather than an error.
  final bool oversized;

  /// The user may press Submit: a file is chosen, it fits, and nothing is in
  /// flight.
  bool get canSubmit => phase == ModelSubmissionPhase.ready && !oversized;

  /// A network call is in flight — the whole form is locked while it is.
  bool get isBusy =>
      phase == ModelSubmissionPhase.uploading ||
      phase == ModelSubmissionPhase.finalizing;

  ModelSubmissionState copyWith({
    ModelSubmissionPhase? phase,
    PickedModelFile? file,
    double? progress,
    LiveProjectsFailure? failure,
    bool? oversized,
    bool clearFailure = false,
  }) {
    return ModelSubmissionState(
      phase: phase ?? this.phase,
      file: file ?? this.file,
      progress: progress ?? this.progress,
      failure: clearFailure ? null : (failure ?? this.failure),
      oversized: oversized ?? this.oversized,
    );
  }
}

class ModelSubmissionNotifier
    extends FamilyNotifier<ModelSubmissionState, String> {
  @override
  ModelSubmissionState build(String projectId) => const ModelSubmissionState();

  /// The server's ceiling, learned from the slot response and remembered so a
  /// second pick can be refused without another round trip. Zero until the
  /// first slot request — an unknown ceiling never rejects a file.
  int _maxBytes = 0;

  /// Opens the file browser. A CANCEL leaves the state untouched, so the
  /// previously chosen file (if any) survives an accidental dismiss.
  Future<void> pickFile() async {
    if (state.isBusy) return;
    final picked = await ref.read(modelFilePickerProvider).pickGlb();
    if (picked == null) return;
    state = ModelSubmissionState(
      phase: ModelSubmissionPhase.ready,
      file: picked,
      oversized: _maxBytes > 0 && picked.size > _maxBytes,
    );
  }

  /// Uploads the chosen file and commits it as a model on this project.
  ///
  /// Never throws. The guard against a double-press is [ModelSubmissionState.isBusy]
  /// here as well as on the button: a second submission would upload the same
  /// file twice and put two identical models in the owner's list.
  Future<void> submit() async {
    final file = state.file;
    if (file == null || state.isBusy || state.oversized) return;

    state = state.copyWith(
      phase: ModelSubmissionPhase.uploading,
      progress: 0,
      clearFailure: true,
    );

    try {
      final repository = ref.read(liveProjectsRepositoryProvider);
      final slot = await repository.createModelUploadSlot(arg);
      _maxBytes = slot.maxBytes;

      // Re-check against the ceiling we only just learned. Refusing here costs
      // the user nothing; discovering it after a 100 MiB upload costs minutes.
      if (slot.maxBytes > 0 && file.size > slot.maxBytes) {
        state = state.copyWith(
          phase: ModelSubmissionPhase.ready,
          oversized: true,
          progress: 0,
        );
        return;
      }

      await ref.read(modelUploadClientProvider).putGlb(
            url: slot.url,
            file: file,
            onProgress: (progress) {
              // A late progress tick after a failure must not resurrect the
              // uploading phase.
              if (state.phase != ModelSubmissionPhase.uploading) return;
              state = state.copyWith(progress: progress);
            },
          );

      state = state.copyWith(
        phase: ModelSubmissionPhase.finalizing,
        progress: 1,
      );
      final model = await repository.submitUploadedModel(arg, slot.key);

      state = state.copyWith(phase: ModelSubmissionPhase.submitted);
      Analytics.logEvent('model_submitted', {
        // Size is the number worth having: it says what artists actually hand
        // over, which is what the server's ceiling has to be tuned against.
        // No file name, no key, no presigned url.
        'size_bytes': file.size,
        'model_status': model.status.name,
      });
    } on LiveProjectsException catch (e) {
      state = state.copyWith(
        phase: ModelSubmissionPhase.ready,
        progress: 0,
        failure: e.failure,
      );
    } catch (_) {
      // Includes the direct-to-S3 PUT, which throws a raw DioException rather
      // than a translated one — the URL in it must never reach the screen, so
      // it is flattened to the generic network copy here.
      state = state.copyWith(
        phase: ModelSubmissionPhase.ready,
        progress: 0,
        failure: LiveProjectsFailure.network,
      );
    }
  }

  /// Back to an empty form — for submitting a second model without leaving the
  /// screen.
  void reset() => state = const ModelSubmissionState();
}

/// One project's "Submit model" state.
final modelSubmissionProvider = NotifierProvider.family<ModelSubmissionNotifier,
    ModelSubmissionState, String>(
  ModelSubmissionNotifier.new,
);

/// Mapped, staff-facing copy for a failed submission. Never a raw code, a key,
/// or a URL — the same mapped-only rule the rest of this surface follows.
String modelSubmissionFailureMessage(LiveProjectsFailure failure) =>
    switch (failure) {
      LiveProjectsFailure.uploadMissing =>
        'That upload is no longer available. Please choose the file again.',
      LiveProjectsFailure.modelTooLarge =>
        'That model is too large. Please submit a smaller file.',
      LiveProjectsFailure.notAModel =>
        'That file is not a .glb model.',
      LiveProjectsFailure.storeFailed =>
        'The model could not be stored. Please try again.',
      LiveProjectsFailure.notExportable =>
        'This project has no finished upload to attach a model to.',
      LiveProjectsFailure.notFound =>
        'This project no longer exists.',
      LiveProjectsFailure.forbidden =>
        'Your account no longer has staff access.',
      LiveProjectsFailure.rateLimited =>
        'Too many submissions right now. Please try again later.',
      LiveProjectsFailure.network =>
        'The upload didn’t finish — check your connection and try again.',
      _ => 'Something went wrong. Please try again.',
    };
