# ✅ Stage 10 — Offers, combos and happy-hour pricing

> **Status (2026-09-30): built, uncommitted.** Typecheck / analyze / lint clean on all four sides.
> Tests (only the necessary ones): the SHARED vector file `offer-vectors.json` (21 cases: windows,
> past midnight, IST vs UTC, date-range ends, priority, tie → bigger discount, no stacking,
> non-discounts skipped) runs against BOTH pricing copies — `mirage-fe/src/features/menu/offers.test.tsx`
> (26, passing) and `recapture-api/tests/catalog-offers.test.ts` (29, passing, also save-time rules,
> the 20-active cap, draftRevision bumps, and the publish block). Full suite not run.
>
> **API** — `models/CatalogOffer.ts` + `types/offer.types.ts`; `services/offers/offerPricing.ts`
> (the pure copy: window, price, status chip); `services/catalogOffersService.ts` (CRUD, checks,
> preview, the product editor's list); `services/catalog/offersBlock.ts` (`restaurant.offers` for
> the publish). Routes: `GET/POST /catalog/offers`, `PUT/DELETE /catalog/offers/:id`,
> `PATCH /catalog/offers/:id/active`, `POST /catalog/offers/preview`,
> `GET /catalog/offers/for-product/:productId`. Weekly report gains `offerViews`.
> **Mirage-be** — `helper/offersFields.js`, `restaurant.offers` (Mixed), accepted on create/update
> restaurant, returned in the public payload; `offer_viewed` event. **Mirage-fe** — `offers.ts`
> (the diner's copy), `OfferViews.tsx` (price tag, top strip, combo card), `useOfferViews` in
> `useTracking.ts`; MenuScreen: per-minute prices on card / row / detail sheet, the strip under the
> announcement, an **Offers** pill (only while something is on offer) with combo cards on top;
> en + hi strings. **Flutter** — `domain/catalog/offer.dart`, `data/repositories/offers_repository.dart`,
> `screens/catalog/offers_screen.dart` (list + editor), `widgets/catalog/product_offers_line.dart`;
> routes `/catalog/offers`, `/catalog/offers/new`, `/catalog/offers/:offerId`; "Offers & happy
> hour" in the catalog's ⋮ menu (NOT behind `appearanceEnabled` — nothing reaches the menu until
> an offer exists and is published).
>
> **Differs from the text below:**
> - **No Mirage `offerModel.js`, no CRUD routes, no replace-all publish step.** Offers travel as
>   one `restaurant.offers` JSON block on the branding sync, dishes by published NAME — the Stage 7
>   spotlight pattern. Ids would need every dish to exist on Mirage first; names do not. Any offer
>   edit bumps `draftRevision`, which already re-sends branding, so it is also a full replace.
> - Category targets are **expanded to dish names at publish** (plus `targetLabel`, e.g.
>   "Drinks", for the strip). A dish added to the section later joins at its own publish.
> - Only switched-on, not-ended offers are sent; the page still checks every window each minute.
> - **No variants**: ReCapture products have none, so the variant rules do not apply.
> - Fixed price is dishes-only (a section-wide "₹199" makes no sense); percent must be < 100.
>   Category / whole-menu offers silently skip a dish they cannot discount (both sides agree).
> - Percent rounds to the whole rupee. Combo image not built (the card shows the dishes' photos).
> - Editor is one scrolling form with the four numbered steps, not a paged wizard.
> - An offer whose chosen dish was deleted cannot be re-saved until the dish is re-picked
>   (`TARGET_NOT_FOUND`); the publish already drops the missing dish.
> - **Plan-gated (decided 2026-09-30): Signature and above.** New `offers` entitlement; on Taste the
>   publish sends no offers and the publish screen lists them as held back (saved offers are kept).
>   Lock chip on the Offers screen.

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
