// src/routes/rep.ts
//
// The field surface (mounted at /rep): a SALES_REP turns a printed standee into
// a live catalog and authors on the restaurant's behalf.
//
// THIS ROUTER MIRRORS THE OWNER ROUTES; IT NEVER MODIFIES THEM. `/catalog` and
// `/projects` are untouched by this stage — no second, weaker door into owner
// data. Where a rep does something an owner can already do, this router
// AUTHORIZES and then delegates to the owner service with the restaurant's own
// userId. The moment a route here grows its own product logic, the two
// implementations start drifting and the rep path becomes the one nobody tests.
//
// ONE GATE, ONE FUNCTION: every catalog-scoped route resolves its catalog
// through `resolveDelegatedCatalog` and through nothing else. A `null` from it
// is answered with the SAME 404 a nonexistent catalog gives — a rep must not be
// able to probe for catalogs they do not hold. Grep this file for
// `resolveDelegatedCatalog`: if a catalog is ever obtained another way, that is
// the bug.
//
// Standard envelope throughout (unlike routes/public.ts, whose carve-out is
// documented in AGENTS.md and applies to that router alone).
import { Router, raw, type Response } from 'express';
import { Types } from 'mongoose';

import { asyncHandler } from '@/utils/asyncHandler';
import { requireAuth } from '@/middleware/auth';
import { requireRole } from '@/middleware/requireRole';
import { hashIdentifier } from '@/utils/otp';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { QrCode } from '@/models/QrCode';
import { qrCodeParam, standeeQrQuerySchema } from '@/validation/qrSchemas';
import {
  brandingBytesQuerySchema,
  brandingCommitSchema,
  brandingUploadUrlSchema,
  catalogProductParamsSchema,
  createProductSchema,
  productImageBytesQuerySchema,
  productImageUploadUrlSchema,
  updateBusinessProfileSchema,
  updateProductSchema,
} from '@/validation/catalogSchemas';
import { repActivationSchema, attachQrCodeSchema } from '@/validation/repSchemas';
import {
  activate,
  attachCodeToCatalog,
  retireCode,
} from '@/services/activationService';
import {
  listDelegatedCatalogs,
  resolveDelegatedCatalog,
} from '@/services/catalogDelegationService';
import { findRepStandee, listRepStandees } from '@/services/standeeAssignmentService';
import { renderStandeeSheet } from '@/services/standeeSheetService';
import { QrResolverNotConfiguredError } from '@/services/qrCodeService';
import { ifNoneMatchSatisfied, strongETag } from '@/utils/etag';
import {
  createProduct,
  createProductImageSlot,
  getProduct,
  listProducts,
  storeProductImageBytes,
  updateProduct,
} from '@/services/catalogProductsService';
import {
  commitBrandingImage,
  createBrandingImageSlot,
  getBusinessProfile,
  getCatalog,
  storeBrandingImageBytes,
  updateBusinessProfile,
} from '@/services/catalogService';
import { listCategories } from '@/services/catalogCategoriesService';
import {
  PRODUCT_IMAGE_CONTENT_TYPES,
  sniffProductImageContentType,
} from '@/utils/productImageKeys';
import { requestPublish } from '@/services/catalogPublishService';
import { consumeRateWindow } from '@/utils/rateLimit';
import { env } from '@/config/env';

const router = Router();

// Router-level gates, mirroring admin.ts. requireRole re-reads the role from the
// DB on every request, so a revoked rep loses /rep at once rather than at token
// expiry. Role comparison is inclusive upward: MODEL_ARTIST and ADMIN pass here
// too, which is accepted rather than overlooked — both are script-granted, and
// every acting-on-behalf-of write leaves a CatalogDelegation row behind.
router.use(requireAuth);
router.use(requireRole('SALES_REP'));

/**
 * How many dishes a rep's detail screen loads. Generous enough to be the whole
 * list during a visit — a rep adds dishes one at a time at a table, not fifty.
 */
const REP_PRODUCT_PAGE_SIZE = 100;

function fail(res: Response, status: number, code: string, message: string): void {
  res.status(status).json({ status: 'error', code, message });
}

/** The one answer for "no such catalog" AND "not delegated to you". */
function notDelegated(res: Response): void {
  fail(res, 404, 'CATALOG_NOT_FOUND', 'That catalog was not found.');
}

function invalidCode(res: Response): void {
  fail(res, 400, 'INVALID_REQUEST', 'Invalid QR code.');
}

/**
 * GET /rep/codes/:code — the preflight the rep's scanner calls before showing
 * the activation form.
 *
 * Purely advisory: the state can change between this call and the activation,
 * and the conditional claim in activationService is what actually decides. This
 * exists so a rep sees "already in use" before typing a restaurant's details,
 * not so the client can skip the 409.
 *
 * No enumeration concern — the whole router is behind requireRole('SALES_REP'),
 * and a rep holding a physical standee already knows the code exists.
 */
