// src/routes/catalog.ts
//
// The catalog authoring surface. Thin by convention: parse, delegate, map the
// service's discriminated result onto a status code. No business logic here.
//
// ⚠ ROUTE ORDER IS LOAD-BEARING. Express matches in declaration order, so every
// STATIC sub-path (`/products/reorder`, `/products/bulk`) must be declared
// BEFORE the parameterised `/products/:id`. Declared the other way round,
// `:id` swallows the literal string "reorder" and the request 400s on an
// invalid ObjectId — a bug that looks like a validation problem.
import { Router, raw } from 'express';
import { asyncHandler } from '@/utils/asyncHandler';
import { requireAuth } from '@/middleware/auth';
import { decodePositionCursor, type PositionCursor } from '@/utils/cursor';
import { hashIdentifier } from '@/utils/otp';
import { track, AnalyticsEvent } from '@/utils/analytics';
import {
  brandingCommitSchema,
  brandingUploadUrlSchema,
  bulkProductsSchema,
  catalogEntityIdParamsSchema,
  createCatalogSchema,
  createCategorySchema,
  createProductSchema,
  duplicateProductSchema,
  listProductsQuerySchema,
  productImageBytesQuerySchema,
  productImageCommitSchema,
  productImageUploadUrlSchema,
  reorderSchema,
  updateBusinessProfileSchema,
  updateCatalogSchema,
  updateCategorySchema,
  updateProductSchema,
} from '@/validation/catalogSchemas';
import {
  commitBrandingImage,
  createBrandingImageSlot,
  createCatalog,
  getBusinessProfile,
  getCatalog,
  updateBusinessProfile,
  updateCatalog,
} from '@/services/catalogService';
import {
  createCategory,
  deleteCategory,
  listCategories,
  reorderCategories,
  updateCategory,
} from '@/services/catalogCategoriesService';
import {
  bulkProducts,
  commitProductImage,
  createProduct,
  createProductImageSlot,
  deleteProduct,
  duplicateProduct,
  getProduct,
  listProducts,
  reorderProducts,
  setProductArchived,
  storeProductImageBytes,
  updateProduct,
} from '@/services/catalogProductsService';
import {
  PRODUCT_IMAGE_CONTENT_TYPES,
  type ProductImageContentType,
} from '@/utils/productImageKeys';
import { consumeRateWindow } from '@/utils/rateLimit';
import { env } from '@/config/env';
import type { Response } from 'express';
import type { ZodError } from 'zod';

const router = Router();

// Every route here requires a valid access token; ownership is derived from it
// and NEVER from the body or query.
router.use(requireAuth);

// ── Response helpers ────────────────────────────────────────────────────────
// One envelope, built in one place, so a new route cannot invent a shape.

function badRequest(res: Response, error: ZodError): void {
  const issue = error.issues[0];
  const field = issue?.path.join('.') || 'body';
  res.status(400).json({
    status: 'error',
    code: 'INVALID_REQUEST',
    message: issue?.message ?? 'Invalid request',
    fields: { [field]: issue?.message ?? 'invalid value' },
  });
}

function fail(res: Response, httpStatus: number, code: string, message: string): void {
  res.status(httpStatus).json({ status: 'error', code, message });
}

/**
 * The caller has no catalog yet. A 404 rather than an empty 200: "you have no
 * catalog" and "here is your empty catalog" are different states, and the
 * client's first-run flow branches on exactly this.
 */
function noCatalog(res: Response): void {
  fail(res, 404, 'CATALOG_NOT_FOUND', 'You do not have a catalog yet.');
}

/**
 * The one place a rejected image key becomes a response.
 *
 * Four distinct statuses rather than one, because each has a different fix and
 * the client shows a different next action: re-upload, pick a smaller file, or
 * "this is not yours". FORBIDDEN is the ONE place in this router that is not
 * enumeration-safe, and deliberately so — the key is a value the client already
 * holds, so a 403 leaks nothing it did not already know, and collapsing it into
 * 404 would leave a user with a valid image staring at "product not found".
 */
