// src/models/CatalogChangeLog.ts
//
// Who changed what on the Today screen (more-customization Stage 14): one row
// per dish per change — "Ravi marked Paneer Tikka sold out · 2:14 pm", and the
// bulk price batches that "Undo last price change" reverses.
//
// Kept small and bounded: rows older than 90 days are removed by a TTL index —
// this is a "what happened this week" log, not an audit archive.
import { Schema, model, Document, Types } from 'mongoose';

export const CHANGE_KINDS = [
  'AVAILABILITY',
  'PRICE',
  'BULK_PRICE',
  'UNDO_PRICE',
  'AUTO_BACK_IN_STOCK',
] as const;
export type ChangeKind = (typeof CHANGE_KINDS)[number];

export interface ICatalogChangeLog extends Document {
  catalogId: Types.ObjectId;
  /** Null for the system (the 05:00 back-in-stock sweep). */
  actorUserId: Types.ObjectId | null;
  /** Denormalised so the log reads the same after the person is removed. */
  actorName: string;
  kind: ChangeKind;
  /** For BULK_PRICE: every dish in the batch, which is what undo restores. */
  changes: { productId: Types.ObjectId; productName: string; from: unknown; to: unknown }[];
  /** BULK_PRICE only: when it was undone (one undo per batch). */
  undoneAt?: Date | null;
  at: Date;
}

const CatalogChangeLogSchema = new Schema<ICatalogChangeLog>(
  {
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    actorUserId: { type: Schema.Types.ObjectId, ref: 'User', default: null },
    actorName: { type: String, required: true, maxlength: 60 },
    kind: { type: String, enum: CHANGE_KINDS, required: true },
    changes: {
      type: [
        new Schema(
          {
            productId: { type: Schema.Types.ObjectId, ref: 'CatalogProduct' },
            productName: String,
            from: Schema.Types.Mixed,
            to: Schema.Types.Mixed,
          },
          { _id: false }
        ),
      ],
      default: [],
    },
    undoneAt: { type: Date, default: null },
    at: { type: Date, required: true, default: () => new Date() },
  },
  { minimize: false }
);

CatalogChangeLogSchema.index({ catalogId: 1, at: -1 });
CatalogChangeLogSchema.index({ at: 1 }, { expireAfterSeconds: 90 * 24 * 60 * 60 });

export const CatalogChangeLog = model<ICatalogChangeLog>(
  'CatalogChangeLog',
  CatalogChangeLogSchema
);
