# Stage 11 — "My plate" list (pre-order list, not an order)

**Side:** Mirage-fe mainly; small Mirage-be analytics + ReCapture toggle.
**Depends on:** nothing (Stage 10 prices used if present, Stage 7.3 table number if present).
**Size:** S–M

## Why

Customers browse the menu on their phone, then have to remember everything and read it out to the
waiter. Tourists and people who don't speak the waiter's language struggle. "My plate" lets them
tap **+** on dishes, see a running total, and show one clean screen to the waiter.

It is **not** ordering: no payment, no kitchen integration, no server-side order. That keeps it
small, free of staff training, and zero-risk for the restaurant — and it is the natural first step
towards real ordering later (§ Later).

## What the customer sees

- A **+** button on each card and in the detail sheet (qty stepper once added).
- Floating pill at the bottom: "🍽 My plate · 4 items · ₹860" (reuse `FloatingMenuPill.tsx` pattern).
- My plate sheet: items with qty, variant, note field ("less spicy"), total, and a big
  **"Show to waiter"** mode: full-screen, large text, high contrast, dish names in the restaurant's
  **primary language** (Stage 6) even if the customer browses in another — the waiter reads it.
- Optional "Send on WhatsApp" (if `engagement.whatsappOrder`, Stage 7.3) with the list prefilled.
- "Clear plate" and auto-clear after 4 hours.

---

## Mirage-fe

- State: `src/features/plate/plateStore.ts` — per restaurant slug, localStorage (try/catch; if
  storage fails, keep in memory). Shape `{ items: { itemId, variantId?, qty, note? }[], updatedAt }`.
- On load, drop lines whose item no longer exists or is sold out (show "1 item was removed —
  no longer available").
- Totals use Stage 10 `priceFor` when present; label "Estimated total — taxes may apply".
- `arEnabled`, themes, layout variants: the **+** must work in every card variant (Stage 3).
- Analytics (append to EVENT_TYPES in both files): `plate_item_added`, `plate_opened`,
  `plate_shown_to_waiter`, `plate_sent_whatsapp` with `{ itemCount, total }` — gives Stage 9 a new
  metric: "86 customers built a plate, average ₹640".

## Mirage-be

- Nothing stored except analytics events. Add `plateStats` to the scoped summary aggregation.

## ReCapture

- `Catalog.plate: { enabled: boolean (default true); showTotal: boolean (default true) }` synced in
  `syncCatalogBranding()`; toggle on the Appearance / menu settings screen. Some fine-dine owners
  won't want totals shown.
- Weekly report + analytics screen: "Plates built", "Avg plate value", "Most added dish".

## Later (not in this stage)

Table ordering: plate → "Place order" → order doc in Mirage-be → owner/staff screen in ReCapture
with a sound alert → status back to the customer. Needs table QRs (`?t=` from 7.3), staff roles
(Stage 14) and a clear "who confirms" flow. Design separately once plate usage data exists.

## Tests

- Store: add/remove/qty/note, persistence, storage-failure fallback, stale item pruning.
- Total with and without offers; variants.
- "Show to waiter" renders primary-language names.

## Done when

- [ ] On a phone: add 3 dishes, reload the page, plate is still there; show-to-waiter is readable at arm's length.
- [ ] With `plate.enabled = false`, no + buttons appear.
- [ ] Plate events appear in analytics.
