// lib/domain/catalog/publish_status.dart
//
// `GET /catalog/publish/status`, parsed (features 37, 38, 52, 68).
//
// SERVER TRUTH, ALL OF IT. Nothing in these types is derived from anything the
// client holds, which is what lets a phone and a tablet polling the same run
// show the identical "7 of 10 published". The client keeps NO publish state of
// its own — it has no way to know whether the worker finished a row between two
// polls, and a locally-advanced counter would be a lie the moment the run
// partially fails.
//
// ONE PARSING DECISION IS LOAD-BEARING: the per-product and per-run `message`
// fields in the payload are DELIBERATELY NOT READ. Only the `code` is, and the
// sentence comes from `sync_error_copy.dart`. That is what makes "no raw Mirage
// prose can reach the UI" a property of the code rather than a rule somebody
// has to keep remembering — there is no field the text could arrive in.
import '../entities/catalog_json.dart';
import '../entities/catalog_status.dart';
import '../entities/product_sync_status.dart';
import '../entities/product_type.dart';
import 'publish_gate.dart';
import 'sync_error_copy.dart';

/// How a publish run ended, or that it has not.
///
/// [partial] is the state this whole screen is designed around: publishing ten
/// products is ten sequential uploads against a server that may be waking from
/// a sleeping tier, so some succeeding and some not is the EXPECTED outcome,
/// not the exceptional one. The successes really are live (the catalog stays
/// PUBLISHED and the QR works) while `publishedRevision` is not advanced — so
/// "draft changes not yet live" is simultaneously true.
enum PublishRunState { queued, running, succeeded, partial, failed, unknown }

extension PublishRunStateX on PublishRunState {
  /// Must match the backend `PUBLISH_RUN_STATES` exactly.
  String get apiValue => switch (this) {
        PublishRunState.queued => 'QUEUED',
        PublishRunState.running => 'RUNNING',
        PublishRunState.succeeded => 'SUCCEEDED',
        PublishRunState.partial => 'PARTIAL',
        PublishRunState.failed => 'FAILED',
        PublishRunState.unknown => 'UNKNOWN',
      };

  static PublishRunState fromApiValue(String value) =>
      switch (value.toUpperCase()) {
        'QUEUED' => PublishRunState.queued,
        'RUNNING' => PublishRunState.running,
        'SUCCEEDED' => PublishRunState.succeeded,
        'PARTIAL' => PublishRunState.partial,
        'FAILED' => PublishRunState.failed,
        _ => PublishRunState.unknown,
      };

  /// The run is still moving — keep polling.
  ///
  /// [PublishRunState.unknown] counts as IN FLIGHT on purpose. A state this
  /// build does not recognise is far more likely to be a new in-progress state
  /// than a new terminal one, and the cost of being wrong is asymmetric: a few
  /// extra polls against a finished run, versus a progress bar frozen forever
  /// on a run that is still going.
  bool get isInFlight =>
      this == PublishRunState.queued ||
      this == PublishRunState.running ||
      this == PublishRunState.unknown;

  bool get isTerminal => !isInFlight;

  String get label => switch (this) {
        PublishRunState.queued => 'Queued',
        PublishRunState.running => 'Publishing…',
        PublishRunState.succeeded => 'Published',
        PublishRunState.partial => 'Partly published',
        PublishRunState.failed => 'Publish failed',
        PublishRunState.unknown => 'Publishing…',
      };
}

/// What a run was asked to do. Fixed for the run's lifetime by the endpoint
/// that enqueued it.
enum PublishMode { full, retryFailed, unpublish, unknown }

extension PublishModeX on PublishMode {
  String get apiValue => switch (this) {
        PublishMode.full => 'FULL',
        PublishMode.retryFailed => 'RETRY_FAILED',
        PublishMode.unpublish => 'UNPUBLISH',
        PublishMode.unknown => 'UNKNOWN',
      };

  static PublishMode fromApiValue(String value) => switch (value.toUpperCase()) {
        'FULL' => PublishMode.full,
        'RETRY_FAILED' => PublishMode.retryFailed,
        'UNPUBLISH' => PublishMode.unpublish,
        _ => PublishMode.unknown,
      };

  /// Taking the catalog offline reads nothing like putting it online, so the
  /// screen must never describe one as the other.
  bool get isUnpublish => this == PublishMode.unpublish;
}

/// The headline numbers behind "7 of 10 published · 3 failed".
class PublishRunCounts {
  const PublishRunCounts({
    this.total = 0,
    this.synced = 0,
    this.failed = 0,
    this.skipped = 0,
  });

  final int total;
  final int synced;
  final int failed;

  /// Rows the planner decided not to touch. Counted separately from failures
  /// because a skip is not a problem the user has to fix.
  final int skipped;

  bool get hasFailures => failed > 0;

  /// How far along the run is, 0..1, or null when the total is not known yet
  /// (a QUEUED run before the planner has run). Null renders an indeterminate
  /// bar — a determinate one sitting at zero reads as "stuck".
  double? get progress {
    if (total <= 0) return null;
    return ((synced + failed + skipped) / total).clamp(0.0, 1.0);
  }

  factory PublishRunCounts.fromMap(Map<String, dynamic> map) =>
      PublishRunCounts(
        total: catalogCount(map['total']),
        synced: catalogCount(map['synced']),
        failed: catalogCount(map['failed']),
        skipped: catalogCount(map['skipped']),
      );
}

/// One publish run.
class PublishRun {
  const PublishRun({
    required this.id,
    required this.state,
    required this.mode,
    required this.counts,
    this.startedAt,
    this.finishedAt,
    this.errorCode,
  });

