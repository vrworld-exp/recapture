// src/services/menuImport/menuImportService.ts
//
// Menu import from photos / PDF (more-customization Stage 13.1). The reps' big
// time saver: photograph the printed menu, get a draft, fix a few items, apply.
//
//   create  → presigned PUTs for ≤ 10 pages          (UPLOADING)
//   start   → pages checked in S3, MENU_IMPORT job    (PROCESSING)
//   worker  → each page read by the AI provider, one clean draft (READY | FAILED)
//   apply   → the reviewed list becomes categories + image-only dishes tagged
//             with the import id, ONE draftRevision bump, never a publish
//   undo    → removes what apply created that nobody has edited since
//
// Callers resolve the catalog (owner's own, or a rep's delegated one) and pass
// it in; this file never decides WHO may act, only what the action does.
import { createHash, randomUUID } from 'node:crypto';

import sharp from 'sharp';
import { Types } from 'mongoose';

import { BUCKET_RAW } from '@/config/s3';
import type { ICatalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import { Job } from '@/models/Job';
import {
  MenuImport,
  MENU_IMPORT_MAX_PAGES,
  MENU_IMPORT_MAX_PER_DAY,
  MENU_IMPORT_MEDIA_TYPES,
  type IMenuImport,
} from '@/models/MenuImport';
import { MENU_IMPORT_JOB_TYPE } from '@/models/types/job.types';
import { AiBudgetExceededError } from '@/modules/ai/budget';
import { AiOutputError, getAiProvider, type MenuPage } from '@/modules/ai/provider';
import { bumpDraftRevision } from '@/services/catalogService';
import { deleteObject, getObjectBytes, headObject, putObjectBytes } from '@/services/s3ObjectStore';
import { s3EnvPrefix } from '@/utils/s3Keys';
import {
  normalizeDishName,
  sanitizeMenu,
  variantsLine,
  type MenuDraft,
  type RawPage,
} from './sanitize';

/** Largest page accepted (a phone photo is 2–6 MB; a menu PDF rarely 10). */
export const MENU_IMPORT_MAX_FILE_BYTES = 20 * 1024 * 1024;
/** Long edge the photo is scaled to before reading — plenty for print, cheap in tokens. */
const IMAGE_LONG_EDGE = 1600;
const FILE_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

type CatalogRef = Pick<ICatalog, 'userId'> & { _id: Types.ObjectId };

// ── DTO ────────────────────────────────────────────────────────────────────

export interface MenuImportDto {
  id: string;
  status: IMenuImport['status'];
  pages: number;
  pagesDone: number;
  draft: MenuDraft | null;
  /** Draft item key → the existing dish with the same name ("update price?"). */
  matches: Record<string, { productId: string; name: string; price: number | null }>;
  error: { code: string; message: string } | null;
  costInr: number;
  createdAt: string;
}

async function matchesFor(
  catalogId: Types.ObjectId,
  draft: MenuDraft | undefined
): Promise<MenuImportDto['matches']> {
  if (!draft) return {};
  const existing = await CatalogProduct.find({ catalogId, deletedAt: null })
    .select({ _id: 1, name: 1, price: 1 })
    .lean<{ _id: Types.ObjectId; name: string; price?: number }[]>()
    .exec();
  const byName = new Map(existing.map((p) => [normalizeDishName(p.name), p]));
  const out: MenuImportDto['matches'] = {};
  for (const c of draft.categories) {
    for (const item of c.items) {
      const hit = byName.get(normalizeDishName(item.name));
      if (hit)
        out[item.key] = { productId: String(hit._id), name: hit.name, price: hit.price ?? null };
    }
  }
  return out;
}

/** A PROCESSING import untouched this long has lost its job (retries exhausted). */
const PROCESSING_STALE_MS = 30 * 60 * 1000;

async function toDto(row: IMenuImport): Promise<MenuImportDto> {
  // The job's retries can run out on a long AI outage; without this the app
  // would poll a PROCESSING import forever.
  if (row.status === 'PROCESSING' && Date.now() - row.updatedAt.getTime() > PROCESSING_STALE_MS) {
    row.status = 'FAILED';
    row.error = { code: 'TIMED_OUT', message: 'Reading the menu took too long. Please try again.' };
    await row.save();
  }
  return {
    id: String(row._id),
    status: row.status,
    pages: row.files.length,
    pagesDone: row.pagesDone,
    draft: row.draft ?? null,
    matches: row.status === 'READY' ? await matchesFor(row.catalogId, row.draft) : {},
    error: row.error ? { code: row.error.code, message: row.error.message } : null,
    costInr: row.costInr,
    createdAt: row.createdAt.toISOString(),
  };
}

// ── Create / start ─────────────────────────────────────────────────────────

export type ImportRejection =
  | 'AI_NOT_CONFIGURED'
  | 'TOO_MANY_PAGES'
  | 'UNSUPPORTED_FILE'
  | 'FILE_TOO_LARGE'
  | 'DAILY_LIMIT'
  | 'NOT_FOUND'
  | 'WRONG_STATE'
  | 'PAGES_MISSING';

const extFor = (contentType: string): string =>
  ({ 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'application/pdf': 'pdf' })[
    contentType
  ] ?? 'bin';

export async function createImport(
  catalog: CatalogRef,
  actorUserId: string,
  files: { contentType: string; size: number }[],
  now = new Date()
): Promise<
  | { outcome: 'REJECTED'; code: ImportRejection }
  | {
      outcome: 'OK';
      import: MenuImportDto;
      uploads: { page: number; contentType: string }[];
    }
> {
  if (!getAiProvider()) return { outcome: 'REJECTED', code: 'AI_NOT_CONFIGURED' };
  if (files.length === 0 || files.length > MENU_IMPORT_MAX_PAGES) {
    return { outcome: 'REJECTED', code: 'TOO_MANY_PAGES' };
  }
  if (files.some((f) => !(MENU_IMPORT_MEDIA_TYPES as readonly string[]).includes(f.contentType))) {
    return { outcome: 'REJECTED', code: 'UNSUPPORTED_FILE' };
  }
  if (files.some((f) => f.size > MENU_IMPORT_MAX_FILE_BYTES)) {
    return { outcome: 'REJECTED', code: 'FILE_TOO_LARGE' };
  }
  const today = await MenuImport.countDocuments({
    catalogId: catalog._id,
    createdAt: { $gte: new Date(now.getTime() - 24 * 60 * 60 * 1000) },
  }).exec();
  if (today >= MENU_IMPORT_MAX_PER_DAY) return { outcome: 'REJECTED', code: 'DAILY_LIMIT' };

  const id = new Types.ObjectId();
  const prefix = `${s3EnvPrefix()}/imports/${catalog._id.toHexString()}/${id.toHexString()}/`;
  const keyed = files.map((f, i) => ({
    key: `${prefix}${i + 1}-${randomUUID().slice(0, 8)}.${extFor(f.contentType)}`,
    contentType: f.contentType,
  }));
  const row = await MenuImport.create({
    _id: id,
    catalogId: catalog._id,
    createdByUserId: new Types.ObjectId(actorUserId),
    files: keyed,
  });
  return {
    outcome: 'OK',
    import: await toDto(row),
    uploads: keyed.map((f, i) => ({ page: i + 1, contentType: f.contentType })),
  };
}

/**
 * Stores one page's bytes (sent through our API, not a presigned PUT: the web
 * build cannot PUT cross-origin to the bucket — the same reason product photos
 * go through `/catalog/products/image/bytes`).
 */
export async function uploadImportPage(
  catalog: CatalogRef,
  importId: string,
  page: number,
  contentType: string,
  body: Buffer
): Promise<{ outcome: 'REJECTED'; code: ImportRejection } | { outcome: 'OK' }> {
  const row = await findImport(catalog, importId);
  if (!row) return { outcome: 'REJECTED', code: 'NOT_FOUND' };
  if (row.status !== 'UPLOADING') return { outcome: 'REJECTED', code: 'WRONG_STATE' };
  const file = row.files[page - 1];
  if (!file) return { outcome: 'REJECTED', code: 'NOT_FOUND' };
  if (file.contentType !== contentType) return { outcome: 'REJECTED', code: 'UNSUPPORTED_FILE' };
  if (body.length === 0 || body.length > MENU_IMPORT_MAX_FILE_BYTES) {
    return { outcome: 'REJECTED', code: 'FILE_TOO_LARGE' };
  }
  await putObjectBytes(BUCKET_RAW, file.key, body, contentType);
  return { outcome: 'OK' };
}

async function findImport(catalog: CatalogRef, importId: string): Promise<IMenuImport | null> {
  if (!Types.ObjectId.isValid(importId)) return null;
  return MenuImport.findOne({ _id: new Types.ObjectId(importId), catalogId: catalog._id }).exec();
}

export async function getImport(
  catalog: CatalogRef,
  importId: string
): Promise<MenuImportDto | null> {
  const row = await findImport(catalog, importId);
  return row ? toDto(row) : null;
}

/** Every page uploaded → PROCESSING + the worker job. Idempotent on retry. */
export async function startImport(
  catalog: CatalogRef,
  importId: string
): Promise<
  { outcome: 'REJECTED'; code: ImportRejection } | { outcome: 'OK'; import: MenuImportDto }
> {
  const row = await findImport(catalog, importId);
  if (!row) return { outcome: 'REJECTED', code: 'NOT_FOUND' };
  if (row.status === 'PROCESSING') return { outcome: 'OK', import: await toDto(row) };
  if (row.status !== 'UPLOADING') return { outcome: 'REJECTED', code: 'WRONG_STATE' };

  for (const f of row.files) {
    const head = await headObject(BUCKET_RAW, f.key);
    if (head.outcome === 'absent') return { outcome: 'REJECTED', code: 'PAGES_MISSING' };
    if (head.contentLength > MENU_IMPORT_MAX_FILE_BYTES) {
      return { outcome: 'REJECTED', code: 'FILE_TOO_LARGE' };
    }
  }
  row.status = 'PROCESSING';
  await row.save();
  try {
    await Job.create({
      userId: catalog.userId,
      jobType: MENU_IMPORT_JOB_TYPE,
      state: 'QUEUED',
      idempotencyKey: `menu-import:${row._id.toHexString()}`,
      queuedAt: new Date(),
      payload: { importId: row._id.toHexString() },
    });
  } catch (err) {
    if ((err as { code?: unknown }).code !== 11000) throw err;
  }
  return { outcome: 'OK', import: await toDto(row) };
}

// ── Worker ─────────────────────────────────────────────────────────────────

async function pageFor(key: string, contentType: string): Promise<MenuPage | null> {
  const got = await getObjectBytes(BUCKET_RAW, key);
  if (got.outcome === 'absent') return null;
  if (contentType === 'application/pdf') {
    return { mediaType: 'application/pdf', base64: got.body.toString('base64') };
  }
  // Upright (EXIF), scaled down, re-encoded: a 12 MP phone photo becomes a few
  // hundred KB the model reads just as well, at a fraction of the tokens.
  const jpeg = await sharp(got.body)
    .rotate()
    .resize({
      width: IMAGE_LONG_EDGE,
      height: IMAGE_LONG_EDGE,
      fit: 'inside',
      withoutEnlargement: true,
    })
    .jpeg({ quality: 85 })
    .toBuffer();
  return { mediaType: 'image/jpeg', base64: jpeg.toString('base64') };
}

/**
 * The MENU_IMPORT job body. A page the model declines or garbles is skipped
 * (and said so); the import fails only when no page produced a dish. Transient
 * API errors throw — the worker retries the job, and pages already read are
 * read again (the draft is rebuilt whole, never appended to).
 */
export async function processImport(importId: string): Promise<{ status: string; dishes: number }> {
  const row = await MenuImport.findById(importId).exec();
  if (!row || row.status !== 'PROCESSING') return { status: row?.status ?? 'GONE', dishes: 0 };
  const provider = getAiProvider();
  const fail = async (code: string, message: string) => {
    row.status = 'FAILED';
    row.error = { code, message };
    await row.save();
    return { status: 'FAILED', dishes: 0 };
  };
  if (!provider) return fail('AI_NOT_CONFIGURED', 'Menu import is switched off.');

  const pages: RawPage[] = [];
  let skipped = 0;
  row.pagesDone = 0;
  row.costInr = 0;
  for (const f of row.files) {
    const page = await pageFor(f.key, f.contentType);
    if (!page) {
      skipped += 1;
    } else {
      try {
        const { value, costInr } = await provider.extractMenu(page);
        pages.push(value);
        row.costInr = Math.round((row.costInr + costInr) * 100) / 100;
      } catch (err) {
        if (err instanceof AiBudgetExceededError) {
          return fail(
            'AI_BUDGET',
            'The AI budget for this month is used up. Try again next month.'
          );
        }
        if (!(err instanceof AiOutputError)) throw err;
        skipped += 1;
      }
    }
    row.pagesDone += 1;
    await row.save();
  }

  const draft = sanitizeMenu(pages);
  const dishes = draft.categories.reduce((n, c) => n + c.items.length, 0);
  if (dishes === 0) {
    return fail(
      'NO_DISHES',
      skipped
        ? 'No dishes could be read. Retake the photos flat, in good light, one page per photo.'
        : 'No dishes were found on these pages.'
    );
  }
  row.draft = draft;
  row.status = 'READY';
  if (skipped)
    row.error = { code: 'PAGES_SKIPPED', message: `${skipped} page(s) could not be read.` };
  await row.save();
  return { status: 'READY', dishes };
}

// ── Apply / undo ───────────────────────────────────────────────────────────

export interface ApplyItemInput {
  name: string;
  description?: string | null;
  price?: number | null;
  variants?: { label: string; price: number }[];
  foodType?: 'VEG' | 'NON_VEG' | 'NONE';
  /** When set, this row UPDATES that existing dish's price instead of creating one. */
  updateProductId?: string;
}

export interface ApplyInput {
  categories: { name: string; items: ApplyItemInput[] }[];
}

export interface ApplyResultDto {
  created: number;
  updated: number;
  /** Rows skipped because a dish with that name already exists (and no update was chosen). */
  skipped: number;
  categoriesCreated: number;
}

/** What "edited since" is judged by: the fields an owner or rep actually changes. */
const fingerprint = (p: {
  name: string;
  price?: number | null;
  description?: string | null;
  categoryId?: Types.ObjectId | null;
  foodType?: string;
}): string =>
  createHash('sha1')
    .update(
      JSON.stringify([
        p.name,
        p.price ?? null,
        p.description ?? null,
        String(p.categoryId ?? ''),
        p.foodType ?? '',
      ])
    )
    .digest('hex');

export async function applyImport(
  catalog: CatalogRef,
  importId: string,
  input: ApplyInput
): Promise<
  | { outcome: 'REJECTED'; code: ImportRejection }
  | { outcome: 'OK'; result: ApplyResultDto; import: MenuImportDto }
> {
  const row = await findImport(catalog, importId);
  if (!row) return { outcome: 'REJECTED', code: 'NOT_FOUND' };
  if (row.status !== 'READY') return { outcome: 'REJECTED', code: 'WRONG_STATE' };
  const catalogId = catalog._id;

  const [liveCategories, liveProducts, maxCat, maxProd] = await Promise.all([
    CatalogCategory.find({ catalogId, deletedAt: null }).select({ _id: 1, name: 1 }).lean().exec(),
    CatalogProduct.find({ catalogId, deletedAt: null })
      .select({ _id: 1, name: 1, price: 1 })
      .lean<{ _id: Types.ObjectId; name: string; price?: number }[]>()
      .exec(),
    CatalogCategory.findOne({ catalogId, deletedAt: null })
      .sort({ position: -1 })
      .select({ position: 1 })
      .lean()
      .exec(),
    CatalogProduct.findOne({ catalogId, deletedAt: null })
      .sort({ position: -1 })
      .select({ position: 1 })
      .lean()
      .exec(),
  ]);
  const categoryByName = new Map(
    liveCategories.map((c) => [normalizeDishName(c.name), c._id as Types.ObjectId])
  );
  const productByName = new Map(liveProducts.map((p) => [normalizeDishName(p.name), p]));
  const productById = new Map(liveProducts.map((p) => [String(p._id), p]));

  let categoryPosition = (maxCat?.position ?? -1) + 1;
  let productPosition = (maxProd?.position ?? -1) + 1;
  const createdCategoryIds: Types.ObjectId[] = [];
  const createdProductIds: Types.ObjectId[] = [];
  const fingerprints: Record<string, string> = {};
  const priceUpdates: { productId: Types.ObjectId; from: number | null; to: number }[] = [];
  const usedNames = new Set<string>();
  let skipped = 0;

  for (const c of input.categories) {
    const items = c.items.filter((i) => i.name.trim());
    if (items.length === 0) continue;
    let categoryId: Types.ObjectId | null = null;
    const categoryFor = async (): Promise<Types.ObjectId> => {
      if (categoryId) return categoryId;
      const key = normalizeDishName(c.name) || 'menu';
      const existing = categoryByName.get(key);
      if (existing) {
        categoryId = existing;
        return existing;
      }
      const created = await CatalogCategory.create({
        catalogId,
        userId: catalog.userId,
        name: c.name.trim().slice(0, 80) || 'Menu',
        position: categoryPosition++,
        importId: row._id,
      });
      categoryId = created._id as Types.ObjectId;
      categoryByName.set(key, categoryId);
      createdCategoryIds.push(categoryId);
      return categoryId;
    };

    for (const item of items) {
      if (item.updateProductId) {
        const target = productById.get(item.updateProductId);
        if (
          target &&
          typeof item.price === 'number' &&
          item.price > 0 &&
          item.price !== target.price
        ) {
          await CatalogProduct.updateOne(
            { _id: target._id, catalogId },
            { $set: { price: item.price } }
          ).exec();
          priceUpdates.push({ productId: target._id, from: target.price ?? null, to: item.price });
        }
        continue;
      }
      const key = normalizeDishName(item.name);
      if (!key || productByName.has(key) || usedNames.has(key)) {
        skipped += 1;
        continue;
      }
      usedNames.add(key);
      const variants = item.variants ?? [];
      const description = [
        item.description?.trim() || '',
        variants.length > 1 ? variantsLine(variants) : '',
      ]
        .filter(Boolean)
        .join(' — ')
        .slice(0, 2000);
      const doc = {
        catalogId,
        userId: catalog.userId,
        type: 'IMAGE_ONLY' as const,
        name: item.name.trim().slice(0, 120),
        ...(description ? { description } : {}),
        ...(typeof item.price === 'number' && item.price > 0 ? { price: item.price } : {}),
        categoryId: await categoryFor(),
        foodType: item.foodType ?? 'NONE',
        position: productPosition++,
        importId: row._id,
      };
      const created = await CatalogProduct.create(doc);
      createdProductIds.push(created._id as Types.ObjectId);
      fingerprints[String(created._id)] = fingerprint(created);
    }
  }

  if (createdProductIds.length || priceUpdates.length) await bumpDraftRevision(catalogId);
  row.status = 'APPLIED';
  row.appliedAt = new Date();
  row.applied = {
    categoryIds: createdCategoryIds,
    productIds: createdProductIds,
    priceUpdates,
    // Stored beside the ids: what each created dish looked like, for undo.
    ...({ fingerprints } as object),
  } as IMenuImport['applied'];
  await row.save();
  await purgeFiles(row).catch(() => undefined);
  return {
    outcome: 'OK',
    result: {
      created: createdProductIds.length,
      updated: priceUpdates.length,
      skipped,
      categoriesCreated: createdCategoryIds.length,
    },
    import: await toDto(row),
  };
}

/**
 * Undo: removes the dishes this import created that are exactly as it left
 * them (edited ones stay), puts back prices it changed if still untouched, and
 * removes the sections it created that are now empty. One draftRevision bump.
 */
export async function undoImport(
  catalog: CatalogRef,
  importId: string
): Promise<
  | { outcome: 'REJECTED'; code: ImportRejection }
  | { outcome: 'OK'; removed: number; kept: number; pricesRestored: number }
> {
  const row = await findImport(catalog, importId);
  if (!row) return { outcome: 'REJECTED', code: 'NOT_FOUND' };
  if (row.status !== 'APPLIED' || !row.applied) return { outcome: 'REJECTED', code: 'WRONG_STATE' };
  const catalogId = catalog._id;
  const applied = row.applied as NonNullable<IMenuImport['applied']> & {
    fingerprints?: Record<string, string>;
  };
  const now = new Date();

  const created = await CatalogProduct.find({
    _id: { $in: applied.productIds },
    catalogId,
    deletedAt: null,
  }).exec();
  let removed = 0;
  let kept = 0;
  for (const p of created) {
    if (applied.fingerprints?.[String(p._id)] === fingerprint(p)) {
      await CatalogProduct.updateOne(
        { _id: p._id, deletedAt: null },
        { $set: { deletedAt: now } }
      ).exec();
      removed += 1;
    } else {
      kept += 1;
    }
  }

  let pricesRestored = 0;
  for (const u of applied.priceUpdates ?? []) {
    const res = await CatalogProduct.updateOne(
      { _id: u.productId, catalogId, deletedAt: null, price: u.to },
      u.from === null ? { $unset: { price: 1 } } : { $set: { price: u.from } }
    ).exec();
    pricesRestored += res.modifiedCount;
  }

  for (const categoryId of applied.categoryIds) {
    const stillUsed = await CatalogProduct.exists({
      catalogId,
      categoryId,
      deletedAt: null,
    }).exec();
    if (!stillUsed) {
      await CatalogCategory.updateOne(
        { _id: categoryId, catalogId, deletedAt: null },
        { $set: { deletedAt: now } }
      ).exec();
    }
  }

  if (removed || pricesRestored) await bumpDraftRevision(catalogId);
  row.status = 'UNDONE';
  await row.save();
  return { outcome: 'OK', removed, kept, pricesRestored };
}

// ── Files ──────────────────────────────────────────────────────────────────

async function purgeFiles(row: IMenuImport): Promise<void> {
  if (row.filesPurgedAt) return;
  await Promise.all(row.files.map((f) => deleteObject(BUCKET_RAW, f.key).catch(() => undefined)));
  row.filesPurgedAt = new Date();
  await row.save();
}

/** Periodic: menu photos kept at most 30 days (applied / undone ones go at once). */
export async function purgeOldImportFiles(now = new Date()): Promise<number> {
  const old = await MenuImport.find({
    filesPurgedAt: null,
    createdAt: { $lt: new Date(now.getTime() - FILE_RETENTION_MS) },
  })
    .limit(100)
    .exec();
  for (const row of old) await purgeFiles(row);
  return old.length;
}
