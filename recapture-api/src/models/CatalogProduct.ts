// src/models/CatalogProduct.ts
//
// One sellable item in a business's catalog — either a 3D product backed by a
// captured ProjectModel, or an image-only product that is a photo, a name and a
// price.
//
// This is the core authoring row of the whole phase. Three groups of fields
// live here and must not be confused:
//   • AUTHORING  — what the user typed/picked. Only routes/services write these,
//                  and every write bumps the catalog's `draftRevision`.
//   • MAPPING    — `mirageItemId`, `mirageCategoryIdAtSync`. Written by the
//                  publish worker only. `mirageItemId` IS the idempotency
//                  record: Mirage has no idempotency keys, so its presence is
//                  what turns a replayed publish into an UPDATE instead of a
//                  duplicate item.
//   • SYNC STATE — `syncStatus`, `syncError`, `lastSyncedAt`,
//                  `publishedSnapshot`. Also worker-owned.
import { Schema, model, Document, Types } from 'mongoose';
import {
  PRODUCT_ALLERGENS,
  PRODUCT_DIETARY,
  PRODUCT_AVAILABILITIES,
  PRODUCT_FOOD_TYPES,
  PRODUCT_MODEL_STATUSES,
  PRODUCT_TYPES,
  SYNC_STATUSES,
  type ProductAssets,
  type ProductAvailability,
  type ProductFoodType,
  type ProductModelStatus,
  type ProductPublishedSnapshot,
  type ProductTranslations,
  type ProductType,
  type SyncError,
  type SyncStatus,
} from './types/catalog.types';
import { SyncErrorSchema } from './catalogShared';

export interface ICatalogProduct extends Document {
  catalogId: Types.ObjectId;
  /** Denormalised owner — every ownership check is then one query, no join. */
  userId: Types.ObjectId;
  type: ProductType;
  /**
   * Does this product have a usable 3D model right now — the runtime fact, next
   * to `type`'s authored intent.
   *
   * AUTHORING-ADJACENT BUT NOT AUTHORED: the product services set it when a
   * model is linked, and the MESHY WORKER moves it as generation progresses. It
   * is deliberately NOT in PRODUCT_DIFF_FIELDS — Mirage has no such concept, so
   * a status change on its own has nothing to send and must not plan a publish.
   *
   * Read it through `effectiveModelStatus`, never raw: documents predating the
   * field materialise as NONE and are derived back to READY from their glbUrl.
   */
  modelStatus: ProductModelStatus;
  name: string;
  description?: string;
  /**
   * Minor-unit-free price, as Mirage stores it (`price: Number`). Mirage drops
   * a falsy or non-positive price entirely (adminController.js), so a product
   * with no price publishes as a product with no price — not as zero.
   */
  price?: number;
  /**
   * ReCapture-only. Mirage has NO currency field and its own commented-out
   * aggregation assumes INR, so this is stored for a future multi-currency
   * decision and never sent.
   */
  currency: string;
  /** null / absent = uncategorized. */
  categoryId?: Types.ObjectId | null;
  /** ReCapture-only — Mirage's item schema has no tags. */
  tags: string[];
  /** ReCapture-only — Mirage's item schema has no availability. */
  availability: ProductAvailability;
  /** ReCapture-only — Mirage's item schema has no featured flag. */
  featured: boolean;
  /**
   * The veg / non-veg / no-label marker on the public menu. PUBLISHED — see
   * ProductFoodType. Defaults to VEG; read through `effectiveFoodType` so a
   * document predating the field reads the same way.
   */
  foodType: ProductFoodType;
  /**
   * Stage 5 — PUBLISHED. Badge ids from `Catalog.badges` (a deleted badge is
   * pulled from every product in the same request), structured diet and
   * allergen codes, and optional facts. All absent on older documents, which
   * render exactly as before.
   */
  badgeIds?: string[];
  dietary?: string[];
  allergens?: string[];
  spiceLevel?: number | null;
  calories?: number | null;
  servesCount?: number | null;
  prepMinutes?: number | null;
  /**
   * Stage 6 — PUBLISHED. The dish's name / description in other languages,
   * keyed by language code. Only the catalog's enabled languages reach the
   * menu; the rest are kept for when the owner switches them back on.
   */
  i18n?: ProductTranslations;
  /**
   * Stage 7 — PUBLISHED. "Goes well with": up to four other products of this
   * catalog, in the owner's order. Published as the dishes' stored names
   * (unique per restaurant on Mirage); an archived or deleted one drops out.
   */
  pairsWith?: Types.ObjectId[];
  /**
   * Display order within the catalog. ReCapture honours it everywhere; Mirage
   * has no sort field at all, so on the public page order is by creation date.
   * That gap is real and is stated in the publish UI rather than papered over.
   */
  position: number;
  /** THREE_D only: the capture project and the ProjectModel this points at. */
  sourceProjectId?: Types.ObjectId;
  sourceModelId?: Types.ObjectId;
  assets?: ProductAssets;
  /**
   * The Mirage item id. Written IMMEDIATELY after a successful create-item and
   * before anything else in the run — that single write is what makes a crash
   * cost zero duplicates, exactly as `ProjectModel.meshyTaskId` does for Meshy.
   * Never rewritten except when Mirage reports the item is gone.
   */
  mirageItemId?: string;
  /**
   * The Mirage category the item was filed under at the last sync.
   *
   * ⚠ THE OLD REASON FOR THIS FIELD IS GONE, THE FIELD IS NOT. update-item used
   * to ignore `category`, so a move had to be published as delete + recreate;
   * the current handler applies it and repoints both back-references
   * (adminController.js:1452-1481), so a move is an ordinary UPDATE and the
   * Mirage item id — with its whole analytics history — survives. What this
   * field still answers is "which Mirage category does Mirage think this item is
   * in", which is what lets the planner notice a re-filing caused by something
   * other than an edit (the delete-item cascade re-creating a category under a
   * NEW id) and what tells productSync whether to send `categoryId` at all.
   */
  mirageCategoryIdAtSync?: string;
  syncStatus: SyncStatus;
  syncError?: SyncError;
  lastSyncedAt?: Date;
  /** The diff basis — see ProductPublishedSnapshot. */
  publishedSnapshot?: ProductPublishedSnapshot;
  /** Hidden from the catalog (and deleted from Mirage on the next publish). */
  /** Stage 13: the menu import that created it — what "Undo import" removes. */
  importId?: Types.ObjectId;
  /**
   * Stage 14.1: "sold out until tomorrow". The availability sweep puts the dish
   * back IN_STOCK at this instant (05:00 IST) and publishes. Absent = stays as set.
   */
  availabilityResetAt?: Date;
  /** Stage 16 — BRANCH rows only: the main outlet's product this one follows. */
  masterProductId?: Types.ObjectId;
  /**
   * Stage 16 — BRANCH rows only: the master's values as last copied down. A
   * field whose branch value differs from this is one the branch changed
   * itself (an override), and copy-down leaves it alone.
   */
  masterSync?: Record<string, unknown>;
  archivedAt?: Date;
  deletedAt?: Date;
  createdAt: Date;
  updatedAt: Date;
}

