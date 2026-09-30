// src/services/offers/offerPricing.ts
//
// Offer windows and the one-price-per-dish rule (more-customization Stage 10).
//
// ⚠ DUPLICATED ON PURPOSE in mirage-fe/src/features/menu/offers.ts, which is
// what the diner actually pays by. This copy drives the app's previews ("₹250 →
// ₹199"), the status chips (Live now / Scheduled / Ended) and the save-time
// checks. Both are pinned by the same vectors (tests/fixtures/offer-vectors.json
// here, src/features/menu/offer-vectors.json there) — change one, change both
// and the vector file.
//
// Rules: one price per dish, never stacked. Lower `priority` wins; on a tie,
// the bigger discount. A result that is not above zero and below the base price
// does not apply. Pure — every function takes `now`.
import type { OfferKind, OfferSchedule } from '@/models/types/offer.types';

export const OFFER_TIMEZONE = 'Asia/Kolkata';
const ALL_DAYS = [0, 1, 2, 3, 4, 5, 6];
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/** What the pricing needs of an offer — the stored one or the published one. */
export interface PricedOffer {
  id: string;
  name: string;
  kind: OfferKind;
  value?: number;
  priority: number;
  schedule: OfferSchedule;
}

const toMinutes = (hhmm: string): number => {
  const [h, m] = hhmm.split(':').map(Number);
  return h * 60 + m;
};

/** Weekday (0 = Sunday) and minutes since midnight of `date` in `timeZone`. */
export function zonedDayMinutes(
  date: Date,
  timeZone = OFFER_TIMEZONE
): { day: number; minutes: number } {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    weekday: 'short',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(date);
  const get = (type: string): string => parts.find((p) => p.type === type)?.value ?? '';
  return {
    day: WEEKDAYS.indexOf(get('weekday')),
    minutes: Number(get('hour')) * 60 + Number(get('minute')),
  };
}

const at = (value: Date | string | undefined): number =>
  value === undefined ? NaN : typeof value === 'string' ? Date.parse(value) : value.getTime();

/** Inside its dates, on its days, in its hours — at `now`, in the restaurant's zone. */
export function isOfferLive(
  offer: Pick<PricedOffer, 'schedule'>,
  now: Date,
  timeZone = OFFER_TIMEZONE
): boolean {
  const s = offer.schedule ?? {};
  const t = now.getTime();
  const start = at(s.startsAt);
  const end = at(s.endsAt);
  if (!Number.isNaN(start) && t < start) return false;
  if (!Number.isNaN(end) && t >= end) return false;

  const days = s.days && s.days.length ? s.days : ALL_DAYS;
  const today = zonedDayMinutes(now, timeZone);
  if (!(s.from && s.to)) return days.includes(today.day);

  const from = toMinutes(s.from);
  const to = toMinutes(s.to);
  if (to > from) return days.includes(today.day) && today.minutes >= from && today.minutes < to;
  // Past midnight: tonight's window, or the tail of yesterday's.
  const yesterday = (today.day + 6) % 7;
  return (
    (days.includes(today.day) && today.minutes >= from) ||
    (days.includes(yesterday) && today.minutes < to)
  );
}

/** The price `offer` makes of `base`, or null when it would not be a real discount. */
export function discountedPrice(
  offer: Pick<PricedOffer, 'kind' | 'value'>,
  base: number
): number | null {
  if (!(base > 0) || typeof offer.value !== 'number') return null;
  let final: number;
  switch (offer.kind) {
    case 'PERCENT':
      final = Math.round(base * (1 - offer.value / 100));
      break;
    case 'FLAT':
      final = base - offer.value;
      break;
    case 'FIXED_PRICE':
      final = offer.value;
      break;
    default:
      return null;
  }
  return final > 0 && final < base ? final : null;
}

export interface OfferPrice {
  base: number;
  final: number;
  offerId: string;
  offerName: string;
}

/**
 * The one price a dish sells at under `candidates` — offers already known to be
 * live AND to target this dish. Null = full price.
 */
export function priceFor(base: number, candidates: readonly PricedOffer[]): OfferPrice | null {
  let best: OfferPrice | null = null;
  let bestPriority = Infinity;
  for (const offer of candidates) {
    if (offer.kind === 'COMBO') continue;
    const final = discountedPrice(offer, base);
    if (final === null) continue;
    if (
      offer.priority < bestPriority ||
      (offer.priority === bestPriority && best !== null && final < best.final)
    ) {
      best = { base, final, offerId: offer.id, offerName: offer.name };
      bestPriority = offer.priority;
    }
  }
  return best;
}

export type OfferStatus = 'LIVE' | 'SCHEDULED' | 'ENDED' | 'PAUSED';

/**
 * The chip on the owner's list. SCHEDULED covers both "starts on a later date"
 * and "a recurring window that is not open right now" — either way it will go
 * live by itself.
 */
export function offerStatus(
  offer: Pick<PricedOffer, 'schedule'> & { active: boolean },
  now: Date,
  timeZone = OFFER_TIMEZONE
): OfferStatus {
  if (!offer.active) return 'PAUSED';
  const end = at(offer.schedule?.endsAt);
  if (!Number.isNaN(end) && now.getTime() >= end) return 'ENDED';
  return isOfferLive(offer, now, timeZone) ? 'LIVE' : 'SCHEDULED';
}