function failImageKey(
  res: Response,
  outcome: 'INVALID_KEY' | 'FORBIDDEN' | 'OBJECT_NOT_FOUND' | 'TOO_LARGE'
): void {
  switch (outcome) {
    case 'INVALID_KEY':
      return fail(res, 422, 'INVALID_KEY', 'That image key is not valid.');
    case 'FORBIDDEN':
      return fail(res, 403, 'FORBIDDEN', 'That image does not belong to this catalog.');
    case 'OBJECT_NOT_FOUND':
      return fail(res, 409, 'OBJECT_NOT_FOUND', 'Upload the image before saving it.');
    case 'TOO_LARGE':
      return fail(res, 413, 'PAYLOAD_TOO_LARGE', 'That image is too large. Please choose a smaller one.');
  }
}

// ── Catalog ─────────────────────────────────────────────────────────────────

/** GET /catalog — the caller's catalog, or 404 before they create one. */
router.get(
  '/',
  asyncHandler(async (req, res) => {
    const catalog = await getCatalog(req.user!.userId);
    if (!catalog) return noCatalog(res);

    res.status(200).json({ status: 'success', catalog });
  })
);

/**
 * POST /catalog — create the caller's catalog.
 *
 * Idempotent by design: a second call returns the existing catalog with 200
 * instead of a 409. One-per-user means a retry is a replay, and a client that
 * lost a response must be able to recover without special-casing an error.
 */
router.post(
  '/',
  asyncHandler(async (req, res) => {
    const parsed = createCatalogSchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const userId = req.user!.userId;
    const result = await createCatalog(userId, parsed.data);

    track(AnalyticsEvent.CATALOG_CREATED, {
      user_id_hash: hashIdentifier(userId),
      catalog_id: result.catalog.id,
      was_existing: result.outcome === 'ALREADY_EXISTS',
    });

    res
      .status(result.outcome === 'CREATED' ? 201 : 200)
      .json({ status: 'success', catalog: result.catalog });
  })
);

/** PATCH /catalog — update catalog metadata / business profile. */
router.patch(
  '/',
  asyncHandler(async (req, res) => {
    const parsed = updateCatalogSchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const userId = req.user!.userId;
    const result = await updateCatalog(userId, parsed.data);

    if (result.outcome === 'NOT_FOUND') return noCatalog(res);

    track(AnalyticsEvent.CATALOG_UPDATED, {
      user_id_hash: hashIdentifier(userId),
      catalog_id: result.catalog.id,
      fields: Object.keys(parsed.data),
    });

    res.status(200).json({ status: 'success', catalog: result.catalog });
  })
);

/**
 * POST /catalog/logo/upload-url — mint a presigned PUT slot for the logo or the
 * cover image (feature 2).
 *
 * One route with a `slot` field rather than two near-identical ones: they differ
 * only in which field the commit writes.
 */
router.post(
  '/logo/upload-url',
  asyncHandler(async (req, res) => {
    const parsed = brandingUploadUrlSchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const userId = req.user!.userId;
    const rate = await consumeRateWindow(
      `product-image-upload:${userId}`,
      env.PRODUCT_IMAGE_UPLOAD_MAX_PER_WINDOW,
      env.PRODUCT_IMAGE_UPLOAD_WINDOW_SECONDS
    );
    if (rate.limited) {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        message: 'Too many upload requests. Please try again later.',
        retryAfter: rate.retryAfter,
      });
      return;
    }

    const result = await createBrandingImageSlot(userId, parsed.data);
    if (result.outcome === 'NOT_FOUND') return noCatalog(res);

    res.status(200).json({ status: 'success', ...result.slot });
  })
);

