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
  ANNOUNCEMENT_STYLES,
  BADGE_COLORS,
  BADGE_ICONS,
  MENU_LANGUAGES,
  type CatalogBadge,
  type CatalogAnnouncement,
  type CatalogLanguages,
  type CatalogTranslations,
  type CatalogAppearance,
  type CatalogContact,
  type CatalogHours,
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
  /** The public menu's look — see CatalogAppearance. Absent = Basalt. */
  appearance?: CatalogAppearance;
  /** Stage 4: opening hours. Absent = none, no chip on the menu. */
  hours?: CatalogHours;
  /** Stage 4: the announcement strip. Absent = none. */
  announcement?: CatalogAnnouncement;
  /** Stage 5: the owner's badge library. Products reference these by id. */
  badges?: CatalogBadge[];
  /** Stage 6: which languages the menu is offered in. Absent = English only. */
  languages?: CatalogLanguages;
  /**
   * Stage 6: the announcement and badge labels in each extra language. Kept
   * even for a language the owner has since switched off — it is simply not
   * published until the language is back on.
   */
  i18n?: CatalogTranslations;
  status: CatalogStatus;
  /**
   * The Mirage restaurant this catalog is projected into. Written ONCE, at
   * provisioning, and NEVER rewritten — the public URL is built from it, so
   * repointing it would break every printed QR.
   */
  mirageRestaurantId?: string;
  mirageProvisionedAt?: Date;
  /**
   * The materialised "Uncategorized" Mirage category (feature 26).
   *
   * ReCapture lets a product have no category; Mirage's create-item does not —
   * it rejects a missing or invalid category ObjectId outright
   * (adminController.js:1030-1040). So the bucket is created on demand, at most
   * once, the first time a run has an uncategorized product to file, and its id
   * is remembered here so later runs reuse it instead of colliding on the name.
   *
   * Worker-owned, like every other `mirage*` field. CLEARED when Mirage's
   * delete-item cascade removes it, exactly as `CatalogCategory.mirageCategoryId`
   * is — a stale id here makes the next create-item fail on a dead parent.
   */
  mirageUncategorizedCategoryId?: string;
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

// Bounds only — membership of THEME_PRESET_IDS and colour contrast are checked
// at the API boundary (catalogSchemas.ts / colorContrast.ts), where a failure
// is a 400 with a reason rather than a Mongoose 500.
const CatalogAppearanceSchema = new Schema<CatalogAppearance>(
  {
    presetId: { type: String, trim: true, maxlength: 40 },
    mode: { type: String, enum: ['dark', 'light'] },
    primary: { type: String, trim: true, match: /^#[0-9a-fA-F]{6}$/ },
    accent: { type: String, trim: true, match: /^#[0-9a-fA-F]{6}$/ },
    layout: { type: String, enum: ['grid', 'list', 'large'] },
    fontId: { type: String, trim: true, maxlength: 40 },
    showFilters: { type: Boolean },
  },
  { _id: false }
);

// Stage 4. Bounds only — overlap / per-day / holiday rules are the Zod
// schema's job, where a failure is a 400 that names the field.
const CatalogHoursSchema = new Schema<CatalogHours>(
  {
    timezone: { type: String, trim: true, maxlength: 64, default: 'Asia/Kolkata' },
    weekly: {
      type: [
        new Schema(
          {
            day: { type: Number, min: 0, max: 6, required: true },
            open: { type: String, required: true, match: /^([01]\d|2[0-3]):[0-5]\d$/ },
            close: { type: String, required: true, match: /^([01]\d|2[0-3]):[0-5]\d$/ },
          },
          { _id: false }
        ),
      ],
      default: [],
    },
    closedDates: { type: [String], default: [] },
    showOpenBadge: { type: Boolean, default: true },
  },
  { _id: false }
);

const CatalogAnnouncementSchema = new Schema<CatalogAnnouncement>(
  {
    text: { type: String, required: true, trim: true, maxlength: 120 },
    emoji: { type: String, trim: true, maxlength: 8 },
    style: { type: String, enum: ANNOUNCEMENT_STYLES, default: 'info' },
    startsAt: { type: Date },
    endsAt: { type: Date },
    link: { type: String, trim: true, maxlength: 300 },
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
    appearance: { type: CatalogAppearanceSchema },
    hours: { type: CatalogHoursSchema },
    announcement: { type: CatalogAnnouncementSchema },
    badges: {
      type: [
        new Schema<CatalogBadge>(
          {
            id: { type: String, required: true, maxlength: 40 },
            label: { type: String, required: true, trim: true, maxlength: 18 },
            icon: { type: String, required: true, enum: BADGE_ICONS },
            color: { type: String, required: true, enum: BADGE_COLORS },
          },
          { _id: false }
        ),
      ],
      default: undefined,
    },
    languages: {
      type: new Schema<CatalogLanguages>(
        {
          primary: { type: String, enum: MENU_LANGUAGES, required: true, default: 'en' },
          extra: { type: [{ type: String, enum: MENU_LANGUAGES }], default: [] },
        },
        { _id: false }
      ),
    },
    // Mixed: keyed by language, shape and bounds checked by the Zod schema.
    // Written with dotted `i18n.<lang>` paths, so no markModified is needed.
    i18n: { type: Schema.Types.Mixed },
    status: { type: String, enum: CATALOG_STATUSES, required: true, default: 'DRAFT' },
    mirageRestaurantId: { type: String },
    mirageProvisionedAt: { type: Date },
    mirageUncategorizedCategoryId: { type: String },
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
  type CatalogAppearance,
  type CatalogContact,
  type CatalogSocials,
  type CatalogStatus,
  type PublicUrlScheme,
};
