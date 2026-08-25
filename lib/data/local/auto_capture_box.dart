// lib/data/local/auto_capture_box.dart
import 'package:hive/hive.dart';

import 'box_names.dart';
import 'hive_init.dart';

/// The store contract the Level A capture screen depends on to persist the
/// user's auto-capture ON/OFF preference. Lets the UI read/write the preference
/// without binding to Hive (tests inject a fake).
abstract interface class AutoCaptureStore {
  /// The persisted preference, or null when none is stored yet (first run) or
  /// persistence is unavailable — the caller applies its own default.
  Future<bool?> getEnabled();

  /// Persists the auto-capture preference.
  Future<void> setEnabled(bool enabled);
}

/// Hive-backed [AutoCaptureStore]. Stores the single Level A auto-capture flag in
/// the `capture_prefs` `Box<String>` (the same JSON-string convention as the
/// other boxes — no TypeAdapters).
///
/// Resilience mirrors [LevelIntroBox]/[PermissionFlowBox]: every operation is
/// wrapped so it never throws past this class. A missing/corrupt record — or an
/// environment where Hive is unavailable (e.g. a widget-test host) — degrades
/// [getEnabled] to null (caller defaults) and makes writes a silent no-op.
class AutoCaptureBox implements AutoCaptureStore {
  AutoCaptureBox();

  /// Key for the Level A auto-capture preference.
  static const String _levelAKey = 'level_a_auto_capture';

  Box<String>? _box;

  Future<Box<String>?> _tryOpen() async {
    final existing = _box;
    if (existing != null && existing.isOpen) return existing;
    try {
      return _box = await openStringBoxSafely(BoxNames.capturePrefs);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool?> getEnabled() async {
    try {
      final box = await _tryOpen();
      final raw = box?.get(_levelAKey);
      if (raw == 'true') return true;
      if (raw == 'false') return false;
      return null; // absent / unreadable → caller defaults
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    try {
      final box = await _tryOpen();
      if (box == null) return;
      await box.put(_levelAKey, enabled ? 'true' : 'false');
    } catch (_) {
      // Persistence unavailable — fail silent (preference just won't persist).
    }
  }
}
