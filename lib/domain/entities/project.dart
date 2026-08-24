// lib/domain/entities/project.dart
import 'project_source.dart';
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
    this.modelCount = 0,
    this.source = ProjectSource.capture,
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

  /// VIEWABLE (SUCCEEDED) 3D models this project has — `modelCount` on the API
  /// DTO. Drives the staff-only Models button, which must not open a history
  /// with nothing in it. Failed/pending generations are deliberately NOT counted
  /// (backend contract), so 0 means "nothing to view", not "nothing was tried".
  final int modelCount;

  /// Whether the staff Models entry point has anything to show.
  bool get hasViewableModels => modelCount > 0;

  /// Where this project's photos came from — `source` on the API DTO.
  ///
  /// Drives what the card's PRIMARY action opens: an upload project goes to its
  /// photo grid, never into pre-capture (which would run a ring flow the
  /// project has no plan for). Defaults to [ProjectSource.capture], so a row
  /// from an older API or an older cache behaves exactly as it always did.
  final ProjectSource source;

  /// Convenience for the many `source == ProjectSource.upload` branches.
  bool get isUploadProject => source.isUpload;

  /// What the card's PRIMARY action should be — status AND source together.
  ///
  /// `DRAFT` is the one status that means two different things. On a capture
  /// project it is an unfinished session, so "Resume" walks back into the
  /// capture flow. On an UPLOAD project there is nothing to resume: the photos
  /// are already on S3 and the project is complete as an upload. What is left
  /// is choosing which photos a model gets built from, so the action says that
  /// instead of borrowing capture's word for it.
  ///
  /// Every other status is shared, and deliberately so: an upload project that
  /// is PROCESSING or COMPLETED is the same thing a capture project is, and it
  /// gets the same "Processing…" / "View" treatment.
  ProjectCardAction get cardAction {
    if (isUploadProject && status == ProjectStatus.draft) {
      return ProjectCardAction.selectPhotos;
    }
    return status.cardAction;
  }

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
    final rawModels = map['modelCount'];
    return Project(
      id: (map['id'] ?? '').toString(),
      name: rawName == null || rawName.isEmpty ? 'Untitled project' : rawName,
      status: ProjectStatusDisplay.fromApiValue((map['status'] ?? '').toString()),
      thumbnailUrl: rawThumb == null || rawThumb.isEmpty ? null : rawThumb,
      updatedAt: _parseDate(map['updatedAt']),
      totalPhotos: rawPhotos is num && rawPhotos >= 0 ? rawPhotos.toInt() : 0,
      // Absent on a row cached before this field existed → 0 (button hidden)
      // rather than a crash; the next fetch fills it in.
      modelCount: rawModels is num && rawModels >= 0 ? rawModels.toInt() : 0,
      // Absent (older API, older cache) → capture, never a crash.
      source: projectSourceFromApi(map['source'] as String?),
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
        // Must round-trip: a cached row read back without it would drop to 0 and
        // hide the Models button until the next successful fetch.
        'modelCount': modelCount,
        // Same rule, sharper consequence: a cached upload project read back
        // without this would default to capture and offer a CAPTURE action —
        // sending the artist into a ring flow for a project that has none —
        // until the next successful fetch.
        'source': source.apiValue,
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
    int? modelCount,
    ProjectSource? source,
    bool? isPending,
  }) {
    return Project(
      id: id,
      name: name ?? this.name,
      status: status ?? this.status,
      thumbnailUrl: thumbnailUrl,
      updatedAt: updatedAt ?? this.updatedAt,
      totalPhotos: totalPhotos ?? this.totalPhotos,
      modelCount: modelCount ?? this.modelCount,
      source: source ?? this.source,
      isPending: isPending ?? this.isPending,
    );
  }
}
