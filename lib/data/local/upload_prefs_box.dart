// lib/data/local/upload_prefs_box.dart
//
// Device-local upload preferences — today just "Upload on mobile data" (offline
// capture, Step B3). Stored in the shared `capture_prefs` `Box<String>` under
// its own key, exactly like CaptureSettingsBox: a user preference, not capture
// data, so no new box. Never throws past this class — an unavailable box reads
// as "unset" (caller default: OFF) and writes become a silent no-op.
import 'package:hive/hive.dart';

import 'box_names.dart';
import 'hive_init.dart';

abstract interface class UploadPrefsStore {
  /// Persisted "Upload on mobile data", or null when unset/unavailable.
  Future<bool?> getUploadOnMobileData();
  Future<void> setUploadOnMobileData(bool enabled);
}

class UploadPrefsBox implements UploadPrefsStore {
  UploadPrefsBox();

  static const String _mobileDataKey = 'upload_on_mobile_data';

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
  Future<bool?> getUploadOnMobileData() async {
    try {
      final raw = (await _tryOpen())?.get(_mobileDataKey);
      if (raw == 'true') return true;
      if (raw == 'false') return false;
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setUploadOnMobileData(bool enabled) async {
    try {
      final box = await _tryOpen();
      if (box == null) return;
      await box.put(_mobileDataKey, enabled ? 'true' : 'false');
    } catch (_) {/* persistence unavailable — fail silent */}
  }
}