/** PUT /catalog/logo — bind an uploaded object as the logo or cover. */
router.put(
  '/logo',
  asyncHandler(async (req, res) => {
    const parsed = brandingCommitSchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const userId = req.user!.userId;
    const result = await commitBrandingImage(userId, parsed.data);

    if (result.outcome === 'NOT_FOUND') return noCatalog(res);
    if (result.outcome !== 'COMMITTED') return failImageKey(res, result.outcome);

    track(AnalyticsEvent.CATALOG_UPDATED, {
      user_id_hash: hashIdentifier(userId),
      catalog_id: result.profile.id,
      fields: [parsed.data.slot],
    });

    res.status(200).json({ status: 'success', profile: result.profile });
  })
);

// ── Business profile (features 58, 60) ──────────────────────────────────────
//
// A profile-shaped VIEW of the same catalog document — there is no separate
// profile row, and `User` is deliberately not involved (it is near-PII-free and
// `GET /auth/me` is masked-only). The profile DTO carries `publicFields` so the
// client marks ReCapture-only fields from ONE source of truth instead of
// hardcoding Mirage's carried-field list.

/** GET /catalog/profile — the caller's business profile. */
router.get(
  '/profile',
  asyncHandler(async (req, res) => {
    const profile = await getBusinessProfile(req.user!.userId);
    if (!profile) return noCatalog(res);

    res.status(200).json({ status: 'success', profile });
  })
);

/**
 * PATCH /catalog/profile — edit the business profile.
 *
 * Bumps `draftRevision` like every other authoring write: branding reaches
 * customers only at publish (feature 59), so an edit here must light up the
 * "draft changes not yet live" badge (feature 38).
 */
router.patch(
  '/profile',
  asyncHandler(async (req, res) => {
    const parsed = updateBusinessProfileSchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const userId = req.user!.userId;
    const result = await updateBusinessProfile(userId, parsed.data);

    if (result.outcome === 'NOT_FOUND') return noCatalog(res);

    track(AnalyticsEvent.CATALOG_UPDATED, {
      user_id_hash: hashIdentifier(userId),
      catalog_id: result.profile.id,
      // Names only, never values — the profile holds phone/email/address.
      fields: Object.keys(parsed.data),
    });

    res.status(200).json({ status: 'success', profile: result.profile });
  })
);

// ── Categories ──────────────────────────────────────────────────────────────

router.get(
  '/categories',
  asyncHandler(async (req, res) => {
    const result = await listCategories(req.user!.userId);
    if (result.outcome === 'NO_CATALOG') return noCatalog(res);

    res.status(200).json({
      status: 'success',
      categories: result.categories,
      uncategorizedCount: result.uncategorizedCount,
    });
  })
);

router.post(
  '/categories',
  asyncHandler(async (req, res) => {
    const parsed = createCategorySchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const userId = req.user!.userId;
    const result = await createCategory(userId, parsed.data);

    if (result.outcome === 'NO_CATALOG') return noCatalog(res);
    if (result.outcome === 'DUPLICATE_NAME') {
      return fail(
        res,
        409,
        'DUPLICATE_NAME',
        'A category with that name already exists in your catalog.'
      );
    }

    track(AnalyticsEvent.CATALOG_CATEGORY_CREATED, {
      user_id_hash: hashIdentifier(userId),
      category_id: result.category.id,
    });

    res.status(201).json({ status: 'success', category: result.category });
  })
);

// STATIC before :id — see the file header.
router.post(
  '/categories/reorder',
  asyncHandler(async (req, res) => {
    const parsed = reorderSchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const result = await reorderCategories(req.user!.userId, parsed.data.ids);

    if (result.outcome === 'NO_CATALOG') return noCatalog(res);
    if (result.outcome === 'ID_SET_MISMATCH') {
      return fail(
        res,
        400,
        'ID_SET_MISMATCH',
        'Send every category id exactly once. Reload and try again.'
      );
    }

    res.status(200).json({ status: 'success', categories: result.categories });
  })
);

