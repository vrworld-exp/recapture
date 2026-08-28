// lib/data/local/active_session_box.dart
import 'dart:convert';

import 'package:hive/hive.dart';

import '../../domain/entities/active_session.dart';
import 'box_names.dart';
import 'hive_init.dart';

/// Typed gateway over the (unencrypted) `active_session` box. Holds no sensitive
/// data — just the resumable capture session — so it is a plain Hive box. Hive
/// types never leak past this class.
class ActiveSessionBox {
  ActiveSessionBox();

  static const String _key = 'session';

  Box<String>? _box;
  Future<Box<String>>? _opening;

  Future<Box<String>> _open() {
    final existing = _box;
    if (existing != null && existing.isOpen) return Future.value(existing);
    // Share a single in-flight open so concurrent calls never double-open.
    return _opening ??= openStringBoxSafely(BoxNames.activeSession).then((box) {
      _box = box;
      _opening = null;
      return box;
    });
  }

  Future<void> save(ActiveSession session) async {
    await (await _open()).put(_key, jsonEncode(session.toJson()));
  }

  /// Returns the stored session, or null when absent/corrupt (never throws).
  Future<ActiveSession?> read() async {
    final raw = (await _open()).get(_key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return ActiveSession.fromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  Future<void> clear() async {
    await (await _open()).delete(_key);
  }
}
