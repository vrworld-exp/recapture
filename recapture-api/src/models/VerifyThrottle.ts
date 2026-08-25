// src/models/VerifyThrottle.ts
import { Schema, model, Document } from 'mongoose';

/**
 * Sliding-window counter for verify *attempts* against one identifier.
 *
 * This is deliberately separate from the per-OTP-record `attempts` field: that
 * counter dies with its record (deleted on success, expiry, or lockout), so it
 * cannot throttle an attacker who keeps re-requesting fresh codes. This document
 * survives independently and TTL-purges once its window lapses.
 *
 * Keyed by the *hashed* identifier so no raw PII is stored. Same no-Redis,
 * DB-window technique the send path uses.
 */
export interface IVerifyThrottle extends Document {
  identifierHash: string;
  windowStartedAt: Date;
  attemptCount: number;
  /** TTL anchor — Mongo purges the doc once this time passes (see index below). */
  purgeAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const VerifyThrottleSchema = new Schema<IVerifyThrottle>(
  {
    identifierHash: { type: String, required: true, unique: true },
    windowStartedAt: { type: Date, required: true },
    attemptCount: { type: Number, required: true, default: 0 },
    purgeAt: { type: Date, required: true },
  },
  {
    timestamps: true,
  }
);

VerifyThrottleSchema.index({ purgeAt: 1 }, { expireAfterSeconds: 0 });

export const VerifyThrottle = model<IVerifyThrottle>('VerifyThrottle', VerifyThrottleSchema);
