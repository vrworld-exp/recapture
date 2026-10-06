// lib/domain/upload/pending_capture.dart
//
// Pure Dart — NO Flutter / IO. One record per capture that FINISHED (reached the
// Capture Summary) but whose upload the server has not yet confirmed. This is
// what lets several captures wait for upload at once: [ActiveSession] stays the
// single-slot pointer for a capture still being SHOT, and a finished capture
// moves out of that slot into one of these.
//
// SELF-CONTAINED ON PURPOSE. The per-level photo ledger the upload flow packs
// from lives in memory only (LevelCaptureLedgerRegistry) — it does not survive a
// restart. So a pending capture is packed into its upload bundle at SAVE time
// (CaptureBundlePacker → `<documents>/upload_workspace/bundles/<localId>/`), and
// this record carries everything the later upload needs: the bundle location,
// the per-ring counts the upload spec is built from, the mode/variant/size the
// job must declare, and the ids that make a retry idempotent.
//
// The bundle location is stored RELATIVE to the app documents directory, never
// absolute: on iOS the app container path changes when the app is updated, so
// an absolute path persisted before an update points at nothing afterwards.
//
// Persistence follows the repo convention: JSON in a `Box<String>` (no
// TypeAdapters). [fromJson] returns null on anything unreplayable and unknown
// enum values fall back safely, so a record written by a newer or older app
// version still parses (or is skipped) — it never crashes the list.

/// Where a pending capture is in its life. Wire names are persisted — do not
/// rename members without a migration.
enum PendingCaptureState {
  /// Captured and packed, not yet handed to the uploader (offline at save,
  /// waiting for Wi-Fi, or waiting for the user's tap).
  savedLocal,

  /// Handed to the uploader and waiting for a connection — mirrors
  /// `UploadJobState.offlineQueued`. Resumes automatically.
  waitingNetwork,

  /// The upload engine is running (uploading or retrying).
  uploading,

  /// A NON-network terminal failure. Needs the user's Retry (or Delete).
  failed,

  /// Finalize returned QUEUED. Transient: the record is deleted right after and
  /// the card shows the server status from then on.
  uploaded;

  String get wire => name;

  /// Unknown/absent → [savedLocal]: the safest reading of a record we cannot
  /// interpret is "on the phone, not uploaded" — it is neither dropped nor
  /// treated as done.
  static PendingCaptureState fromWire(Object? raw) =>
      PendingCaptureState.values.firstWhere(
        (s) => s.name == raw,
        orElse: () => PendingCaptureState.savedLocal,
      );
}

/// The current persisted shape. Bump only with a reader that still accepts the
/// older shapes (fields are added with defaults, never repurposed).
const int kPendingCaptureSchemaVersion = 1;

/// Folder (relative to the app documents directory) that holds every packed
/// upload bundle. Shared with the live upload flow's workspace.
const String kPendingBundlesRelDir = 'upload_workspace/bundles';

/// The default bundle location for [localId], relative to app documents.
String pendingBundleRelPathFor(String localId) =>
    '$kPendingBundlesRelDir/$localId';

class PendingCapture {
  const PendingCapture({
    required this.localId,
    required this.projectId,
    required this.ownerUserId,
    required this.projectName,
    required this.objectSize,
    required this.captureMode,
    required this.flowVariant,
    required this.frameCount,
    required this.byteCount,
    required this.state,
    required this.capturedAt,
    required this.updatedAt,
    required this.bundleRelPath,
    required this.perLevelCounts,
    this.uploadSessionId,
    this.lastErrorCode,
    this.attempts = 0,
    this.mobileDataApproved = false,
    this.userPaused = false,
    this.jobKeyGeneration = 0,
  });

  /// Stable for the record's whole life (a uuid). Keys the store, the card, and
  /// the idempotency keys of the upload — never changes.
  final String localId;

  /// The project this capture belongs to: a `pending_…` id while the project
  /// itself was created offline and is not yet on the server, then the server
  /// id once the offline outbox has reconciled it.
  final String projectId;

  /// The logged-in user who captured it. Every read filters on this, so another
  /// account on the same phone never sees, counts or uploads it.
  final String ownerUserId;

  final String projectName;

  /// `ObjectSize.apiValue` — what POST /jobs must declare (the server rejects a
  /// size that differs from the project's).
  final String objectSize;

  /// `CaptureMode.id` (`full` | `meshy`). A Meshy capture must upload as Meshy.
  final String captureMode;

