# Stage 14 — Quick edit, bulk prices, staff access, printable PDF menu

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