router.get(
  '/codes/:code',
  asyncHandler(async (req, res) => {
    const parsed = qrCodeParam.safeParse(req.params.code);
    if (!parsed.success) return invalidCode(res);

    const qrCode = await QrCode.findOne({ code: parsed.data, deletedAt: null }).exec();
    if (!qrCode) {
      return fail(res, 404, 'CODE_NOT_FOUND', 'That code is not one of ours.');
    }

    res.status(200).json({
      status: 'success',
      code: qrCode.code,
      state: qrCode.state,
      available: qrCode.state === 'UNASSIGNED',
    });
  })
);

/**
 * POST /rep/activations — the whole stage in one call.
 *
 * 201 on a fresh activation, 200 on an idempotent re-run of one that already
 * succeeded, 409 when the standee belongs to someone else.
 */
router.post(
  '/activations',
  asyncHandler(async (req, res) => {
    const parsed = repActivationSchema.safeParse(req.body);
    if (!parsed.success) {
      return fail(
        res,
        400,
        'INVALID_REQUEST',
        parsed.error.issues[0]?.message ?? 'Invalid request'
      );
    }

    const repUserId = new Types.ObjectId(req.user!.userId);
    const result = await activate({ repUserId, ...parsed.data });

    switch (result.outcome) {
      case 'RESOLVER_NOT_CONFIGURED':
        // 409, matching the batch-export route's answer to the same missing
        // variable. Activating against a guessed host would freeze a broken URL
        // onto the catalog permanently.
        return fail(
          res,
          409,
          'RESOLVER_NOT_CONFIGURED',
          'PUBLIC_RESOLVER_BASE_URL is not configured on this deployment.'
        );
      case 'RATE_LIMITED':
        res.status(429).json({
          status: 'error',
          code: 'RATE_LIMITED',
          message: 'Too many activations. Try again shortly.',
          retryAfter: result.retryAfter,
        });
        return;
      case 'CODE_NOT_FOUND':
        return fail(res, 404, 'CODE_NOT_FOUND', 'That code is not one of ours.');
      case 'CODE_UNAVAILABLE':
        return fail(
          res,
          409,
          'CODE_UNAVAILABLE',
          'That code is already in use or has been retired.'
        );
      case 'ACTIVATED':
      case 'ALREADY_ACTIVE':
        break;
    }

    res.status(result.outcome === 'ACTIVATED' ? 201 : 200).json({
      status: 'success',
      outcome: result.outcome,
      catalogId: String(result.catalog._id),
      publicUrl: result.publicUrl,
    });
  })
);

/** GET /rep/catalogs — the restaurants this rep may currently act on. */
router.get(
  '/catalogs',
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalogs = await listDelegatedCatalogs(repUserId);
    res.status(200).json({ status: 'success', catalogs });
  })
);

/**
 * GET /rep/catalogs/:id — one delegated restaurant, in the OWNER's own shape.
 *
 * `listDelegatedCatalogs` above answers a PICKER: a name, a status, and nothing
 * a rep would have to scroll past to find the restaurant they are standing in.
 * The preview and the restaurant-details screens need the catalog document
 * itself — the draft revision behind "not published yet", the counts, the slug —
 * so they read it here rather than growing the list row into a second, heavier
 * DTO that every list render would then pay for.
 */
router.get(
  '/catalogs/:id',
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, req.params.id);
    if (!catalog) return notDelegated(res);

    const dto = await getCatalog(String(catalog.userId));
    // Unreachable — the delegation resolved a catalog — but a null here would
    // otherwise serialise as `catalog: null` and read on the client as an
    // ordinary "no catalog", which is a state a rep can do nothing about.
    if (!dto) return notDelegated(res);

    res.status(200).json({ status: 'success', catalog: dto });
  })
);

/**
 * GET /rep/catalogs/:id/categories — the sections the public page will have.
 *
 * READ-ONLY on this surface, and that is the whole design: a rep previews a menu
 * grouped the way the owner grouped it, and can move a dish between EXISTING
 * sections from the dish editor. Creating, renaming, reordering and deleting
 * categories stay owner-only — they reshape a page the restaurant lives with
 * long after the visit ends.
 */
router.get(
  '/catalogs/:id/categories',
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, req.params.id);
    if (!catalog) return notDelegated(res);

    const result = await listCategories(String(catalog.userId));
    if (result.outcome === 'NO_CATALOG') return notDelegated(res);

    res.status(200).json({
      status: 'success',
      categories: result.categories,
      uncategorizedCount: result.uncategorizedCount,
    });
  })
);

// ── The restaurant's own details, on their behalf ───────────────────────────
//
// THE GAP THIS CLOSES. A rep activates a standee with a name and a phone number
// and nothing else — that is all the activation form asks for, deliberately,
// because a rep standing at a counter cannot fill in a business profile before
// the restaurant has agreed to anything. Everything else the public page shows —
// the address customers navigate to, the website, the logo on the header — had
// no rep-facing door at all: it could be typed only by the OWNER, signing in on
// their own phone, after the rep had gone. In a pilot that means published pages
// carrying a name and a phone number and nothing more.
//
// Every route below DELEGATES to the owner service with the restaurant's userId,
// exactly as the product routes do. Nothing here knows what a profile is.

