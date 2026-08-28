// src/services/catalog/assetPreflight.ts
//
// Everything that can be known about a product's assets WITHOUT moving a byte:
// where each one lives, whether it is there, how big it is, and whether it is
// the same object we pushed last time.
//
// WHY IT IS A SEPARATE PASS. The alternative is discovering that a GLB is
// missing, or 140 MiB, after ninety seconds of upload into a Mirage instance
// that had to wake up first — and then discovering it again on every retry. A
// HEAD costs one round trip and answers all three questions. Failing here is
// free; failing after the upload is minutes of the user's time and a wasted
// multipart body on a sleeping tier.
//
// EVERY FAILURE HERE IS TERMINAL FOR THE ROW, NEVER RETRYABLE. A missing object,
// an oversize model and a content type that is not what the key promised do not
// heal by being attempted again — they need the user (or an operator) to do
// something. Reporting them as retryable would burn the job's whole attempt
// budget on a product that was never going to publish.
import { env } from '@/config/env';
import { BUCKET_ARTIFACTS, CLOUDFRONT_BASE } from '@/config/s3';
import { headObject } from '@/services/s3ObjectStore';
import type { AssetIdentity, AssetIdentityMap, AssetSlot } from '@/services/catalog/assetUploader';
import type { RowFailure } from '@/services/catalog/publishRunState';
import type { CatalogSnapshotProduct } from '@/services/catalog/publishSnapshot';
import { CatalogSyncErrorCode, syncFailure } from '@/services/catalog/publishSyncErrors';

/**
 * The content types each slot may legitimately hold.
 *
 * S3 reports whatever was set at PUT time, and the capture pipeline is the only
 * thing that writes these keys, so a mismatch means the product points at
 * something it should not — a preview where a model belongs, most likely. It is
 * a cheap sanity check against a class of bug that otherwise surfaces as a blank
 * card on a customer's phone.
 *
 * `application/octet-stream` is accepted everywhere because S3 stores it for
 * anything uploaded without an explicit type, which older artifacts were.
 */
