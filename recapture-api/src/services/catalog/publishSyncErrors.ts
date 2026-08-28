// src/services/catalog/publishSyncErrors.ts
//
// Mirage's failures, translated into ReCapture's vocabulary — once, here.
//
// THE RULE (catalog.types.ts, SyncError): what lands on a row's `syncError`,
// in a run entry's `code`, or in any response body is an `UPPER_SNAKE`
// ReCapture code and OUR sentence. Mirage's prose is unversioned, untested,
// written for its own admin panel, and in several places is a copy-paste bug
// ("Only chef can access this api." from a handler guarding `role === "admin"`).
// It is a classification INPUT inside the adapter and it stops there.
//
// The adapter (mirageErrors.ts) has already decided WHAT KIND of failure this
// is. This module decides what to TELL THE USER about it, which is a different
// question and depends on what we were doing: a `MIRAGE_NOT_FOUND` while
// creating an item means the category is gone, while updating one means the
// item is gone, and those want different sentences and different repairs.
import { MirageError, MirageErrorCode } from '@/services/mirage';
import type { RowFailure } from '@/services/catalog/publishRunState';

/**
 * Stable codes a publish row can carry. The Flutter client switches on these,
 * so treat every value as part of the API contract.
 */
export const CatalogSyncErrorCode = {
  /** Mirage enforces per-restaurant name uniqueness and we could not adopt. */
  DUPLICATE_NAME: 'PUBLISH_DUPLICATE_NAME',
  /** Mirage said "already exists" but the entity was nowhere to be found. */
  RECONCILE_FAILED: 'PUBLISH_RECONCILE_FAILED',
  /** The same, for a category — a different repair, so a different sentence. */
  CATEGORY_RECONCILE_FAILED: 'PUBLISH_CATEGORY_RECONCILE_FAILED',
  /** The category this product belongs to has no Mirage id in this run. */
  CATEGORY_UNRESOLVED: 'PUBLISH_CATEGORY_UNRESOLVED',
  /** Mirage no longer has the category we tried to file this product under. */
  CATEGORY_MISSING: 'PUBLISH_CATEGORY_MISSING',
  /** The run reached a product before the restaurant existed. */
  RESTAURANT_UNRESOLVED: 'PUBLISH_RESTAURANT_UNRESOLVED',
  /** Mirage no longer has the restaurant this catalog is mapped to. */
  RESTAURANT_MISSING: 'PUBLISH_RESTAURANT_MISSING',
  /** Mirage refused the file for its size. Our preflight should catch it first. */
  ASSET_TOO_LARGE: 'PUBLISH_ASSET_TOO_LARGE',
  /** The asset this product points at is not in our bucket (any more). */
  ASSET_MISSING: 'PUBLISH_ASSET_MISSING',
  /** The stored object is not the kind of file this slot is supposed to hold. */
  ASSET_UNSUPPORTED: 'PUBLISH_ASSET_UNSUPPORTED',
  /**
   * URL transfer mode only: Mirage accepted the write but the stored URL still
   * points at OUR CDN, so it never fetched the asset. Almost certainly a Mirage
   * that predates M1 with MIRAGE_ASSET_TRANSFER_MODE switched on too early.
   */
  ASSET_NOT_INGESTED: 'PUBLISH_ASSET_NOT_INGESTED',
  /** Mirage rejected our credential. An operator has to fix it. */
  AUTH_REJECTED: 'PUBLISH_AUTH_REJECTED',
  /** Mirage did not answer in time. */
  UPSTREAM_TIMEOUT: 'PUBLISH_UPSTREAM_TIMEOUT',
  /** Mirage could not be reached, or answered 5xx. */
  UPSTREAM_UNAVAILABLE: 'PUBLISH_UPSTREAM_UNAVAILABLE',
  /** Mirage answered 2xx with a body we could not read. */
  UPSTREAM_MALFORMED: 'PUBLISH_UPSTREAM_MALFORMED',
  /** Mirage publishing is not configured on this deployment. */
  NOT_CONFIGURED: 'PUBLISH_NOT_CONFIGURED',
  /**
   * Mirage accepted the write but did not apply the category move we asked for.
   * Kept as an explicit failure rather than a silent no-op: the alternative is
   * reporting success while the product stays under the wrong tab forever.
   */
  CATEGORY_MOVE_REJECTED: 'PUBLISH_CATEGORY_MOVE_REJECTED',
  /** Anything else Mirage rejected as bad input. */
  REJECTED: 'PUBLISH_REJECTED',
} as const;

