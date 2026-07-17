// lib/domain/entities/project_model.dart
//
// Typed model of one 3D-model GENERATION record, as both the staff surface
// (`/admin/projects/:id/models`) and the owner surface (`GET /projects/:id`'s
// `model`) return it. Hand-synced with the backend's ProjectModelDto /
// OwnerModelDto (recapture-api/src/services/projectModelsService.ts) — there is
// no shared package, so a change on either side must be mirrored here.
//
// The staff and owner payloads differ deliberately: the owner one carries no
// keys, no selection and no staff actor ids. This entity models the UNION and
// leaves the staff-only fields null when parsed from the owner shape.

/// Where the model came from. Drives the "Created by Meshy AI" badge — the badge
/// is never inferred from anything else.
enum ModelSource {
  meshy,
  manual,
  /// A source this build does not know (server ahead of the app). Renders
  /// unbadged rather than crashing the viewer.
  unknown;

  static ModelSource parse(Object? raw) => switch (raw.toString()) {
        'meshy' => ModelSource.meshy,
        'manual' => ModelSource.manual,
        _ => ModelSource.unknown,
      };

  /// The origin label shown on the viewer, or null when there is nothing to
  /// attribute.
  String? get badgeLabel => switch (this) {
        ModelSource.meshy => 'Created by Meshy AI',
        ModelSource.manual || ModelSource.unknown => null,
      };
}

/// Generation lifecycle. `QUEUED`/`PROCESSING` are the polling states.
enum ModelStatus {
  queued,
  processing,
  succeeded,
  failed,
  /// Unknown to this build — treated as terminal so polling can't spin forever.
  unknown;

  static ModelStatus parse(Object? raw) => switch (raw.toString()) {
        'QUEUED' => ModelStatus.queued,
        'PROCESSING' => ModelStatus.processing,
        'SUCCEEDED' => ModelStatus.succeeded,
        'FAILED' => ModelStatus.failed,
        _ => ModelStatus.unknown,
      };

  /// Whether a generation in this state is still expected to change — the
  /// polling loop's stop condition.
  bool get isPending => this == ModelStatus.queued || this == ModelStatus.processing;
}

/// Why a generation failed. Mirrors ProjectModelDto's `error`.
///
/// [message] is SAFE to display: the backend contract is that meshyClient never
/// interpolates a response body or a presigned URL into one. Staff payload only.
class ModelError {
  const ModelError({required this.code, required this.message});

  final String code;
  final String message;

  static ModelError? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final message = (raw['message'] ?? '').toString();
    if (message.isEmpty) return null;
    return ModelError(code: (raw['code'] ?? '').toString(), message: message);
  }
}

/// One generation attempt.
class ProjectModelView {
  const ProjectModelView({
    required this.id,
    required this.source,
    required this.status,
    this.glbUrl,
    this.previewUrl,
    this.approved = false,
    this.selectedKeys = const [],
    this.createdAt,
    this.error,
  });

  final String id;
  final ModelSource source;
  final ModelStatus status;

  /// Our CloudFront GLB URL — non-null exactly when [status] is succeeded.
  final String? glbUrl;
  final String? previewUrl;

  /// Whether staff signed off on this model ("no manual creation needed").
  final bool approved;

  /// The photos this attempt used. Staff payload only — empty for an owner.
  final List<String> selectedKeys;

  /// When the attempt was requested — how the history labels its rows (an index
  /// would renumber itself as new generations land at the head of the list).
  /// Null when the timestamp is absent or malformed.
  final DateTime? createdAt;

  /// The failure, for a FAILED record. Staff payload only — the owner endpoint
  /// never returns a failed attempt, so [tryFromOwnerMap] never parses this.
  final ModelError? error;

  bool get isViewable => status == ModelStatus.succeeded && glbUrl != null;

  /// Parses the STAFF shape (`/admin/projects/:id/models` items), where the
  /// URLs live under `artifacts`.
  static ProjectModelView? tryFromStaffMap(Object? raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString();
    if (id.isEmpty) return null;
    final artifacts = raw['artifacts'];
    return ProjectModelView(
      id: id,
      source: ModelSource.parse(raw['source']),
      status: ModelStatus.parse(raw['status']),
      glbUrl: artifacts is Map ? artifacts['glb'] as String? : null,
      previewUrl: artifacts is Map ? artifacts['preview'] as String? : null,
      approved: raw['approved'] != null,
      selectedKeys: [
        if (raw['selectedKeys'] case final List keys)
          for (final k in keys) k.toString(),
      ],
      // A malformed timestamp yields null rather than throwing — a history row
      // that can't be labelled is still worth showing.
      createdAt: DateTime.tryParse((raw['createdAt'] ?? '').toString()),
      error: ModelError.tryParse(raw['error']),
    );
  }

  /// Parses the OWNER shape (`GET /projects/:id` → `model`), which is flat and
  /// only ever describes a finished model.
  static ProjectModelView? tryFromOwnerMap(Object? raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString();
    final glb = (raw['glbUrl'] ?? '').toString();
    if (id.isEmpty || glb.isEmpty) return null;
    return ProjectModelView(
      id: id,
      source: ModelSource.parse(raw['source']),
      // The owner endpoint only ever returns a SUCCEEDED model.
      status: ModelStatus.succeeded,
      glbUrl: glb,
      previewUrl: raw['previewUrl'] as String?,
      approved: raw['approved'] == true,
      createdAt: DateTime.tryParse((raw['createdAt'] ?? '').toString()),
      // NO `error` here, deliberately: the owner endpoint only ever returns a
      // SUCCEEDED model, so parsing one would only invite leaking a failure
      // (and the staff copy that goes with it) onto the owner's surface.
    );
  }
}
