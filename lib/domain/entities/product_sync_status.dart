// lib/domain/entities/product_sync_status.dart

/// How one product or category stands against the live Mirage catalog
/// (feature 52).
///
/// The meaning is precise and worth keeping precise: [synced] means *Mirage
/// matches the last published snapshot* — NOT "there is nothing to publish".
/// Editing a synced product does not move it back to [pending]; it bumps the
/// catalog's draft revision instead, and the publish planner re-plans it as an
/// update on the next run. So a product can be `synced` while the catalog still
/// shows "Draft changes not yet live", and both statements are true.
///
///   never ──publish──► pending ──► synced
///                         └──────► failed ──retry──► pending
///
/// [unknown] is the defensive fallback for an unmapped backend value.
enum ProductSyncStatus { never, pending, synced, failed, unknown }

extension ProductSyncStatusX on ProductSyncStatus {
  String get label => switch (this) {
        ProductSyncStatus.never => 'Not published',
        ProductSyncStatus.pending => 'Publishing…',
        ProductSyncStatus.synced => 'Live',
        ProductSyncStatus.failed => 'Failed',
        ProductSyncStatus.unknown => 'Unknown',
      };

  /// A publish run is working on this row right now.
  bool get isInProgress => this == ProductSyncStatus.pending;

  /// Needs the user's attention — the publish screen's "Retry failed" acts on
  /// exactly these rows.
  bool get needsAttention => this == ProductSyncStatus.failed;

  /// API string value — must match the backend `SYNC_STATUSES` exactly.
  String get apiValue => switch (this) {
        ProductSyncStatus.never => 'NEVER',
        ProductSyncStatus.pending => 'PENDING',
        ProductSyncStatus.synced => 'SYNCED',
        ProductSyncStatus.failed => 'FAILED',
        ProductSyncStatus.unknown => 'UNKNOWN',
      };

  static ProductSyncStatus fromApiValue(String value) => switch (value.toUpperCase()) {
        'NEVER' => ProductSyncStatus.never,
        'PENDING' => ProductSyncStatus.pending,
        'SYNCED' => ProductSyncStatus.synced,
        'FAILED' => ProductSyncStatus.failed,
        _ => ProductSyncStatus.unknown,
      };
}