const ProductAssetsSchema = new Schema<ProductAssets>(
  {
    // OUR CloudFront URLs, copied from ProjectModel.artifacts.cdnUrls at
    // create/replace time. Copied rather than resolved on read so a later
    // regeneration cannot silently change what a published product points at.
    glbUrl: { type: String },
    usdzUrl: { type: String },
    thumbnailUrl: { type: String },
    // An S3 KEY, never a URL (the User.avatarKey precedent) — the API derives
    // the URL, and the key is what the commit step validates ownership against.
    imageKey: { type: String },
  },
  { _id: false }
);

const CatalogProductSchema = new Schema<ICatalogProduct>(
  {
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    type: { type: String, enum: PRODUCT_TYPES, required: true },
    // Every pre-existing document materialises as NONE on read through this
    // default, so there is no migration — the same reasoning as User.role's.
    // `effectiveModelStatus` is what turns a legacy NONE back into READY.
    modelStatus: {
      type: String,
      enum: PRODUCT_MODEL_STATUSES,
      required: true,
      default: 'NONE',
    },
    name: { type: String, required: true, trim: true, maxlength: 120 },
    description: { type: String, trim: true, maxlength: 2000 },
    price: { type: Number, min: 0 },
    currency: { type: String, required: true, default: 'INR', trim: true, maxlength: 8 },
    categoryId: { type: Schema.Types.ObjectId, ref: 'CatalogCategory', default: null },
    tags: { type: [String], required: true, default: [] },
    availability: {
      type: String,
      enum: PRODUCT_AVAILABILITIES,
      required: true,
      default: 'IN_STOCK',
    },
    featured: { type: Boolean, required: true, default: false },
    // VEG on every document that never chose, which is exactly what Mirage
    // has been rendering for those items — so no migration and no visible
    // change for anything already published.
    foodType: { type: String, enum: PRODUCT_FOOD_TYPES, required: true, default: 'VEG' },
    badgeIds: { type: [String], default: undefined },
    dietary: { type: [{ type: String, enum: PRODUCT_DIETARY }], default: undefined },
    allergens: { type: [{ type: String, enum: PRODUCT_ALLERGENS }], default: undefined },
    spiceLevel: { type: Number, min: 0, max: 3 },
    calories: { type: Number, min: 0, max: 5000 },
    servesCount: { type: Number, min: 1, max: 50 },
    prepMinutes: { type: Number, min: 0, max: 600 },
    // Mixed, keyed by language; bounds are the Zod schema's. Written through
    // dotted `i18n.<lang>` paths so one language never overwrites another.
    i18n: { type: Schema.Types.Mixed },
    pairsWith: { type: [{ type: Schema.Types.ObjectId, ref: 'CatalogProduct' }], default: undefined },
    position: { type: Number, required: true, default: 0 },
    sourceProjectId: { type: Schema.Types.ObjectId, ref: 'Project' },
    sourceModelId: { type: Schema.Types.ObjectId, ref: 'ProjectModel' },
    assets: { type: ProductAssetsSchema },
    mirageItemId: { type: String },
    mirageCategoryIdAtSync: { type: String },
    syncStatus: { type: String, enum: SYNC_STATUSES, required: true, default: 'NEVER' },
    syncError: { type: SyncErrorSchema },
    lastSyncedAt: { type: Date },
    // Mixed, NOT a sub-schema: the snapshot's shape follows whatever the planner
    // currently diffs, and a strict sub-schema would silently drop a newly
    // diffed field — which the planner would then read back as "unchanged" and
    // skip, publishing nothing. Same reasoning as ModelGenerationTrace.selection.
    publishedSnapshot: { type: Schema.Types.Mixed },
    importId: { type: Schema.Types.ObjectId, ref: 'MenuImport' },
    availabilityResetAt: { type: Date },
    masterProductId: { type: Schema.Types.ObjectId, ref: 'CatalogProduct' },
    masterSync: { type: Schema.Types.Mixed },
    archivedAt: { type: Date },
    deletedAt: { type: Date },
  },
  { timestamps: true }
);

