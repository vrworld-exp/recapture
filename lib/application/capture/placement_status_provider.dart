// lib/application/capture/placement_status_provider.dart
//
// Placement-status source for the centre-frame guide (PlacementBoxOverlay).
// Folds the native detection stream (placement_channel: normalized bounding box
// @ ~10 Hz) through the PURE placement evaluator — carrying the previous status
// back in so the evaluator's good-state hysteresis (Schmitt band) applies across
// samples — and exposes the resulting [PlacementStatus] for the HUD to watch.
//
// FAIL-OPEN: before the first detection, and PERMANENTLY when the detector is
// unavailable (PLACEMENT_UNAVAILABLE, missing plugin on a test host, iOS until
// the port lands), the status is [PlacementStatus.idle] — the guide rests white
// and never blocks or warns on absent hardware. Transitions are emitted only on
// CHANGE, so widgets rebuild per state flip, not per detector frame.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/capture/placement_evaluator.dart';
import '../../domain/entities/placement_box.dart';
import '../../platform/placement_channel.dart';

/// Injectable seam: the native placement-detection source. Production wires the
/// real [PlacementDetectionStream]; tests override this with a controlled stream
/// (no platform channels needed).
final placementDetectionSourceProvider =
    Provider.autoDispose<Stream<PlacementDetection>>(
  (ref) => PlacementDetectionStream().detections(),
);

/// The evaluator thresholds in force. A single seam so a later remote-config
/// task can override them without touching the fold below.
final placementTolerancesProvider = Provider<PlacementTolerances>(
  (ref) => const PlacementTolerances(),
);

/// The live placement status for the guide. Emits on TRANSITIONS only; idle
/// until the first detection and whenever the detector is absent/broken.
final placementStatusProvider =
    StreamProvider.autoDispose<PlacementStatus>((ref) {
  final source = ref.watch(placementDetectionSourceProvider);
  final tolerances = ref.watch(placementTolerancesProvider);
  final controller = StreamController<PlacementStatus>();
  var previous = PlacementStatus.idle;

  void emit(PlacementStatus next) {
    if (next == previous) return;
    previous = next;
    if (!controller.isClosed) controller.add(next);
  }

  final sub = source.listen(
    (detection) => emit(evaluatePlacement(
      detection,
      tolerances: tolerances,
      previous: previous,
    )),
    // Absent/failed detector → the guide rests at idle, never an error state.
    // (The native side latches unavailability, so no retry loop here.)
    onError: (Object _, StackTrace __) => emit(PlacementStatus.idle),
  );

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });

  return controller.stream;
});
