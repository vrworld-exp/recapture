// src/models/User.ts
import { Schema, model, Document } from 'mongoose';

export type AuthProvider = 'cognito' | 'firebase' | 'custom';

/**
 * Access roles, in ascending privilege order. Privilege is INCLUSIVE upward
 * (ADMIN ⊇ MODEL_ARTIST ⊇ USER): every role check must go through
 * {@link hasRoleAtLeast}, never exact equality, so an admin passes every
 * model-artist gate. Granted only via scripts/set-user-role.ts (DB flag) —
 * there is deliberately no grant UI or endpoint.
 */
export const USER_ROLES = ['USER', 'MODEL_ARTIST', 'ADMIN'] as const;
export type UserRole = (typeof USER_ROLES)[number];

const ROLE_RANK: Record<UserRole, number> = { USER: 0, MODEL_ARTIST: 1, ADMIN: 2 };

/** The ONE role comparison — inclusive upward, never `===`. */
export function hasRoleAtLeast(role: UserRole, minRole: UserRole): boolean {
  return ROLE_RANK[role] >= ROLE_RANK[minRole];
}

export interface IUser extends Document {
  authProvider: AuthProvider;
  authUid: string;
  email?: string;
  phone?: string;
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
