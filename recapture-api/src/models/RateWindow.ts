// src/models/RateWindow.ts
import { Schema, model, Document } from 'mongoose';

/**
 * Generic DB-backed sliding-window counter, keyed by an opaque string. This
 * service has no Redis, so rate limiting reuses the same single-document window
 * technique the OTP send path uses — generalized here so any endpoint can share
 * it (see `consumeRateWindow`). TTL-purges once a window lapses.
 *
 * The `key` is caller-namespaced (e.g. `refresh:<ip>`) and should never contain
 * raw PII — hash any identifier before using it as a key.
 */
export interface IRateWindow extends Document {
  key: string;
  windowStartedAt: Date;
  count: number;
  /** TTL anchor — Mongo purges the doc once this time passes (see index below). */
  purgeAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const RateWindowSchema = new Schema<IRateWindow>(
  {
    key: { type: String, required: true, unique: true },
    windowStartedAt: { type: Date, required: true },
    count: { type: Number, required: true, default: 0 },
    purgeAt: { type: Date, required: true },
  },
  {
    timestamps: true,
  }
);

RateWindowSchema.index({ purgeAt: 1 }, { expireAfterSeconds: 0 });

export const RateWindow = model<IRateWindow>('RateWindow', RateWindowSchema);