/** GET /rep/catalogs/:id/profile — the restaurant's business profile. */
router.get(
  '/catalogs/:id/profile',
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, req.params.id);
    if (!catalog) return notDelegated(res);

    const profile = await getBusinessProfile(String(catalog.userId));
    if (!profile) return notDelegated(res);

    res.status(200).json({ status: 'success', profile });
  })
);

/**
 * PATCH /rep/catalogs/:id/profile — edit it.
 *
 * Bumps `draftRevision` like every other authoring write, so an edit here lights
 * up the same "draft changes not yet live" badge an owner's edit does and
 * reaches customers only at publish. A rep who fills in an address and leaves
 * without publishing has changed nothing customers can see — which is why the
 * screen says so and the publish button is one tap away.
 */
router.patch(
  '/catalogs/:id/profile',
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, req.params.id);
    if (!catalog) return notDelegated(res);

    const parsed = updateBusinessProfileSchema.safeParse(req.body);
    if (!parsed.success) {
      return fail(
        res,
        400,
        'INVALID_REQUEST',
        parsed.error.issues[0]?.message ?? 'Invalid request'
      );
    }

    const result = await updateBusinessProfile(String(catalog.userId), parsed.data);
    if (result.outcome === 'NOT_FOUND') return notDelegated(res);

    track(AnalyticsEvent.CATALOG_UPDATED, {
      // The hashed REP — they made the request. The restaurant is identified by
      // catalog_id, which is not personal data.
      user_id_hash: hashIdentifier(req.user!.userId),
      catalog_id: result.profile.id,
      // Names only, never values — the profile holds phone/email/address.
      fields: Object.keys(parsed.data),
    });

    res.status(200).json({ status: 'success', profile: result.profile });
  })
);

/**
 * POST /rep/catalogs/:id/logo/upload-url — a presigned slot for the logo or the
 * cover. NATIVE clients only, for the reason the product-image pair documents:
 * the PUT is cross-origin to a bucket that serves no CORS policy.
 *
 * Minting through the RESTAURANT's userId is what makes the key land inside the
 * restaurant's own key space — the one the commit below will accept. A rep
 * calling the owner-facing route would mint a key in their own (usually
 * nonexistent) catalog's space and be refused at commit time.
 */
router.post(
  '/catalogs/:id/logo/upload-url',
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, req.params.id);
    if (!catalog) return notDelegated(res);

    const parsed = brandingUploadUrlSchema.safeParse(req.body);
    if (!parsed.success) {
      return fail(
        res,
        400,
        'INVALID_REQUEST',
        parsed.error.issues[0]?.message ?? 'Invalid request'
      );
    }

    // Keyed on the REP for the same reason the product-image window is: they are
    // who can loop this, and a per-restaurant key would let one rep exhaust
    // another restaurant's budget.
    const rate = await consumeRateWindow(
      `product-image-upload:${req.user!.userId}`,
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

    const result = await createBrandingImageSlot(String(catalog.userId), parsed.data);
    if (result.outcome === 'NOT_FOUND') return notDelegated(res);

    res.status(200).json({ status: 'success', ...result.slot });
  })
);

/**
 * POST /rep/catalogs/:id/logo/bytes — the same upload in ONE call.
 *
 * THE PATH THE BROWSER BUILD ACTUALLY USES, and the reason a rep can set a
 * restaurant's logo from a laptop at all. Same rate key as the slot route above:
 * the two are alternative spellings of one action, so alternating must not
 * double a rep's budget.
 *
 * The declared Content-Type is NOT trusted — the magic bytes decide.
 */
router.post(
  '/catalogs/:id/logo/bytes',
  raw({
    type: [...PRODUCT_IMAGE_CONTENT_TYPES],
    limit: env.CATALOG_PRODUCT_IMAGE_MAX_BYTES,
  }),
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, req.params.id);
    if (!catalog) return notDelegated(res);

    const params = brandingBytesQuerySchema.safeParse(req.query);
    if (!params.success) {
      return fail(
        res,
        400,
        'INVALID_REQUEST',
        params.error.issues[0]?.message ?? 'Invalid request'
      );
    }

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

    const sniffed = sniffProductImageContentType(body);
    if (sniffed === null) {
      return fail(
        res,
        415,
        'UNSUPPORTED_MEDIA_TYPE',
        'That file is not a JPEG, PNG or WebP.'
      );
    }

    const rate = await consumeRateWindow(
      `product-image-upload:${req.user!.userId}`,
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

    const result = await storeBrandingImageBytes(String(catalog.userId), {
      bytes: body,
      contentType: sniffed,
      slot: params.data.slot,
    });
    if (result.outcome === 'NOT_FOUND') return notDelegated(res);

    res.status(200).json({ status: 'success', key: result.key });
  })
);

/**
 * PUT /rep/catalogs/:id/logo — bind an uploaded object as the logo or cover.
 *
 * SEPARATE FROM THE UPLOAD ON PURPOSE, and the client depends on it: an upload
 * that succeeds and a commit that fails is a retryable state where the retry is
 * the COMMIT alone. Collapsing the two would make a rep on restaurant wifi send
 * the same 4 MiB logo twice.
 */
