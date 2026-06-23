// lib/application/capture/analytics/coverage_analytics_provider.dart
//
// Wires the [CoverageAnalyticsTracker] as an EXTERNAL observer of the segment
// coverage state — the pure [SegmentCoverage] model + its notifier stay
// analytics-free. Reading/watching this provider activates the listeners; the
// capture screen should `ref.watch` it for the duration of a Level A session so
// the events fire as captures fill segments.
//
// NOTE: this is the integration seam. The capture→coverage write path
// (segmentCoverageProvider.recordCapture being called on an accepted capture) is
// owned by a separate wiring task and is not yet called live, so today this
// observer is dormant in-app until that lands — it is fully exercised in tests by
// driving the coverage notifier directly.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/entities/capture_readiness.dart' show CaptureMode;
import '../guidance_engine.dart' show captureModeProvider;
import '../segment_coverage_provider.dart';
import 'capture_level_events.dart';
import 'capture_level_session.dart';
import 'coverage_analytics_tracker.dart';

/// Activates the coverage-analytics observer. Listens to [segmentCoverageProvider]
/// transitions (so the model stays pure) and resets the tracker when the analytics
/// session changes (a new level-session re-arms milestone/transition tracking).
/// Returns the tracker (mostly for tests); the value matters less than the
/// side-effect of the registered listeners.
final coverageAnalyticsObserverProvider =
    Provider<CoverageAnalyticsTracker>((ref) {
  final tracker = CoverageAnalyticsTracker();

  // New analytics session (started by the capture screen) → re-arm tracking.
  ref.listen<CaptureLevelSession?>(captureLevelSessionProvider, (prev, next) {
    if (prev?.sessionId != next?.sessionId) tracker.reset();
  });

  // Observe coverage transitions from the outside — emission context is pulled
  // from the session + capture-mode providers at emit time.
  ref.listen(segmentCoverageProvider, (prev, next) {
    final session = ref.read(captureLevelSessionProvider);
    final mode = ref.read(captureModeProvider);
    tracker.onCoverageChanged(
      next,
      level: session?.level ?? CaptureLevel.a,
      projectId: session?.projectId ?? '',
      sessionId: session?.sessionId ?? '',
      captureMode: mode == CaptureMode.manual ? 'manual' : 'guided',
      deviceType:
          defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    );
  });

  return tracker;
});
