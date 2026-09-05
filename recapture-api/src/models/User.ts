// src/models/User.ts
import { Schema, model, Document } from 'mongoose';

export type AuthProvider = 'cognito' | 'firebase' | 'custom';

/**
 * Access roles, in ascending privilege order. Privilege is INCLUSIVE upward
 * (ADMIN ⊇ MODEL_ARTIST ⊇ SALES_REP ⊇ USER): every role check must go through
 * {@link hasRoleAtLeast}, never exact equality, so an admin passes every
 * model-artist gate. Granted only via scripts/set-user-role.ts (DB flag) —
 * there is deliberately no grant UI or endpoint.
 *
 * SALES_REP sits at rank 1: a rep is trusted with act-on-behalf-of writes but
 * with none of the staff surfaces. Note the upward inclusion is REAL here —
 * MODEL_ARTIST and ADMIN both pass every /rep gate. That is accepted, not
 * overlooked: both are script-granted trusted roles, and every acting-on-behalf
 * write leaves a CatalogDelegation row, so the inheritance is auditable.
 */
export const USER_ROLES = ['USER', 'SALES_REP', 'MODEL_ARTIST', 'ADMIN'] as const;
export type UserRole = (typeof USER_ROLES)[number];

const ROLE_RANK: Record<UserRole, number> = {
  USER: 0,
  SALES_REP: 1,
  MODEL_ARTIST: 2,
  ADMIN: 3,
};

/** The ONE role comparison — inclusive upward, never `===`. */
export function hasRoleAtLeast(role: UserRole, minRole: UserRole): boolean {
  return ROLE_RANK[role] >= ROLE_RANK[minRole];
}

export interface IUser extends Document {
  authProvider: AuthProvider;
  authUid: string;
  email?: string;
  phone?: string;
  /**
   * User-chosen display name, shown on the Profile screen. Optional and
   * unverified — the OTP flow never collects one, so every pre-existing user
   * reads as `undefined` (no migration needed, same reasoning as the `role`
   * default below). Set only via PATCH /auth/me.
   */
  displayName?: string;
  /**
   * The S3 KEY of the user's profile picture — `{env}/avatars/{id}/{uuid}.jpg`
   * (utils/avatarKeys.ts) — NEVER a URL.
   *
   * The raw bucket is private, so the only readable URL is a PRESIGNED one, and
   * a presigned URL is a bearer credential that dies within the hour.
   * Persisting one would put a short-lived credential in a document that gets
   * logged, exported and backed up. The URL is therefore DERIVED per response
   * (see accountSnapshot) and exists nowhere else.
   *
   * Absent on every pre-existing document; materializes as undefined on read,
   * so there is no migration (same reasoning as the `role` default below).
   */
  avatarKey?: string;
  /** When the avatar was last set. Absent — not null — when never set. */
  avatarUpdatedAt?: Date;
  emailVerified: boolean;
  phoneVerified: boolean;
  role: UserRole;
  createdAt: Date;
  updatedAt: Date;
}

const UserSchema = new Schema<IUser>(
  {
    authProvider: {
      type: String,
      enum: ['cognito', 'firebase', 'custom'],
      required: true,
    },
    authUid: {
      type: String,
      required: true,
      unique: true,
    },
    email: {
      type: String,
      lowercase: true,
      trim: true,
    },
    phone: {
      type: String,
      trim: true,
    },
    // Absent on every pre-existing document; materializes as undefined on read.
    displayName: {
      type: String,
      trim: true,
      maxlength: 60,
    },
    // The S3 key, never a URL — see the interface comment above.
    avatarKey: {
      type: String,
      trim: true,
    },
    avatarUpdatedAt: { type: Date },
    // Set true once the identifier is proven via a successful OTP verification.
    emailVerified: { type: Boolean, required: true, default: false },
    phoneVerified: { type: Boolean, required: true, default: false },
    // The schema default also backfills pre-role documents on read: a user doc
    // without the field materializes as USER, so no migration is needed.
    role: {
      type: String,
      enum: USER_ROLES,
      required: true,
      default: 'USER',
    },
  },
  {
    timestamps: true,
  }
);

// authUid uniqueness is enforced by `unique: true` above, which creates
// an index automatically. No additional index needed.

export const User = model<IUser>('User', UserSchema);
