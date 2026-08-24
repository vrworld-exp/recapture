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
  /// An upload project resolves WITHOUT consulting the status table at all,
  /// because every word in it is a capture word and none of them are true here:
  /// the photos are already on S3, so there is no session to "Resume", nothing
  /// is "Processing…" (no worker ever claims a photo-upload job, so that
  /// spinner would never stop), and there is no failed transfer to "Retry".
  /// A finished model is the only real destination, so that is the only action
  /// it can ever offer — and until one exists the card carries no primary
  /// action at all, letting Preview / Models / Generate 3D model be the whole
  /// row, exactly as they are on a capture project.
  ///
  /// Resolving the two sources separately (rather than falling through for
  /// "the statuses that happen to agree") is deliberate: the fall-through is
  /// what would let a DRAFT upload send an artist into pre-capture — a ring
  /// flow this project has no plan for and can never complete.
  ProjectCardAction get cardAction {
    if (isUploadProject) {
      return hasViewableModels || status == ProjectStatus.completed
          ? ProjectCardAction.view
          : ProjectCardAction.none;
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
