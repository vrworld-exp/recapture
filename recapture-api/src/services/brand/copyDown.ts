// src/services/brand/copyDown.ts
//
// Stage 16b — keep every BRANCH outlet in step with its MAIN outlet.
//
// HOW. Not by hooking each of the ~30 write paths (editor, Today, AI, import,
// rep, staff, reorder …): every authoring write already ends in a draft bump
// (D6), and `bumpDraftRevision` calls `afterAuthoringWrite`, which — for a
// MASTER catalog only — reconciles its branches. The reconcile is idempotent and
// diff-based, so running it after any write, any number of times, converges.
//
// OVERRIDES without bookkeeping in those write paths: each branch row keeps
// `masterSync`, the values copy-down last wrote. A branch field whose current
// value differs from `masterSync` is one the branch changed itself — it is left
// alone. "Reset to main outlet" simply re-copies and re-snapshots.
//
// NEVER COPIED (per outlet): availability (stock), contact, address, hours,
// announcement, links, customers, offers, staff, subscription, standees, slug,
// the review link, and the catalog name (Mirage adopts restaurants by name).
import { Types } from 'mongoose';
import { BUCKET_ARTIFACTS } from '@/config/s3';
import { Catalog, type ICatalog } from '@/models/Catalog';
import { CatalogCategory, type ICatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct, type ICatalogProduct } from '@/models/CatalogProduct';
import { copyObject } from '@/services/s3ObjectStore';
import { buildProductImageKey, parseProductImageKey } from '@/utils/productImageKeys';

// ── Field lists ─────────────────────────────────────────────────────────────

/** Catalog fields set once on the main outlet and copied to every branch (Q3). */
export const BRAND_WIDE_FIELDS = [
  'appearance',
  'logoKey',
  'coverImageKey',
  'badges',
  'languages',
  'i18n',
  'arBranding',
  'qrStyle',
  'plate',
  'aiTone',
] as const;

/** Product fields copied as-is (ids that point into the catalog are mapped separately). */
export const PRODUCT_SYNC_FIELDS = [
  'type',
  'modelStatus',
  'name',
  'description',
  'price',
  'currency',
  'tags',
  'featured',
  'foodType',
  'badgeIds',
  'dietary',
  'allergens',
  'spiceLevel',
  'calories',
  'servesCount',
  'prepMinutes',
  'i18n',
  'position',
  'sourceProjectId',
  'sourceModelId',
  'assets.glbUrl',
  'assets.usdzUrl',
  'assets.thumbnailUrl',
] as const;

/** Mapped product fields: category / pairings / image, tracked in `masterSync` too. */
export const PRODUCT_MAPPED_FIELDS = ['categoryId', 'pairsWith', 'assets.imageKey'] as const;

export const CATEGORY_SYNC_FIELDS = ['name', 'position', 'schedule', 'outsideWindow', 'i18n'] as const;

/** The fields a branch product can override — what the app labels "From main outlet". */
export const PRODUCT_OVERRIDABLE_FIELDS = [...PRODUCT_SYNC_FIELDS, ...PRODUCT_MAPPED_FIELDS];

// ── Helpers ─────────────────────────────────────────────────────────────────

function getPath(obj: unknown, path: string): unknown {
  let cur: unknown = obj;
  for (const part of path.split('.')) {
    if (cur === null || cur === undefined || typeof cur !== 'object') return undefined;
    cur = (cur as Record<string, unknown>)[part];
  }
  return cur;
}

/** Stable, ObjectId- and undefined-tolerant comparison value. */
function norm(value: unknown): string {
  return JSON.stringify(value ?? null, (_k, v: unknown) => {
    if (v instanceof Types.ObjectId) return v.toHexString();
    if (v instanceof Date) return v.toISOString();
    if (v && typeof v === 'object' && !Array.isArray(v)) {
      const o = v as Record<string, unknown>;
      if (typeof (o as { toHexString?: unknown }).toHexString === 'function') {
        return (o as unknown as Types.ObjectId).toHexString();
      }
      return Object.keys(o)
        .sort()
        .reduce<Record<string, unknown>>((acc, key) => {
          if (o[key] !== undefined) acc[key] = o[key];
          return acc;
        }, {});
    }
    return v;
  });
}

