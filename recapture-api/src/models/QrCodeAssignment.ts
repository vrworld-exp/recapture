// src/models/QrCodeAssignment.ts
import { Schema, model, Document, Types } from 'mongoose';

/**
 * The mapping LEDGER: one row per period during which a code pointed at a
 * catalog.
 *
 * `QrCode.catalogId` is the current pointer; these rows are the history.
 * Reassignment CLOSES the open row (sets `unassignedAt`) and OPENS a new one —
 * it never edits or deletes a row. That is what makes repointing a standee
 * non-destructive, and it is what lets the scan rollups stay attributed to the
 * mapping that was live when the scan actually happened: a scan counted against
 * yesterday's restaurant does not silently migrate to today's.
 *
 * The open row is the one with `unassignedAt: null`. There is at most one per
 * code, but that is an invariant the activation service maintains rather than
 * an index constraint — a partial unique index here would turn a legitimate
 * concurrent repoint into a 500 instead of a retry.
 */
export interface IQrCodeAssignment extends Document {
  qrCodeId: Types.ObjectId;
  catalogId: Types.ObjectId;
  assignedAt: Date;
  /** Null while this mapping is live; set when the code is repointed or retired. */
  unassignedAt: Date | null;
  /** The rep (or staff member) who made the mapping, for audit. */
  assignedByUserId: Types.ObjectId;
  createdAt: Date;
  updatedAt: Date;
}

const QrCodeAssignmentSchema = new Schema<IQrCodeAssignment>(
  {
    qrCodeId: { type: Schema.Types.ObjectId, ref: 'QrCode', required: true },
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    assignedAt: { type: Date, required: true },
    unassignedAt: { type: Date, default: null },
    assignedByUserId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
  },
  { timestamps: true }
);

// ── Indexes ────────────────────────────────────────────────────────────────
// "The history of this code, newest first" — and, taking the first row, "what
// does this code point at right now" without trusting the denormalised pointer.
QrCodeAssignmentSchema.index({ qrCodeId: 1, assignedAt: -1 });

// "Every code that has ever pointed at this catalog, open mappings first" —
// `unassignedAt: null` sorts ahead of any date, so the live set is the prefix.
QrCodeAssignmentSchema.index({ catalogId: 1, unassignedAt: 1 });

export const QrCodeAssignment = model<IQrCodeAssignment>(
  'QrCodeAssignment',
  QrCodeAssignmentSchema
);
