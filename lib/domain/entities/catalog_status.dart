// lib/domain/entities/catalog_status.dart

/// Whether the business's catalog is live for customers (feature 4).
///
/// State machine (server-owned — the client never transitions this itself):
///
///   draft ──publish──► published ◄──republish── unpublished
///                          └────unpublish─────────┘
///
/// [draft] is "never published"; [unpublished] is "was live, taken offline" —
/// and the two are NOT interchangeable, because an unpublished catalog keeps
/// its provisioned public URL and QR code while a draft has none yet.
///
/// Mirage itself has no published flag; this whole distinction lives on the
/// ReCapture side (see 02-feature-to-side-mapping.md, feature 4), which is why
/// it is the API's `status` string and not something derived from Mirage.
///
/// [unknown] is a defensive fallback for an unmapped backend value: a client
/// that is one deploy behind must render the catalog, not crash on it.
enum CatalogStatus { draft, published, unpublished, unknown }

extension CatalogStatusX on CatalogStatus {
  /// Human-readable label for status pills and the publish screen.
  String get label => switch (this) {
        CatalogStatus.draft => 'Draft',
        CatalogStatus.published => 'Published',
        CatalogStatus.unpublished => 'Unpublished',
        CatalogStatus.unknown => 'Unknown',
      };

  /// True when customers can reach the catalog right now.
  bool get isLive => this == CatalogStatus.published;

  /// API string value — must match the backend `CATALOG_STATUSES` exactly.
  String get apiValue => switch (this) {
        CatalogStatus.draft => 'DRAFT',
        CatalogStatus.published => 'PUBLISHED',
        CatalogStatus.unpublished => 'UNPUBLISHED',
        CatalogStatus.unknown => 'UNKNOWN',
      };

  /// Parses an API string. Case-insensitive; anything unrecognised becomes
  /// [CatalogStatus.unknown] rather than throwing.
  static CatalogStatus fromApiValue(String value) => switch (value.toUpperCase()) {
        'DRAFT' => CatalogStatus.draft,
        'PUBLISHED' => CatalogStatus.published,
        'UNPUBLISHED' => CatalogStatus.unpublished,
        _ => CatalogStatus.unknown,
      };
}