export function sameValue(a: unknown, b: unknown): boolean {
  return norm(a) === norm(b);
}

/** Mongo keys cannot hold dots — `masterSync` stores `assets.glbUrl` as `assets:glbUrl`. */
const syncKey = (field: string): string => field.replace(/\./g, ':');

/** Plain JSON copy so a Mixed snapshot never aliases a live document value. */
function snap(value: unknown): unknown {
  if (value === undefined) return null;
  return JSON.parse(norm(value));
}

/** True when the branch row still holds what copy-down last wrote there. */
function followsMaster(row: { masterSync?: Record<string, unknown> }, field: string, current: unknown): boolean {
  const sync = row.masterSync ?? {};
  if (!(syncKey(field) in sync)) return true; // never synced (e.g. a new field) — adopt the master's
  return sameValue(sync[syncKey(field)], current);
}

/** Copies a product image into the branch's own S3 keyspace (16b: never share keys). */
async function copyImageForBranch(
  masterKey: string,
  branchCatalogId: Types.ObjectId,
  branchProductId: Types.ObjectId
): Promise<string | null> {
  const parsed = parseProductImageKey(masterKey);
  if (!parsed.ok) return null;
  const destKey = buildProductImageKey(
    branchCatalogId.toHexString(),
    branchProductId.toHexString(),
    new Types.ObjectId().toHexString(),
    parsed.value.ext
  );
  try {
    await copyObject(BUCKET_ARTIFACTS, masterKey, destKey);
    return destKey;
  } catch (err) {
    console.warn(`[copy-down] image copy failed for ${masterKey}:`, (err as Error).message);
    return null;
  }
}

// ── Single-flight scheduler ─────────────────────────────────────────────────

const running = new Map<string, Promise<void>>();
const dirty = new Set<string>();

/**
 * Reconciles every branch of `masterId`. Overlapping calls for one master
 * collapse into one extra pass (in-process); the unique `{catalogId,
 * masterProductId}` index covers two API instances racing.
 * Never throws: a failed copy-down must not fail the owner's edit — the next
 * write (or "Publish all outlets") reconciles again.
 */
export function scheduleCopyDown(masterId: Types.ObjectId | string): Promise<void> {
  const key = String(masterId);
  const current = running.get(key);
  if (current) {
    dirty.add(key);
    return current;
  }
  const pass = (async () => {
    try {
      do {
        dirty.delete(key);
        await reconcileBranches(new Types.ObjectId(key));
      } while (dirty.has(key));
    } catch (err) {
      console.error(`[copy-down] master ${key} failed:`, err);
    } finally {
      running.delete(key);
    }
  })();
  running.set(key, pass);
  return pass;
}

/**
 * Called by every draft bump. A no-op (no extra read) unless the caller already
 * knows the catalog is a MASTER — `bumpDraftRevision` gets `brandRole` back
 * from its own update.
 */
export async function afterAuthoringWrite(
  catalog: { _id: unknown; brandRole?: string | null } | null
): Promise<void> {
  if (!catalog || catalog.brandRole !== 'MASTER') return;
  await scheduleCopyDown(catalog._id as Types.ObjectId);
}

// ── Reconcile ───────────────────────────────────────────────────────────────

export async function reconcileBranches(masterId: Types.ObjectId): Promise<void> {
  const master = await Catalog.findOne({ _id: masterId, brandRole: 'MASTER', deletedAt: null }).exec();
  if (!master) return;
  const branches = await Catalog.find({
    masterCatalogId: masterId,
    brandRole: 'BRANCH',
    deletedAt: null,
  }).exec();
  if (branches.length === 0) return;

  const [masterCategories, masterProducts] = await Promise.all([
    CatalogCategory.find({ catalogId: masterId }).lean<ICatalogCategory[]>().exec(),
    CatalogProduct.find({ catalogId: masterId }).lean<ICatalogProduct[]>().exec(),
  ]);

  for (const branch of branches) {
    const changed =
      (await syncBrandWide(master, branch)) ||
      false;
    const catChanged = await syncCategories(branch, masterCategories);
    const prodChanged = await syncProducts(branch, masterProducts);
    if (changed || catChanged || prodChanged) {
      await Catalog.updateOne({ _id: branch._id }, { $inc: { draftRevision: 1 } }).exec();
    }
  }
}

