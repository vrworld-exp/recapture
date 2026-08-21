// src/models/CatalogCategory.ts
//
// A grouping of products inside one catalog.
//
// Categories are NOT optional plumbing: Mirage's create-item rejects a missing
// or invalid category ObjectId (mirage-be/src/Controllers/adminController.js:847-854),
// so nothing can be published until the catalog's categories exist on the
// Mirage side. The "Uncategorized" bucket is a null `categoryId` on the product
// in ReCapture, materialised as a real Mirage category on first need.
import { Schema, model, Document, Types } from 'mongoose';
import { SYNC_STATUSES, type SyncError, type SyncStatus } from './types/catalog.types';
import { SyncErrorSchema } from './catalogShared';

export interface ICatalogCategory extends Document {
  catalogId: Types.ObjectId;
  /** Denormalised owner — every ownership check is then one query, no join. */
  userId: Types.ObjectId;
  name: string;
  /** Display order within the catalog. Ties break on `_id` (see the index). */
  position: number;
  /**
   * The Mirage category this maps to. Like every mapping field it is written by
   * the publish worker only.
   *
   * ⚠ It is CLEARED when Mirage's delete-item removes the category's last item.
   * The publish path passes `?keepCategory=true` to opt OUT of that cascade
   * (adminController.js:1651-1672), but a deployment predating the flag
   * cascades anyway and reports it in `deletedCategory` — at which point a stale
   * id here would make the next create-item fail with `400 "Category not
   * found"`. `categorySync.repairCascadedCategory` clears it, which forces a
   * re-create on the next run.
   */
  mirageCategoryId?: string;
  syncStatus: SyncStatus;
  syncError?: SyncError;
  lastSyncedAt?: Date;
  deletedAt?: Date;
  createdAt: Date;
  updatedAt: Date;
}

const CatalogCategorySchema = new Schema<ICatalogCategory>(
  {
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    name: { type: String, required: true, trim: true, maxlength: 80 },
    position: { type: Number, required: true, default: 0 },
    mirageCategoryId: { type: String },
    syncStatus: { type: String, enum: SYNC_STATUSES, required: true, default: 'NEVER' },
    syncError: { type: SyncErrorSchema },
    lastSyncedAt: { type: Date },
    // Soft-delete, house convention. The unique index below filters on the same
    // `deletedAt: null` form the queries use, which matches an unset field too —
    // so a live row is covered whether it stores null or nothing.
    deletedAt: { type: Date },
  },
  { timestamps: true }
);

// ── Indexes ────────────────────────────────────────────────────────────────
// Primary read: "this catalog's categories in display order". `_id` is in the
// key so equal positions still order deterministically.
CatalogCategorySchema.index({ catalogId: 1, position: 1, _id: 1 });

// Names are unique within a catalog among LIVE rows: Mirage rejects a duplicate
// (name, restaurant) category outright (adminController.js:560-568), so allowing
// two here would only defer the failure to publish time, where it is far more
// expensive to explain. Partial so deleted rows never block a re-created name
// (`deletedAt: null` also matches the unset field, so live rows are covered).
// NOTE: `{$exists: false}` is NOT usable here — Mongo rejects it in a partial
// filter as an unsupported `$not`.
CatalogCategorySchema.index(
  { catalogId: 1, name: 1 },
  { unique: true, partialFilterExpression: { deletedAt: null } }
);

export const CatalogCategory = model<ICatalogCategory>(
  'CatalogCategory',
  CatalogCategorySchema
);