  /// `CaptureFlowVariant.id` (`with_bottom` | `without_bottom`).
  final String flowVariant;

  /// Images in the packed bundle (the manifest is not counted).
  final int frameCount;

  /// On-disk footprint of the packed bundle — drives the Wi-Fi rule and the
  /// "about N MB" copy.
  final int byteCount;

  final PendingCaptureState state;

  /// The server job id once POST /jobs has answered — also the
  /// UploadQueueEntry / UploadProgressStore key, so a resume continues from the
  /// saved part ETags instead of starting a second job.
  final String? uploadSessionId;

  /// Mapped failure reason for the label (an `UploadErrorCategory.wireName` or
  /// a more specific pending-capture reason). Never a raw error.
  final String? lastErrorCode;

  /// Upload attempts started for this capture.
  final int attempts;

  final DateTime capturedAt;
  final DateTime updatedAt;

  /// The packed bundle folder, RELATIVE to the app documents directory (see the
  /// library doc for why it is never absolute).
  final String bundleRelPath;

  /// Ring name (`EYE`/`TOP`/`LOW`) → image count, exactly as the packer wrote
  /// them. The upload spec is rebuilt from this plus [bundleRelPath].
  final Map<String, int> perLevelCounts;

  /// The user confirmed uploading this capture over mobile data. Holds for the
  /// rest of this capture's upload, so a Wi-Fi → mobile switch mid-upload does
  /// not pause something the user already said yes to.
  final bool mobileDataApproved;

  /// The user pressed Pause. Never resumed automatically — connectivity, Wi-Fi
  /// or an app restart do not override it; only Resume does. Persisted here
  /// (not only on the upload queue entry) so it survives anything that
  /// rebuilds the queue.
  final bool userPaused;

  /// Bumped only by "Upload as new project" (the old project was deleted on
  /// the server). Part of [jobIdempotencyKey], so the new project's job gets a
  /// fresh key instead of a 409 for reusing the old one with a new body.
  final int jobKeyGeneration;

  /// The POST /jobs `Idempotency-Key` for this capture: STABLE across every
  /// attempt, restart and resume, so a retry after a lost response — or a
  /// relaunch mid-upload — replays the SAME job (and its saved part ETags)
  /// instead of creating a second one. Server rule: ≤ 128 chars of
  /// `[A-Za-z0-9_-]`; a uuid localId fits.
  String get jobIdempotencyKey => jobKeyFor(localId, jobKeyGeneration);

  /// [jobIdempotencyKey] for a capture not built yet (the Summary's online
  /// Upload knows the localId before the record exists).
  static String jobKeyFor(String localId, [int generation = 0]) =>
      generation == 0 ? 'capture-$localId' : 'capture-$localId-g$generation';

  /// True while the project is still the offline placeholder. The literal
  /// mirrors `kPendingProjectIdPrefix` (projects_notifier.dart), which the
  /// domain layer cannot import; `pending_capture_store_test.dart` pins the two
  /// together.
  bool get hasPendingProject => projectId.startsWith('pending_');

  bool get isMeshy => captureMode == 'meshy';

  PendingCapture copyWith({
    String? projectId,
    String? projectName,
    PendingCaptureState? state,
    String? uploadSessionId,
    bool clearUploadSessionId = false,
    String? lastErrorCode,
    bool clearLastErrorCode = false,
    int? attempts,
    DateTime? updatedAt,
    bool? mobileDataApproved,
    bool? userPaused,
    int? jobKeyGeneration,
  }) =>
      PendingCapture(
        localId: localId,
        projectId: projectId ?? this.projectId,
        ownerUserId: ownerUserId,
        projectName: projectName ?? this.projectName,
        objectSize: objectSize,
        captureMode: captureMode,
        flowVariant: flowVariant,
        frameCount: frameCount,
        byteCount: byteCount,
        state: state ?? this.state,
        uploadSessionId: clearUploadSessionId
            ? null
            : (uploadSessionId ?? this.uploadSessionId),
        lastErrorCode:
            clearLastErrorCode ? null : (lastErrorCode ?? this.lastErrorCode),
        attempts: attempts ?? this.attempts,
        capturedAt: capturedAt,
        updatedAt: updatedAt ?? this.updatedAt,
        bundleRelPath: bundleRelPath,
        perLevelCounts: perLevelCounts,
        mobileDataApproved: mobileDataApproved ?? this.mobileDataApproved,
        userPaused: userPaused ?? this.userPaused,
        jobKeyGeneration: jobKeyGeneration ?? this.jobKeyGeneration,
      );