/** Brand-wide catalog fields (+ engagement minus the review link, + spotlight mapped). */
async function syncBrandWide(master: ICatalog, branch: ICatalog): Promise<boolean> {
  const set: Record<string, unknown> = {};
  const unset: Record<string, 1> = {};
  for (const field of BRAND_WIDE_FIELDS) {
    const want = master.get(field) as unknown;
    if (sameValue(want, branch.get(field))) continue;
    if (want === undefined || want === null) unset[field] = 1;
    else set[field] = snap(want);
  }

  const mEng = master.engagement ? { ...(snap(master.engagement) as Record<string, unknown>) } : null;
  if (mEng) {
    delete mEng.reviewUrl;
    const bEng = (snap(branch.engagement) as Record<string, unknown> | null) ?? {};
    const want = { ...mEng, ...(bEng.reviewUrl ? { reviewUrl: bEng.reviewUrl } : {}) };
    if (!sameValue(want, branch.engagement)) set.engagement = want;
  }

  if (master.spotlight) {
    const ids = master.spotlight.productIds ?? [];
    const rows = await CatalogProduct.find({
      catalogId: branch._id,
      masterProductId: { $in: ids.filter((i) => Types.ObjectId.isValid(i)).map((i) => new Types.ObjectId(i)) },
    })
      .select({ _id: 1, masterProductId: 1 })
      .lean()
      .exec();
    const byMaster = new Map(rows.map((r) => [String(r.masterProductId), String(r._id)]));
    const want = {
      ...(snap(master.spotlight) as Record<string, unknown>),
      productIds: ids.map((i) => byMaster.get(i)).filter((i): i is string => !!i),
    };
    if (!sameValue(want, branch.spotlight)) set.spotlight = want;
  } else if (branch.spotlight) {
    unset.spotlight = 1;
  }

  if (Object.keys(set).length === 0 && Object.keys(unset).length === 0) return false;
  await Catalog.updateOne(
    { _id: branch._id },
    {
      ...(Object.keys(set).length > 0 ? { $set: set } : {}),
      ...(Object.keys(unset).length > 0 ? { $unset: unset } : {}),
    }
  ).exec();
  return true;
}

async function syncCategories(branch: ICatalog, masterCategories: ICatalogCategory[]): Promise<boolean> {
  const branchId = branch._id as Types.ObjectId;
  const rows = await CatalogCategory.find({ catalogId: branchId, deletedAt: null }).exec();
  const byMaster = new Map(rows.filter((r) => r.masterCategoryId).map((r) => [String(r.masterCategoryId), r]));
  let changed = false;

  for (const m of masterCategories) {
    const mine = byMaster.get(String(m._id));
    if (m.deletedAt) {
      if (!mine) continue;
      await CatalogProduct.updateMany(
        { catalogId: branchId, categoryId: mine._id, deletedAt: null },
        { $set: { categoryId: null } }
      ).exec();
      await CatalogCategory.updateOne({ _id: mine._id, deletedAt: null }, { $set: { deletedAt: new Date() } }).exec();
      changed = true;
      continue;
    }

    const values: Record<string, unknown> = {};
    for (const f of CATEGORY_SYNC_FIELDS) values[f] = getPath(m, f);

    if (!mine) {
      const masterSync = Object.fromEntries(CATEGORY_SYNC_FIELDS.map((f) => [syncKey(f), snap(values[f])]));
      try {
        await CatalogCategory.create({
          catalogId: branchId,
          userId: branch.userId,
          masterCategoryId: m._id,
          masterSync,
          ...stripUndefined(values),
        });
      } catch (err) {
        if ((err as { code?: number }).code !== 11000) throw err;
        // Same name as a branch-only section (or a racing pass): link to it.
        await CatalogCategory.updateOne(
          { catalogId: branchId, name: m.name, deletedAt: null, masterCategoryId: { $exists: false } },
          { $set: { masterCategoryId: m._id, masterSync } }
        ).exec();
      }
      changed = true;
      continue;
    }

    const set: Record<string, unknown> = {};
    for (const f of CATEGORY_SYNC_FIELDS) {
      const current = getPath(mine.toObject(), f);
      if (sameValue(values[f], current)) continue;
      if (!followsMaster(mine, f, current)) continue; // the branch changed it itself
      set[f] = values[f] === undefined ? null : values[f];
      set[`masterSync.${syncKey(f)}`] = snap(values[f]);
    }
    if (Object.keys(set).length > 0) {
      await CatalogCategory.updateOne({ _id: mine._id }, { $set: set }).exec();
      changed = true;
    }
  }
  return changed;
}

