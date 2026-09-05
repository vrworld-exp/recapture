// lib/domain/catalog/sync_error_copy.dart
//
// THE BOUNDARY. One sentence and one next action per publish-failure code.
//
// A publish talks to Mirage, and Mirage's own error prose is written for
// whoever operates Mirage — not for a restaurant owner looking at their phone.
// The backend already refuses to pass it through: every upstream failure is
// mapped onto a ReCapture `PUBLISH_*` code before it is stored or returned
// (`recapture-api/src/services/catalog/publishSyncErrors.ts`).
//
// This file makes the client's side of that guarantee STRUCTURAL rather than a
// promise. The status DTO carries both a `code` and a `message`, and the client
// deliberately parses ONLY THE CODE — see [PublishProductStatus]. A backend
// change, a proxy, a stubbed response, or a server one deploy ahead cannot put
// upstream text on this screen, because there is no field it could arrive in.
// The cost is one generic sentence for a code this build has never heard of,
// which is exactly what the backend's own `messageForSyncCode` falls back to.
//
// The wording mirrors the backend's table on purpose: improving one should
// improve the other, and the two are hand-synced (AGENTS.md §0.1).
//
// ⚠ F10 (the feedback layer) NOW OWNS THIS TABLE. Its entry point is
// `catalog_error_copy.dart`: one lookup — [catalogErrorCopy] — over two tables
// split by ORIGIN. These are a publish run's PER-ITEM codes, read out of stored
// rows; that file holds the HTTP ENVELOPE codes, which can arrive at any call
// site. The type is shared ([CatalogErrorCopy] is an alias of [SyncErrorCopy]),
// so the two cannot drift into different shapes, and one enumerating test
// (`test/catalog/feedback_test.dart`) covers both against the backend's own
// sources.
//
// Add a PUBLISH_* per-item code here; add anything the API can return in an
// envelope there.

/// One failure, as the user reads it: what happened, and what to do next.
class SyncErrorCopy {
  const SyncErrorCopy(this.message, this.action);

  /// One sentence. Never upstream prose.
  final String message;

  /// The next action, or null when there is nothing for the user to do but
  /// wait or retry — the retry button is already on the screen, and inventing
  /// an action for an outage is worse than admitting there is none.
  final String? action;
}

/// The generic fallback, for a code this build does not know.
///
/// Public so F10's enumerating test can tell a MAPPED code from one that fell
/// through to this — an unmapped publish code must fail CI, not quietly read as
/// "did not succeed".
const SyncErrorCopy kUnknownSyncErrorCopy = SyncErrorCopy(
  'Publishing this item did not succeed. Try again, or edit it and publish '
      'again.',
  null,
);

const Map<String, SyncErrorCopy> _copy = {
  'PUBLISH_DUPLICATE_NAME': SyncErrorCopy(
    'Another item in this catalog already uses this name.',
    'Rename it, then publish again.',
  ),
  'PUBLISH_RECONCILE_FAILED': SyncErrorCopy(
    'This item may already exist online under a different category.',
    'Rename it, then publish again.',
  ),
  'PUBLISH_CATEGORY_RECONCILE_FAILED': SyncErrorCopy(
    'A category with this name already exists online but could not be matched.',
    'Rename the category, then publish again.',
  ),
  'PUBLISH_CATEGORY_UNRESOLVED': SyncErrorCopy(
    "This product's category could not be published, so the product was "
        'skipped.',
    'Fix the category, then publish again.',
  ),
  'PUBLISH_CATEGORY_MISSING': SyncErrorCopy(
    'The category this product belongs to is no longer online.',
    'Publish again to recreate it.',
  ),
  'PUBLISH_RESTAURANT_UNRESOLVED': SyncErrorCopy(
    'Your catalog is not set up online yet.',
    'Publish again once that step succeeds.',
  ),
  'PUBLISH_RESTAURANT_MISSING': SyncErrorCopy(
    'Your online catalog could not be found.',
    'Contact support before publishing again.',
  ),
  'PUBLISH_ASSET_TOO_LARGE': SyncErrorCopy(
    'This file is too large to publish.',
    'Use a smaller model or image.',
  ),
  'PUBLISH_ASSET_MISSING': SyncErrorCopy(
    "One of this product's files is missing.",
    'Re-upload it, then publish again.',
  ),
  'PUBLISH_ASSET_UNSUPPORTED': SyncErrorCopy(
    "One of this product's files is not a supported format.",
    'Replace it, then publish again.',
  ),
  'PUBLISH_ASSET_NOT_INGESTED': SyncErrorCopy(
    'This product was published but its files did not transfer.',
    'Try again in a few minutes.',
  ),
  'PUBLISH_AUTH_REJECTED': SyncErrorCopy(
    'Publishing is temporarily unavailable. We have been notified.',
    null,
  ),
  'PUBLISH_UPSTREAM_TIMEOUT': SyncErrorCopy(
    'Publishing this item timed out.',
    'Try again in a few minutes.',
  ),
  'PUBLISH_UPSTREAM_UNAVAILABLE': SyncErrorCopy(
    'The catalog service is unavailable right now.',
    'Try again in a few minutes.',
  ),
  'PUBLISH_UPSTREAM_MALFORMED': SyncErrorCopy(
    'Publishing this item did not complete correctly.',
    'Try again.',
  ),
  'PUBLISH_NOT_CONFIGURED': SyncErrorCopy(
    'Publishing is not available on this app version.',
    'Contact support.',
  ),
  'PUBLISH_CATEGORY_MOVE_REJECTED': SyncErrorCopy(
    'This product could not be moved to its new category online.',
    'Try again, or move it back.',
  ),
  'PUBLISH_REJECTED': SyncErrorCopy(
    'The catalog service would not accept this item.',
    'Try again, or edit it and publish again.',
  ),
};

/// OUR sentence for a publish-failure [code].
///
/// Total by construction: an unrecognised code — an older build's, one added
/// after this release, or a corrupted value — degrades to
/// [kUnknownSyncErrorCopy] rather than showing the raw code to someone who has
/// no use for it.
SyncErrorCopy syncErrorCopy(String? code) {
  if (code == null || code.isEmpty) return kUnknownSyncErrorCopy;
  return _copy[code] ?? kUnknownSyncErrorCopy;
}
