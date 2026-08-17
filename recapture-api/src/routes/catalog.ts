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
import { Router } from 'express';
import { asyncHandler } from '@/utils/asyncHandler';
import { requireAuth } from '@/middleware/auth';
import { decodePositionCursor, type PositionCursor } from '@/utils/cursor';
import { hashIdentifier } from '@/utils/otp';
import { track, AnalyticsEvent } from '@/utils/analytics';
import {
  bulkProductsSchema,
  catalogEntityIdParamsSchema,
  createCatalogSchema,
  createCategorySchema,
  createProductSchema,
  listProductsQuerySchema,
  reorderSchema,
  updateCatalogSchema,
  updateCategorySchema,
  updateProductSchema,
} from '@/validation/catalogSchemas';
import { createCatalog, getCatalog, updateCatalog } from '@/services/catalogService';
import {
  createCategory,
  deleteCategory,
  listCategories,
  reorderCategories,
  updateCategory,
} from '@/services/catalogCategoriesService';
import {
  bulkProducts,
  createProduct,
  deleteProduct,
  getProduct,
  listProducts,
  reorderProducts,
  setProductArchived,
  updateProduct,
} from '@/services/catalogProductsService';
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
