// src/routes/aiCatalogRoutes.ts
//
// Menu import, AI dish descriptions and photo enhancement (more-customization
// Stage 13) — ONE router, mounted twice with a different catalog resolver:
//   • /catalog/…                 — the owner's own catalog;
//   • /rep/catalogs/:id/…        — a rep's delegated catalog (import is the
//                                  rep's main onboarding time saver).
// Decided 2026-09-30: reps and owners on every plan; Claude; ₹2,000/month cap.
import { raw, Router, type Request, type Response } from 'express';
import { Types } from 'mongoose';
import { z } from 'zod';

import type { ICatalog } from '@/models/Catalog';
import { Catalog } from '@/models/Catalog';
import { MenuImport, MENU_IMPORT_MAX_PAGES, MENU_IMPORT_MEDIA_TYPES } from '@/models/MenuImport';
import { env } from '@/config/env';
import { spentThisMonth } from '@/modules/ai/budget';
import { isAiConfigured } from '@/modules/ai/provider';
import {
  AI_TONES,
  enhanceProductImage,
  MAX_DISHES_PER_REQUEST,
  suggestDescriptions,
} from '@/services/aiContentService';
import {
  applyImport,
  createImport,
  getImport,
  MENU_IMPORT_MAX_FILE_BYTES,
  startImport,
  undoImport,
  uploadImportPage,
} from '@/services/menuImport/menuImportService';
import { asyncHandler } from '@/utils/asyncHandler';

export type CatalogResolver = (req: Request) => Promise<ICatalog | null>;

const fail = (res: Response, status: number, code: string, message: string): void => {
  res.status(status).json({ status: 'error', code, message });
};

const REJECTION: Record<string, [number, string]> = {
  AI_NOT_CONFIGURED: [503, 'AI features are switched off.'],
  AI_BUDGET: [429, 'The AI budget for this month is used up. Try again next month.'],
  AI_FAILED: [502, 'The AI could not write that. Please try again.'],
  TOO_MANY_PAGES: [400, `Add 1 to ${MENU_IMPORT_MAX_PAGES} pages.`],
  UNSUPPORTED_FILE: [400, 'Use photos (JPG, PNG, WebP) or a PDF.'],
  FILE_TOO_LARGE: [400, 'Each page must be under 20 MB.'],
  DAILY_LIMIT: [429, 'You can import 5 menus a day. Try again tomorrow.'],
  NOT_FOUND: [404, 'That was not found.'],
  WRONG_STATE: [409, 'That import is not at this step any more.'],
  PAGES_MISSING: [409, 'Some pages did not finish uploading. Try again.'],
  INVALID_KEY: [400, 'That photo cannot be enhanced.'],
  FORBIDDEN: [403, 'That photo belongs to another catalog.'],
  UNREADABLE: [422, 'That photo could not be read.'],
};

const reject = (res: Response, code: string): void => {
  const [status, message] = REJECTION[code] ?? [400, 'That request was not accepted.'];
  fail(res, status, code, message);
};

const createSchema = z
  .object({
    files: z
      .array(
        z.object({
          contentType: z.enum(MENU_IMPORT_MEDIA_TYPES),
          size: z.number().int().positive().max(MENU_IMPORT_MAX_FILE_BYTES),
        })
      )
      .min(1)
      .max(MENU_IMPORT_MAX_PAGES),
  })
  .strict();

const applySchema = z
  .object({
    categories: z
      .array(
        z.object({
          name: z.string().trim().min(1).max(80),
          items: z
            .array(
              z.object({
                name: z.string().trim().min(1).max(120),
                description: z.string().trim().max(500).nullable().optional(),
                price: z.number().positive().max(100_000).nullable().optional(),
                variants: z
                  .array(
                    z.object({
                      label: z.string().trim().min(1).max(30),
                      price: z.number().positive(),
                    })
                  )
                  .max(6)
                  .optional(),
                foodType: z.enum(['VEG', 'NON_VEG', 'NONE']).optional(),
                updateProductId: z
                  .string()
                  .regex(/^[a-f0-9]{24}$/i)
                  .optional(),
              })
            )
            .max(500),
        })
      )
      .max(100),
  })
  .strict();