router.patch(
  '/categories/:id',
  asyncHandler(async (req, res) => {
    const params = catalogEntityIdParamsSchema.safeParse(req.params);
    if (!params.success) return badRequest(res, params.error);

    const parsed = updateCategorySchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const result = await updateCategory(req.user!.userId, params.data.id, parsed.data);

    if (result.outcome === 'NO_CATALOG') return noCatalog(res);
    if (result.outcome === 'NOT_FOUND') {
      return fail(res, 404, 'NOT_FOUND', 'Category not found.');
    }
    if (result.outcome === 'DUPLICATE_NAME') {
      return fail(
        res,
        409,
        'DUPLICATE_NAME',
        'A category with that name already exists in your catalog.'
      );
    }

    res.status(200).json({ status: 'success', category: result.category });
  })
);

router.delete(
  '/categories/:id',
  asyncHandler(async (req, res) => {
    const params = catalogEntityIdParamsSchema.safeParse(req.params);
    if (!params.success) return badRequest(res, params.error);

    const userId = req.user!.userId;
    const result = await deleteCategory(userId, params.data.id);

    if (result.outcome === 'NO_CATALOG') return noCatalog(res);
    if (result.outcome === 'NOT_FOUND') {
      return fail(res, 404, 'NOT_FOUND', 'Category not found.');
    }

    track(AnalyticsEvent.CATALOG_CATEGORY_DELETED, {
      user_id_hash: hashIdentifier(userId),
      category_id: params.data.id,
      moved_product_count: result.movedProductCount,
    });

    res.status(200).json({
      status: 'success',
      // The client shows "3 products moved to Uncategorized" — deleting a
      // grouping must never look like it deleted the things inside it.
      movedProductCount: result.movedProductCount,
    });
  })
);

// ── Products ────────────────────────────────────────────────────────────────

router.get(
  '/products',
  asyncHandler(async (req, res) => {
    const parsed = listProductsQuerySchema.safeParse(req.query);
    if (!parsed.success) return badRequest(res, parsed.error);

    // A tampered cursor is a 400, never a 500 or a silently wrong page.
    let cursor: PositionCursor | undefined;
    if (parsed.data.cursor !== undefined) {
      const decoded = decodePositionCursor(parsed.data.cursor);
      if (!decoded) {
        return fail(res, 400, 'INVALID_REQUEST', 'Invalid cursor');
      }
      cursor = decoded;
    }

    const userId = req.user!.userId;
    const result = await listProducts(userId, parsed.data, cursor);
    if (result.outcome === 'NO_CATALOG') return noCatalog(res);

    track(AnalyticsEvent.CATALOG_PRODUCTS_LISTED, {
      user_id_hash: hashIdentifier(userId),
      result_count: result.items.length,
      is_filtered: Boolean(
        parsed.data.categoryId || parsed.data.type || parsed.data.availability || parsed.data.q
      ),
    });

    res
      .status(200)
      .json({ status: 'success', items: result.items, nextCursor: result.nextCursor });
  })
);

router.post(
  '/products',
  asyncHandler(async (req, res) => {
    const parsed = createProductSchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const userId = req.user!.userId;
    const result = await createProduct(userId, parsed.data);

    switch (result.outcome) {
      case 'NO_CATALOG':
        return noCatalog(res);
      case 'CATEGORY_NOT_FOUND':
        return fail(res, 404, 'CATEGORY_NOT_FOUND', 'That category does not exist.');
      case 'MODEL_NOT_FOUND':
        // Not-owned and not-existing collapse into one answer — the
        // enumeration-safe rule. Never confirm someone else's model exists.
        return fail(res, 404, 'MODEL_NOT_FOUND', 'That 3D model was not found.');
      case 'MODEL_NOT_READY':
        return fail(
          res,
          409,
          'MODEL_NOT_READY',
          'That 3D model is not finished yet. Wait for it to complete, then try again.'
        );
      case 'DUPLICATE_NAME':
        return fail(
          res,
          409,
          'DUPLICATE_NAME',
          'A product with that name already exists in your catalog.'
        );
      case 'INVALID_KEY':
      case 'FORBIDDEN':
      case 'OBJECT_NOT_FOUND':
      case 'TOO_LARGE':
        return failImageKey(res, result.outcome);
      case 'CREATED':
        break;
    }

    track(AnalyticsEvent.CATALOG_PRODUCT_CREATED, {
      user_id_hash: hashIdentifier(userId),
      product_id: result.product.id,
      product_type: result.product.type,
      has_category: result.product.categoryId !== null,
    });

    res.status(201).json({ status: 'success', product: result.product });
  })
);

