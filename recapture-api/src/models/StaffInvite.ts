// src/models/StaffInvite.ts
//
// An owner's invitation for someone to help run the menu (more-customization
// Stage 14.3), by phone number. If a ReCapture user with that verified phone
// already exists the grant is made at once and no invite is stored; otherwise
// this row waits until that person signs in with the number (OTP) and opens
// the staff area, which claims it into a CatalogDelegation.
import { Schema, model, Document, Types } from 'mongoose';

export interface IStaffInvite extends Document {
  catalogId: Types.ObjectId;
  /** E.164, as the owner typed it (normalised). */
  phone: string;
  kind: 'MANAGER' | 'STAFF';
  /** What the owner calls them ("Ravi"). */
  name?: string;
  invitedByUserId: Types.ObjectId;
  claimedAt: Date | null;
  revokedAt: Date | null;
  createdAt: Date;
  updatedAt: Date;
}

const StaffInviteSchema = new Schema<IStaffInvite>(
  {
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    phone: { type: String, required: true, match: /^\+[1-9]\d{6,14}$/ },
    kind: { type: String, enum: ['MANAGER', 'STAFF'], required: true },
    name: { type: String, trim: true, maxlength: 40 },
    invitedByUserId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    claimedAt: { type: Date, default: null },
    revokedAt: { type: Date, default: null },
  },
  { timestamps: true }
);

// One open invite per number per catalog.
StaffInviteSchema.index(
  { catalogId: 1, phone: 1 },
  { unique: true, partialFilterExpression: { claimedAt: null, revokedAt: null } }
);
// The claim read: "open invites for this phone".
StaffInviteSchema.index({ phone: 1, claimedAt: 1, revokedAt: 1 });

export const StaffInvite = model<IStaffInvite>('StaffInvite', StaffInviteSchema);
