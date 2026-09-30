// src/routes/todayRoutes.ts
//
// The Today screen's API (more-customization Stage 14.1–14.2) — ONE router,
// mounted for the owner (`/catalog/…`, role OWNER) and for the restaurant's
// helpers (`/staff/catalogs/:id/…`, role MANAGER or STAFF from their grant).
// Every permission is enforced in todayService, not here: a route that forgot
// a check would still be refused.
import { Router, type Request, type Response } from 'express';
import { Types } from 'mongoose';
import { z } from 'zod';

import type { ICatalog } from '@/models/Catalog';
import { User } from '@/models/User';
import type { ActorRole } from '@/services/staff/staffPermissions';
import {
  applyBulkPrices,
  applyTodayChanges,
  getToday,
  previewBulkPrices,
  publishFromToday,
  ROUNDINGS,
  undoLastBulkPrices,
  type Actor,
} from '@/services/todayService';
import { asyncHandler } from '@/utils/asyncHandler';

export type TodayResolver = (
  req: Request
) => Promise<{ catalog: ICatalog; role: ActorRole } | null>;

const objectId = z.string().regex(/^[a-f0-9]{24}$/i);

const changesSchema = z
  .object({
    changes: z
      .array(
        z
          .object({
            productId: objectId,
            availability: z.enum(['IN_STOCK', 'OUT_OF_STOCK']).optional(),
            untilTomorrow: z.boolean().optional(),
            price: z.number().positive().max(100_000).nullable().optional(),
          })
          .strict()
      )
      .min(1)
      .max(500),
    publish: z.boolean().default(false),
  })
  .strict();

const bulkSchema = z
  .object({
    productIds: z.array(objectId).max(500).optional(),
    categoryIds: z.array(objectId).max(100).optional(),
    mode: z.enum(['PERCENT', 'FLAT']),
    amount: z
      .number()
      .min(-90)
      .max(10_000)
      .refine((v) => v !== 0, 'Enter a change'),
    rounding: z.enum(ROUNDINGS).default('NONE'),
  })
  .strict()
  .refine((v) => (v.productIds?.length ?? 0) + (v.categoryIds?.length ?? 0) > 0, {
    message: 'Choose dishes or sections',
  });

const REJECT: Record<string, [number, string]> = {
  FORBIDDEN: [403, 'You do not have permission to do that.'],
  NOT_FOUND: [404, 'One of those dishes was not found.'],
  NOTHING_TO_DO: [409, 'There is nothing to change.'],
};

const fail = (res: Response, code: string): void => {
  const [status, message] = REJECT[code] ?? [400, 'That request was not accepted.'];
  res.status(status).json({ status: 'error', code, message });
};

async function actorFor(req: Request, role: ActorRole): Promise<Actor> {
  const userId = req.user!.userId;
  const user = await User.findById(userId).select({ displayName: 1, phone: 1 }).lean().exec();
  const name = user?.displayName?.trim() || (role === 'OWNER' ? 'Owner' : user?.phone) || 'Staff';
  return { userId, name: name.slice(0, 60), role };
}

export function todayRouter(resolve: TodayResolver, notFound: (res: Response) => void): Router {
  const router = Router({ mergeParams: true });

  const withScope = (
    handler: (req: Request, res: Response, catalog: ICatalog, actor: Actor) => Promise<void>
  ) =>
    asyncHandler(async (req, res) => {
      const scope = await resolve(req);
      if (!scope) return notFound(res);
      await handler(req, res, scope.catalog, await actorFor(req, scope.role));
    });

  const ref = (c: ICatalog) => ({ _id: c._id as Types.ObjectId, userId: c.userId });

  /** GET …/today — every dish, grouped; the undoable price change; the last 20 changes. */
  router.get(
    '/today',
    withScope(async (_req, res, catalog) => {
      res.status(200).json({ status: 'success', ...(await getToday(ref(catalog))) });
    })
  );

  /** POST …/today — `{ changes, publish }`: one batch, one draft bump, optional publish. */
  router.post(
    '/today',
    withScope(async (req, res, catalog, actor) => {
      const parsed = changesSchema.safeParse(req.body);
      if (!parsed.success) return fail(res, 'INVALID');
      const result = await applyTodayChanges(ref(catalog), actor, parsed.data.changes, {
        publish: parsed.data.publish,
      });
      if (result.outcome === 'REJECTED') return fail(res, result.code);
      res.status(200).json({ status: 'success', changed: result.changed, publish: result.publish });
    })
  );

  /** POST …/prices/bulk/preview — old → new, nothing written. */
  router.post(
    '/prices/bulk/preview',
    withScope(async (req, res, catalog, actor) => {
      if (actor.role === 'STAFF') return fail(res, 'FORBIDDEN');
      const parsed = bulkSchema.safeParse(req.body);
      if (!parsed.success) return fail(res, 'INVALID');
      res
        .status(200)
        .json({ status: 'success', rows: await previewBulkPrices(ref(catalog), parsed.data) });
    })
  );

  /** POST …/prices/bulk — ONE write, ONE draft bump, undoable for 7 days. */
  router.post(
    '/prices/bulk',
    withScope(async (req, res, catalog, actor) => {
      const parsed = bulkSchema.safeParse(req.body);
      if (!parsed.success) return fail(res, 'INVALID');
      const result = await applyBulkPrices(ref(catalog), actor, parsed.data);
      if (result.outcome === 'REJECTED') return fail(res, result.code);
      res.status(200).json({ status: 'success', changed: result.changed, batchId: result.batchId });
    })
  );

  /** POST …/prices/undo — the newest bulk change (≤ 7 days); edited dishes are kept. */
  router.post(
    '/prices/undo',
    withScope(async (_req, res, catalog, actor) => {
      const result = await undoLastBulkPrices(ref(catalog), actor);
      if (result.outcome === 'REJECTED') return fail(res, result.code);
      res.status(200).json({ status: 'success', restored: result.restored, kept: result.kept });
    })
  );

  /** POST …/today/publish — publish now (owner, manager, staff). */
  router.post(
    '/today/publish',
    withScope(async (_req, res, catalog, actor) => {
      const result = await publishFromToday(ref(catalog), actor);
      if (result.outcome === 'REJECTED') return fail(res, result.code);
      res.status(200).json({ status: 'success', publish: result.publish });
    })
  );

  return router;
}