const describeSchema = z
  .object({
    productIds: z
      .array(z.string().regex(/^[a-f0-9]{24}$/i))
      .min(1)
      .max(MAX_DISHES_PER_REQUEST),
    perDish: z.number().int().min(1).max(3).default(3),
    language: z
      .string()
      .regex(/^[a-z]{2}$/)
      .optional(),
  })
  .strict();

export function aiCatalogRouter(
  resolveCatalog: CatalogResolver,
  notFound: (res: Response) => void
): Router {
  const router = Router({ mergeParams: true });

  const withCatalog = (
    handler: (req: Request, res: Response, catalog: ICatalog) => Promise<void>
  ) =>
    asyncHandler(async (req, res) => {
      const catalog = await resolveCatalog(req);
      if (!catalog) return notFound(res);
      await handler(req, res, catalog);
    });

  const ref = (c: ICatalog) => ({
    _id: c._id as Types.ObjectId,
    userId: c.userId,
    name: c.name,
    aiTone: c.aiTone,
  });

  /** GET …/ai/status — whether to show the AI buttons at all, and the tone. */
  router.get(
    '/ai/status',
    withCatalog(async (_req, res, catalog) => {
      const enabled = isAiConfigured();
      const spent = enabled ? await spentThisMonth() : 0;
      res.status(200).json({
        status: 'success',
        enabled,
        budgetLeft: enabled && spent < env.AI_MONTHLY_BUDGET_INR,
        tone: catalog.aiTone ?? 'casual',
      });
    })
  );

  /** PUT …/ai/tone — `{ tone: casual | premium | fun }`. ReCapture-only; no publish. */
  router.put(
    '/ai/tone',
    withCatalog(async (req, res, catalog) => {
      const parsed = z
        .object({ tone: z.enum(AI_TONES) })
        .strict()
        .safeParse(req.body);
      if (!parsed.success)
        return fail(res, 400, 'INVALID_REQUEST', 'Choose casual, premium or fun.');
      await Catalog.updateOne({ _id: catalog._id }, { $set: { aiTone: parsed.data.tone } }).exec();
      res.status(200).json({ status: 'success', tone: parsed.data.tone });
    })
  );

  /** POST …/ai/descriptions — up to 3 options per dish; nothing is saved. */
  router.post(
    '/ai/descriptions',
    withCatalog(async (req, res, catalog) => {
      const parsed = describeSchema.safeParse(req.body);
      if (!parsed.success) return fail(res, 400, 'INVALID_REQUEST', 'Pick 1 to 40 dishes.');
      const result = await suggestDescriptions(ref(catalog), parsed.data.productIds, parsed.data);
      if (result.outcome === 'REJECTED') return reject(res, result.code);
      res.status(200).json({ status: 'success', suggestions: result.suggestions });
    })
  );

  /** POST …/images/enhance — `{ productId }` → an enhanced copy of its photo as a new staged key. */
  router.post(
    '/images/enhance',
    withCatalog(async (req, res, catalog) => {
      const parsed = z
        .object({ productId: z.string().regex(/^[a-f0-9]{24}$/i) })
        .strict()
        .safeParse(req.body);
      if (!parsed.success) return fail(res, 400, 'INVALID_REQUEST', 'productId is required.');
      const result = await enhanceProductImage(
        catalog._id as Types.ObjectId,
        parsed.data.productId
      );
      if (result.outcome === 'REJECTED') return reject(res, result.code);
      res.status(200).json({ status: 'success', imageKey: result.key, url: result.url });
    })
  );

  // ── Menu import ──

  /** GET …/imports — the ten newest imports (no draft), for "undo" later. */
  router.get(
    '/imports',
    withCatalog(async (_req, res, catalog) => {
      const rows = await MenuImport.find({ catalogId: catalog._id })
        .sort({ createdAt: -1 })
        .limit(10)
        .select({ _id: 1, status: 1, files: 1, createdAt: 1, appliedAt: 1 })
        .lean()
        .exec();
      res.status(200).json({
        status: 'success',
        imports: rows.map((r) => ({
          id: String(r._id),
          status: r.status,
          pages: r.files.length,
          createdAt: r.createdAt.toISOString(),
          appliedAt: r.appliedAt ? r.appliedAt.toISOString() : null,
        })),
      });
    })
  );

  /** POST …/imports — `{ files: [{contentType, size}] }` → the import + its page slots. */
  router.post(
    '/imports',
    withCatalog(async (req, res, catalog) => {
      const parsed = createSchema.safeParse(req.body);
      if (!parsed.success) {
        return fail(
          res,
          400,
          'INVALID_REQUEST',
          'Add 1 to 10 photos (JPG, PNG, WebP) or PDFs under 20 MB.'
        );
      }
      const result = await createImport(ref(catalog), req.user!.userId, parsed.data.files);
      if (result.outcome === 'REJECTED') return reject(res, result.code);
      res.status(201).json({ status: 'success', import: result.import, uploads: result.uploads });
    })
  );

  /** POST …/imports/:importId/pages/:page — one page's bytes as the raw body. */
  router.post(
    '/imports/:importId/pages/:page',
    raw({ type: [...MENU_IMPORT_MEDIA_TYPES], limit: MENU_IMPORT_MAX_FILE_BYTES }),
    withCatalog(async (req, res, catalog) => {
      const page = Number(req.params.page);
      const body: unknown = req.body;
      if (!Number.isInteger(page) || page < 1 || !Buffer.isBuffer(body)) {
        return reject(res, 'UNSUPPORTED_FILE');
      }
      const contentType = String(req.headers['content-type'] ?? '')
        .split(';')[0]
        .trim();
      const result = await uploadImportPage(
        ref(catalog),
        req.params.importId,
        page,
        contentType,
        body
      );
      if (result.outcome === 'REJECTED') return reject(res, result.code);
      res.status(200).json({ status: 'success' });
    })
  );

  router.post(
    '/imports/:importId/start',
    withCatalog(async (req, res, catalog) => {
      const result = await startImport(ref(catalog), req.params.importId);
      if (result.outcome === 'REJECTED') return reject(res, result.code);
      res.status(202).json({ status: 'success', import: result.import });
    })
  );

  /** GET …/imports/:importId — progress while PROCESSING; the draft + matches when READY. */
  router.get(
    '/imports/:importId',
    withCatalog(async (req, res, catalog) => {
      const dto = await getImport(ref(catalog), req.params.importId);
      if (!dto) return reject(res, 'NOT_FOUND');
      res.status(200).json({ status: 'success', import: dto });
    })
  );

  /** POST …/imports/:importId/apply — the REVIEWED list. One draft bump; no publish. */
  router.post(
    '/imports/:importId/apply',
    withCatalog(async (req, res, catalog) => {
      const parsed = applySchema.safeParse(req.body);
      if (!parsed.success) {
        return fail(res, 400, 'INVALID_REQUEST', parsed.error.issues[0]?.message ?? 'Invalid list');
      }
      const result = await applyImport(ref(catalog), req.params.importId, parsed.data);
      if (result.outcome === 'REJECTED') return reject(res, result.code);
      res.status(200).json({ status: 'success', result: result.result, import: result.import });
    })
  );

  /** POST …/imports/:importId/undo — removes what the import created that nobody edited. */
  router.post(
    '/imports/:importId/undo',
    withCatalog(async (req, res, catalog) => {
      const result = await undoImport(ref(catalog), req.params.importId);
      if (result.outcome === 'REJECTED') return reject(res, result.code);
      res.status(200).json({
        status: 'success',
        removed: result.removed,
        kept: result.kept,
        pricesRestored: result.pricesRestored,
      });
    })
  );

  return router;
}