router.put(
  '/catalogs/:id/logo',
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, req.params.id);
    if (!catalog) return notDelegated(res);

    const parsed = brandingCommitSchema.safeParse(req.body);
    if (!parsed.success) {
      return fail(
        res,
        400,
        'INVALID_REQUEST',
        parsed.error.issues[0]?.message ?? 'Invalid request'
      );
    }

    const result = await commitBrandingImage(String(catalog.userId), parsed.data);
    if (result.outcome === 'NOT_FOUND') return notDelegated(res);
    if (result.outcome !== 'COMMITTED') {
      // INVALID_KEY / FORBIDDEN / OBJECT_NOT_FOUND / TOO_LARGE — all one thing
      // to a rep, who has no way to act on the difference and should not be
      // told which key space they missed.
      return fail(res, 400, result.outcome, 'That image could not be attached.');
    }

    track(AnalyticsEvent.CATALOG_UPDATED, {
      user_id_hash: hashIdentifier(req.user!.userId),
      catalog_id: result.profile.id,
      fields: [parsed.data.slot],
    });

    res.status(200).json({ status: 'success', profile: result.profile });
  })
);

/**
 * GET /rep/catalogs/:id/products — the dishes on a delegated catalog.
 *
 * The rep's detail screen needs to SHOW what it is adding to, and to watch a
 * dish flip from "3D generating" to "AR ready" — neither is possible without
 * this. Delegates to the owner service with the RESTAURANT's userId, exactly
 * as the create route below does, so the rows a rep reads are the rows the
 * owner reads, through the same code.
 *
 * No filters and no cursor: a rep's list is a working set of a few dishes
 * during one visit, not the owner's catalog manager. The owner surface keeps
 * its paging; adding a second parameterised list here would be two query
 * builders to keep in step for a screen that does not need one.
 */
router.get(
  '/catalogs/:id/products',
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, req.params.id);
    if (!catalog) return notDelegated(res);

    const result = await listProducts(String(catalog.userId), {
      limit: REP_PRODUCT_PAGE_SIZE,
      includeArchived: false,
    });
    if (result.outcome === 'NO_CATALOG') return notDelegated(res);

    res.status(200).json({ status: 'success', items: result.items });
  })
);

/**
 * POST /rep/catalogs/:id/products — dish authoring on the restaurant's behalf.
 *
 * DELEGATES to the owner service with the RESTAURANT's userId, so the product
 * that comes out is owned by the restaurant, filed under the restaurant's
 * catalog, and identical in every field to one the owner would have created.
 * The rep's identity is not on the row at all — the audit trail is the
 * CatalogDelegation grant, not a second owner column nothing else understands.
 */
router.post(
  '/catalogs/:id/products',
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, req.params.id);
    if (!catalog) return notDelegated(res);

    const parsed = createProductSchema.safeParse(req.body);
    if (!parsed.success) {
      return fail(
        res,
        400,
        'INVALID_REQUEST',
        parsed.error.issues[0]?.message ?? 'Invalid request'
      );
    }

    // `capturedByUserId` is the REP, and it is the one thing that makes this
    // work. The rep shoots the dish on their own phone, so the Project — and
    // therefore the ProjectModel — belongs to the rep, while the catalog
    // belongs to the restaurant. Without widening ownership by exactly this id
    // every rep-captured dish resolves MODEL_NOT_FOUND. The delegation was
    // proven above; this only says whose captures may be linked.
    const result = await createProduct(String(catalog.userId), parsed.data, {
      capturedByUserId: req.user!.userId,
    });

    switch (result.outcome) {
      case 'NO_CATALOG':
        return notDelegated(res);
      case 'CATEGORY_NOT_FOUND':
        return fail(res, 404, 'CATEGORY_NOT_FOUND', 'That category does not exist.');
      case 'MODEL_NOT_FOUND':
        return fail(res, 404, 'MODEL_NOT_FOUND', 'That 3D model was not found.');
      case 'MODEL_NOT_READY':
        return fail(res, 409, 'MODEL_NOT_READY', 'That 3D model is not finished yet.');
      case 'DUPLICATE_NAME':
        return fail(res, 409, 'DUPLICATE_NAME', 'A product with that name already exists.');
      case 'INVALID_KEY':
      case 'FORBIDDEN':
      case 'OBJECT_NOT_FOUND':
      case 'TOO_LARGE':
        return fail(res, 400, result.outcome, 'That image could not be attached.');
      case 'CREATED':
        break;
    }

    track(AnalyticsEvent.CATALOG_PRODUCT_CREATED, {
      // The hashed REP — they made the request. The restaurant is identified by
      // catalog_id, which is not personal data.
      user_id_hash: hashIdentifier(req.user!.userId),
      product_id: result.product.id,
      product_type: result.product.type,
      has_category: result.product.categoryId !== null,
    });

    res.status(201).json({ status: 'success', product: result.product });
  })
);

