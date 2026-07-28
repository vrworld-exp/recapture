// lib/data/local/generation_tracker_box.dart
import 'dart:convert';

import 'package:hive/hive.dart';

import 'box_names.dart';
import 'hive_init.dart';

/// One 3D-model generation the app is watching, as it survives a restart.
///
/// Deliberately carries NO percent and NO status. Progress and outcome are the
/// SERVER's to state, and a generation can finish, fail, or be superseded while
/// the app is dead — a persisted "42%, running" would then be rendered as fact
/// on next launch and be wrong. What is durable is only "we were watching this
/// project", which is enough to go ask again.
///
/// [projectName] rides along purely so the status bar can name the project
/// without fetching the whole list before it can draw.
class TrackedGenerationRecord {
  const TrackedGenerationRecord({
    required this.projectId,
    required this.projectName,
    required this.startedAt,
  });

  final String projectId;
  final String projectName;

  /// When the app STARTED WATCHING — not when the server started the run. Used
  /// only for the settled-event duration, never shown.
  final DateTime startedAt;

  Map<String, dynamic> toMap() => {
        'projectId': projectId,
        'projectName': projectName,
        'startedAt': startedAt.toIso8601String(),
      };

  /// Returns null for a row with no usable project id — the one field without
  /// which the record cannot be re-polled and is therefore worthless.
  static TrackedGenerationRecord? tryFromMap(Map<String, dynamic> map) {
    final id = (map['projectId'] ?? '').toString();
    if (id.isEmpty) return null;
    return TrackedGenerationRecord(
      projectId: id,
      projectName: (map['projectName'] ?? '').toString(),
      // An unparseable timestamp costs only the duration metric, so it degrades
      // to "now" rather than dropping a generation the user is waiting on.
      startedAt: DateTime.tryParse((map['startedAt'] ?? '').toString()) ??
          DateTime.now(),
    );
  }
}

/// The persistence seam the generation tracker writes through. An interface so
/// widget tests can supply an in-memory fake instead of driving real Hive IO
/// inside `testWidgets` (which this codebase has repeatedly had to wrap in
/// `tester.runAsync`).
abstract interface class GenerationTrackerStore {
  /// The watched set, or `[]` when absent/corrupt. Never throws.
  Future<List<TrackedGenerationRecord>> read();

  /// Overwrites the watched set.
  Future<void> save(List<TrackedGenerationRecord> records);

  /// Forgets everything (logout).
  Future<void> clear();
}

/// Typed gateway over the (unencrypted) `model_generations` box. Stores the
/// whole watched set as one JSON document under a single key. Holds no
/// sensitive data — project ids and names the user already sees. Hive types
/// never leak past this class.
///
/// Corruption policy matches the other gateways: an absent, non-list or
/// unparseable blob degrades to an empty set and [read] never throws, so a bad
/// box on disk can never crash startup. Individual unparseable rows are
/// skipped rather than discarding the whole set.
class GenerationTrackerBox implements GenerationTrackerStore {
  GenerationTrackerBox();

  static const String _key = 'generations';

  Box<String>? _box;
  Future<Box<String>>? _opening;

  Future<Box<String>> _open() {
    final existing = _box;
    if (existing != null && existing.isOpen) return Future.value(existing);
    // Share a single in-flight open so concurrent calls never double-open.
    return _opening ??=
        openStringBoxSafely(BoxNames.modelGenerations).then((box) {
      _box = box;
      _opening = null;
      return box;
    });
  }

  @override
  Future<void> save(List<TrackedGenerationRecord> records) async {
    final payload = jsonEncode([for (final r in records) r.toMap()]);
    await (await _open()).put(_key, payload);
  }

  @override
  Future<List<TrackedGenerationRecord>> read() async {
    try {
      final raw = (await _open()).get(_key);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final records = <TrackedGenerationRecord>[];
      for (final row in decoded) {
        if (row is! Map) continue;
        final record = TrackedGenerationRecord.tryFromMap(
          row.cast<String, dynamic>(),
        );
        if (record != null) records.add(record);
      }
      return records;
    } catch (_) {
      // Includes a box that cannot even be OPENED (Hive uninitialised, disk
      // failure). The tracker's whole contract is "ask the server again", so an
      // unreadable disk costs a resumed watch, never a crash.
      return const [];
    }
  }

  @override
  Future<void> clear() async {
    await (await _open()).delete(_key);
  }
}
