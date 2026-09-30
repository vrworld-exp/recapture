// src/models/CatalogOffer.ts
//
// One scheduled offer or combo on a catalog (more-customization Stage 10).
//
// AUTHORED HERE, PUBLISHED AS A BLOCK. Every write bumps the catalog's
// `draftRevision` (D6), and the next publish sends the whole switched-on list
// to Mirage with the restaurant's branding (`restaurant.offers`), dishes by
// their published NAME — the Stage 7 spotlight pattern, so a dish created in
// the same publish is still found. From then on the public page starts and
// stops each offer by itself; no publish, no cron.
import { Schema, model, Document, Types } from 'mongoose';

import {
  COMBO_MAX_DISHES,
  COMBO_TITLE_MAX,
  OFFER_KINDS,
  OFFER_NAME_MAX,
  OFFER_TARGET_TYPES,
  type OfferKind,
  type OfferSchedule,
  type OfferTargetType,
} from './types/offer.types';

export interface ICatalogOffer extends Document {
  catalogId: Types.ObjectId;
  name: string;
  kind: OfferKind;
  /** 20 (%), 50 (₹ off) or 199 (₹ new price). Absent on a combo. */
  value?: number;
  target: { type: OfferTargetType; ids: Types.ObjectId[] };
  combo?: { productIds: Types.ObjectId[]; price: number; title: string };
  schedule: OfferSchedule;
  /** Paused = false: kept, not published. */
  active: boolean;
  /** When two offers hit one dish, LOWER wins; then the bigger discount. */
  priority: number;
  deletedAt?: Date | null;
  createdAt: Date;
  updatedAt: Date;
}

const ScheduleSchema = new Schema<OfferSchedule>(
  {
    startsAt: { type: Date },
    endsAt: { type: Date },
    days: { type: [Number], default: undefined },
    from: { type: String, match: /^([01]\d|2[0-3]):[0-5]\d$/ },
    to: { type: String, match: /^([01]\d|2[0-3]):[0-5]\d$/ },
  },
  { _id: false }
);

const CatalogOfferSchema = new Schema<ICatalogOffer>(
  {
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    name: { type: String, required: true, trim: true, maxlength: OFFER_NAME_MAX },
    kind: { type: String, enum: OFFER_KINDS, required: true },
    value: { type: Number },
    target: {
      type: new Schema(
        {
          type: { type: String, enum: OFFER_TARGET_TYPES, required: true },
          ids: { type: [Schema.Types.ObjectId], default: [] },
        },
        { _id: false }
      ),
      required: true,
    },
    combo: {
      type: new Schema(
        {
          productIds: {
            type: [Schema.Types.ObjectId],
            validate: (v: unknown[]) => v.length >= 2 && v.length <= COMBO_MAX_DISHES,
          },
          price: { type: Number, required: true },
          title: { type: String, trim: true, maxlength: COMBO_TITLE_MAX },
        },
        { _id: false }
      ),
    },
    schedule: { type: ScheduleSchema, default: () => ({}) },
    active: { type: Boolean, default: true },
    priority: { type: Number, default: 0 },
    deletedAt: { type: Date, default: null },
  },
  { timestamps: true }
);

// The list screen and the publish read: a catalog's live rows, in order.
CatalogOfferSchema.index({ catalogId: 1, deletedAt: 1, priority: 1 });

export const CatalogOffer = model<ICatalogOffer>('CatalogOffer', CatalogOfferSchema);
