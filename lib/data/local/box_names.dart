// lib/data/local/box_names.dart

/// Hive box names. Single source of truth — never hard-code a box name elsewhere.
///
/// Note: auth tokens are intentionally NOT a Hive box. They live in
/// `flutter_secure_storage` via `AuthStorage` (OS Keychain/Keystore), so there
/// is no `user_token` box here — Hive holds only non-sensitive local data.
abstract final class BoxNames {
  /// Resumable capture/project session (in-progress project id, capture step).
  static const String activeSession = 'active_session';

  /// Cached projects list for fast / offline-tolerant first paint.
  static const String projectsCache = 'projects_cache';

  /// Cached remote capture config for instant availability on startup.
  static const String configCache = 'config_cache';

  /// Persisted offline action queue (deferred write mutations) so queued
  /// actions survive app restarts.
  static const String offlineQueue = 'offline_queue';

  /// App-side permission FLOW state (has-been-asked / user-skipped) so the gate
  /// doesn't re-prompt or nag on resume. Holds NO grant status — the OS is the
  /// authority; grant status is always re-checked live.
  static const String permissionFlow = 'permission_flow';

  /// Per-intro "seen" / "don't show again" flags for capture-level intro screens
  /// (keyed by an intro id, e.g. `level_a`). Flow state only — no capture data.
  static const String levelIntro = 'level_intro';

  /// Small per-capture UI preferences (e.g. the Level A auto-capture ON/OFF
  /// choice). User preference only — no capture data.
  static const String capturePrefs = 'capture_prefs';

  /// Resumable guided-capture session snapshots (ring fill counts + the
  /// accepted/warned/rejected photo ledger), keyed by `projectId::levelId`, so a
  /// kill/relaunch restores exact in-progress capture state.
  static const String captureSessions = 'capture_sessions';

  /// Multi-level progression state (current level index + per-level completion
  /// summary), keyed by `projectId`, so the A→B→C sequence + overall completion
  /// resume on relaunch. Per-segment coverage lives in [captureSessions]; this is
  /// the sequencing layer above it.
  static const String captureProgression = 'capture_progression';
}

/// Per-box schema marker. Current migration policy is clear-on-mismatch — when
/// the stored version differs from [version], the box is wiped (no migrations
/// are defined yet).
abstract final class BoxSchema {
  static const int version = 1;
  static const String versionKey = '__schema_version';
}
