// src/models/QrScanDaily.ts
import { Schema, model, Document, Types } from 'mongoose';

/**
 * Scan counts, rolled up to one document per code per assignment per day.
 *
 * A ROLLUP RATHER THAN PER-SCAN ROWS because scan volume is unbounded and
 * public — every customer who looks at a menu is a write — while the resolver
 * must stay fast. This is the same no-Redis, DB-backed shape the rest of the
 * service uses: the resolver does a single `$inc` upsert against the unique
 * index below and returns.
 *
 * `assignmentId` is part of the identity, not just a reference: it is what keeps
 * a repointed code's history honest. Scans that happened while the code pointed
 * at restaurant A stay on A's row forever, and the repoint starts a new row
 * rather than continuing the old count under new ownership.
 */
export interface IQrScanDaily extends Document {
  qrCodeId: Types.ObjectId;
  assignmentId: Types.ObjectId;
  /**
   * The UTC day bucket as `YYYY-MM-DD`.
   *
   * A STRING, NOT A DATE, and UTC rather than local, so the bucket boundary is
   * explicit and cannot drift with the server's timezone. A Date here would
   * make "which day is this scan in" depend on where the process happens to be
   * running, and a redeploy into another region would silently re-bucket.
   */
  day: string;
  count: number;
  createdAt: Date;
  updatedAt: Date;
}

const QrScanDailySchema = new Schema<IQrScanDaily>(
  {
    qrCodeId: { type: Schema.Types.ObjectId, ref: 'QrCode', required: true },
    assignmentId: { type: Schema.Types.ObjectId, ref: 'QrCodeAssignment', required: true },
    day: { type: String, required: true, match: /^\d{4}-\d{2}-\d{2}$/ },
    count: { type: Number, required: true, default: 0 },
  },
  { timestamps: true }
);

// ── Indexes ────────────────────────────────────────────────────────────────
// The bucket identity. This unique index IS the upsert target — the resolver
// relies on it to turn "increment today's count" into one atomic round trip
// with no read-then-write race between concurrent scans.
QrScanDailySchema.index({ qrCodeId: 1, assignmentId: 1, day: 1 }, { unique: true });

// "Scans for this mapping over a date range" — the per-catalog analytics read.
QrScanDailySchema.index({ assignmentId: 1, day: 1 });

export const QrScanDaily = model<IQrScanDaily>('QrScanDaily', QrScanDailySchema);