// STATIC before :id — see the file header.
router.post(
  '/products/reorder',
  asyncHandler(async (req, res) => {
    const parsed = reorderSchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const result = await reorderProducts(req.user!.userId, parsed.data.ids);

    if (result.outcome === 'NO_CATALOG') return noCatalog(res);
    if (result.outcome === 'ID_SET_MISMATCH') {
      return fail(
        res,
        400,
        'ID_SET_MISMATCH',
        'One or more products could not be reordered. Reload and try again.'
      );
    }

    res.status(200).json({ status: 'success', reordered: result.count });
  })
);

router.post(
  '/products/bulk',
  asyncHandler(async (req, res) => {
    const parsed = bulkProductsSchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const userId = req.user!.userId;
    const result = await bulkProducts(userId, parsed.data);

    if (result.outcome === 'NO_CATALOG') return noCatalog(res);
    if (result.outcome === 'CATEGORY_NOT_FOUND') {
      return fail(res, 404, 'CATEGORY_NOT_FOUND', 'That category does not exist.');
    }
    if (result.outcome === 'ID_SET_MISMATCH') {
      return fail(
        res,
        400,
        'ID_SET_MISMATCH',
        'One or more products could not be found. Reload and try again.'
      );
    }

    track(AnalyticsEvent.CATALOG_PRODUCTS_BULK_ACTION, {
      user_id_hash: hashIdentifier(userId),
      action: parsed.data.action,
      requested_count: parsed.data.ids.length,
      affected_count: result.affected,
    });

    res.status(200).json({ status: 'success', affected: result.affected });
  })
);

/**
 * POST /catalog/products/image/upload-url — mint ONE presigned PUT slot.
 *
 * STATIC, so it is declared before `/products/:id` per the file header.
 *
 * Stateless and cheap (a local SigV4 presign — no S3 call, no DB write), so it
 * carries its own generous rate window rather than anything heavier, exactly
 * like the avatar and model-image slots.
 *
 * The returned `url` is a WRITE bearer credential for that one key until
 * `expiresAt`: this response body is the ONLY place it may appear — never a log
 * line, never an analytics property.
 */
router.post(
  '/products/image/upload-url',
  asyncHandler(async (req, res) => {
    const parsed = productImageUploadUrlSchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const userId = req.user!.userId;
    const rate = await consumeRateWindow(
      `product-image-upload:${userId}`,
      env.PRODUCT_IMAGE_UPLOAD_MAX_PER_WINDOW,
      env.PRODUCT_IMAGE_UPLOAD_WINDOW_SECONDS
    );
    if (rate.limited) {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        message: 'Too many upload requests. Please try again later.',
        retryAfter: rate.retryAfter,
      });
      return;
    }

    const result = await createProductImageSlot(userId, parsed.data);
    if (result.outcome === 'NO_CATALOG') return noCatalog(res);
    if (result.outcome === 'NOT_FOUND') {
      return fail(res, 404, 'NOT_FOUND', 'Product not found.');
    }

    res.status(200).json({ status: 'success', ...result.slot });
  })
);