  // ── persistence codec ─────────────────────────────────────────────────────

  Map<String, Object?> toJson() => {
        'v': kPendingCaptureSchemaVersion,
        'localId': localId,
        'projectId': projectId,
        'ownerUserId': ownerUserId,
        'projectName': projectName,
        'objectSize': objectSize,
        'captureMode': captureMode,
        'flowVariant': flowVariant,
        'frameCount': frameCount,
        'byteCount': byteCount,
        'state': state.wire,
        if (uploadSessionId != null) 'uploadSessionId': uploadSessionId,
        if (lastErrorCode != null) 'lastErrorCode': lastErrorCode,
        'attempts': attempts,
        'capturedAt': capturedAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'bundleRelPath': bundleRelPath,
        'perLevelCounts': perLevelCounts,
        'mobileDataApproved': mobileDataApproved,
        'userPaused': userPaused,
        'jobKeyGeneration': jobKeyGeneration,
      };

  /// Strict on what makes the capture uploadable and attributable (ids, owner,
  /// at least one image); tolerant on everything else. Returns null — never
  /// throws — on a record that cannot be used.
  static PendingCapture? fromJson(Map<String, Object?> json) {
    final localId = json['localId'];
    final projectId = json['projectId'];
    final owner = json['ownerUserId'];
    if (localId is! String || localId.isEmpty) return null;
    if (projectId is! String || projectId.isEmpty) return null;
    // An unowned capture could be uploaded under whoever logs in next — never.
    if (owner is! String || owner.isEmpty) return null;

    final counts = <String, int>{};
    final rawCounts = json['perLevelCounts'];
    if (rawCounts is Map) {
      for (final e in rawCounts.entries) {
        final n = e.value;
        if (e.key is String && n is num && n > 0) {
          counts[e.key as String] = n.toInt();
        }
      }
    }
    final frameCount = _int(json['frameCount']) ??
        counts.values.fold<int>(0, (a, b) => a + b);

    final capturedAt =
        DateTime.tryParse('${json['capturedAt']}') ?? DateTime.now().toUtc();
    final bundleRel = json['bundleRelPath'];

    return PendingCapture(
      localId: localId,
      projectId: projectId,
      ownerUserId: owner,
      projectName: _str(json['projectName']) ?? '',
      objectSize: _str(json['objectSize']) ?? 'medium',
      captureMode: _str(json['captureMode']) ?? 'full',
      flowVariant: _str(json['flowVariant']) ?? 'with_bottom',
      frameCount: frameCount,
      byteCount: _int(json['byteCount']) ?? 0,
      state: PendingCaptureState.fromWire(json['state']),
      uploadSessionId: _str(json['uploadSessionId']),
      lastErrorCode: _str(json['lastErrorCode']),
      attempts: _int(json['attempts']) ?? 0,
      capturedAt: capturedAt,
      updatedAt: DateTime.tryParse('${json['updatedAt']}') ?? capturedAt,
      bundleRelPath: bundleRel is String && bundleRel.isNotEmpty
          ? bundleRel
          : pendingBundleRelPathFor(localId),
      perLevelCounts: counts,
      mobileDataApproved: json['mobileDataApproved'] == true,
      userPaused: json['userPaused'] == true,
      jobKeyGeneration: _int(json['jobKeyGeneration']) ?? 0,
    );
  }

  static String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

  static int? _int(Object? v) => v is num ? v.toInt() : null;
}

/// [captures] owned by [ownerUserId], oldest capture first — the order they are
/// listed in and drained in. A null/empty owner sees nothing.
List<PendingCapture> pendingCapturesOwnedBy(
  Iterable<PendingCapture> captures,
  String? ownerUserId,
) {
  if (ownerUserId == null || ownerUserId.isEmpty) return const [];
  return [
    for (final c in captures)
      if (c.ownerUserId == ownerUserId) c,
  ]..sort(comparePendingCapturesOldestFirst);
}

/// Oldest capture first; ties broken by [PendingCapture.localId] so the order
/// is total and stable across restarts.
int comparePendingCapturesOldestFirst(PendingCapture a, PendingCapture b) {
  final byTime = a.capturedAt.compareTo(b.capturedAt);
  return byTime != 0 ? byTime : a.localId.compareTo(b.localId);
}