const ACCEPTED_TYPES: Record<AssetSlot, readonly RegExp[]> = {
  object: [/^model\/gltf-binary$/i, /^application\/octet-stream$/i],
  objectIos: [/^model\/vnd\.usdz\+zip$/i, /^application\/octet-stream$/i],
  image: [/^image\//i, /^application\/octet-stream$/i],
};

/** The filename Mirage will build its S3 key around. */
const FILENAMES: Record<AssetSlot, string> = {
  object: 'model.glb',
  objectIos: 'model.usdz',
  image: 'image.jpg',
};

/** One asset, resolved and verified, ready to transfer. */
export interface PreflightedAsset {
  slot: AssetSlot;
  bucket: string;
  key: string;
  /** The public ReCapture URL — what `url` transfer mode sends. */
  url: string;
  size: number;
  contentType: string;
  filename: string;
  identity: AssetIdentity;
  /**
   * True when `publishedSnapshot` already records these exact bytes at this
   * exact source. THE SINGLE BIGGEST COST SAVER on a republish: an unchanged
   * 40 MiB model is not read, not uploaded, and not sent.
   */
  unchanged: boolean;
}

export type PreflightResult =
  | { outcome: 'OK'; assets: PreflightedAsset[] }
  | { outcome: 'BLOCKED'; failure: RowFailure };

/**
 * A ReCapture CloudFront URL back to the S3 key behind it.
 *
 * Every asset URL in the system is built as `${CLOUDFRONT_BASE}/${key}` — by
 * the capture engine, the Meshy processor and the optimizer alike — so this is
 * the exact inverse and not a guess. A URL on any other host is NOT ours and
 * returns null: it is either a Meshy link that escaped the re-host (which
 * productSync refuses outright) or a hand-edited row, and in both cases the
 * right answer is to refuse rather than to fetch from a stranger.
 */
export function keyFromCdnUrl(url: string): string | null {
  const prefix = `${CLOUDFRONT_BASE}/`;
  if (!url.startsWith(prefix)) return null;
  const key = url.slice(prefix.length);
  return key.length > 0 ? key : null;
}

/** Where each slot's bytes live for this product. */
function sourceFor(
  product: CatalogSnapshotProduct,
  slot: AssetSlot
): { key: string; url: string } | null {
  if (slot === 'object') {
    const key = product.glbUrl ? keyFromCdnUrl(product.glbUrl) : null;
    return key && product.glbUrl ? { key, url: product.glbUrl } : null;
  }
  if (slot === 'objectIos') {
    const key = product.usdzUrl ? keyFromCdnUrl(product.usdzUrl) : null;
    return key && product.usdzUrl ? { key, url: product.usdzUrl } : null;
  }

  // The image slot has two sources and they are mutually exclusive by product
  // type: a 3D product's card picture is its GENERATED thumbnail (feature 8d/51)
  // and an image-only product's is the photo the user committed. The key space
  // differs — the thumbnail arrives as a CDN URL, the photo as a raw S3 key —
  // which is why this branch exists at all.
  if (product.type === 'THREE_D') {
    const key = product.thumbnailUrl ? keyFromCdnUrl(product.thumbnailUrl) : null;
    return key && product.thumbnailUrl ? { key, url: product.thumbnailUrl } : null;
  }
  return product.imageKey
    ? { key: product.imageKey, url: `${CLOUDFRONT_BASE}/${product.imageKey}` }
    : null;
}

function typeAccepted(slot: AssetSlot, contentType: string): boolean {
  return ACCEPTED_TYPES[slot].some((pattern) => pattern.test(contentType));
}

/**
 * Is this the same object, byte for byte, as the one recorded in
 * `publishedSnapshot`?
 *
 * ETag first, because it is exact and it catches the case a URL comparison
 * cannot: a key OVERWRITTEN IN PLACE (a re-optimized model written back over
 * its own key) has the same URL and different bytes. When S3 gave us no ETag —
 * or the snapshot predates the field — the answer is NO, and the asset is
 * re-pushed. Erring toward an extra upload is the right direction; erring the
 * other way publishes a product whose model is silently a version behind.
 */
function isUnchanged(previous: AssetIdentity | undefined, current: AssetIdentity): boolean {
  if (!previous) return false;
  if (previous.source !== current.source) return false;
  if (!previous.etag || !current.etag) return false;
  return previous.etag === current.etag;
}

/**
 * HEADs every requested slot and reports what the transfer can rely on.
 *
 * ⚠ THE THUMBNAIL RULE. A 3D product with no image is a blank card on the
 * public page — the model streams in over seconds and there is nothing to look
 * at meanwhile — so a THREE_D product whose thumbnail is still being generated
 * is BLOCKED rather than published half-dressed. That is a deliberate refusal,
 * not an oversight: the user is told to wait, which is recoverable, instead of
 * being given a live page that looks broken.
 */
export async function preflightAssets(
  product: CatalogSnapshotProduct,
  slots: readonly AssetSlot[],
  published: AssetIdentityMap | undefined
): Promise<PreflightResult> {
  const assets: PreflightedAsset[] = [];

  for (const slot of slots) {
    const source = sourceFor(product, slot);
    if (!source) {
      // The plan asked for a slot this product cannot fill. For the image slot
      // on a 3D product that is the missing-thumbnail case above; for the model
      // slots the planner would not have asked, so it means the row lost its
      // asset between the snapshot and now.
      return {
        outcome: 'BLOCKED',
        failure: syncFailure(
          CatalogSyncErrorCode.ASSET_MISSING,
          slot === 'image' && product.type === 'THREE_D'
            ? "This product's preview image is still being generated. Try publishing again in a minute."
            : 'A file this product needs could not be found. Re-upload it, then publish again.'
        ),
      };
    }

    const head = await headObject(BUCKET_ARTIFACTS, source.key);
    if (head.outcome === 'absent') {
      return {
        outcome: 'BLOCKED',
        failure: syncFailure(CatalogSyncErrorCode.ASSET_MISSING),
      };
    }

    if (head.contentLength > env.MIRAGE_MAX_ASSET_BYTES) {
      // Rejected BEFORE the upload. Reaching Mirage's own 100 MB multer cap
      // costs the whole transfer first and comes back as an unclassifiable HTML
      // error page.
      return {
        outcome: 'BLOCKED',
        failure: syncFailure(CatalogSyncErrorCode.ASSET_TOO_LARGE),
      };
    }

    if (!typeAccepted(slot, head.contentType)) {
      return {
        outcome: 'BLOCKED',
        failure: syncFailure(CatalogSyncErrorCode.ASSET_UNSUPPORTED),
      };
    }

    const identity: AssetIdentity = {
      source: source.url,
      ...(head.etag ? { etag: head.etag } : {}),
      size: head.contentLength,
    };

    assets.push({
      slot,
      bucket: BUCKET_ARTIFACTS,
      key: source.key,
      url: source.url,
      size: head.contentLength,
      contentType: head.contentType,
      filename: FILENAMES[slot],
      identity,
      unchanged: isUnchanged(published?.[slot], identity),
    });
  }

  return { outcome: 'OK', assets };
}