/**
 * POST /catalog/products/image/bytes — upload a product image in ONE call: the
 * raw image body goes to S3 server-side and the key it landed on comes back.
 * Feed that key to `POST /catalog/products` (image-only create) or to
 * `PUT /catalog/products/:id/image` (replace), exactly as if it had been
 * presigned.
 *
 * STATIC, so it is declared before `/products/:id` per the file header.
 *
 * WHY THIS EXISTS ALONGSIDE THE PRESIGNED SLOT. The three-step flow
 * (upload-url → PUT to S3 → commit) keeps image bytes off this API and is the
 * right shape for a native client. It cannot work from the BROWSER build: the
 * PUT is cross-origin to the artifacts bucket, which serves no CORS policy —
 * the same wall that forced `POST /auth/me/avatar/bytes` and the admin
 * photo-bytes proxy. A product image is a single ≤5 MiB file, so proxying it
 * costs little; this reasoning does NOT extend to capture uploads, which must
 * stay direct-to-S3.
 *
 * The body is the image itself (Content-Type: image/jpeg | image/png |
 * image/webp), not multipart — no parser dependency, and the type is
 * unambiguous.
 *
 * The declared Content-Type is NOT trusted: the magic bytes decide, so a
 * mislabelled body cannot store an object whose stored type lies about its
 * content.
 *
 * `productId` rides in the QUERY, not the body — the body is the image. It is
 * optional for the same reason it is optional on the slot route: an image-only
 * product is created WITH its key, so the upload comes first and the product
 * does not exist yet.
 */
router.post(
  '/products/image/bytes',
  // Only these types are parsed at all; anything else leaves req.body unset and
  // falls through to the 415 below. `limit` is the first line of defence on
  // size — the explicit check after it is the second.
  raw({
    type: [...PRODUCT_IMAGE_CONTENT_TYPES],
    limit: env.CATALOG_PRODUCT_IMAGE_MAX_BYTES,
  }),
  asyncHandler(async (req, res) => {
    const params = productImageBytesQuerySchema.safeParse(req.query);
    if (!params.success) return badRequest(res, params.error);

    const body: unknown = req.body;
    if (!Buffer.isBuffer(body) || body.length === 0) {
      return fail(
        res,
        415,
        'UNSUPPORTED_MEDIA_TYPE',
        'Send the image as a JPEG, PNG or WebP body.'
      );
    }
    if (body.length > env.CATALOG_PRODUCT_IMAGE_MAX_BYTES) {
      return fail(
        res,
        413,
        'PAYLOAD_TOO_LARGE',
        'That image is too large. Please choose a smaller one.'
      );
    }

    // The bytes, not the header, decide what this is.
    const sniffed = sniffProductImageContentType(body);
    if (sniffed === null) {
      return fail(
        res,
        415,
        'UNSUPPORTED_MEDIA_TYPE',
        'That file is not a JPEG, PNG or WebP.'
      );
    }

    const userId = req.user!.userId;
    // The same window as the presigned slot, and deliberately the SAME key:
    // the two routes are alternative spellings of one action, so a client
    // cannot double its budget by alternating between them.
    const rate = await consumeRateWindow(
      `product-image-upload:${userId}`,
      env.PRODUCT_IMAGE_UPLOAD_MAX_PER_WINDOW,
      env.PRODUCT_IMAGE_UPLOAD_WINDOW_SECONDS
    );
    if (rate.limited) {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        message: 'Too many upload requests. Please try again later.',
        retryAfter: rate.retryAfter,
      });
      return;
    }

    const result = await storeProductImageBytes(userId, {
      bytes: body,
      contentType: sniffed,
      productId: params.data.productId,
    });
    if (result.outcome === 'NO_CATALOG') return noCatalog(res);
    if (result.outcome === 'NOT_FOUND') {
      return fail(res, 404, 'NOT_FOUND', 'Product not found.');
    }

    res.status(200).json({ status: 'success', key: result.key });
  })
);

/**
 * JPEG/PNG/WebP by MAGIC BYTES, or null. Mirrors the client's sniffer exactly,
 * and the pair must not be able to disagree — the stored content type is
 * derived from this, and the key's extension from that.
 */
