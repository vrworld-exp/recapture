// src/models/User.ts
import { Schema, model, Document } from 'mongoose';

export type AuthProvider = 'cognito' | 'firebase' | 'custom';

export interface IUser extends Document {
  authProvider: AuthProvider;
  authUid: string;
  email?: string;
  phone?: string;
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
  },
  {
    timestamps: true,
  }
);

// authUid uniqueness is enforced by `unique: true` above, which creates
// an index automatically. No additional index needed.

export const User = model<IUser>('User', UserSchema);
