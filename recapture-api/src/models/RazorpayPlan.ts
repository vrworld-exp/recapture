// src/models/RazorpayPlan.ts
//
// Razorpay's SUBSCRIPTIONS need a Razorpay PLAN (`plan_…`): a price and a
// period, immutable once created. We mint one per (plan, interval, price) the
// first time an owner turns autopay on at that price, and remember it here so
// every later mandate at the same price reuses it instead of piling duplicate
// plans onto the Razorpay dashboard.
//
// The price is part of the key on purpose: flipping SUBSCRIPTION_TESTING_PRICES
// or an ops re-price mints a NEW plan, and a mandate already running on the
// old one keeps charging the price the owner agreed to (§3c, the frozen quote).
import { Schema, model, Document } from 'mongoose';
import { BILLING_INTERVALS, PLAN_IDS, type BillingInterval, type PlanId } from './types/subscription.types';

export interface IRazorpayPlan extends Document {
  /** `${planId}:${interval}:${amountPaise}` — unique. */
  key: string;
  planId: PlanId;
  interval: BillingInterval;
  amountPaise: number;
  providerPlanId: string;
  createdAt: Date;
  updatedAt: Date;
}

const RazorpayPlanSchema = new Schema<IRazorpayPlan>(
  {
    key: { type: String, required: true, trim: true, maxlength: 128 },
    planId: { type: String, enum: PLAN_IDS, required: true },
    interval: { type: String, enum: BILLING_INTERVALS, required: true },
    amountPaise: { type: Number, required: true, min: 100, validate: Number.isInteger },
    providerPlanId: { type: String, required: true, trim: true, maxlength: 128 },
  },
  { timestamps: true }
);

RazorpayPlanSchema.index({ key: 1 }, { unique: true });

export function razorpayPlanKey(planId: PlanId, interval: BillingInterval, amountPaise: number): string {
  return `${planId}:${interval}:${amountPaise}`;
}

export const RazorpayPlan = model<IRazorpayPlan>('RazorpayPlan', RazorpayPlanSchema);
