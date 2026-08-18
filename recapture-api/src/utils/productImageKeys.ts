// src/utils/productImageKeys.ts
//
// CANONICAL S3 key naming for CATALOG PRODUCT IMAGES — the single source of
// truth for building AND parsing every product-image key.
//
// A THIRD key space, deliberately separate from utils/s3Keys.ts (capture jobs)
// and utils/avatarKeys.ts (profile pictures), for the same reason those two are
// separate from each other: each has its own strict parser, and widening one to
// serve another is how a hostile key reaches a bucket it was never meant to.
//
// Key format (exact):
//   {env}/catalog/{catalogId}/products/{slotId}/{imageId}.{jpg|png|webp}
//
//   • {env} is CONFIG-DRIVEN via s3EnvPrefix() — IMPORTED from s3Keys.ts, never
//     re-derived here, so a staging deploy can never emit prod/... keys and the
//     NODE_ENV mapping lives in exactly one place. It is also the prefix-delete
//     firewall.
//   • {catalogId} is the ownership boundary. A catalog is 1:1 with a user, so
//     comparing this against the caller's own catalog is the whole containment
//     check — the commit route does exactly that.
//   • {slotId} groups one product's images and is the SWEEP boundary. It is the
//     product id once the product exists, and a fresh randomUUID() when the
//     image is uploaded BEFORE its product (feature 13 — an image-only product
//     is created WITH its committed image key, so the upload has to be able to
//     come first). The parser therefore validates its SHAPE, never its
//     existence: an id here is a grouping, not an authorization claim.
//   • {imageId} is a fresh randomUUID() per upload, so the key CHANGES on every
//     replacement. That buys cache-busting for free — this bucket is
//     CloudFront-fronted, and a stable key would serve the previous picture from
//     the edge for as long as the TTL says — and makes commit a pointer flip.
//
// BUCKET: BUCKET_ARTIFACTS, behind CloudFront — the OPPOSITE of the avatar
// decision, for the opposite reason. An avatar is a photograph of a person and
// lives in the private raw bucket behind short-lived presigned GETs; a product
// image is public catalog content that a customer's browser loads directly off
// the CDN. Putting product images in the private bucket would mean minting a
// presigned GET for every card in the grid.
//
// Every interpolated segment is validated before composition with the SAME
// discipline as the other two key spaces (no `/` or `\`, no whitespace or
// control characters, no leading dot — which also kills ".." — never empty), so
// a hostile value can neither traverse the hierarchy nor inject extra key
// levels. Builders THROW; the parser returns a discriminated failure, never a
// partial parse.
//
// SECURITY: parseProductImageKey is the containment guard for every route that
// accepts a client-supplied key. The client names the key at commit time, so the
// commit re-derives the caller's catalog from the token and compares it against
// the parsed catalogId. It is the security boundary of the whole product-image
// feature; tests/product-image-keys.test.ts covers it directly.
import { s3EnvPrefix, S3_ENV_PREFIXES, type S3EnvPrefix } from '@/utils/s3Keys';

/** The literal segments that namespace every product-image key. */
export const CATALOG_SEGMENT = 'catalog';
export const PRODUCTS_SEGMENT = 'products';

/** The image extensions a product-image key may carry — the set is closed. */
export const PRODUCT_IMAGE_EXTENSIONS = ['jpg', 'png', 'webp'] as const;
export type ProductImageExtension = (typeof PRODUCT_IMAGE_EXTENSIONS)[number];

/**
 * The upload content types we accept — a closed set. It is baked into the
 * presigned signature, so it also fixes what can ever be STORED at that key.
 *
 * webp is here and absent from the avatar set on purpose: a catalog grid loads
 * dozens of these over a phone connection, and webp is materially smaller.
 */
export const PRODUCT_IMAGE_CONTENT_TYPES = ['image/jpeg', 'image/png', 'image/webp'] as const;
export type ProductImageContentType = (typeof PRODUCT_IMAGE_CONTENT_TYPES)[number];

/** Content type → the extension its key carries. */
const EXT_BY_CONTENT_TYPE: Readonly<Record<ProductImageContentType, ProductImageExtension>> = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
};

/** The key extension for an accepted upload content type. */
export function productImageExtensionFor(
  contentType: ProductImageContentType
): ProductImageExtension {
  return EXT_BY_CONTENT_TYPE[contentType];
}

