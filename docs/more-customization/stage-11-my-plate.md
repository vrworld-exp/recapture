# ✅ Stage 11 — "My plate" list (pre-order list, not an order)

> **Status (2026-09-30): built, uncommitted.** Typecheck / analyze / lint clean on all four sides
> (Flutter: all of `lib`). Tests: `mirage-fe/src/features/plate/plate.test.tsx` (11 — lines, notes,
> reload, 4-hour clear, storage-blocked fallback, pruning, totals with / without offers, settings,
> waiter view in the primary language); `recapture-api/tests/weekly-report.test.ts` extended
> (plates recorded, another restaurant's row ignored). All mirage-fe feature tests pass (89) — one
> pre-existing Stage 3 test bug fixed (`MenuLayouts.test.tsx`: two ₹320 dishes, `getByText` →
> `getAllByText`). Full suites not run.
>
> **Mirage-fe** — `src/features/plate/plateStore.ts` (pure store + `usePlate` hook + settings
> resolver), `src/features/plate/MyPlate.tsx` (+ / stepper, pill, sheet, waiter view); + on grid /
> large cards, list rows and the detail sheet (`MenuList.plateFor`, `MenuItemCardProps.plate`);
> totals use the Stage 10 offer price; "Send on WhatsApp" when Stage 7's WhatsApp ordering is on;
> table number from `?t=`; 4 events. **Mirage-be** — the 4 events, `restaurant.plate`
> (`{ enabled, showTotal }`, parsed in `helper/offersFields.js`), public payload, `plateStats` in
> the summary (cache key → `v3`). **API** — `Catalog.plate` on the profile patch (bumps
> draftRevision), profile DTO, always sent with branding; analytics summary `plateStats` (rows
> scope-checked like every per-dish panel); weekly report `metrics.plates`. **Flutter** —
> `MenuPlate` entity, `updatePlate`, `screens/catalog/plate_settings_screen.dart` at `/catalog/plate`
> (⋮ "My plate"), `AnalyticsPlateCard`, weekly report line "🍽 86 customers built a plate, average ₹640".
>
> **Differs from the text below:**
> - **Mirage treats an absent `plate` as OFF** (D5: the menu looks the same until the restaurant's
>   next publish). ReCapture's default is ON as written, so it appears at each owner's next publish.
> - Because it is on by default, its switches are on their **own ungated screen**, not in
>   "Spotlight & customer buttons" (hidden behind `appearanceEnabled`) — owners can always turn it off.
> - No variants (ReCapture dishes have none). No + on sold-out dishes.
> - A plate's value in stats = the largest total its session reported; one plate per session.
> - The waiter view is black on white whatever the theme; names use Stage 6's `primaryName`.
> - Stored per restaurant slug in localStorage (`mirage_plate:<slug>`), memory fallback.
> - **Plan-gated (decided 2026-09-30): Signature and above.** New `plate` entitlement; on Taste the
>   publish sends `enabled: false`. It is listed as held back only if the owner switched it on
>   themselves. Default stays ON (confirmed) on covered plans. Lock chip on the My plate screen.
>   `entitlementsKey` gains the two fields only when not both covered, so fully covered catalogs
>   do not all read as "plan changed" after this release.

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