export type CatalogSyncErrorCodeValue =
  (typeof CatalogSyncErrorCode)[keyof typeof CatalogSyncErrorCode];

/** The sentence shown for each code. One place, so improving it improves history. */
const MESSAGES: Record<CatalogSyncErrorCodeValue, string> = {
  [CatalogSyncErrorCode.DUPLICATE_NAME]:
    'Another item in this catalog already uses this name. Rename it, then publish again.',
  [CatalogSyncErrorCode.RECONCILE_FAILED]:
    'This item may already exist online under a different category. Rename it, then publish again.',
  [CatalogSyncErrorCode.CATEGORY_RECONCILE_FAILED]:
    'A category with this name already exists online but could not be matched. Rename the category, then publish again.',
  [CatalogSyncErrorCode.CATEGORY_UNRESOLVED]:
    "This product's category could not be published, so the product was skipped. Fix the category and publish again.",
  [CatalogSyncErrorCode.CATEGORY_MISSING]:
    'The category this product belongs to is no longer online. Publish again to recreate it.',
  [CatalogSyncErrorCode.RESTAURANT_UNRESOLVED]:
    'Your catalog is not set up online yet. Publish again once that step succeeds.',
  [CatalogSyncErrorCode.RESTAURANT_MISSING]:
    'Your online catalog could not be found. Contact support before publishing again.',
  [CatalogSyncErrorCode.ASSET_TOO_LARGE]:
    'This file is too large to publish. Use a smaller model or image.',
  [CatalogSyncErrorCode.ASSET_MISSING]:
    "One of this product's files is missing. Re-upload it, then publish again.",
  [CatalogSyncErrorCode.ASSET_UNSUPPORTED]:
    "One of this product's files is not a supported format. Replace it, then publish again.",
  [CatalogSyncErrorCode.ASSET_NOT_INGESTED]:
    'This product was published but its files did not transfer. Try again in a few minutes.',
  [CatalogSyncErrorCode.AUTH_REJECTED]:
    'Publishing is temporarily unavailable. We have been notified — try again later.',
  [CatalogSyncErrorCode.UPSTREAM_TIMEOUT]:
    'Publishing this item timed out. Try again in a few minutes.',
  [CatalogSyncErrorCode.UPSTREAM_UNAVAILABLE]:
    'The catalog service is unavailable right now. Try again in a few minutes.',
  [CatalogSyncErrorCode.UPSTREAM_MALFORMED]:
    'Publishing this item did not complete correctly. Try again.',
  [CatalogSyncErrorCode.NOT_CONFIGURED]:
    'Publishing is not available on this app version. Contact support.',
  [CatalogSyncErrorCode.CATEGORY_MOVE_REJECTED]:
    'This product could not be moved to its new category online. Try again, or move it back.',
  [CatalogSyncErrorCode.REJECTED]:
    'The catalog service would not accept this item. Try again, or edit it and publish again.',
};

/**
 * The sentence for a stored code, resolved AT READ TIME.
 *
 * This is why the activity log stores only the code: improving a message here
 * improves every past run's history too, instead of freezing whatever wording
 * happened to be current the day a product failed. An unrecognised code (an
 * older build's, or one since removed) degrades to a generic sentence rather
 * than returning the raw code to a user, who has no use for it.
 */
export function messageForSyncCode(code: string): string {
  return (
    MESSAGES[code as CatalogSyncErrorCodeValue] ??
    'Publishing this item did not succeed. Try again, or edit it and publish again.'
  );
}