/**
 * POST /rep/catalogs/:id/products/image/upload-url — one presigned PUT slot for
 * an image-only dish the rep is authoring.
 *
 * WITHOUT THIS, image-only dishes are impossible for a rep. The owner-facing
 * `/catalog/products/image/upload-url` mints a key scoped to the CALLER's own
 * catalog, so a rep calling it gets a key in their own (usually non-existent)
 * catalog's space, which `checkCatalogImageKey` then rejects at create time.
 * Delegating with the RESTAURANT's userId — exactly as the create route above
 * does — mints the key inside the restaurant's catalog, which is the one the
 * create will accept.
 *
 * Declared AFTER `/catalogs/:id/products` and before nothing in particular:
 * the paths differ past the shared prefix, so no literal segment is at risk of
 * being swallowed as an id.
 *
 * The returned `url` is a WRITE bearer credential for that one key until
 * `expiresAt`: this response body is the ONLY place it may appear — never a log
 * line, never an analytics property.
 */
router.post(
  '/catalogs/:id/products/image/upload-url',
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, req.params.id);
    if (!catalog) return notDelegated(res);

    const parsed = productImageUploadUrlSchema.safeParse(req.body);
    if (!parsed.success) {
      return fail(
        res,
        400,
        'INVALID_REQUEST',
        parsed.error.issues[0]?.message ?? 'Invalid request'
      );
    }

    // Keyed on the REP, not the restaurant. The rep is who can loop this, and a
    // per-restaurant key would let one rep exhaust another restaurant's budget
    // by activating and hammering it. Same window as the owner-facing slot.
    const rate = await consumeRateWindow(
      `product-image-upload:${req.user!.userId}`,
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

    const result = await createProductImageSlot(String(catalog.userId), parsed.data);
    // NO_CATALOG cannot happen (the delegation resolved one) but is handled
    // rather than cast away; NOT_FOUND is a productId that is not this
    // catalog's, which reads as not-delegated for the same enumeration reason.
    if (result.outcome !== 'OK') return notDelegated(res);

    res.status(201).json({ status: 'success', slot: result.slot });
  })
);

/**
 * POST /rep/catalogs/:id/products/image/bytes — the same upload in ONE call,
 * for the browser build.
 *
 * WHY BOTH SPELLINGS. The presigned route above is the right shape for a native
 * client and keeps image bytes off this API. It cannot work from the WEB build:
 * the PUT is cross-origin to the artifacts bucket, which serves no CORS policy.
 * That is the same wall that produced `/catalog/products/image/bytes`, and the
 * rep surface hits it for the same reason — so a rep at a desk can author an
 * image-only dish, which is stage 10's row 20.
 *
 * Same rate window as the slot route and deliberately the SAME key: the two are
 * alternative spellings of one action, so alternating must not double a rep's
 * budget.
 *
 * The declared Content-Type is NOT trusted — the magic bytes decide.
 */
router.post(
  '/catalogs/:id/products/image/bytes',
  raw({
    type: [...PRODUCT_IMAGE_CONTENT_TYPES],
    limit: env.CATALOG_PRODUCT_IMAGE_MAX_BYTES,
  }),
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, req.params.id);
    if (!catalog) return notDelegated(res);

    const params = productImageBytesQuerySchema.safeParse(req.query);
    if (!params.success) {
      return fail(
        res,
        400,
        'INVALID_REQUEST',
        params.error.issues[0]?.message ?? 'Invalid request'
      );
    }

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

    const sniffed = sniffProductImageContentType(body);
    if (sniffed === null) {
      return fail(
        res,
        415,
        'UNSUPPORTED_MEDIA_TYPE',
        'That file is not a JPEG, PNG or WebP.'
      );
    }

    const rate = await consumeRateWindow(
      `product-image-upload:${req.user!.userId}`,
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

    const result = await storeProductImageBytes(String(catalog.userId), {
      bytes: body,
      contentType: sniffed,
      productId: params.data.productId,
    });
    if (result.outcome !== 'OK') return notDelegated(res);

    res.status(200).json({ status: 'success', key: result.key });
  })
);

// ── One dish, read and edited ───────────────────────────────────────────────
//
// DECLARED AFTER `/products/image/upload-url` AND `/products/image/bytes`, and
// that ordering is load-bearing: Express matches in declaration order, so a
// `:productId` route registered above them would swallow the literal `image`
// segment and answer "invalid product id" to every upload. The owner router
// orders the same pair the same way for the same reason.

/**
 * GET /rep/catalogs/:id/products/:productId — one dish.
 *
 * The list route above already carries every dish, so this is not how the detail
 * screen FIRST sees one — it is how that screen survives a browser reload. The
 * rep surface runs in a browser as well as an APK, and a reload on
 * `/rep/catalogs/x/dishes/y` arrives with an empty navigation stack and nothing
 * in hand but the two ids in the URL.
 */
router.get(
  '/catalogs/:id/products/:productId',
  asyncHandler(async (req, res) => {
    const params = catalogProductParamsSchema.safeParse(req.params);
    if (!params.success) return notDelegated(res);

    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, params.data.id);
    if (!catalog) return notDelegated(res);

    const result = await getProduct(String(catalog.userId), params.data.productId);
    if (result.outcome !== 'OK') {
      // NO_CATALOG cannot happen (the delegation resolved one) and NOT_FOUND is
      // a product that is not this catalog's — which reads as not-delegated, for
      // the same enumeration reason the whole file collapses those two.
      return fail(res, 404, 'NOT_FOUND', 'That dish was not found.');
    }

    res.status(200).json({ status: 'success', product: result.product });
  })
);

