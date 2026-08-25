// lib/application/capture/session/capture_session_store.dart
//
// Hive gateway for capture-session snapshots. Follows the repo's box convention
// (see ActiveSessionBox / hive_init.dart): a `Box<String>` holding JSON strings,
// opened via [openStringBoxSafely] (corruption + schema-version safe), NO Hive
// TypeAdapters. One entry per (projectId, levelId), keyed `'$projectId::$levelId'`.
//
// GROUNDING vs the brief: the brief used a `Box<Map<dynamic,dynamic>>` + a sync
// `load`; this repo opens boxes asynchronously and stores JSON strings, so every
// method is async (matching ActiveSessionBox). [load] returns null on absent OR
// corrupt/unparseable data — never throws, so a bad blob means "start fresh".
//
// NOTE: Hive `put` is last-write-wins; two rapid saves to the same key need no
// extra locking here.
import 'dart:convert';

import 'package:hive/hive.dart';

import '../../../data/local/box_names.dart';
import '../../../data/local/hive_init.dart';
import 'capture_session_codec.dart';
import 'capture_session_state.dart';

class CaptureSessionStore {
  CaptureSessionStore();

  Box<String>? _box;
  Future<Box<String>>? _opening;

  Future<Box<String>> _open() {
    final existing = _box;
    if (existing != null && existing.isOpen) return Future.value(existing);
    return _opening ??= openStringBoxSafely(BoxNames.captureSessions).then((box) {
      _box = box;
      _opening = null;
      return box;
    });
  }

  /// The '::' separator is depended on by [clearProject]'s prefix match — change
  /// both together.
  String _keyFor(String projectId, String levelId) => '$projectId::$levelId';

  /// Persists [state], overwriting any prior snapshot for the same
  /// (projectId, levelId).
  Future<void> save(CaptureSessionState state) async {
    final box = await _open();
    await box.put(
      _keyFor(state.projectId, state.levelId),
      jsonEncode(CaptureSessionCodec.toJson(state)),
    );
  }

  /// The snapshot for (projectId, levelId), or null when absent OR
  /// corrupt/unparseable (never throws — treat null as "start fresh").
  Future<CaptureSessionState?> load(String projectId, String levelId) async {
    final box = await _open();
    final raw = box.get(_keyFor(projectId, levelId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return CaptureSessionCodec.fromJson(decoded);
    } on FormatException {
      return null;
    } on CaptureSessionParseException {
      return null;
    }
  }

  /// True if an entry exists for (projectId, levelId) — it may still be
  /// unparseable; use [load] to confirm it restores.
  Future<bool> hasSession(String projectId, String levelId) async {
    final box = await _open();
    return box.containsKey(_keyFor(projectId, levelId));
  }

  /// Removes the snapshot for (projectId, levelId). No-op if absent.
  Future<void> clear(String projectId, String levelId) async {
    final box = await _open();
    await box.delete(_keyFor(projectId, levelId));
  }

  /// Removes every snapshot for [projectId] across all levels; leaves other
  /// projects (and the box's schema-version marker) untouched.
  Future<void> clearProject(String projectId) async {
    final box = await _open();
    final prefix = '$projectId::';
    final keys =
        box.keys.where((k) => k.toString().startsWith(prefix)).toList();
    await box.deleteAll(keys);
  }
}