/** Thrown by the builders on any invalid segment — callers never receive a
 * malformed key. */
export class ProductImageKeyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ProductImageKeyError';
  }
}

/**
 * Allowed shape of ONE key segment — the same rule as the other two key spaces,
 * kept as its own const rather than shared so neither space can be loosened by a
 * change made for the other: starts alphanumeric (a leading dot, and therefore
 * "..", is rejected), then alphanumerics, dot, underscore, hyphen. Excludes `/`
 * and `\` (hierarchy injection), whitespace, and control characters.
 */
const SEGMENT_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

function requireSegment(name: string, value: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new ProductImageKeyError(`${name} must be a non-empty string`);
  }
  if (!SEGMENT_RE.test(value)) {
    throw new ProductImageKeyError(
      `${name} contains characters not allowed in an S3 key segment ` +
        `(allowed: alphanumeric start, then [A-Za-z0-9._-]): ${JSON.stringify(value)}`
    );
  }
  return value;
}

/**
 * Every object belonging to ONE catalog: `{env}/catalog/{catalogId}/products/`.
 *
 * The cleanup boundary for deleting a whole catalog. Deleting one PRODUCT sweeps
 * {@link buildProductImagePrefix} instead.
 */
export function buildCatalogProductsPrefix(catalogId: string): string {
  return `${s3EnvPrefix()}/${CATALOG_SEGMENT}/${requireSegment('catalogId', catalogId)}/${PRODUCTS_SEGMENT}/`;
}

/**
 * Every image under one slot: `{env}/catalog/{catalogId}/products/{slotId}/`.
 *
 * This is the per-product CLEANUP boundary — a successful commit wipes every
 * OTHER object under it rather than only the previously-committed key, which
 * self-heals the orphans left by presigned uploads the user abandoned. Derive it
 * from a stored key with {@link productImagePrefixOf} rather than reconstructing
 * it from a product id: a product created from a staged upload has a slot that
 * is NOT its own id.
 */
export function buildProductImagePrefix(catalogId: string, slotId: string): string {
  return `${buildCatalogProductsPrefix(catalogId)}${requireSegment('slotId', slotId)}/`;
}

/**
 * Full product-image key:
 * `{env}/catalog/{catalogId}/products/{slotId}/{imageId}.{jpg|png|webp}`.
 *
 * Round-trip guarantee: `parseProductImageKey(buildProductImageKey(c, s, i, e))`
 * returns exactly `{ env: s3EnvPrefix(), catalogId: c, slotId: s, imageId: i,
 * ext: e }`.
 */
export function buildProductImageKey(
  catalogId: string,
  slotId: string,
  imageId: string,
  ext: ProductImageExtension
): string {
  if (!(PRODUCT_IMAGE_EXTENSIONS as readonly string[]).includes(ext)) {
    throw new ProductImageKeyError(
      `ext must be one of ${PRODUCT_IMAGE_EXTENSIONS.join('/')}: ${JSON.stringify(ext)}`
    );
  }
  return `${buildProductImagePrefix(catalogId, slotId)}${requireSegment('imageId', imageId)}.${ext}`;
}

/** All segments of one canonical product-image key, exactly as they appear. */
export interface ParsedProductImageKey {
  env: S3EnvPrefix;
  catalogId: string;
  /** The grouping segment — a product id, or an upload-slot uuid. See the header. */
  slotId: string;
  imageId: string;
  ext: ProductImageExtension;
}

export type ParseProductImageKeyResult =
  | { ok: true; value: ParsedProductImageKey }
  | { ok: false; reason: string };

/**
 * STRICT parser for canonical product-image keys. Accepts ONLY the exact scheme
 * — six segments, a known env prefix, the two literal namespace segments, valid
 * id segments, and a single lowercase `.jpg`/`.png`/`.webp` — and returns a
 * discriminated failure (never a partial parse) otherwise.
 *
 * Note this does NOT check the env prefix against the CONFIGURED one: it reports
 * which env the key claims and the caller decides. The commit route rejects a
 * mismatch (a staging client must never commit a prod key) — keeping that check
 * at the call site is what makes the mismatch a distinguishable 422 rather than
 * an indistinguishable "malformed".
 */