/** A failure with our code and our sentence. */
export function syncFailure(
  code: CatalogSyncErrorCodeValue,
  overrideMessage?: string
): RowFailure {
  return { code, message: overrideMessage ?? MESSAGES[code] };
}

/**
 * What a `MIRAGE_NOT_FOUND` means depends entirely on what we were doing.
 *
 * The adapter cannot tell us — its own comment says so: Mirage's global 404
 * handler emits a body containing "not found" too, so the code proves only that
 * SOMETHING was missing. The operation is the disambiguator, and it is the
 * caller's, not the classifier's.
 */
export type SyncOperation =
  | 'CREATE_CATEGORY'
  | 'UPDATE_CATEGORY'
  | 'CREATE_ITEM'
  | 'UPDATE_ITEM'
  | 'DELETE_ITEM'
  | 'LIST';

const NOT_FOUND_MEANS: Record<SyncOperation, CatalogSyncErrorCodeValue> = {
  // create-category's only parent is the restaurant.
  CREATE_CATEGORY: CatalogSyncErrorCode.RESTAURANT_MISSING,
  // update-category 404s on the category itself.
  UPDATE_CATEGORY: CatalogSyncErrorCode.CATEGORY_MISSING,
  // create-item checks the category first, then the restaurant; the category is
  // by far the likelier of the two to have vanished, because delete-item's
  // last-item cascade removes categories behind our back.
  CREATE_ITEM: CatalogSyncErrorCode.CATEGORY_MISSING,
  // update-item 404s on the item, and 400s "Category not found" on a bad move.
  UPDATE_ITEM: CatalogSyncErrorCode.CATEGORY_MISSING,
  // A delete of something already gone is handled as success before it gets here.
  DELETE_ITEM: CatalogSyncErrorCode.REJECTED,
  LIST: CatalogSyncErrorCode.RESTAURANT_MISSING,
};

/**
 * MirageError → the row's failure.
 *
 * `retryable` and `auth` failures never reach here in the normal path — the
 * processor rethrows them so the whole job backs off rather than blaming a
 * product for Mirage being asleep. They are mapped anyway so that a caller that
 * DOES choose to record one (the run's last attempt, say) still gets one of our
 * codes rather than a bare string.
 */
export function mapMirageFailure(error: MirageError, operation: SyncOperation): RowFailure {
  switch (error.code) {
    case MirageErrorCode.ALREADY_EXISTS:
      return syncFailure(CatalogSyncErrorCode.DUPLICATE_NAME);
    case MirageErrorCode.NOT_FOUND:
      return syncFailure(NOT_FOUND_MEANS[operation]);
    case MirageErrorCode.ASSET_TOO_LARGE:
      return syncFailure(CatalogSyncErrorCode.ASSET_TOO_LARGE);
    case MirageErrorCode.API_KEY_REJECTED:
    case MirageErrorCode.AUTH_REJECTED:
      return syncFailure(CatalogSyncErrorCode.AUTH_REJECTED);
    case MirageErrorCode.TIMEOUT:
      return syncFailure(CatalogSyncErrorCode.UPSTREAM_TIMEOUT);
    case MirageErrorCode.UNREACHABLE:
    case MirageErrorCode.SERVER_ERROR:
    case MirageErrorCode.RATE_LIMITED:
      return syncFailure(CatalogSyncErrorCode.UPSTREAM_UNAVAILABLE);
    case MirageErrorCode.MALFORMED_RESPONSE:
      return syncFailure(CatalogSyncErrorCode.UPSTREAM_MALFORMED);
    case MirageErrorCode.NOT_CONFIGURED:
      return syncFailure(CatalogSyncErrorCode.NOT_CONFIGURED);
    default:
      return syncFailure(CatalogSyncErrorCode.REJECTED);
  }
}

/** True when the caller should let the worker's backoff handle this instead. */
export function isRetryableMirageFailure(error: unknown): boolean {
  return error instanceof MirageError && error.isRetryable;
}
