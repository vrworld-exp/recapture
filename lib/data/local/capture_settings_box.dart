// lib/data/local/capture_settings_box.dart
import 'package:hive/hive.dart';

import '../../domain/entities/capture_settings.dart';
import 'box_names.dart';
import 'hive_init.dart';

/// Persistence for the Level A capture settings that are NOT the auto-capture
/// flag — save-to-gallery and quality mode. Auto-capture intentionally stays in
/// [AutoCaptureStore] (key `level_a_auto_capture`) so the pill and the Settings
/// sheet share one source; this store only owns the two extra keys.
abstract interface class CaptureSettingsStore {
  /// Persisted save-to-gallery flag, or null when unset/unavailable.
  Future<bool?> getSaveToGallery();
  Future<void> setSaveToGallery(bool enabled);

  /// Persisted quality mode, or null when unset/unavailable.
  Future<QualityMode?> getQuality();
  Future<void> setQuality(QualityMode mode);
}

/// Hive-backed [CaptureSettingsStore]. Stores both keys in the shared
/// `capture_prefs` `Box<String>` (JSON-string convention, no TypeAdapters).
///
/// Resilience mirrors [AutoCaptureBox]: every operation is wrapped so it never
/// throws past this class. A missing/corrupt record — or a host where Hive is
/// unavailable (e.g. a widget-test host) — degrades reads to null (caller
/// defaults) and makes writes a silent no-op.
class CaptureSettingsBox implements CaptureSettingsStore {
  CaptureSettingsBox();

  static const String _saveToGalleryKey = 'level_a_save_to_gallery';
  static const String _qualityKey = 'level_a_quality_mode';

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
  Future<bool?> getSaveToGallery() async {
    try {
      final raw = (await _tryOpen())?.get(_saveToGalleryKey);
      if (raw == 'true') return true;
      if (raw == 'false') return false;
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setSaveToGallery(bool enabled) async {
    try {
      final box = await _tryOpen();
      if (box == null) return;
      await box.put(_saveToGalleryKey, enabled ? 'true' : 'false');
    } catch (_) {
      // Persistence unavailable — fail silent.
    }
  }

  @override
  Future<QualityMode?> getQuality() async {
    try {
      final raw = (await _tryOpen())?.get(_qualityKey);
      if (raw == null) return null;
      return qualityModeFromString(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setQuality(QualityMode mode) async {
    try {
      final box = await _tryOpen();
      if (box == null) return;
      await box.put(_qualityKey, qualityModeToString(mode));
    } catch (_) {
      // Persistence unavailable — fail silent.
    }
  }
}
