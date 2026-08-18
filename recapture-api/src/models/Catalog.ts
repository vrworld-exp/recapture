// src/models/Catalog.ts
//
// ONE catalog per user — the business's storefront, authored in ReCapture and
// projected into Mirage by the publish worker.
//
// This document is the authoring root: products and categories hang off it, and
// its two revision counters are the whole draft/published split. Nothing here
// is written by the publish worker except the mapping fields
// (`mirageRestaurantId`, `mirageProvisionedAt`, `publicUrl`, `publicUrlScheme`)
// and the finalize fields (`status`, `publishedRevision`, `lastPublishedAt`,
// `activePublishRunId`).
import { Schema, model, Document, Types } from 'mongoose';
import {
  CATALOG_STATUSES,
  PUBLIC_URL_SCHEMES,
  type CatalogContact,
  type CatalogSocials,
  type CatalogStatus,
  type PublicUrlScheme,
} from './types/catalog.types';

export interface ICatalog extends Document {
  /**
   * The owner. UNIQUE — one catalog per account is the product rule, and the
   * index below is what enforces it, including under a concurrent double
   * create (the loser's E11000 is resolved to a replay of the winner, the same
   * shape as every other idempotent create in this codebase).
   */
  userId: Types.ObjectId;
  /** The catalog's display name — what customers see as the storefront title. */
  name: string;
  /** The legal/trading business name. Shown in the app; branding only. */
  businessName?: string;
  /** S3 keys, never URLs — the API derives URLs (avatar precedent). */
  logoKey?: string;
  coverImageKey?: string;
  contact?: CatalogContact;
  status: CatalogStatus;
  /**
   * The Mirage restaurant this catalog is projected into. Written ONCE, at
   * provisioning, and NEVER rewritten — the public URL is built from it, so
   * repointing it would break every printed QR.
   */
  mirageRestaurantId?: string;
  mirageProvisionedAt?: Date;
  /**
   * The customer-facing catalog URL. FROZEN at provisioning: written once and
   * read back verbatim by the QR renderer, the share sheet and every response.
   *
   * No code path may ever RECOMPUTE this for an existing catalog. That is the
   * hard constraint behind feature 32 (a printed QR must keep working through
   * renames, republishes and product churn) and it should fail code review on
   * that basis alone.
   */
  publicUrl?: string;
  /** How `publicUrl` was derived — see PUBLIC_URL_SCHEMES. */
  publicUrlScheme?: PublicUrlScheme;
  /**
   * Bumped by EVERY authoring write (catalog metadata, products, categories).
   * Paired with `publishedRevision` this is the entire "you have unpublished
   * changes" signal — no per-field dirty tracking, no diffing at read time.
   */
  draftRevision: number;
  /**
   * The `draftRevision` captured by the last FULLY successful publish run.
   * Starts at -1 so a brand-new catalog (draftRevision 0) already reads as
   * "not yet live" without a special case.
   *
   * A PARTIAL run does NOT advance it — some products failed, so "draft changes
   * not yet live" is literally true and the badge must stay on (§7.8).
   */
  publishedRevision: number;
  lastPublishedAt?: Date;
  /**
   * The in-flight publish run, or null. Set by a conditional findOneAndUpdate
   * guarded on `activePublishRunId: null`, which is what makes a second
   * simultaneous publish a clean 409 instead of two runs racing Mirage's
   * non-atomic, non-idempotent writes.
   */
  activePublishRunId?: Types.ObjectId | null;
  deletedAt?: Date;
  createdAt: Date;
  updatedAt: Date;
}

const CatalogSocialsSchema = new Schema<CatalogSocials>(
  {
    instagram: { type: String, trim: true, maxlength: 200 },
    facebook: { type: String, trim: true, maxlength: 200 },
    youtube: { type: String, trim: true, maxlength: 200 },
    whatsapp: { type: String, trim: true, maxlength: 40 },
  },
  { _id: false }
);

const CatalogContactSchema = new Schema<CatalogContact>(
  {
    phone: { type: String, trim: true, maxlength: 32 },
    email: { type: String, trim: true, maxlength: 254 },
    address: { type: String, trim: true, maxlength: 300 },
    website: { type: String, trim: true, maxlength: 200 },
    socials: { type: CatalogSocialsSchema },
  },
  { _id: false }
);

const CatalogSchema = new Schema<ICatalog>(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    name: { type: String, required: true, trim: true, maxlength: 120 },
    businessName: { type: String, trim: true, maxlength: 120 },
    logoKey: { type: String },
    coverImageKey: { type: String },
    contact: { type: CatalogContactSchema },
    status: { type: String, enum: CATALOG_STATUSES, required: true, default: 'DRAFT' },
    mirageRestaurantId: { type: String },
    mirageProvisionedAt: { type: Date },
    publicUrl: { type: String },
    publicUrlScheme: { type: String, enum: PUBLIC_URL_SCHEMES },
    draftRevision: { type: Number, required: true, default: 0 },
    publishedRevision: { type: Number, required: true, default: -1 },
    lastPublishedAt: { type: Date },
    activePublishRunId: { type: Schema.Types.ObjectId, ref: 'CatalogPublishRun', default: null },
    // Soft-delete per the house convention. NOTE the unique index below is on
    // `userId` alone, so a soft-deleted catalog still occupies its owner's one
    // slot — restore, don't re-create. That is deliberate: "delete my catalog"
    // is the explicitly-confirmed destructive action that also gives up the
    // public URL, and it must not be reachable by accident.
    deletedAt: { type: Date },
  },
  { timestamps: true }
);

// ── Indexes ────────────────────────────────────────────────────────────────
// One catalog per user. This index IS the rule — services must not try to
// enforce it with a read-then-write, which two concurrent creates would both
// pass. The loser gets E11000 and replays the winner.
CatalogSchema.index({ userId: 1 }, { unique: true });

// Operational query path: "published catalogs, most recently touched first" —
// staff/ops listing and any future backfill sweep.
CatalogSchema.index({ status: 1, updatedAt: -1 });

// ONE catalog per Mirage restaurant, enforced by the database.
//
// Provisioning ADOPTS a Mirage restaurant whose name matches (§7.5) — which is
// what lets a pilot business that already exists in Mirage keep its page. The
// hazard is the other direction: two ReCapture users who both call their
// catalog "Blue Cafe" would otherwise adopt the SAME restaurant, and the second
// one's publish would write its products into the first one's public page.
//
// Partial rather than sparse so the constraint applies to exactly the documents
// that carry a mapping; an unprovisioned catalog holds no slot.
CatalogSchema.index(
  { mirageRestaurantId: 1 },
  { unique: true, partialFilterExpression: { mirageRestaurantId: { $type: 'string' } } }
);

export const Catalog = model<ICatalog>('Catalog', CatalogSchema);

export {
  CATALOG_STATUSES,
  PUBLIC_URL_SCHEMES,
  type CatalogContact,
  type CatalogSocials,
  type CatalogStatus,
  type PublicUrlScheme,
};