function stripUndefined(o: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && v !== null));
}

interface Maps {
  category: Map<string, Types.ObjectId>;
  product: Map<string, Types.ObjectId>;
}

function mappedValues(m: ICatalogProduct, maps: Maps): Record<string, unknown> {
  return {
    categoryId: m.categoryId ? (maps.category.get(String(m.categoryId)) ?? null) : null,
    pairsWith: m.pairsWith
      ? m.pairsWith.map((id) => maps.product.get(String(id))).filter((x): x is Types.ObjectId => !!x)
      : undefined,
  };
}

async function syncProducts(branch: ICatalog, masterProducts: ICatalogProduct[]): Promise<boolean> {
  const branchId = branch._id as Types.ObjectId;
  let changed = false;

  const cats = await CatalogCategory.find({ catalogId: branchId, deletedAt: null, masterCategoryId: { $exists: true } })
    .select({ _id: 1, masterCategoryId: 1 })
    .lean()
    .exec();
  const maps: Maps = {
    category: new Map(cats.map((c) => [String(c.masterCategoryId), c._id as Types.ObjectId])),
    product: new Map(),
  };

  // Pass 1 — create the missing rows so pairings can be mapped in pass 2.
  let rows = await CatalogProduct.find({ catalogId: branchId, masterProductId: { $exists: true } }).exec();
  const linked = new Set(rows.map((r) => String(r.masterProductId)));
  for (const m of masterProducts) {
    if (m.deletedAt || m.archivedAt || linked.has(String(m._id))) continue;
    try {
      await cloneProduct(branch, m, maps);
      changed = true;
    } catch (err) {
      if ((err as { code?: number }).code !== 11000) throw err;
    }
  }
  if (changed) {
    rows = await CatalogProduct.find({ catalogId: branchId, masterProductId: { $exists: true } }).exec();
  }
  for (const r of rows) maps.product.set(String(r.masterProductId), r._id as Types.ObjectId);
  const byMaster = new Map(rows.map((r) => [String(r.masterProductId), r]));

  // Pass 2 — copy changed fields; archive what the main outlet removed.
  for (const m of masterProducts) {
    const mine = byMaster.get(String(m._id));
    if (!mine) continue;
    const set: Record<string, unknown> = {};
    const unset: Record<string, 1> = {};
    const sync = mine.masterSync ?? {};

    const gone = !!(m.deletedAt || m.archivedAt);
    if (gone && !mine.archivedAt && !mine.deletedAt) {
      set.archivedAt = new Date();
      set['masterSync.archivedByMain'] = true;
    } else if (!gone && mine.archivedAt && sync.archivedByMain === true) {
      unset.archivedAt = 1;
      set['masterSync.archivedByMain'] = false;
    }

    if (!gone) {
      const plain = mine.toObject() as unknown as Record<string, unknown>;
      const mapped = mappedValues(m, maps);
      for (const f of [...PRODUCT_SYNC_FIELDS, 'categoryId', 'pairsWith'] as string[]) {
        const want = f in mapped ? mapped[f] : getPath(m, f);
        const current = getPath(plain, f);
        if (sameValue(want, current)) {
          if (!sameValue(sync[syncKey(f)], want)) set[`masterSync.${syncKey(f)}`] = snap(want);
          continue;
        }
        if (!followsMaster(mine, f, current)) continue;
        if (want === undefined || want === null) unset[f] = 1;
        else set[f] = want;
        set[`masterSync.${syncKey(f)}`] = snap(want);
      }

      // The image: copied to the branch's own key whenever the master's changes.
      const masterKey = m.assets?.imageKey ?? null;
      const currentKey = mine.assets?.imageKey ?? null;
      const imageFollows = followsMaster(mine, 'assets.imageKey', currentKey);
      if (imageFollows && (sync.srcImageKey ?? null) !== masterKey) {
        if (masterKey) {
          const copied = await copyImageForBranch(masterKey, branchId, mine._id as Types.ObjectId);
          if (copied) {
            set['assets.imageKey'] = copied;
            set[`masterSync.${syncKey('assets.imageKey')}`] = copied;
            set['masterSync.srcImageKey'] = masterKey;
          }
        } else if (currentKey) {
          unset['assets.imageKey'] = 1;
          set[`masterSync.${syncKey('assets.imageKey')}`] = null;
          set['masterSync.srcImageKey'] = null;
        }
      }
    }

    if (Object.keys(set).length === 0 && Object.keys(unset).length === 0) continue;
    const touchesContent = [...Object.keys(set), ...Object.keys(unset)].some((k) => !k.startsWith('masterSync.'));
    await CatalogProduct.updateOne(
      { _id: mine._id },
      {
        ...(Object.keys(set).length > 0 ? { $set: set } : {}),
        ...(Object.keys(unset).length > 0 ? { $unset: unset } : {}),
      }
    ).exec();
    if (touchesContent) changed = true;
  }
  return changed;
}

