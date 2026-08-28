// lib/application/capture/retake_session_provider.dart
//
// The forced-target OVERRIDE hook for Level A retake mode. Holds the active
// [RetakeRequest] (null = normal guided capture) for the current capture entry.
//
// The capture screen `begin`s a retake on mount (from the route arg, once it has
// validated the index against the live segment count) and `clear`s it when the
// retake completes, the user backs out, or a NEW normal entry primes the screen.
// The ring coverage map reads this to highlight [RetakeRequest.ringIndex] as the
// target instead of the normal next-uncaptured segment, so the chosen angle is
// visibly the one to re-shoot.
//
// This is deliberately a thin holder: index validation lives on the request
// ([RetakeRequest.isValidFor]) against the config-driven segment count, so this
// provider never needs to read config itself.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/retake_request.dart';

/// The active retake for the current Level A capture entry, or null in normal
/// guided capture. Watch it where the forced target must override normal
/// targeting (the ring map highlight); mutate it via [RetakeSessionNotifier].
final retakeSessionProvider =
    NotifierProvider<RetakeSessionNotifier, RetakeRequest?>(
  RetakeSessionNotifier.new,
);

class RetakeSessionNotifier extends Notifier<RetakeRequest?> {
  @override
  RetakeRequest? build() => null;

  /// Enters retake mode with [request] as the forced target. The caller is
  /// responsible for having validated [request] against the live segment count
  /// ([RetakeRequest.isValidFor]) first.
  void begin(RetakeRequest request) => state = request;

  /// Returns to normal targeting. A no-op when already cleared, so reactive
  /// consumers don't churn.
  void clear() {
    if (state != null) state = null;
  }
}
