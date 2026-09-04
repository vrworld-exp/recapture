// lib/application/rep/rep_activation_notifier.dart
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/rep_repository.dart';
import '../../domain/entities/qr_code_preflight.dart';
import '../../domain/entities/rep_activation.dart';
import '../../domain/rep/qr_code_input.dart';

/// Where the rep is in the activation flow.
///
/// A LINEAR SEQUENCE, and the order is the whole point: the code is checked
/// BEFORE the restaurant's details are asked for, so a rep never fills in a
/// whole profile against a standee that turns out to be taken. [confirming] is
/// the step that exists because of the phone number — see [RepActivationState].
enum RepActivationStep { code, details, confirming, done }

@immutable
class RepActivationState {
  const RepActivationState({
    this.step = RepActivationStep.code,
    this.preflight,
    this.result,
    this.failure,
    this.isBusy = false,
    this.pendingRequest,
  });

  final RepActivationStep step;

  /// What the server said about the code. Present from [RepActivationStep.details]
  /// onward — it is what let the flow get there.
  final QrCodePreflight? preflight;

  /// The activated catalog, once it exists.
  final RepActivation? result;

  /// The last failure, for the screen to map to copy. NEVER rendered as-is —
  /// the screen reads [CatalogFailure.code], never the message.
  final CatalogFailure? failure;

  final bool isBusy;

  /// The filled-in request, held while the rep confirms the phone number.
  ///
  /// ⚠ THE CONFIRMATION STEP IS NOT CEREMONY. A mistyped phone creates a real
  /// account for a number nobody owns, which permanently holds the catalog slot
  /// the real restaurant needs — the unique index counts soft-deleted rows — and
  /// the restaurant then signs in on their correct number to find an empty
  /// second account. Nothing about that failure is visible at activation time,
  /// or an hour later, or on the rep's screen at all. Showing the normalised
  /// number back and requiring a deliberate tap is the cheapest place in the
  /// whole system to catch it.
  final RepActivationRequest? pendingRequest;

  bool get isDone => step == RepActivationStep.done && result != null;

  RepActivationState copyWith({
    RepActivationStep? step,
    QrCodePreflight? preflight,
    RepActivation? result,
    Object? failure = _unset,
    bool? isBusy,
    Object? pendingRequest = _unset,
  }) =>
      RepActivationState(
        step: step ?? this.step,
        preflight: preflight ?? this.preflight,
        result: result ?? this.result,
        failure:
            identical(failure, _unset) ? this.failure : failure as CatalogFailure?,
        isBusy: isBusy ?? this.isBusy,
        pendingRequest: identical(pendingRequest, _unset)
            ? this.pendingRequest
            : pendingRequest as RepActivationRequest?,
      );
}

const Object _unset = Object();

/// Drives one activation, from a code in a box to a live catalog.
///
/// No HTTP here and no parsing — both live in [RepRepository]. This owns the
/// sequence and nothing else.
class RepActivationNotifier extends Notifier<RepActivationState> {
  @override
  RepActivationState build() => const RepActivationState();

  RepRepository get _repo => ref.read(repRepositoryProvider);

  /// Checks a code and, when it is usable, opens the details form.
  ///
  /// [raw] is whatever the rep typed, pasted or scanned — a bare code, a
  /// hyphenated one, or a full standee URL. Normalised locally first so a
  /// hopeless string never becomes a request; the server normalises again, and
  /// only its answer decides anything.
  Future<void> submitCode(String raw) async {
    final code = QrCodeInput.normalize(raw);
    if (code == null) {
      state = state.copyWith(
        failure: const CatalogFailure(
          code: 'INVALID_REQUEST',
          message: 'That does not look like a standee code.',
        ),
      );
      return;
    }

    state = state.copyWith(isBusy: true, failure: null);
    try {
      final preflight = await _repo.preflight(code);
      if (!preflight.isAvailable) {
        state = state.copyWith(
          isBusy: false,
          preflight: preflight,
          failure: const CatalogFailure(
            code: RepErrorCodes.codeUnavailable,
            message: 'That code is already in use.',
          ),
        );
        return;
      }
      state = state.copyWith(
        isBusy: false,
        preflight: preflight,
        step: RepActivationStep.details,
        failure: null,
      );
    } on CatalogFailure catch (failure) {
      state = state.copyWith(isBusy: false, failure: failure);
    }
  }

  /// Holds the filled-in details and moves to the confirmation step.
  ///
  /// Deliberately does NOT submit. See [RepActivationState.pendingRequest].
  void review(RepActivationRequest request) {
    state = state.copyWith(
      pendingRequest: request,
      step: RepActivationStep.confirming,
      failure: null,
    );
  }

  /// Back to the details form from the confirmation — the rep spotted a typo,
  /// which is exactly what the step is for.
  void editDetails() {
    state = state.copyWith(step: RepActivationStep.details, failure: null);
  }

  /// The explicit tap. Only this sends the activation.
  Future<void> confirm() async {
    final request = state.pendingRequest;
    if (request == null || state.isBusy) return;

    state = state.copyWith(isBusy: true, failure: null);
    try {
      final result = await _repo.activate(request);
      state = state.copyWith(
        isBusy: false,
        result: result,
        step: RepActivationStep.done,
        failure: null,
      );
    } on CatalogFailure catch (failure) {
      // Stay on the confirmation step: everything the rep typed is still here,
      // and a taken code is fixed by going back to the code box, not by
      // retyping a restaurant's details.
      state = state.copyWith(isBusy: false, failure: failure);
    }
  }

  /// Starts over at the code box, keeping nothing. Used by "scan another" after
  /// a taken code, and by the success screen's "activate another".
  void restart() {
    state = const RepActivationState();
  }
}

/// One activation flow. Auto-disposed with the screen.
final repActivationProvider =
    NotifierProvider<RepActivationNotifier, RepActivationState>(
  RepActivationNotifier.new,
);
