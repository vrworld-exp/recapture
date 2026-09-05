// src/services/catalog/assetUploader.ts
//
// The seam between "which product fields to push" (productSync, B2) and "get
// the bytes across" (assetSync, B3).
//
// WHY IT IS A SEAM AND NOT A FUNCTION CALL. Asset transfer is the expensive,
// failure-prone half of publishing: a 90 MB GLB read out of S3 and posted into
// Mirage's multer on a tier that sleeps. B2's product executor must be testable
// without any of that, and B3 must be able to change transfer strategy (bytes
// vs the M1 URL path) without touching the executor. So the executor asks for
// SLOTS and receives either the parts to attach or a terminal row failure, and
// never learns which mode produced them.
//
// The registry is the same module-level swap point as `setMirageClient` and
// `setPublishExecutors` — the pattern this codebase already uses instead of a
// DI container.
import type { MirageFileField, MirageFileUpload } from '@/services/mirage';
import type { PublishRunContext } from '@/services/catalog/publishExecutors';
import type { RowFailure } from '@/services/catalog/publishRunState';
import type { CatalogSnapshotProduct } from '@/services/catalog/publishSnapshot';

/**
 * Which of Mirage's three file slots a step needs filled.
 *
 * Named after Mirage's own multer field names (multer.js:15-19) rather than
 * after ReCapture's asset names, because that is the vocabulary both transfer
 * modes end up speaking: `object` is the GLB, `objectIos` the USDZ, `image` the
 * photo (a 3D product's generated thumbnail, an image-only product's picture).
 */
export type AssetSlot = MirageFileField;

/**
 * What the URL transfer mode sends instead of bytes.
 *
 * ⚠ NOT SUPPORTED BY MIRAGE TODAY. `create-item` overwrites `image`/`model`
 * with values computed from `req.files` and `update-item` only assigns from an
 * uploaded file, so a URL in the body is ignored
 * (adminController.js:1145-1177, 1478-1492). The field names below are the ones
 * Mirage prompt M1 proposes; the type exists so B3 can implement both paths and
 * flip between them with one config flag rather than a rewrite.
 */
export interface AssetUrlFields {
  imageUrl?: string;
  objectUrl?: string;
  objectIosUrl?: string;
}

/**
 * How an asset was identified when it was last pushed, recorded into
 * `publishedSnapshot` so the next run can answer "are these the same bytes?"
 * exactly rather than by comparing URLs that never change when a key is
 * overwritten in place.
 */
export interface AssetIdentity {
  /** The ReCapture URL or S3 key the bytes came from. */
  source: string;
  /** S3 ETag, when the store gave us one. */
  etag?: string;
  size?: number;
}

export type AssetIdentityMap = Partial<Record<AssetSlot, AssetIdentity>>;

export interface AssetSyncRequest {
  product: CatalogSnapshotProduct;
  /**
   * The slots this step wants pushed. A CREATE asks for everything the product
   * has; an UPDATE asks only for the slots whose source actually changed, which
   * is what keeps a price edit from re-uploading a 40 MB model.
   */
  slots: readonly AssetSlot[];
  context: PublishRunContext;
}

/**
 * READY carries what to attach; BLOCKED is a TERMINAL row failure.
 *
 * Blocked rather than thrown on purpose: a missing or oversize asset is this
 * product's problem and nobody else's, and the run must record it and move on
 * (the per-row isolation guarantee). B3's preflight is what produces it, before
 * a single byte is read.
 */
export type AssetSyncResult =
  | {
      outcome: 'READY';
      files: Partial<Record<AssetSlot, MirageFileUpload>>;
      urls?: AssetUrlFields;
      /** Merged into `publishedSnapshot` after a successful push. */
      identities: AssetIdentityMap;
    }
  | { outcome: 'BLOCKED'; failure: RowFailure };

export type AssetUploader = (request: AssetSyncRequest) => Promise<AssetSyncResult>;

/**
 * The B2 default: attach nothing, block nothing.
 *
 * A product still publishes — its name, price, description and category all
 * reach Mirage — it just arrives without its picture or its model. That is the
 * correct degradation for a half-built feature: the text half of the publish is
 * genuinely exercised end to end, and B3 turns the asset half on by registering
 * a real implementation. A default that threw would make B2's own tests depend
 * on B3 existing.
 */
const noopUploader: AssetUploader = async () => ({
  outcome: 'READY',
  files: {},
  identities: {},
});

let uploader: AssetUploader = noopUploader;

export function getAssetUploader(): AssetUploader {
  return uploader;
}

export function setAssetUploader(next: AssetUploader): void {
  uploader = next;
}

/** Back to the no-op. Call in a test's `afterEach`. */
export function resetAssetUploader(): void {
  uploader = noopUploader;
}