/**
 * PATCH /rep/catalogs/:id/products/:productId — edit a dish on the restaurant's
 * behalf.
 *
 * THE OTHER HALF OF `POST /catalogs/:id/products`. Before this, a rep could add
 * a dish and never touch it again: a typo in a name, a price agreed at the table
 * after the dish was entered, or a photo shot before the kitchen plated it
 * properly all needed the OWNER to sign in and fix them. The rep who made the
 * mistake, standing in the room, could not.
 *
 * Accepts the OWNER's own update schema, unnarrowed. The rep screen sends a
 * subset (name, description, price, category, availability, image key) and the
 * fields it never sends are simply absent — narrowing the schema here would be a
 * second set of bounds to keep in step with the first, which is the drift this
 * router exists to avoid. Ownership still comes from the resolved delegation and
 * never from the body.
 *
 * ONE FIELD OF THAT SCHEMA CANNOT SUCCEED HERE, and it is worth naming rather
 * than pretending otherwise: `sourceModelId`. `updateProduct` takes no
 * `capturedByUserId` widening the way `createProduct` does, so a model the REP
 * captured is not visible to a lookup scoped to the RESTAURANT and resolves
 * MODEL_NOT_FOUND. Re-pointing a dish at a different capture is therefore an
 * owner action today; the rep screen does not offer it, and a rep who somehow
 * sent one gets an honest 404 rather than a silent no-op.
 */
router.patch(
  '/catalogs/:id/products/:productId',
  asyncHandler(async (req, res) => {
    const params = catalogProductParamsSchema.safeParse(req.params);
    if (!params.success) return notDelegated(res);

    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, params.data.id);
    if (!catalog) return notDelegated(res);

    const parsed = updateProductSchema.safeParse(req.body);
    if (!parsed.success) {
      return fail(
        res,
        400,
        'INVALID_REQUEST',
        parsed.error.issues[0]?.message ?? 'Invalid request'
      );
    }

    const result = await updateProduct(
      String(catalog.userId),
      params.data.productId,
      parsed.data
    );

    switch (result.outcome) {
      case 'NO_CATALOG':
      case 'NOT_FOUND':
        return fail(res, 404, 'NOT_FOUND', 'That dish was not found.');
      case 'CATEGORY_NOT_FOUND':
        return fail(res, 404, 'CATEGORY_NOT_FOUND', 'That category does not exist.');
      case 'DUPLICATE_NAME':
        return fail(res, 409, 'DUPLICATE_NAME', 'A product with that name already exists.');
      case 'MODEL_NOT_FOUND':
        return fail(res, 404, 'MODEL_NOT_FOUND', 'That 3D model was not found.');
      case 'MODEL_NOT_READY':
        return fail(res, 409, 'MODEL_NOT_READY', 'That 3D model is not finished yet.');
      case 'INVALID_KEY':
      case 'FORBIDDEN':
      case 'OBJECT_NOT_FOUND':
      case 'TOO_LARGE':
        return fail(res, 400, result.outcome, 'That image could not be attached.');
      case 'UPDATED':
        break;
    }

    track(AnalyticsEvent.CATALOG_PRODUCT_UPDATED, {
      // The hashed REP — they made the request.
      user_id_hash: hashIdentifier(req.user!.userId),
      product_id: result.product.id,
      fields: Object.keys(parsed.data),
    });

    res.status(200).json({ status: 'success', product: result.product });
  })
);

/**
 * POST /rep/catalogs/:id/qr-codes — attach a replacement standee.
 *
 * Leaves `publicUrl` alone (see attachCodeToCatalog). Retiring the code being
 * replaced is a SEPARATE call: "print a spare" and "kill the lost one" are two
 * decisions, and a rep often wants only the first.
 */
router.post(
  '/catalogs/:id/qr-codes',
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, req.params.id);
    if (!catalog) return notDelegated(res);

    const parsed = attachQrCodeSchema.safeParse(req.body);
    if (!parsed.success) return invalidCode(res);

    const result = await attachCodeToCatalog({
      repUserId,
      catalog,
      code: parsed.data.code,
    });

    switch (result.outcome) {
      case 'CODE_NOT_FOUND':
        return fail(res, 404, 'CODE_NOT_FOUND', 'That code is not one of ours.');
      case 'CODE_UNAVAILABLE':
        return fail(
          res,
          409,
          'CODE_UNAVAILABLE',
          'That code is already in use or has been retired.'
        );
      case 'SOURCE_CATALOG_PUBLISHED':
        return fail(
          res,
          409,
          'SOURCE_CATALOG_PUBLISHED',
          'That code is live on a catalog that has already been published. ' +
            'Retire it there first, then use a fresh code.'
        );
      case 'ATTACHED':
      case 'ALREADY_ATTACHED':
        break;
    }

    res.status(result.outcome === 'ATTACHED' ? 201 : 200).json({
      status: 'success',
      outcome: result.outcome,
      code: result.code,
      // Unchanged, and echoed back so the client can SEE it is unchanged.
      publicUrl: catalog.publicUrl ?? null,
    });
  })
);

