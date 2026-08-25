// lib/application/capture/session/capture_session_keys.dart
//
// Centralised string keys for the JSON-storable representation of a
// CaptureSessionState (and its nested ledger records), so encode and decode can
// never drift out of sync via a typo.
abstract final class CaptureSessionKeys {
  CaptureSessionKeys._();

  // CaptureSessionState
  static const schemaVersion = 'schema_version';
  static const projectId = 'project_id';
  static const levelId = 'level_id';
  static const segmentCount = 'segment_count';
  static const fillThreshold = 'fill_threshold';
  static const fillCounts = 'fill_counts';
  static const position = 'position';
  static const accepted = 'accepted';
  static const warned = 'warned';
  static const rejected = 'rejected';
  static const savedAtMs = 'saved_at_ms';

  // CapturedPhotoRecord
  static const segmentIndex = 'segment_index'; // nullable
  static const framePath = 'frame_path';
  static const blurScore = 'blur_score';
  static const meanLuminance = 'mean_luminance';
  static const yawDegrees = 'yaw_degrees';
  static const pitchDegrees = 'pitch_degrees';
  static const sensorTimestampNs = 'sensor_timestamp_ns';

  // WarnedPhotoRecord
  static const isUnderexposed = 'is_underexposed';
  static const isOverexposed = 'is_overexposed';

  // RejectedPhotoRecord
  static const reason = 'reason';
  static const stabilityScore = 'stability_score';
}
