// src/services/catalogImages.ts
//
// The shared half of the catalog image flow: validating a client-supplied key,
// and sweeping what a new one supersedes.
//
// Its own module rather than a helper inside catalogProductsService because both
// product images and catalog BRANDING (logo, cover) need it, and branding lives
// in catalogService — which catalogProductsService already imports. Putting the
// shared code in either of them would close an import cycle.
import type { Types } from 'mongoose';

import { env } from '@/config/env';
import { BUCKET_ARTIFACTS } from '@/config/s3';
import {
  deleteObject,
  deleteObjectsUnderPrefix,
  headObject,
  listObjectsUnderPrefix,
} from '@/services/s3ObjectStore';
import { parseProductImageKey, productImagePrefixOf } from '@/utils/productImageKeys';
import { s3EnvPrefix } from '@/utils/s3Keys';

/**
 * Why a client-supplied image key was refused. Each maps to its own status at
 * the route because each has a different fix: re-upload, pick a smaller image,
 * or "this is not yours".
 */
export type ImageKeyCheck =
  | { outcome: 'INVALID_KEY' }
  | { outcome: 'FORBIDDEN' }
  | { outcome: 'OBJECT_NOT_FOUND' }
  | { outcome: 'TOO_LARGE' }
  | { outcome: 'OK' };

/**
 * THE containment guard for every client-supplied image key.
 *
 * Four checks, in this order and for these reasons:
 *   1. the key parses as one of ours at all;
 *   2. its `catalogId` segment is the CALLER'S catalog — this is what stops one
 *      business pointing at another business's object, and it is why the key
 *      carries the catalog id in the first place;
 *   3. its env segment matches this deployment, so a staging client can never
 *      commit a prod key;
 *   4. the object exists and is within the size cap. Presigning cannot enforce a
 *      size, so the cap is enforced HERE, exactly as AVATAR_MAX_BYTES is — and an
 *      over-cap object is deleted rather than left sitting in the bucket forever
 *      uncollected, because only a SUCCESSFUL commit runs a sweep.
 */
export async function checkCatalogImageKey(
  catalogId: Types.ObjectId,
  key: string
): Promise<ImageKeyCheck> {
  const parsed = parseProductImageKey(key);
  if (!parsed.ok) return { outcome: 'INVALID_KEY' };
  if (parsed.value.catalogId !== catalogId.toHexString()) return { outcome: 'FORBIDDEN' };
  if (parsed.value.env !== s3EnvPrefix()) return { outcome: 'INVALID_KEY' };

  const head = await headObject(BUCKET_ARTIFACTS, key);
  if (head.outcome === 'absent') return { outcome: 'OBJECT_NOT_FOUND' };
  if (head.contentLength > env.CATALOG_PRODUCT_IMAGE_MAX_BYTES) {
    await deleteObject(BUCKET_ARTIFACTS, key).catch(() => undefined);
    return { outcome: 'TOO_LARGE' };
  }

  return { outcome: 'OK' };
}

/**
 * Removes the objects a newly committed image supersedes.
 *
 * Sweeps the whole slot prefix rather than only the previous key, which also
 * collects the orphans left by presigned uploads the user abandoned before
 * committing. When the new key came from a DIFFERENT slot (a staged upload
 * replacing a bound one) the old slot is swept too — otherwise the previous
 * image would survive forever under a prefix nothing points at any more.
 *
 * The prefix is derived from the STORED key, never rebuilt from an entity id: a
 * product created from a staged upload has a slot that is not its own id.
 *
 * NEVER THROWS. Every caller runs this AFTER flipping its pointer, so a failure
 * here is an orphaned object, not a broken product — and must not fail a write
 * that has already succeeded.
 */
export async function sweepSupersededImages(
  newKey: string,
  previousKey?: string
): Promise<void> {
  const newPrefix = productImagePrefixOf(newKey);
  try {
    if (newPrefix) {
      const survivors = await listObjectsUnderPrefix(BUCKET_ARTIFACTS, newPrefix);
      await Promise.all(
        survivors
          .filter((object) => object.key !== newKey)
          .map((object) => deleteObject(BUCKET_ARTIFACTS, object.key))
      );
    }
    const oldPrefix = previousKey ? productImagePrefixOf(previousKey) : null;
    if (oldPrefix && oldPrefix !== newPrefix) {
      await deleteObjectsUnderPrefix(BUCKET_ARTIFACTS, oldPrefix);
    }
  } catch {
    /* best-effort: the pointer has already flipped */
  }
}
