// src/models/RefreshToken.ts
import { Schema, model, Document, Types } from 'mongoose';

/**
 * A persisted refresh token, stored as a hash only — the plaintext is returned
 * to the client exactly once at issuance and never written down. Persisting the
 * hash is what makes a token revocable and rotatable; an unstored refresh token
 * could be neither.
 *
 * Rotation: each rotation issues a new record carrying the same `family` and a
 * `rotatedFrom` pointer to its predecessor, so a whole lineage can be revoked if
 * a stolen token is ever replayed.
 *
 * Lifecycle flags (both null at issuance):
 *   - `rotatedAt` → set when this token has been exchanged for a successor; a
 *     rotated token is single-use and must never verify again.
 *   - `revokedAt` → set when the token (or its whole family) is invalidated,
 *     e.g. by reuse-detection on the refresh endpoint.
 */
export interface IRefreshToken extends Document {
  /** HMAC of the opaque token. The raw token is never stored. */
  tokenHash: string;
  userId: Types.ObjectId;
  /** Stable id shared across one rotation lineage. */
  family: string;
  /** `_id` (as string) of the predecessor this token rotated from, if any. */
  rotatedFrom: string | null;
  /** When this token was exchanged for a successor (single-use marker). */
  rotatedAt: Date | null;
  /** When this token was explicitly invalidated. */
  revokedAt: Date | null;
  expiresAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const RefreshTokenSchema = new Schema<IRefreshToken>(
  {
    tokenHash: { type: String, required: true, unique: true },
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    family: { type: String, required: true, index: true },
    rotatedFrom: { type: String, default: null },
    rotatedAt: { type: Date, default: null },
    revokedAt: { type: Date, default: null },
    expiresAt: { type: Date, required: true },
  },
  {
    timestamps: true,
  }
);

// TTL cleanup: Mongo reaps the record once `expiresAt` passes.
RefreshTokenSchema.index({ expiresAt: 1 }, { expireAfterSeconds: 0 });

export const RefreshToken = model<IRefreshToken>('RefreshToken', RefreshTokenSchema);
