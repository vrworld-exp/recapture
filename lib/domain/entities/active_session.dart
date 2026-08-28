// lib/domain/entities/active_session.dart

/// A resumable capture/project session. Minimal, versioned shape — the capture
/// flow that fully populates this isn't built yet, so this holds only what is
/// knowable now and is designed to be extended later (add fields with defensive
/// defaults so old persisted blobs keep parsing).
class ActiveSession {
  const ActiveSession({
    required this.projectId,
    required this.updatedAt,
    this.step,
  });

  /// The in-progress project this session belongs to.
  final String projectId;

  /// Opaque capture-step marker (e.g. a level/route id). Shape TBD with the
  /// capture flow; kept as a free-form string so it can evolve without a
  /// migration.
  final String? step;

  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'projectId': projectId,
        'step': step,
        'updatedAt': updatedAt.toIso8601String(),
      };

  /// Defensive parse — returns null on anything missing/ill-typed so a stale or
  /// pre-model-change blob is treated as "no active session" rather than crashing.
  static ActiveSession? fromJson(Map<String, dynamic> json) {
    final projectId = json['projectId'];
    if (projectId is! String || projectId.isEmpty) return null;
    final step = json['step'];
    final updatedAt = DateTime.tryParse('${json['updatedAt']}');
    return ActiveSession(
      projectId: projectId,
      step: step is String ? step : null,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }
}
