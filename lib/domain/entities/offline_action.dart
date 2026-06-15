// lib/domain/entities/offline_action.dart
//
// Pure Dart — NO Flutter/Riverpod imports. A deferred write/mutation the app
// queues while it cannot reach the backend (rename/delete/retry a project) and
// replays once connectivity returns. Reads are NOT queued here — those are
// served from `projects_cache`. All timestamps are UTC.

/// The kind of deferred mutation. `unknown` is the forward-compatible bucket for
/// a type loaded from an older/newer app version — such actions are dropped on
/// drain so they can never wedge the queue.
enum OfflineActionType { renameProject, deleteProject, retryProject, unknown }

/// Analytics-facing name for each action type (snake_case, never the enum name).
extension OfflineActionTypeAnalytics on OfflineActionType {
  String get analyticsValue => switch (this) {
        OfflineActionType.renameProject => 'rename_project',
        OfflineActionType.deleteProject => 'delete_project',
        OfflineActionType.retryProject => 'retry_project',
        OfflineActionType.unknown => 'unknown',
      };
}

/// A single queued action. Immutable — [incremented] returns a copy with a
/// bumped [attempts] count rather than mutating in place.
class OfflineAction {
  const OfflineAction({
    required this.id,
    required this.type,
    required this.payload,
    required this.createdAt,
    this.attempts = 0,
  });

  final String id; // process-unique; see [newId]
  final OfflineActionType type;
  final Map<String, dynamic> payload; // action-specific (e.g. {projectId, newName})
  final DateTime createdAt; // UTC
  final int attempts; // drain attempts so far (drop guard)

  /// A copy with one more drain attempt recorded.
  OfflineAction incremented() => OfflineAction(
        id: id,
        type: type,
        payload: payload,
        createdAt: createdAt,
        attempts: attempts + 1,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type.name,
        'payload': payload,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'attempts': attempts,
      };

  /// Defensive parse — missing/ill-typed fields degrade to safe values rather
  /// than throwing, so a blob written by an older app version (or a partially
  /// corrupt row) never crashes the restore. An unrecognized `type` maps to
  /// [OfflineActionType.unknown] (dropped on drain).
  factory OfflineAction.fromMap(Map<String, dynamic> m) => OfflineAction(
        id: m['id'] is String ? m['id'] as String : newId(),
        type: OfflineActionType.values.firstWhere(
          (t) => t.name == m['type'],
          orElse: () => OfflineActionType.unknown,
        ),
        payload: (m['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
        createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '')?.toUtc() ??
            DateTime.now().toUtc(),
        attempts: (m['attempts'] as num?)?.toInt() ?? 0,
      );

  /// Generates a process-unique id. No `uuid` dependency is present, so this
  /// uses microsecond time + a wrapping counter — unique enough for a per-user,
  /// single-device queue (the only scope this stub targets).
  static String newId() {
    _counter = (_counter + 1) & 0xffffffff;
    return '${DateTime.now().toUtc().microsecondsSinceEpoch}-$_counter';
  }

  static int _counter = 0;
}
