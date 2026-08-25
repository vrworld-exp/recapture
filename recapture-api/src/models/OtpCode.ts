// src/models/OtpCode.ts
import { Schema, model, Document } from 'mongoose';

export type OtpChannel = 'sms' | 'email';

/**
 * A pending one-time passcode for a single identifier (normalized phone or
 * email). At most one record exists per identifier — each new send overwrites
 * the previous one, so only the latest code can ever verify.
 *
 * The plaintext code is NEVER stored: only `otpHash` (an HMAC) is persisted.
 * The verify endpoint (separate task) consumes `attempts` and checks `expiresAt`.
 *
 * Rate-limit bookkeeping lives on the same document so the send path needs a
 * single round-trip (no Redis in this service):
 *   - `lastSentAt`      → resend-cooldown anchor
 *   - `windowStartedAt` → start of the current sliding send window
 *   - `sendCount`       → sends so far within that window
 */
export interface IOtpCode extends Document {
  identifier: string; // normalized phone (E.164) or lowercased email
  channel: OtpChannel;
  otpHash: string;
  expiresAt: Date;
  attempts: number;
  lastSentAt: Date;
  windowStartedAt: Date;
  sendCount: number;
  /** TTL anchor — Mongo purges the doc once this time passes (see index below). */
  purgeAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const OtpCodeSchema = new Schema<IOtpCode>(
  {
    identifier: {
      type: String,
      required: true,
      unique: true, // one live OTP record per identifier (auto-indexed)
    },
    channel: {
      type: String,
      enum: ['sms', 'email'],
      required: true,
    },
    otpHash: { type: String, required: true },
    expiresAt: { type: Date, required: true },
    attempts: { type: Number, required: true, default: 0 },
    lastSentAt: { type: Date, required: true },
    windowStartedAt: { type: Date, required: true },
    sendCount: { type: Number, required: true, default: 1 },
    purgeAt: { type: Date, required: true },
  },
  {
    timestamps: true,
  }
);

// TTL cleanup: delete the record once `purgeAt` is in the past. `purgeAt` is set
// to outlast both the OTP validity and the rate window, so expired codes are
// reaped without dropping rate-limit counters mid-window.
OtpCodeSchema.index({ purgeAt: 1 }, { expireAfterSeconds: 0 });

export const OtpCode = model<IOtpCode>('OtpCode', OtpCodeSchema);