/**
 * POST /rep/qr-codes/:code/retire — take one standee out of service.
 *
 * Authorized through the code's OWN catalog: a rep may retire only a code that
 * points at a catalog they hold. The delegation gate is the same one every
 * other route here uses; the only difference is that the catalog id comes from
 * the code rather than from the URL.
 */
router.post(
  '/qr-codes/:code/retire',
  asyncHandler(async (req, res) => {
    const parsed = qrCodeParam.safeParse(req.params.code);
    if (!parsed.success) return invalidCode(res);

    const repUserId = new Types.ObjectId(req.user!.userId);
    const qrCode = await QrCode.findOne({ code: parsed.data, deletedAt: null }).exec();
    // An unbound code has no catalog to check a delegation against, so there is
    // nothing this rep could be authorised for — the same 404 as a code that
    // does not exist, rather than a hint that it does.
    if (!qrCode?.catalogId) {
      return fail(res, 404, 'CODE_NOT_FOUND', 'That code is not one of ours.');
    }

    const catalog = await resolveDelegatedCatalog(repUserId, String(qrCode.catalogId));
    if (!catalog) return notDelegated(res);

    const result = await retireCode(qrCode);
    res.status(200).json({ status: 'success', outcome: result.outcome, code: qrCode.code });
  })
);

/**
 * POST /rep/catalogs/:id/publish — put the menu online before leaving the table.
 *
 * THE GAP THIS CLOSES. Until now a menu went live exactly two ways: a 3D dish
 * finishing generation (`promoteModelToProducts` → `tryPublish`), or the OWNER
 * signing in and tapping Publish. A restaurant the rep filled with photo-only
 * dishes has no model to finish, so nothing ever published, and the standee on
 * the table stayed dead until the owner got around to it. The field guide
 * covered that with a warning in capitals — which is a documentation patch over
 * a product hole, and it contradicts the one thing this feature promises: leave
 * a WORKING standee behind.
 *
 * DELEGATES, never reimplements. `requestPublish` is keyed by the catalog OWNER,
 * exactly as `tryPublish` calls it from the promotion path, so a rep-initiated
 * publish and an owner-initiated one are the same run through the same gates,
 * the same lock and the same provisioning. This route only decides whether the
 * rep is allowed to ask.
 *
 * The rate window is keyed on the CATALOG, not the rep: the thing being
 * protected is one restaurant's Mirage writes, and a rep legitimately works
 * several restaurants in a day.
 */
router.post(
  '/catalogs/:id/publish',
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);
    const catalog = await resolveDelegatedCatalog(repUserId, req.params.id);
    if (!catalog) return notDelegated(res);

    const catalogId = String(catalog._id);
    const ownerUserId = String(catalog.userId);

    const rate = await consumeRateWindow(
      `rep-publish:${catalogId}`,
      env.PUBLISH_MAX_PER_WINDOW,
      env.PUBLISH_WINDOW_SECONDS
    );
    if (rate.limited) {
      return fail(res, 429, 'RATE_LIMITED', 'Too many requests. Please try again shortly.');
    }

    const result = await requestPublish(ownerUserId);

    // ANSWERED BEFORE THE EVENT, mirroring respondToPublishRequest. The
    // analytics `outcome` union deliberately excludes NOT_FOUND — a publish for
    // a catalog that vanished mid-request is not a publish attempt to count —
    // and the compiler enforces that ordering here.
    if (result.outcome === 'NOT_FOUND') {
      // It resolved a moment ago, so this is a delete mid-request. Answered with
      // the delegation 404 so every not-found on this router reads identically.
      return notDelegated(res);
    }

    // The OWNER's hash, not the rep's. The event answers "how often is a publish
    // attempted for this catalog, and what stops it" — a question about the
    // restaurant, not about who pressed the button. Who acted is already durable
    // in the CatalogDelegation row, which is where an audit belongs.
    const gates = result.outcome === 'BLOCKED' ? result.gates : [];
    track(AnalyticsEvent.CATALOG_PUBLISH_REQUESTED, {
      user_id_hash: hashIdentifier(ownerUserId),
      catalog_id: catalogId,
      mode: 'FULL',
      outcome: result.outcome,
      gate_count: gates.length,
      ...(gates.length > 0 ? { blocked_by: [...new Set(gates.map((gate) => gate.code))] } : {}),
    });

    switch (result.outcome) {
      case 'IN_PROGRESS':
        res.status(409).json({
          status: 'error',
          code: 'PUBLISH_IN_PROGRESS',
          message: 'A publish is already running for this catalog.',
          runId: result.runId,
        });
        return;

      case 'BLOCKED':
        // EVERY failing gate, byte-identical to what `POST /catalog/publish`
        // returns — the rep and the owner must be told the same thing about the
        // same catalog. `rep-publish.test.ts` asserts that equality rather than
        // trusting this comment.
        res.status(422).json({
          status: 'error',
          code: 'PUBLISH_BLOCKED',
          message: 'This catalog is not ready to publish yet.',
          gates: result.gates,
        });
        return;

      case 'NAME_TAKEN':
        res.status(409).json({
          status: 'error',
          code: result.code,
          message: 'That catalog name is already in use. Try the suggested one.',
          fields: { name: result.suggestedName },
        });
        return;

      case 'NOTHING_TO_RETRY':
        // Unreachable for mode FULL — requestPublish only returns it from
        // requestRetry — but the switch stays exhaustive so adding an outcome is
        // a compile error here rather than a silent fallthrough to no response.
        res.status(200).json({ status: 'success', runId: null, queued: false });
        return;

      case 'QUEUED':
        res.status(202).json({
          status: 'success',
          runId: result.run.runId,
          queued: true,
          ...(result.mapping ? { publicUrl: result.mapping.publicUrl } : {}),
        });
        return;
    }
  })
);