async function cloneProduct(branch: ICatalog, m: ICatalogProduct, maps: Maps): Promise<void> {
  const branchId = branch._id as Types.ObjectId;
  const _id = new Types.ObjectId();
  const values: Record<string, unknown> = {};
  for (const f of PRODUCT_SYNC_FIELDS) {
    if (f.startsWith('assets.')) continue;
    values[f] = getPath(m, f);
  }
  const mapped = mappedValues(m, maps);
  const assets: Record<string, unknown> = {
    glbUrl: m.assets?.glbUrl,
    usdzUrl: m.assets?.usdzUrl,
    thumbnailUrl: m.assets?.thumbnailUrl,
  };
  const masterSync: Record<string, unknown> = {};
  for (const f of PRODUCT_SYNC_FIELDS) masterSync[syncKey(f)] = snap(getPath(m, f));
  masterSync.categoryId = snap(mapped.categoryId);
  masterSync.pairsWith = snap(mapped.pairsWith);
  masterSync[syncKey('assets.imageKey')] = null;
  masterSync.srcImageKey = null;

  if (m.assets?.imageKey) {
    const copied = await copyImageForBranch(m.assets.imageKey, branchId, _id);
    if (copied) {
      assets.imageKey = copied;
      masterSync[syncKey('assets.imageKey')] = copied;
      masterSync.srcImageKey = m.assets.imageKey;
    }
  }

  await CatalogProduct.create({
    _id,
    catalogId: branchId,
    userId: branch.userId,
    masterProductId: m._id,
    masterSync,
    ...stripUndefined(values),
    categoryId: mapped.categoryId,
    ...(mapped.pairsWith && (mapped.pairsWith as unknown[]).length > 0 ? { pairsWith: mapped.pairsWith } : {}),
    availability: m.availability,
    assets: stripUndefined(assets),
    syncStatus: 'NEVER',
  });
}

/**
 * "Reset to main outlet" for one branch product: every field goes back to the
 * main outlet's value and follows it again from now on.
 */
export async function resetBranchProduct(
  branchId: Types.ObjectId,
  productId: Types.ObjectId
): Promise<'OK' | 'NOT_FOUND' | 'NOT_LINKED'> {
  const row = await CatalogProduct.findOne({ _id: productId, catalogId: branchId, deletedAt: null }).exec();
  if (!row) return 'NOT_FOUND';
  if (!row.masterProductId) return 'NOT_LINKED';
  // Clearing the snapshot makes every field "never synced" → adopt the master's.
  await CatalogProduct.updateOne(
    { _id: row._id },
    { $unset: { masterSync: 1 } }
  ).exec();
  const branch = await Catalog.findById(branchId).select({ masterCatalogId: 1 }).lean().exec();
  if (branch?.masterCatalogId) await reconcileBranches(branch.masterCatalogId as Types.ObjectId);
  return 'OK';
}

/** Which fields of a branch product differ from what copy-down last wrote. */
export function overriddenFields(row: {
  masterProductId?: unknown;
  masterSync?: Record<string, unknown>;
  [k: string]: unknown;
}): string[] {
  if (!row.masterProductId || !row.masterSync) return [];
  return PRODUCT_OVERRIDABLE_FIELDS.filter(
    (f) => syncKey(f) in row.masterSync! && !sameValue(row.masterSync![syncKey(f)], getPath(row, f))
  );
}
