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
  PRODUCT_AVAILABILITIES,
  PRODUCT_TYPES,
  SYNC_STATUSES,
  type ProductAssets,
  type ProductAvailability,
  type ProductPublishedSnapshot,
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

// Name search, and the pre-publish uniqueness check that mirrors Mirage's
// per-restaurant item-name constraint (adminController.js:888-897) so the
// collision is caught while the user is still looking at the product.
CatalogProductSchema.index({ catalogId: 1, name: 1 });

// Reverse lookup Mirage id → product. Used by the analytics proxy to partition
// top-products rows into 3D vs image-only, and by reconciliation. Sparse: only
// published products carry one.
CatalogProductSchema.index({ mirageItemId: 1 }, { sparse: true });

export const CatalogProduct = model<ICatalogProduct>('CatalogProduct', CatalogProductSchema);
