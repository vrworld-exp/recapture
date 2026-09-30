// src/models/CustomerContact.ts
//
// One diner who asked, on the public menu, to get this restaurant's offers on
// WhatsApp (more-customization Stage 12.2). Mirage takes the sign-up; ReCapture
// PULLS it (customersService.syncCustomers) with the restaurant forced from the
// owner's own mapping, so this is a copy keyed by Mirage's id.
//
// PERSONAL DATA, consent-first (DPDP Act 2023): the verbatim notice and its
// version are kept with the moment it was agreed to. An opted-out row is KEPT
// with `optedOutAt` so the opt-out is remembered — and it is excluded from every
// export and every count of who can be messaged. Rows with no activity for 24
// months are deleted, and all of them go with the catalog.
import { Schema, model, Document, Types } from 'mongoose';

export interface ICustomerContact extends Document {
  catalogId: Types.ObjectId;
  /** Mirage's opt-in id — the upsert key. */
  mirageOptInId: string;
  /** E.164, "+91…". */
  phone: string;
  name?: string;
  birthday?: { day: number; month: number };
  consentText: string;
  consentVersion: string;
  consentAt: Date;
  optedOutAt: Date | null;
  createdAt: Date;
  updatedAt: Date;
}

const CustomerContactSchema = new Schema<ICustomerContact>(
  {
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    mirageOptInId: { type: String, required: true },
    phone: { type: String, required: true, match: /^\+91[6-9]\d{9}$/ },
    name: { type: String, trim: true, maxlength: 60 },
    birthday: {
      type: new Schema(
        {
          day: { type: Number, min: 1, max: 31, required: true },
          month: { type: Number, min: 1, max: 12, required: true },
        },
        { _id: false }
      ),
    },
    consentText: { type: String, required: true, maxlength: 500 },
    consentVersion: { type: String, required: true, maxlength: 20 },
    consentAt: { type: Date, required: true },
    optedOutAt: { type: Date, default: null },
  },
  { timestamps: true }
);

CustomerContactSchema.index({ catalogId: 1, mirageOptInId: 1 }, { unique: true });
// The owner's list, newest sign-up first.
CustomerContactSchema.index({ catalogId: 1, consentAt: -1 });

export const CustomerContact = model<ICustomerContact>('CustomerContact', CustomerContactSchema);
