# ✅ Stage 14 — Quick edit, bulk prices, staff access, printable PDF menu

> **Status (2026-09-30): built, uncommitted.** Typecheck / lint / analyze clean (Flutter: all of
> `lib`). Tests: `recapture-api/tests/today-staff-pdf.test.ts` (17 — rounding vectors, bulk apply =
> one bump, undo restores exact values and keeps dishes edited since, one undo per batch, staff
> permission matrix over HTTP incl. 403 on price / bulk / undo for STAFF, MANAGER may price, invite
> → claim on sign-in, revoke effective on the next request, staff grant never a rep grant, 5-helper
> cap, own-number refused, 05:00 IST reset time, back-in-stock sweep, PDF for 0 / 1 / 200 dishes in
> all three templates, wrapping); `test/catalog/stage14_today_test.dart` (2). Regression: rep,
> publish, product-sync suites pass (123). **Also fixed a Stage 7 drift** found by
> `rep-catalog-qr.test.ts`: the rep's QR route still printed the plain square (and a different
> ETag) after the owner's got the branded style — both now use `services/printableQr.ts`.
>
> **14.1 / 14.2** — `services/todayService.ts` (list, one-batch changes, "sold out until tomorrow"
> via `CatalogProduct.availabilityResetAt` = next 05:00 IST, bulk preview / apply / 7-day undo,
> `runAvailabilityResetSweep` every 5 min), `models/CatalogChangeLog.ts` (per-dish "Ravi marked X
> sold out", BULK_PRICE batches for undo; 90-day TTL), `routes/todayRoutes.ts` mounted for the
> owner (`/catalog/today`, `/catalog/prices/bulk[/preview]`, `/catalog/prices/undo`,
> `/catalog/today/publish`). Flutter `screens/catalog/today_screen.dart` at `/catalog/today`.
> **14.3** — `CatalogDelegation.kind` (REP | MANAGER | STAFF; old rows = REP via
> `REP_KIND_FILTER`, applied to every rep query), `models/StaffInvite.ts`,
> `services/staff/{staffPermissions,staffService}.ts`, owner `/catalog/staff` (list / invite by
> phone / remove), helper area `/staff` (`GET /staff/catalogs`, then the Today router under
> `/staff/catalogs/:id`). Permissions enforced in the service, not only the route. Flutter
> `screens/catalog/staff_screen.dart`: `/catalog/staff`, `/staff` (helper's list → Today); the
> "No catalog yet" screen offers "Restaurants I help run" to someone who helps somewhere.
> **14.4** — `services/menuPdfService.ts`, `GET /catalog/menu.pdf?template&size&includeQr&source`;
> "Printable menu" dialog in the catalog ⋮ menu (share / download).
>
> **Differs from the text below:**
> - **No separate "targeted publish" mode.** The ordinary publish already diffs and pushes only
>   changed dishes (plus a branding refresh), which is what the promotion path uses too.
> - **Managers get stock + prices + bulk prices + publish — not full dish / section / offer
>   editing.** That would mean exposing the whole authoring API through `/staff`; not built.
> - **Revoke does not kill refresh tokens** — the grant is re-read on every request, so access
>   ends on the next call anyway, and a helper who is also an owner elsewhere is not logged out.
> - Invites: a user with that verified phone gets access at once; otherwise the invite is claimed
>   when they first open `/staff` after signing in with the number. 5 helpers max, **not plan-gated**
>   (Stage 8's table has no row for it — decide if wanted).
> - Price-undo batches live in the change log (`BULK_PRICE`), no separate `PriceChangeLog`.
>   Dishes have one price, so "applies to variants" does not arise.
> - **PDF is Latin-only**: the hand-rolled writer uses built-in Helvetica, so prices print as
>   "Rs 250" and dishes print in the menu's primary language; Hindi / Devanagari would need an
>   embedded, shaped font — not done. No template thumbnails in the picker. Theme primary colour on
>   headings (too-light colours fall back to near-black for paper).
> - No Android home-screen shortcut ("Mark sold out") — needs a native quick-actions plugin.

**Side:** recapture-api + Flutter.
**Depends on:** nothing.
**Size:** M

## Why

Daily menu changes are small but frequent: "paneer is finished", "raise all prices by ₹10".
Today each needs opening a dish editor, saving, then publishing. Owners also can't hand this to a
manager without handing over the whole account (including billing).

---

## 14.1 Quick-edit screen ("Today")

- New tab/screen **Today** in ReCapture: every dish in one dense list grouped by category with:
  - an **In stock / Sold out** switch,
  - inline price field,
  - a search box and "Show sold out only" chip.
- Changes collect in a bottom bar "3 changes · **Publish now**" → one PATCH batch → one publish.
- **Fast path for stock**: availability-only changes use a targeted publish (only the changed items),
  the same targeted mechanism the Meshy processor uses for promoted models
  (`catalogModelPromotionService.ts`), so going "sold out" is live in seconds, not a full run.
- **Auto back in stock**: "Sold out until tomorrow" option → `availabilityResetAt` on the product;
  a daily sweep at 05:00 IST flips it back and triggers a targeted publish.
- Android home-screen shortcut (app shortcut) "Mark sold out" → opens this screen.

## 14.2 Bulk price update

- From the Today screen: select dishes (or whole categories) → **Change prices**:
  - `+/- %` (e.g. +5%), `+/- ₹` (e.g. +10), rounding rule (none / to ₹5 / to ₹9 ending).
  - Applies to variants too.
- Preview table old → new, then apply as **one** `bulkWrite` + one `draftRevision` bump.
- Store a `PriceChangeLog { catalogId, userId, changes[], at }` so "Undo last price change" is possible for 7 days.

## 14.3 Staff access

Constraint: `Catalog.userId` is unique (one catalog per owner) and the role ladder is linear
(`SALES_REP` at rank 1 — see `docs/next-phase/07-same-day-activation.md` D3). **Reuse the
delegation model** instead of inventing a second one.

- Extend `CatalogDelegation` with `kind: 'REP' | 'STAFF'` and `permissions`:

  | Permission | Manager | Staff |
  |---|---|---|
  | Toggle availability | ✅ | ✅ |
  | Edit prices | ✅ | — |
  | Edit dishes / categories / offers | ✅ | — |
  | Publish | ✅ | ✅ (availability fast path only) |
  | Appearance, subscription, billing, customers export | — | — |

- Owner invites by phone number → OTP login (existing `otpService.ts`) → the invited user sees
  only that catalog. Owner can revoke any time; revoke kills refresh tokens for that delegation.
- Every write records `actorUserId`; `catalogActivityService.ts` shows "Ravi marked Paneer Tikka sold out · 2:14 pm".
- Server-side enforcement in a `requireCatalogPermission(p)` middleware — never trust the app to hide buttons.
- Limit: 5 staff per catalog (plan-gated in Stage 8).

## 14.4 Printable PDF menu

For owners who still want paper, table tents, or a menu for Zomato listings.

- `GET /catalog/menu.pdf?template=classic|compact|twoColumn&size=A4|A5&includeQr=true`
- Built with the existing PDF primitives (`pdfPrimitives.ts`, like `standeeSheetPdf.ts`): logo,
  cover (Stage 3), categories, dishes with price/variants/veg marks, badges (Stage 5) as small
  labels, footer QR "Scan to see our dishes in 3D" pointing at `publicUrl`.
- Theme colours from Stage 2 applied to headings. Devanagari font embedded when the menu has
  Hindi (Stage 6).
- Flutter: "Download printable menu" → template picker with thumbnail → share/print.
- Uses **draft** or **published** data (toggle, default published) so what's printed matches what's live.

## Tests

- Batch availability + targeted publish touches only changed items; sweep resets `availabilityResetAt`.
- Bulk price rounding vectors; undo restores exact old values.
- Staff permission matrix enforced on every route (table-driven test); revoke invalidates tokens.
- PDF renders for 0, 1 and 200 dishes; long names wrap; Hindi renders.

## Done when

- [ ] Marking a dish sold out on the Today screen shows "Sold out" on the live menu within ~10 s.
- [ ] "+5%, round to ₹5" across Drinks updates 18 dishes in one step and can be undone.
- [ ] A staff user can toggle stock but gets 403 on price edits even via direct API calls.
- [ ] Printed A4 menu looks like the restaurant's theme and its QR opens the live menu.
