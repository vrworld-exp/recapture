# Stage 10 — Offers, combos and happy-hour pricing

**Side:** recapture-api + Flutter + Mirage BE/FE.
**Depends on:** Stage 4 (time rules in `Asia/Kolkata`), Stage 5 badges are nice-to-have.
**Size:** M

## Why

Owners run offers all the time — happy hour, weekday lunch, festival discounts — and today they
do it with a printed sheet or by editing prices and forgetting to change them back. A scheduled
offer that starts and stops by itself is something a paper menu cannot do.

## What the customer sees

- Dish card: ~~₹250~~ **₹199** with a small "Happy hour" ribbon in `--c-accent`.
- Top of menu: "🍹 Happy hour now — 20% off drinks · ends 7 pm" (reuses the Stage 4 strip area,
  under any announcement).
- An **Offers** pill in the category bar listing every dish currently on offer.
- Combos: a card "Burger + Fries + Coke — ₹299 (save ₹80)" showing the included dishes.

---

## Data model (recapture-api)

New collection `CatalogOffer`:

```ts
interface ICatalogOffer {
  catalogId: ObjectId;
  name: string;                              // "Happy hour" (shown to customers, ≤ 30)
  kind: 'PERCENT' | 'FLAT' | 'FIXED_PRICE' | 'COMBO';
  value?: number;                            // 20 (%), 50 (₹ off), 199 (₹ new price)
  target: { type: 'PRODUCTS' | 'CATEGORIES' | 'ALL'; ids: ObjectId[] };
  combo?: { productIds: ObjectId[]; price: number; title: string; imageKey?: string };
  schedule: {
    startsAt?: Date; endsAt?: Date;          // overall validity
    days?: number[]; from?: 'HH:mm'; to?: 'HH:mm'; // recurring window, optional
  };
  active: boolean;
  priority: number;                          // when two offers hit one dish, lower wins
  deletedAt?: Date;
}
```

Rules:
- One price per dish: when several offers match, pick by `priority`, then biggest discount. Never
  stack. Resolution function lives in **one** shared pure module duplicated with a shared test
  vector file in Mirage-fe (like the contrast function in Stage 2).
- Offer price must be `> 0` and `< base price`; `FIXED_PRICE` on a dish without price → 400.
- Variants: percent/flat apply to each variant price; fixed price only allowed on dishes without variants.
- Max 20 active offers per catalog.
- Creating/editing an offer is an authoring change → `$inc draftRevision` (D6), live on Publish;
  **the time window then works by itself**.

## Mirage

- **BE**: new `offerModel.js` `{ restaurant, name, kind, value, itemIds, categoryIds, all, combo, schedule, priority }`;
  admin CRUD routes mirroring category routes; the public menu endpoint returns
  `offers: [...]` for the restaurant (active + not expired only; the FE still checks the window).
- **Publish worker** (`services/catalog/publishPlanner.ts`): new step after products —
  replace-all offers for the restaurant (small list, full replace is simpler and safe). Map product
  and category ids → Mirage ids; drop references to unpublished/archived items.
- **FE**: `src/features/menu/offers.ts` — `activeOffers(offers, now, tz)` and
  `priceFor(item, offers)` → `{ base, final, offerName } | null`. `MenuItemCard` and the detail
  sheet render the strike-through. Re-evaluate every minute. Analytics: `offer_viewed` event
  (append to EVENT_TYPES in both files).

## Flutter

- **Offers** screen from catalog screen: list with status chip (Scheduled / Live now / Ended /
  Paused), toggle, swipe to delete.
- Offer editor wizard: 1) type (percent / flat / fixed / combo) 2) which dishes (search + category
  select) 3) when (always / date range / every day at times — presets "Happy hour 5–7 pm",
  "Weekday lunch 12–3 pm", "Weekend") 4) preview of 3 affected dishes with old → new price.
- Product editor shows "On offer: Happy hour (−20%)" when an offer applies.
- Weekly report (Stage 9) adds "Offer views" for live offers.

## Tests

- Price resolution: overlap by priority, no stacking, variants, fixed on variant dish rejected.
- Window: recurring across midnight, date range end, IST vs device zone.
- Worker replace-all maps ids and drops archived products.

## Done when

- [ ] "Happy hour 5–7 pm, 20% off Drinks" shows discounted prices at 5:00 and normal prices at 7:00 without a re-publish.
- [ ] A combo card shows its dishes and savings.
- [ ] A catalog without offers looks unchanged.
