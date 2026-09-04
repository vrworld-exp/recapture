// src/models/QrBatch.ts
import { Schema, model, Document, Types } from 'mongoose';

/**
 * One mint run — the unit a print vendor receives as a CSV.
 *
 * Deliberately thin: label, size, who minted it. The codes point AT the batch,
 * not the reverse, so a batch document never grows with its inventory and a
 * 10,000-code mint is 10,000 small writes plus this one, not a 10,000-element
 * array that has to be read whole to answer anything.
 */
export interface IQrBatch extends Document {
  /** Free text for humans, e.g. "Vendor A — Oct 2026, run 3". Never parsed. */
  label: string;
  /**
   * How many codes were REQUESTED. `mintBatch` refuses to leave a batch behind
   * unless it minted exactly this many, so this doubles as the expected row
   * count of the export CSV — the check that catches a short print run.
   */
  count: number;
  createdByUserId: Types.ObjectId;
  createdAt: Date;
  updatedAt: Date;
}

const QrBatchSchema = new Schema<IQrBatch>(
  {
    label: { type: String, required: true, trim: true, maxlength: 120 },
    count: { type: Number, required: true, min: 1 },
    createdByUserId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
  },
  { timestamps: true }
);

// Operational query path: "recent mints first" for an ops/admin listing.
QrBatchSchema.index({ createdAt: -1 });

export const QrBatch = model<IQrBatch>('QrBatch', QrBatchSchema);
