// src/routes/outletRoutes.ts
//
// Stage 16 — an owner's outlets (main + branches), mounted under /catalog by
// catalog.ts after requireAuth. Every other /catalog route acts on the outlet
// named by the `X-Outlet-Id` header (see services/catalog/outletScope.ts);
// these manage the set of outlets itself.
import { Router, type Response } from 'express';
import { z } from 'zod';
import { asyncHandler } from '@/utils/asyncHandler';
import {
  addBranch,
  listOutlets,
  publishAllOutlets,
  resetProductToMain,
} from '@/services/brand/branchService';

function fail(res: Response, httpStatus: number, code: string, message: string): void {
  res.status(httpStatus).json({ status: 'error', code, message });
}

const noCatalog = (res: Response): void =>
  fail(res, 404, 'CATALOG_NOT_FOUND', 'You do not have a catalog yet.');

const addBranchSchema = z
  .object({
    outletName: z.string().trim().min(2).max(40),
    phone: z.string().trim().min(6).max(20).optional(),
    address: z.string().trim().max(300).optional(),
  })
  .strict();

export function outletRoutes(): Router {
  const router = Router();

  /** GET /catalog/outlets — main outlet first, then branches. */
  router.get(
    '/',
    asyncHandler(async (req, res) => {
      const outlets = await listOutlets(req.user!.userId);
      if (!outlets) return noCatalog(res);
      res.status(200).json({ status: 'success', outlets });
    })
  );

  /** POST /catalog/outlets — add a branch; its menu is copied from the main outlet. */
  router.post(
    '/',
    asyncHandler(async (req, res) => {
      const parsed = addBranchSchema.safeParse(req.body);
      if (!parsed.success) {
        return fail(res, 400, 'INVALID_REQUEST', parsed.error.issues[0]?.message ?? 'Invalid request');
      }
      const result = await addBranch(req.user!.userId, parsed.data);
      if (result.outcome === 'NO_CATALOG') return noCatalog(res);
      if (result.outcome === 'LIMIT') {
        return fail(res, 409, 'BRANCH_LIMIT', `You can have up to ${result.max} branches.`);
      }
      if (result.outcome === 'DUPLICATE_NAME') {
        return fail(res, 409, 'DUPLICATE_OUTLET', 'You already have an outlet with that name.');
      }
      res.status(201).json({ status: 'success', outlet: result.outlet });
    })
  );

  /** POST /catalog/outlets/publish-all — one publish per outlet. */
  router.post(
    '/publish-all',
    asyncHandler(async (req, res) => {
      const results = await publishAllOutlets(req.user!.userId);
      if (!results) return noCatalog(res);
      res.status(200).json({ status: 'success', results });
    })
  );

  /** POST /catalog/outlets/:id/products/:productId/reset — "Reset to main outlet". */
  router.post(
    '/:id/products/:productId/reset',
    asyncHandler(async (req, res) => {
      const result = await resetProductToMain(req.user!.userId, req.params.id, req.params.productId);
      if (result === 'NOT_FOUND') {
        return fail(res, 404, 'PRODUCT_NOT_FOUND', 'That dish is not on this outlet.');
      }
      if (result === 'NOT_LINKED') {
        return fail(res, 409, 'NOT_LINKED', 'This dish was added on this outlet only.');
      }
      res.status(200).json({ status: 'success' });
    })
  );

  return router;
}