  final String id;
  final PublishRunState state;
  final PublishMode mode;
  final PublishRunCounts counts;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// A RUN-level failure code (as opposed to a per-row one). The sentence comes
  /// from [errorCopy]; the payload's own `message` is never read.
  final String? errorCode;

  bool get hasError => errorCode != null;

  /// OUR sentence for a run-level failure.
  SyncErrorCopy get errorCopy => syncErrorCopy(errorCode);

  factory PublishRun.fromMap(Map<String, dynamic> map) {
    final error = map['error'];
    return PublishRun(
      id: (map['id'] ?? '').toString(),
      state: PublishRunStateX.fromApiValue((map['state'] ?? '').toString()),
      mode: PublishModeX.fromApiValue((map['mode'] ?? '').toString()),
      counts: map['counts'] is Map<String, dynamic>
          ? PublishRunCounts.fromMap(map['counts'] as Map<String, dynamic>)
          : const PublishRunCounts(),
      startedAt: catalogDate(map['startedAt']),
      finishedAt: catalogDate(map['finishedAt']),
      // The code, and ONLY the code — see this file's header.
      errorCode: error is Map<String, dynamic>
          ? catalogText(error['code'])
          : null,
    );
  }
}

/// One product's standing in the run, as the per-product list renders it.
class PublishProductStatus {
  const PublishProductStatus({
    required this.id,
    required this.name,
    required this.type,
    required this.syncStatus,
    this.failureCode,
  });

  final String id;

  /// The product's own name — the OWNER's catalog content, not upstream text.
  final String name;

  final ProductType type;
  final ProductSyncStatus syncStatus;

  /// The `PUBLISH_*` code for the last failure, if any.
  final String? failureCode;

  bool get hasFailed => syncStatus.needsAttention;

  /// OUR sentence and next action for the failure. Derived from the code; the
  /// payload's `message` is deliberately never parsed, so upstream prose has no
  /// field to travel in.
  SyncErrorCopy get failureCopy => syncErrorCopy(failureCode);

  factory PublishProductStatus.fromMap(Map<String, dynamic> map) =>
      PublishProductStatus(
        id: (map['id'] ?? '').toString(),
        name: catalogText(map['name']) ?? 'Untitled product',
        type: ProductTypeX.fromApiValue((map['type'] ?? '').toString()),
        syncStatus:
            ProductSyncStatusX.fromApiValue((map['syncStatus'] ?? '').toString()),
        failureCode: catalogText(map['code']),
      );
}

/// The whole publish picture at one instant.
class PublishStatus {
  const PublishStatus({
    required this.status,
    required this.hasDraftChanges,
    required this.publicUrl,
    required this.lastPublishedAt,
    required this.activeRunId,
    required this.run,
    required this.products,
    required this.gates,
  });

  final CatalogStatus status;

  /// Feature 38 — "Draft changes not yet live". Server-DERIVED from the draft
  /// and published revision counters, never a stored flag and never something
  /// the client recomputes by diffing.
  final bool hasDraftChanges;

  /// The frozen public URL, or null before the first publish. Display only:
  /// every printed QR resolves through it, so the client never composes,
  /// normalises or rebuilds it.
  final String? publicUrl;

  final DateTime? lastPublishedAt;

  /// Non-null while a run holds the catalog.
  final String? activeRunId;

  /// The MOST RECENT run, in flight or not. Null before the first one.
  final PublishRun? run;

  /// Every live product with its sync standing.
  final List<PublishProductStatus> products;

  /// What would block a publish right now — the same set `POST /publish`
  /// evaluates, so the checklist cannot disagree with the button.
  final List<PublishGate> gates;

  /// A run is holding the catalog right now.
  bool get isPublishing => activeRunId != null;

  /// Whether Publish is worth offering. The server re-checks all of it; this
  /// only avoids a press that is guaranteed to come back 422 or 409.
  bool get canPublish => !isPublishing && gates.isEmpty;

  bool get isLive => status.isLive;

  /// The catalog has a minted URL, so the QR is worth printing — even while
  /// unpublished, because unpublishing keeps both alive (feature 39).
  bool get hasPublicUrl => (publicUrl?.isNotEmpty ?? false);

  /// Rows the user has to act on. Drives the failure list and "Retry failed".
  List<PublishProductStatus> get failures =>
      [for (final product in products) if (product.hasFailed) product];

  List<PublishProductStatus> get published =>
      [for (final product in products) if (product.syncStatus == ProductSyncStatus.synced) product];

  Map<String, List<PublishGate>> get gatesByProduct => gatesByProductId(gates);

  List<PublishGate> get catalogGates => catalogLevelGates(gates);

  factory PublishStatus.fromMap(Map<String, dynamic> map) {
    final run = map['run'];
    final products = map['products'];
    return PublishStatus(
      status: CatalogStatusX.fromApiValue((map['status'] ?? '').toString()),
      // Absent means "we cannot tell" → assume there ARE unpublished changes.
      // Wrongly hiding the badge tells the user their edits are live when they
      // are not; wrongly showing it costs one redundant publish. Same rule as
      // Catalog.hasUnpublishedChanges.
      hasDraftChanges: map['hasDraftChanges'] != false,
      publicUrl: catalogText(map['publicUrl']),
      lastPublishedAt: catalogDate(map['lastPublishedAt']),
      activeRunId: catalogText(map['activeRunId']),
      run: run is Map<String, dynamic> ? PublishRun.fromMap(run) : null,
      products: [
        if (products is List)
          for (final item in products)
            if (item is Map<String, dynamic>)
              PublishProductStatus.fromMap(item),
      ],
      gates: PublishGate.listFrom(map['gates']),
    );
  }
}