// ── Indexes ────────────────────────────────────────────────────────────────
// Primary read: "this catalog's products in display order", and the reorder
// write. `_id` is in the key so equal positions order deterministically — the
// same tie-break discipline as the Project list's (updatedAt, _id) cursor.
CatalogProductSchema.index({ catalogId: 1, position: 1, _id: 1 });

// Category filter, excluding soft-deleted rows in the same index scan.
CatalogProductSchema.index({ catalogId: 1, categoryId: 1, deletedAt: 1 });

// The publish worker's work query ("what still needs syncing") AND feature 53's
// manual retry, which re-enqueues exactly the FAILED subset.
CatalogProductSchema.index({ catalogId: 1, syncStatus: 1 });

// Stage 14.1: the availability sweep's "due now" read.
CatalogProductSchema.index({ availabilityResetAt: 1 }, { sparse: true });

// Name search, and the pre-publish uniqueness check that mirrors Mirage's
// per-restaurant item-name constraint (adminController.js:888-897) so the
// collision is caught while the user is still looking at the product.
CatalogProductSchema.index({ catalogId: 1, name: 1 });

// "Which products are waiting on this model" — the promotion query, run once
// per finished generation and once more each time the worker moves a model's
// status. Compound with `modelStatus` because the filter on it is what makes a
// re-promotion a no-op rather than a second write.
CatalogProductSchema.index({ sourceModelId: 1, modelStatus: 1 });

// Reverse lookup Mirage id → product. Used by the analytics proxy to partition
// top-products rows into 3D vs image-only, and by reconciliation. Sparse: only
// published products carry one.
CatalogProductSchema.index({ mirageItemId: 1 }, { sparse: true });

// Stage 16: "every branch row that follows this master product" — and at most
// one per branch, so two overlapping copy-downs cannot both clone a dish.
CatalogProductSchema.index({ masterProductId: 1 }, { sparse: true });
CatalogProductSchema.index(
  { catalogId: 1, masterProductId: 1 },
  { unique: true, partialFilterExpression: { masterProductId: { $type: 'objectId' } } }
);

export const CatalogProduct = model<ICatalogProduct>('CatalogProduct', CatalogProductSchema);
