// lib/data/local/config_cache_box.dart
import 'dart:convert';

import 'package:hive/hive.dart';

import '../../domain/entities/capture_config.dart';
import 'box_names.dart';
import 'hive_init.dart';

/// Typed gateway over the (unencrypted) `config_cache` box. Stores the capture
/// config as a single JSON blob. Holds no sensitive data. Hive types never leak
/// past this class.
class ConfigCacheBox {
  ConfigCacheBox();

  static const String _key = 'data';

  Box<String>? _box;
  Future<Box<String>>? _opening;

  Future<Box<String>> _open() {
    final existing = _box;
    if (existing != null && existing.isOpen) return Future.value(existing);
    // Share a single in-flight open so concurrent calls never double-open.
    return _opening ??= openStringBoxSafely(BoxNames.configCache).then((box) {
      _box = box;
      _opening = null;
      return box;
    });
  }

  Future<void> save(CaptureConfig config) async {
    await (await _open()).put(_key, jsonEncode(config.toMap()));
  }

  /// Returns the cached config, or null when absent/corrupt. Defensive parse:
  /// `CaptureConfig.fromMap` never throws on a Map, and a non-Map / unparseable
  /// blob returns null (treated as "no cache").
  Future<CaptureConfig?> read() async {
    final raw = (await _open()).get(_key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return CaptureConfig.fromMap(decoded);
    } on FormatException {
      return null;
    }
  }

  Future<void> clear() async {
    await (await _open()).delete(_key);
  }
}
