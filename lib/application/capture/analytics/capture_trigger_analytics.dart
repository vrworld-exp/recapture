// lib/application/capture/analytics/capture_trigger_analytics.dart
//
// The ONE typed call site for the two capture-trigger events — so the manual path
// (the shutter) and the auto path (the auto-capture loop, when built) each emit
// through a single helper rather than hand-assembling maps. Both events fire at
// capture INITIATION (not acceptance), are mutually exclusive for one physical
// capture (different code paths call different methods), and share the session's
// `attempt_number` (the caller passes `session.nextAttempt()`).
//
// Emission routes through [CaptureAnalytics.log] → the guarded `Analytics` seam,
// so a logging failure never blocks or crashes the capture hot path. The
// `was_blocked_override` flag (manual only) is derived HERE from the readiness so
// the fail-open definition lives in one place.
import 'capture_analytics.dart';
import 'capture_level_events.dart';

abstract final class CaptureTriggerAnalytics {
  /// Emits `manual_capture_triggered` at the moment a user tap initiates a
  /// capture. [inBand]/[stable]/[sensorSupported]/[placed] are the live readiness;
  /// `was_blocked_override` is true when the capture fired without ALL guided
  /// gates satisfied (fail-open: sensors off / manual mode).
  static void manual({
    required CaptureLevel level,
    required String projectId,
    required String sessionId,
    required int attemptNumber,
    required int? ringIndex,
    required bool inBand,
    required bool stable,
    required bool sensorSupported,
    required String deviceType,
    bool placed = true,
  }) {
    CaptureAnalytics.log(CaptureManualTriggered(
      level: level,
      projectId: projectId,
      sessionId: sessionId,
      attemptNumber: attemptNumber,
      ringIndex: ringIndex,
      inBand: inBand,
      stable: stable,
      sensorSupported: sensorSupported,
      wasBlockedOverride: !(sensorSupported && inBand && stable && placed),
      deviceType: deviceType,
    ));
  }

  /// Emits `autocapture_triggered` when the auto-capture loop fires a shot. The
  /// single call site for the (separate) loop to invoke at its trigger point.
  static void auto({
    required CaptureLevel level,
    required String projectId,
    required String sessionId,
    required int attemptNumber,
    required int? ringIndex,
    required bool inBand,
    required bool stable,
    required bool sensorSupported,
    required String deviceType,
  }) {
    CaptureAnalytics.log(CaptureAutoTriggered(
      level: level,
      projectId: projectId,
      sessionId: sessionId,
      attemptNumber: attemptNumber,
      ringIndex: ringIndex,
      inBand: inBand,
      stable: stable,
      sensorSupported: sensorSupported,
      deviceType: deviceType,
    ));
  }
}
