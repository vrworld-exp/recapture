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
import { qrCodeParam } from '@/validation/qrSchemas';
import {
  createProductSchema,
  productImageBytesQuerySchema,
  productImageUploadUrlSchema,
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
import {
  createProduct,
  createProductImageSlot,
  listProducts,
  storeProductImageBytes,
} from '@/services/catalogProductsService';
import {
  PRODUCT_IMAGE_CONTENT_TYPES,
  sniffProductImageContentType,
} from '@/utils/productImageKeys';
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

export default router;