export function parseProductImageKey(key: string): ParseProductImageKeyResult {
  const fail = (reason: string): ParseProductImageKeyResult => ({ ok: false, reason });
  if (typeof key !== 'string' || key.length === 0) {
    return fail('key must be a non-empty string');
  }

  const parts = key.split('/');
  if (parts.length !== 6) {
    return fail(
      'key must have exactly 6 segments: ' +
        '{env}/catalog/{catalogId}/products/{slotId}/{imageId}.{jpg|png|webp}'
    );
  }
  const [envSeg, catalogSeg, catalogId, productsSeg, slotId, fileSeg] = parts as [
    string,
    string,
    string,
    string,
    string,
    string,
  ];

  if (!(S3_ENV_PREFIXES as readonly string[]).includes(envSeg)) {
    return fail(
      `unknown env prefix ${JSON.stringify(envSeg)} (expected ${S3_ENV_PREFIXES.join('/')})`
    );
  }
  if (catalogSeg !== CATALOG_SEGMENT) {
    return fail(
      `expected literal ${JSON.stringify(CATALOG_SEGMENT)} as the 2nd segment, got ${JSON.stringify(catalogSeg)}`
    );
  }
  if (!SEGMENT_RE.test(catalogId)) {
    return fail(`invalid catalogId segment: ${JSON.stringify(catalogId)}`);
  }
  if (productsSeg !== PRODUCTS_SEGMENT) {
    return fail(
      `expected literal ${JSON.stringify(PRODUCTS_SEGMENT)} as the 4th segment, got ${JSON.stringify(productsSeg)}`
    );
  }
  if (!SEGMENT_RE.test(slotId)) {
    return fail(`invalid slotId segment: ${JSON.stringify(slotId)}`);
  }

  const dot = fileSeg.lastIndexOf('.');
  if (dot <= 0) {
    return fail(`filename must be {imageId}.{jpg|png|webp}: ${JSON.stringify(fileSeg)}`);
  }
  const imageId = fileSeg.slice(0, dot);
  const ext = fileSeg.slice(dot + 1);
  if (!(PRODUCT_IMAGE_EXTENSIONS as readonly string[]).includes(ext)) {
    return fail(
      `extension must be exactly one of ${PRODUCT_IMAGE_EXTENSIONS.join('/')} (lowercase): ${JSON.stringify(fileSeg)}`
    );
  }
  if (!SEGMENT_RE.test(imageId)) {
    return fail(`invalid imageId segment: ${JSON.stringify(fileSeg)}`);
  }

  return {
    ok: true,
    value: {
      env: envSeg as S3EnvPrefix,
      catalogId,
      slotId,
      imageId,
      ext: ext as ProductImageExtension,
    },
  };
}

/**
 * The branding slots a catalog has. These are the {slotId} values a logo and a
 * cover image live under, and they are RESERVED: a product can never be given
 * one, because a product's slot is either its own ObjectId or a randomUUID and
 * neither can collide with these literals.
 *
 * Branding shares the product key space rather than getting a fourth one because
 * it has identical properties — same bucket, same CloudFront fronting, same
 * ownership boundary (the catalogId segment), same immutable-object replacement.
 * A separate space would be a second parser to keep in step for no gain.
 */
export const BRANDING_SLOTS = ['logo', 'cover'] as const;
export type BrandingSlot = (typeof BRANDING_SLOTS)[number];

/** The key for one branding image. */
export function buildBrandingImageKey(
  catalogId: string,
  slot: BrandingSlot,
  imageId: string,
  ext: ProductImageExtension
): string {
  if (!(BRANDING_SLOTS as readonly string[]).includes(slot)) {
    throw new ProductImageKeyError(
      `slot must be one of ${BRANDING_SLOTS.join('/')}: ${JSON.stringify(slot)}`
    );
  }
  return buildProductImageKey(catalogId, slot, imageId, ext);
}

/**
 * The sweep prefix a stored key belongs to, or null when the key is not one of
 * ours.
 *
 * Always derive the prefix from the STORED KEY rather than rebuilding it from a
 * product id — a product created from a staged upload (feature 13) has a slot
 * that is not its own id, and rebuilding would sweep the wrong prefix, or none.
 */
export function productImagePrefixOf(key: string): string | null {
  const parsed = parseProductImageKey(key);
  if (!parsed.ok) return null;
  return `${parsed.value.env}/${CATALOG_SEGMENT}/${parsed.value.catalogId}/${PRODUCTS_SEGMENT}/${parsed.value.slotId}/`;
}
