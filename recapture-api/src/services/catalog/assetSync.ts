// src/services/catalog/assetSync.ts
//
// The real AssetUploader: preflight, then move the bytes (or the URL) that
// actually changed.
//
// THE SHAPE OF THE PROBLEM. Mirage keeps its OWN copy of every asset. ReCapture
// holds the GLB, the USDZ and the generated preview on BUCKET_ARTIFACTS behind
// its own CloudFront; Mirage's write endpoints take multipart bytes, buffer each
// part to local disk and `readFileSync` it into its own S3 (libs/s3.js). So
// publishing a 3D product means a 40–90 MiB object crossing the wire twice, into
// an instance that sleeps between requests. Everything below is about doing that
// as rarely as possible and, when it must happen, without holding the file in
// memory.
//
// THREE ECONOMIES, in order of how much they save:
//
//   1. THE PLANNER'S DIFF. An unchanged product is a SKIP and never reaches
//      here at all.
//   2. THE SLOT SELECTION (productSync.slotsForUpdate). A price edit asks for
//      zero slots; a new photo asks for `image` and leaves the model alone.
//   3. THE ETag CHECK BELOW. Same slot, same source, same bytes ⇒ nothing is
//      read and nothing is sent, even when the planner could not prove it.
//
// TWO TRANSFER MODES, one flag. `bytes` streams from S3 into the multipart body
// and works against Mirage as deployed. `url` hands Mirage the CloudFront URL
// and is enormously cheaper — but the CURRENT create-item/update-item handlers
// read files from `req.files` only and ignore a URL in the body, so it is inert
// until Mirage prompt M1 lands. Both are implemented so that flipping
// MIRAGE_ASSET_TRANSFER_MODE is a config change, not a rewrite.
import { PassThrough } from 'stream';

import { env } from '@/config/env';
import { getObjectStream } from '@/services/s3ObjectStore';
import type { MirageFileUpload } from '@/services/mirage';
import {
  preflightAssets,
  type PreflightedAsset,
} from '@/services/catalog/assetPreflight';
import type {
  AssetIdentityMap,
  AssetSlot,
  AssetSyncRequest,
  AssetSyncResult,
  AssetUploader,
  AssetUrlFields,
} from '@/services/catalog/assetUploader';
import type { PublishRunContext } from '@/services/catalog/publishExecutors';
import type { CatalogSnapshotProduct } from '@/services/catalog/publishSnapshot';

/** Which `assetUrls` key each slot maps to in URL mode. */
const URL_FIELD: Record<AssetSlot, keyof AssetUrlFields> = {
  image: 'imageUrl',
  object: 'objectUrl',
  objectIos: 'objectIosUrl',
};

/**
 * A multipart part that reads straight out of S3.
 *
 * `open()` is called by the multipart encoder at the moment the part is written,
 * and it is called AGAIN if the request is retried — which is exactly why it is
 * a factory and not a stream: a consumed stream cannot be replayed, and a
 * timeout mid-upload has to be able to restart the whole asset.
 *
 * ⚠ NOTHING HERE CONCATENATES. `getObjectStream` hands back the SDK's own
 * Readable; the encoder pipes it through. Peak memory is one chunk, whatever
 * the file weighs. `getObjectBytes` would be a one-line change here and would
 * quietly reintroduce the 90 MiB-in-RAM failure this module exists to avoid.
 */
function streamPart(asset: PreflightedAsset): MirageFileUpload {
  return {
    kind: 'stream',
    filename: asset.filename,
    contentType: asset.contentType,
    size: asset.size,
    open: () => {
      // Deliberately lazy AND synchronous-looking: the encoder needs a stream
      // NOW, and awaiting inside it would mean buffering the object first.
      // PassThrough bridges the async open into a stream the encoder can start
      // writing from immediately.
      const out = new PassThrough();
      void getObjectStream(asset.bucket, asset.key)
        .then((result) => {
          if (result.outcome === 'absent') {
            // Preflight HEADed it moments ago, so this is a genuine race with a
            // delete. Destroying the stream aborts the request, which the
            // executor classifies and the row records.
            out.destroy(new Error(`asset disappeared between preflight and transfer: ${asset.key}`));
            return;
          }
          result.body.on('error', (err) => out.destroy(err));
          result.body.pipe(out);
        })
        .catch((err: unknown) => out.destroy(err instanceof Error ? err : new Error(String(err))));
      return out;
    },
  };
}

/**
 * Logs a gap ONCE per run rather than once per product.
 *
 * A catalog of fifty image-only products would otherwise emit fifty identical
 * "no USDZ" lines, which is how a useful signal becomes noise nobody reads.
 */
function logOnce(context: PublishRunContext, key: string, message: string): void {
  if (context.loggedOnce.has(key)) return;
  context.loggedOnce.add(key);
  console.info(`[catalog] publish ${context.runId}: ${message}`);
}

/** iOS AR Quick Look needs a USDZ; a 3D product without one silently loses it. */
function noteMissingUsdz(product: CatalogSnapshotProduct, context: PublishRunContext): void {
  if (product.type !== 'THREE_D' || product.usdzUrl) return;
  logOnce(
    context,
    'usdz-missing',
    'at least one 3D product has no USDZ — those products publish without iOS AR Quick Look'
  );
}

export const assetSyncUploader: AssetUploader = async (
  request: AssetSyncRequest
): Promise<AssetSyncResult> => {
  const { product, slots, context } = request;
  noteMissingUsdz(product, context);

  if (slots.length === 0) return { outcome: 'READY', files: {}, identities: {} };

  const preflight = await preflightAssets(product, slots, product.publishedSnapshot?.assetIdentities);
  if (preflight.outcome === 'BLOCKED') return { outcome: 'BLOCKED', failure: preflight.failure };

  // The republish saving. An asset whose bytes are provably the ones Mirage
  // already holds is dropped here — before it is opened, let alone sent.
  const changed = preflight.assets.filter((asset) => !asset.unchanged);
  if (changed.length < preflight.assets.length) {
    logOnce(
      context,
      'assets-unchanged',
      'skipped re-uploading assets that Mirage already holds unchanged'
    );
  }

  const identities: AssetIdentityMap = {};
  for (const asset of preflight.assets) identities[asset.slot] = asset.identity;

  if (env.MIRAGE_ASSET_TRANSFER_MODE === 'url') {
    const urls: AssetUrlFields = {};
    for (const asset of changed) urls[URL_FIELD[asset.slot]] = asset.url;
    return { outcome: 'READY', files: {}, urls, identities };
  }

  const files: Partial<Record<AssetSlot, MirageFileUpload>> = {};
  for (const asset of changed) files[asset.slot] = streamPart(asset);
  return { outcome: 'READY', files, identities };
};
