// src/models/types/offer.types.ts
//
// Offers, combos and happy-hour pricing (more-customization Stage 10).

export const OFFER_KINDS = ['PERCENT', 'FLAT', 'FIXED_PRICE', 'COMBO'] as const;
export type OfferKind = (typeof OFFER_KINDS)[number];

export const OFFER_TARGET_TYPES = ['PRODUCTS', 'CATEGORIES', 'ALL'] as const;
export type OfferTargetType = (typeof OFFER_TARGET_TYPES)[number];

export interface OfferSchedule {
  /** Overall validity. Either bound optional. */
  startsAt?: Date | string;
  endsAt?: Date | string;
  /** Recurring weekdays, 0 = Sunday … 6. Absent / empty = every day. */
  days?: number[];
  /** Recurring daily window, "HH:mm" in Asia/Kolkata; `to` < `from` runs past midnight. */
  from?: string;
  to?: string;
}

/** At most this many switched-on offers per catalog. */
export const MAX_ACTIVE_OFFERS = 20;
/** `name` is what customers read on the ribbon. */
export const OFFER_NAME_MAX = 30;
export const COMBO_TITLE_MAX = 40;
export const COMBO_MAX_DISHES = 10;
