// src/models/CatalogPublishRun.ts
//
// One attempt to project a catalog into Mirage.
//
// The run is the user-visible unit ("7 of 10 published · 3 failed") and the
// audit trail; the Job document behind it is the queue mechanics (claims,
// attempts, backoff). A job that retries bounces QUEUED↔PROCESSING several
// times while the run stays RUNNING and only moves on a real outcome — the same
// separation ProjectModel keeps from its generation job.
//
// `entries[]` doubles as the feature-55 activity log, which is why there is no
// fifth collection.
import { Schema, model, Document, Types } from 'mongoose';
import {
  PUBLISH_ACTIONS,
  PUBLISH_MODES,
  PUBLISH_OUTCOMES,
  PUBLISH_RUN_STATES,
  PUBLISH_TARGET_KINDS,
  type PublishRunCounts,
  type PublishRunEntry,
  type PublishMode,
  type PublishRunError,
  type PublishRunState,
} from './types/catalog.types';

export interface ICatalogPublishRun extends Document {
  catalogId: Types.ObjectId;
  userId: Types.ObjectId;
  /** The queue job that executes this run. */
  jobId: Types.ObjectId;
  /**
   * The catalog's `draftRevision` at the moment publish was requested. On a
   * fully successful run this is what `publishedRevision` becomes — NOT the
   * catalog's revision at finalize time, which may already have moved on
   * because the user kept editing while the run was in flight.
   */
  snapshotRevision: number;
  /**
   * What this run was asked to do. Fixed at creation and never re-decided — the
   * planner takes it as an input, and the status endpoint needs it to tell an
   * UNPUBLISH run apart from a FULL one (they finish with very different
   * counts and mean very different things to the user).
   */
  mode: PublishMode;
  state: PublishRunState;
  counts: PublishRunCounts;
  startedAt?: Date;
  finishedAt?: Date;
  /** Client-supplied Idempotency-Key — unique per user when present. */
  idempotencyKey?: string;
  /** Run-level failure. Per-target failures live on `entries[]`. */
  error?: PublishRunError;
  entries: PublishRunEntry[];
  createdAt: Date;
  updatedAt: Date;
}

const PublishRunCountsSchema = new Schema<PublishRunCounts>(
  {
    total: { type: Number, required: true, default: 0 },
    synced: { type: Number, required: true, default: 0 },
    failed: { type: Number, required: true, default: 0 },
    skipped: { type: Number, required: true, default: 0 },
  },
  { _id: false }
);

const PublishRunEntrySchema = new Schema<PublishRunEntry>(
  {
    target: { type: String, enum: PUBLISH_TARGET_KINDS, required: true },
    targetId: { type: String },
    // Denormalised so the log still reads sensibly after the row it names is
    // deleted. Catalog content, not PII — but it must never be copied into
    // analytics props or log lines.
    targetName: { type: String },
    action: { type: String, enum: PUBLISH_ACTIONS, required: true },
    outcome: { type: String, enum: PUBLISH_OUTCOMES, required: true },
    // A ReCapture UPPER_SNAKE code. Mirage's prose message is a classification
    // input inside the adapter and never reaches storage.
    code: { type: String },
    at: { type: Date, required: true },
  },
  { _id: false }
);

const PublishRunErrorSchema = new Schema<PublishRunError>(
  {
    code: { type: String, required: true },
    message: { type: String, required: true },
  },
  { _id: false }
);

const CatalogPublishRunSchema = new Schema<ICatalogPublishRun>(
  {
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    jobId: { type: Schema.Types.ObjectId, ref: 'Job', required: true },
    snapshotRevision: { type: Number, required: true },
    // Defaulted so runs written before this field existed read as FULL, which
    // is what every one of them was.
    mode: { type: String, enum: PUBLISH_MODES, required: true, default: 'FULL' },
    state: { type: String, enum: PUBLISH_RUN_STATES, required: true, default: 'QUEUED' },
    counts: {
      type: PublishRunCountsSchema,
      required: true,
      default: () => ({ total: 0, synced: 0, failed: 0, skipped: 0 }),
    },
    startedAt: { type: Date },
    finishedAt: { type: Date },
    idempotencyKey: { type: String, maxlength: 128 },
    error: { type: PublishRunErrorSchema },
    entries: { type: [PublishRunEntrySchema], required: true, default: [] },
  },
  { timestamps: true }
);

// ── Indexes ────────────────────────────────────────────────────────────────
// Primary read: "this catalog's runs, newest first" — the publish screen's
// current/last run and the activity log's cursor page.
CatalogPublishRunSchema.index({ catalogId: 1, createdAt: -1 });

// Idempotent publish: at most ONE run per (user, Idempotency-Key). Partial so
// runs created WITHOUT a key never collide. The identical shape ProjectModel
// uses for create-idempotency — the unique index is the race authority, and a
// double-tap's E11000 is resolved to a replay of the winner rather than a
// second run racing Mirage's non-atomic writes.
CatalogPublishRunSchema.index(
  { userId: 1, idempotencyKey: 1 },
  { unique: true, partialFilterExpression: { idempotencyKey: { $exists: true } } }
);

export const CatalogPublishRun = model<ICatalogPublishRun>(
  'CatalogPublishRun',
  CatalogPublishRunSchema
);