function sniffProductImageContentType(bytes: Buffer): ProductImageContentType | null {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return 'image/jpeg';
  }
  const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.length >= 8 && png.every((b, i) => bytes[i] === b)) return 'image/png';
  // RIFF....WEBP — the four size bytes at 4..7 are skipped on purpose.
  if (
    bytes.length >= 12 &&
    bytes.toString('ascii', 0, 4) === 'RIFF' &&
    bytes.toString('ascii', 8, 12) === 'WEBP'
  ) {
    return 'image/webp';
  }
  return null;
}

/**
 * PUT /catalog/products/:id/image — bind an uploaded object to a product
 * (features 13, 16).
 *
 * Separate from `PATCH /products/:id` on purpose: this one has to prove the
 * object exists and is within the size cap before it flips the pointer, and
 * folding that into the general field patch would mean every rename paid for an
 * S3 HEAD.
 */
router.put(
  '/products/:id/image',
  asyncHandler(async (req, res) => {
    const params = catalogEntityIdParamsSchema.safeParse(req.params);
    if (!params.success) return badRequest(res, params.error);

    const parsed = productImageCommitSchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const userId = req.user!.userId;
    const result = await commitProductImage(userId, params.data.id, parsed.data.key);

    if (result.outcome === 'NO_CATALOG') return noCatalog(res);
    if (result.outcome === 'NOT_FOUND') {
      return fail(res, 404, 'NOT_FOUND', 'Product not found.');
    }
    if (result.outcome !== 'COMMITTED') return failImageKey(res, result.outcome);

    track(AnalyticsEvent.CATALOG_PRODUCT_UPDATED, {
      user_id_hash: hashIdentifier(userId),
      product_id: result.product.id,
      fields: ['imageKey'],
    });

    res.status(200).json({ status: 'success', product: result.product });
  })
);

router.get(
  '/products/:id',
  asyncHandler(async (req, res) => {
    const params = catalogEntityIdParamsSchema.safeParse(req.params);
    if (!params.success) return badRequest(res, params.error);

    const result = await getProduct(req.user!.userId, params.data.id);

    if (result.outcome === 'NO_CATALOG') return noCatalog(res);
    if (result.outcome === 'NOT_FOUND') {
      return fail(res, 404, 'NOT_FOUND', 'Product not found.');
    }

    res.status(200).json({ status: 'success', product: result.product });
  })
);

router.patch(
  '/products/:id',
  asyncHandler(async (req, res) => {
    const params = catalogEntityIdParamsSchema.safeParse(req.params);
    if (!params.success) return badRequest(res, params.error);

    const parsed = updateProductSchema.safeParse(req.body);
    if (!parsed.success) return badRequest(res, parsed.error);

    const userId = req.user!.userId;
    const result = await updateProduct(userId, params.data.id, parsed.data);

    switch (result.outcome) {
      case 'NO_CATALOG':
        return noCatalog(res);
      case 'NOT_FOUND':
        return fail(res, 404, 'NOT_FOUND', 'Product not found.');
      case 'CATEGORY_NOT_FOUND':
        return fail(res, 404, 'CATEGORY_NOT_FOUND', 'That category does not exist.');
      case 'DUPLICATE_NAME':
        return fail(
          res,
          409,
          'DUPLICATE_NAME',
          'A product with that name already exists in your catalog.'
        );
      case 'MODEL_NOT_FOUND':
        // Not-owned and not-existing collapse into one answer — never confirm
        // someone else's model exists.
        return fail(res, 404, 'MODEL_NOT_FOUND', 'That 3D model was not found.');
      case 'MODEL_NOT_READY':
        return fail(
          res,
          409,
          'MODEL_NOT_READY',
          'That 3D model is not finished yet. Wait for it to complete, then try again.'
        );
      case 'INVALID_KEY':
      case 'FORBIDDEN':
      case 'OBJECT_NOT_FOUND':
      case 'TOO_LARGE':
        return failImageKey(res, result.outcome);
      case 'UPDATED':
        break;
    }

    track(AnalyticsEvent.CATALOG_PRODUCT_UPDATED, {
      user_id_hash: hashIdentifier(userId),
      product_id: result.product.id,
      fields: Object.keys(parsed.data),
    });

    res.status(200).json({ status: 'success', product: result.product });
  })
);

