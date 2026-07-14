// lib/domain/entities/project.dart
import 'project_status.dart';

/// Maximum length of a project name. Keep in sync with the backend limit to
/// avoid server-side rejection. Single source of truth for the rename sheet and
/// the create-project form.
const int kMaxProjectNameLength = 60;

/// A single capture/scan project shown in the Projects Hub.
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.status,
    required this.updatedAt,
    this.thumbnailUrl,
    this.totalPhotos = 0,
    this.isPending = false,
  });

  final String id;
  final String name;
  final ProjectStatus status;
  final String? thumbnailUrl;
  final DateTime updatedAt;

  /// Photos in the project's latest finalized upload (`stats.totalPhotos` on
  /// the API DTO — manifest-exclusive). 0 until an upload has finalized.
  final int totalPhotos;

  /// True for a project created offline that is still waiting in the offline
  /// outbox to be flushed to the server. Such a row carries a temporary local
  /// [id] (never the server id) and is shown optimistically until reconciled.
  final bool isPending;

  /// Defensive parsing — every field falls back to a safe default so a
  /// malformed API row never crashes the list.
  factory Project.fromMap(Map<String, dynamic> map) {
    final rawName = (map['name'] as String?)?.trim();
    final rawThumb = (map['thumbnailUrl'] as String?)?.trim();
    final stats = map['stats'];
    final rawPhotos = stats is Map ? stats['totalPhotos'] : null;
    return Project(
      id: (map['id'] ?? '').toString(),
      name: rawName == null || rawName.isEmpty ? 'Untitled project' : rawName,
      status: ProjectStatusDisplay.fromApiValue((map['status'] ?? '').toString()),
      thumbnailUrl: rawThumb == null || rawThumb.isEmpty ? null : rawThumb,
      updatedAt: _parseDate(map['updatedAt']),
      totalPhotos: rawPhotos is num && rawPhotos >= 0 ? rawPhotos.toInt() : 0,
      isPending: map['isPending'] == true,
    );
  }

  /// Serialises to the same shape [Project.fromMap] reads, for the projects
  /// cache (round-trips: status via apiValue, updatedAt as ISO-8601, photo
  /// count under the API's nested `stats` shape).
  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'status': status.apiValue,
        'thumbnailUrl': thumbnailUrl,
        'updatedAt': updatedAt.toIso8601String(),
        'stats': {'totalPhotos': totalPhotos},
        'isPending': isPending,
      };

  /// Accepts epoch millis (int) or an ISO-8601 string; falls back to now.
  static DateTime _parseDate(dynamic raw) {
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    if (raw is String) return DateTime.tryParse(raw) ?? DateTime.now();
    return DateTime.now();
  }

  /// Returns a copy with the given fields replaced. Used for in-place list
  /// updates (e.g. after a rename) so the Projects List never has to refetch.
  Project copyWith({
    String? name,
    ProjectStatus? status,
    DateTime? updatedAt,
    int? totalPhotos,
    bool? isPending,
  }) {
    return Project(
      id: id,
      name: name ?? this.name,
      status: status ?? this.status,
      thumbnailUrl: thumbnailUrl,
      updatedAt: updatedAt ?? this.updatedAt,
      totalPhotos: totalPhotos ?? this.totalPhotos,
      isPending: isPending ?? this.isPending,
    );
  }
}
