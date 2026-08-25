// lib/data/local/offline_queue_box.dart
import 'dart:convert';

import 'package:hive/hive.dart';

import '../../domain/entities/offline_action.dart';
import 'box_names.dart';
import 'hive_init.dart';

/// Typed gateway over the (unencrypted) `offline_queue` box. Stores the whole
/// queue as a single JSON list under one key. Holds no sensitive data. Hive
/// types never leak past this class.
///
/// Corruption policy (matching the other gateways): an absent, non-list, or
/// unparseable blob degrades to an empty queue — [read] never throws, so a bad
/// box on disk can never crash startup. Individual unparseable rows are skipped.
class OfflineQueueBox {
  OfflineQueueBox();

  static const String _key = 'actions';

  Box<String>? _box;
  Future<Box<String>>? _opening;

  Future<Box<String>> _open() {
    final existing = _box;
    if (existing != null && existing.isOpen) return Future.value(existing);
    // Share a single in-flight open so concurrent calls never double-open.
    return _opening ??= openStringBoxSafely(BoxNames.offlineQueue).then((box) {
      _box = box;
      _opening = null;
      return box;
    });
  }

  /// Overwrites the persisted queue with [actions] (FIFO order preserved).
  Future<void> save(List<OfflineAction> actions) async {
    final payload = jsonEncode([for (final a in actions) a.toMap()]);
    await (await _open()).put(_key, payload);
  }

  /// Returns the persisted queue, or `[]` when absent/corrupt. Rows that fail to
  /// parse are skipped (partial recovery) rather than discarding the whole list.
  Future<List<OfflineAction>> read() async {
    final raw = (await _open()).get(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final actions = <OfflineAction>[];
      for (final row in decoded) {
        if (row is! Map) continue;
        try {
          actions.add(OfflineAction.fromMap(row.cast<String, dynamic>()));
        } catch (_) {/* skip a single unparseable row */}
      }
      return actions;
    } on FormatException {
      return const [];
    }
  }

  Future<void> clear() async {
    await (await _open()).delete(_key);
  }
}