/**
 * POST /catalog/products/:id/duplicate (feature 18).
 *
 * The copy is auto-renamed unless the caller names it. That is not cosmetic:
 * Mirage keys items by name within a restaurant, so two products sharing a name
 * would collide at publish — long after the user pressed Duplicate.
 */
router.post(
  '/products/:id/duplicate',
  asyncHandler(async (req, res) => {
    const params = catalogEntityIdParamsSchema.safeParse(req.params);
    if (!params.success) return badRequest(res, params.error);

    const parsed = duplicateProductSchema.safeParse(req.body ?? {});
    if (!parsed.success) return badRequest(res, parsed.error);

    const userId = req.user!.userId;
    const result = await duplicateProduct(userId, params.data.id, parsed.data);

    if (result.outcome === 'NO_CATALOG') return noCatalog(res);
    if (result.outcome === 'NOT_FOUND') {
      return fail(res, 404, 'NOT_FOUND', 'Product not found.');
    }
    if (result.outcome === 'DUPLICATE_NAME') {
      return fail(
        res,
        409,
        'DUPLICATE_NAME',
        'A product with that name already exists in your catalog.'
      );
    }

    track(AnalyticsEvent.CATALOG_PRODUCT_CREATED, {
      user_id_hash: hashIdentifier(userId),
      product_id: result.product.id,
      product_type: result.product.type,
      has_category: result.product.categoryId !== null,
    });

    res.status(201).json({ status: 'success', product: result.product });
  })
);

router.delete(
  '/products/:id',
  asyncHandler(async (req, res) => {
    const params = catalogEntityIdParamsSchema.safeParse(req.params);
    if (!params.success) return badRequest(res, params.error);

    const userId = req.user!.userId;
    const result = await deleteProduct(userId, params.data.id);

    if (result.outcome === 'NO_CATALOG') return noCatalog(res);
    if (result.outcome === 'NOT_FOUND') {
      return fail(res, 404, 'NOT_FOUND', 'Product not found.');
    }

    track(AnalyticsEvent.CATALOG_PRODUCT_DELETED, {
      user_id_hash: hashIdentifier(userId),
      product_id: result.id,
      was_already_deleted: result.wasAlreadyDeleted,
    });

    res.status(200).json({ status: 'success', id: result.id });
  })
);

/**
 * POST /catalog/products/:id/archive and /restore.
 *
 * Two routes rather than a PATCH with a boolean: archiving a PUBLISHED product
 * removes it from the live customer-facing catalog on the next publish, and
 * that is worth an explicit verb the client cannot reach by accident while
 * editing a name.
 */
for (const [path, archived] of [
  ['/products/:id/archive', true],
  ['/products/:id/restore', false],
] as const) {
  router.post(
    path,
    asyncHandler(async (req, res) => {
      const params = catalogEntityIdParamsSchema.safeParse(req.params);
      if (!params.success) return badRequest(res, params.error);

      const userId = req.user!.userId;
      const result = await setProductArchived(userId, params.data.id, archived);

      if (result.outcome === 'NO_CATALOG') return noCatalog(res);
      if (result.outcome === 'NOT_FOUND') {
        return fail(res, 404, 'NOT_FOUND', 'Product not found.');
      }

      track(AnalyticsEvent.CATALOG_PRODUCT_ARCHIVED, {
        user_id_hash: hashIdentifier(userId),
          product_id: result.product.id,
        archived,
      });

      res.status(200).json({ status: 'success', product: result.product });
    })
  );
}

export default router;
