// src/models/QrCode.ts
import { Schema, model, Document, Types } from 'mongoose';
import { QR_CODE_STATES, type QrCodeState } from '@/models/types/qr.types';
import { QR_CODE_LENGTH, QR_CODE_RE } from '@/utils/qrCodes';

/**
 * One pre-printed standee: a meaningless, permanent code and the pointer that
 * says what it currently resolves to.
 *
 * `catalogId` IS MANY-TO-ONE AND THAT IS THE WHOLE POINT. Replacing a lost
 * standee means activating a SECOND code onto the SAME catalog and retiring the
 * first — the catalog's `publicUrl` does not move, the old code's scan history
 * stays intact, and the catalog's own immutable-mapping rule is never
 * challenged. Do NOT add a unique index on `catalogId`.
 */
export interface IQrCode extends Document {
  /** Normalised uppercase form — see utils/qrCodes.ts. Unique across all time. */
  code: string;
  batchId: Types.ObjectId;
  state: QrCodeState;
  /**
   * The CURRENT pointer. The history is the QrCodeAssignment ledger; this field
   * is the denormalised head of it so the resolver is one indexed read.
   */
  catalogId?: Types.ObjectId;
  /**
   * The OPEN QrCodeAssignment row — the denormalised head of the ledger, in the
   * same spirit as `catalogId` above.
   *
   * STAGE-3 AMENDMENT to this stage-2 model. It exists so the public resolver's
   * hot path stays at exactly two reads (this code, then its catalog): the scan
   * rollup is bucketed by assignment, and querying the ledger for the open row
   * on every scan would add a third read to the one endpoint whose traffic is
   * unbounded and public. Activation opens the row and sets this field
   * together; retiring or repointing closes the row and moves this pointer.
   */
  currentAssignmentId?: Types.ObjectId;
  activatedAt?: Date;
  /** The rep who activated it, for audit. */
  activatedByUserId?: Types.ObjectId;
  /** House soft-delete convention. */
  deletedAt: Date | null;
  createdAt: Date;
  updatedAt: Date;
}

const QrCodeSchema = new Schema<IQrCode>(
  {
    // `match` and the length bounds are defence in depth, not the contract:
    // codes are normalised by utils/qrCodes.ts before they ever get here. They
    // exist so a hand-written script cannot seed a lowercase or short code that
    // the resolver would then never match.
    code: {
      type: String,
      required: true,
      minlength: QR_CODE_LENGTH,
      maxlength: QR_CODE_LENGTH,
      match: QR_CODE_RE,
    },
    batchId: { type: Schema.Types.ObjectId, ref: 'QrBatch', required: true },
    state: { type: String, enum: QR_CODE_STATES, required: true, default: 'UNASSIGNED' },
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog' },
    currentAssignmentId: { type: Schema.Types.ObjectId, ref: 'QrCodeAssignment' },
    activatedAt: { type: Date },
    activatedByUserId: { type: Schema.Types.ObjectId, ref: 'User' },
    deletedAt: { type: Date, default: null },
  },
  { timestamps: true }
);

// ── Indexes ────────────────────────────────────────────────────────────────
// THIS INDEX IS THE ONLY THING preventing two physical standees from carrying
// the same code, and it is what the mint path's collision retry relies on to
// detect a collision at all. Declared here (not as `unique: true` on the field)
// so it reads as the rule it is.
//
// No case-insensitive collation, deliberately: a collation makes the index's
// behaviour depend on server configuration, and correctness here must not.
// Codes are stored normalised-uppercase instead.
QrCodeSchema.index({ code: 1 }, { unique: true });

// "Which codes point at this catalog, and which of them are live" — the lookup
// behind replacing a lost standee, and behind a catalog's own QR list.
QrCodeSchema.index({ catalogId: 1, state: 1 });

// "What is in this batch, and how much of it has been activated" — the export
// CSV and the ops view of stock burn-down.
QrCodeSchema.index({ batchId: 1, state: 1 });

export const QrCode = model<IQrCode>('QrCode', QrCodeSchema);