/**
 * GET /rep/standees — the stock this rep is carrying.
 *
 * THE POINT OF THE WHOLE ASSIGNMENT FEATURE, from the rep side. Before it, a
 * rep learned their codes by reading eight characters off a PDF an admin had
 * emailed them, and typed those characters at the table. Now the codes are a
 * list in their own app, and `POST /rep/activations` is reached by tapping one.
 *
 * Scoped to the CALLER and nothing else — the rep id comes from the token, not
 * from a query parameter, so there is no shape of this request that reads
 * another rep's folder.
 *
 * Every row carries the resolver URL, so a 409 rather than a partial list when
 * the deployment has no public origin: the same answer `/admin/qr-batches/:id/
 * codes` gives, for the same reason.
 */
router.get(
  '/standees',
  asyncHandler(async (req, res) => {
    const repUserId = new Types.ObjectId(req.user!.userId);

    let standees;
    try {
      standees = await listRepStandees(repUserId);
    } catch (err) {
      if (err instanceof QrResolverNotConfiguredError) {
        return fail(
          res,
          409,
          'RESOLVER_NOT_CONFIGURED',
          'PUBLIC_RESOLVER_BASE_URL is not configured on this deployment.'
        );
      }
      throw err;
    }

    res.status(200).json({ status: 'success', standees });
  })
);

/**
 * GET /rep/standees/:code/qr?format=&size= — the printable sheet, for a code
 * this rep actually holds.
 *
 * A SECOND DOOR TO THE SAME BYTES, and the narrower one. The admin endpoint
 * (`/admin/qr-codes/:code/qr`) renders ANY code and is ADMIN-gated; this one is
 * open to a rep but only for codes assigned to them, which `findRepStandee`
 * decides with a query that has the rep id in it — there is no code parameter
 * that reaches a standee somebody else is holding. Both routes compose the
 * sheet through `renderStandeeSheet`, so what a rep prints and what an admin
 * prints are the same physical object.
 *
 * A code that is not on this rep's list gets a 404, identical to a code that
 * does not exist. A rep must not be able to probe which codes have been minted
 * — the same enumeration rule `notDelegated` applies to catalogs.
 */
router.get(
  '/standees/:code/qr',
  asyncHandler(async (req, res) => {
    const code = qrCodeParam.safeParse(req.params.code);
    if (!code.success) return invalidCode(res);

    const parsed = standeeQrQuerySchema.safeParse(req.query);
    if (!parsed.success) {
      return fail(
        res,
        400,
        'INVALID_REQUEST',
        parsed.error.issues[0]?.message ?? 'Invalid request'
      );
    }

    const repUserId = new Types.ObjectId(req.user!.userId);
    const record = await findRepStandee(repUserId, code.data);
    if (!record) {
      return fail(res, 404, 'CODE_NOT_FOUND', 'That code is not one of ours.');
    }

    const { format, size } = parsed.data;

    let rendered;
    try {
      rendered = await renderStandeeSheet({ record, format, size });
    } catch (err) {
      if (err instanceof QrResolverNotConfiguredError) {
        return fail(
          res,
          409,
          'RESOLVER_NOT_CONFIGURED',
          'PUBLIC_RESOLVER_BASE_URL is not configured on this deployment.'
        );
      }
      throw err;
    }

    if (rendered.outcome === 'CODE_RETIRED') {
      return fail(
        res,
        409,
        'CODE_RETIRED',
        'That standee was retired. Ask for a replacement rather than reprinting it.'
      );
    }

    // The SAME key the admin route uses — url, format, size and nothing else —
    // so the two endpoints agree that identical bytes have an identical tag.
    const etag = strongETag({ url: rendered.url, format, size: rendered.size });
    res.setHeader('ETag', etag);
    res.setHeader('Cache-Control', 'private, max-age=3600');
    if (ifNoneMatchSatisfied(req.header('If-None-Match'), etag)) {
      res.status(304).end();
      return;
    }

    res.setHeader('Content-Type', rendered.contentType);
    res.setHeader('Content-Disposition', `attachment; filename="${rendered.filename}"`);
    res.status(200).send(rendered.body);
  })
);

export default router;
