# Stage 16 — Multi-branch restaurants (design stage — decide before building)

**Side:** recapture-api data model + Flutter + Mirage + subscription.
**Depends on:** Stage 14 (staff/delegation), subscription pack.
**Size:** XL — this is a **design** document with a proposed model; do not start coding until the
questions at the bottom are answered.

## Why

A common request: one owner, 2–5 outlets, mostly the same menu, but some prices, some dishes and
stock differ per outlet, and each outlet has its own QR, address and hours.

## The constraint

- `Catalog.userId` is **unique** — one catalog per account is enforced by the index
  (`models/Catalog.ts` header).
- `publicUrl` / `mirageRestaurantId` are one-per-catalog and **frozen** (`assertMappingImmutable`) —
  printed QRs depend on it.
- Subscription is per catalog (`CatalogSubscription`).

So "just allow two catalogs" breaks the product rule, the owner model and billing at once.

## Proposed model: Brand → Outlets

```
Brand (new)            one per owner — the shared menu master
 ├─ master categories / products (authored once)
 └─ Outlet = Catalog   one per branch (existing Catalog, keeps publicUrl, QR, subscription)
      └─ OutletOverride  per product: { priceOverride?, hidden?, availability }
```

- Keep `Catalog` as the **outlet** so everything published today keeps working (URL, QR, standees,
  subscription, analytics). Relax the unique index to `(userId, brandId, outletCode)` via a
  migration; existing catalogs become brand-less single outlets (brandId null) → zero change for them.
- Authoring the master menu once; each outlet publish = master + overrides → its own Mirage restaurant.
- A master edit marks **all** outlets' drafts dirty; "Publish to all outlets" runs one publish run
  per outlet (existing single-flight guard `activePublishRunId` per catalog stays valid).
- Staff (Stage 14) scoped per outlet: an outlet manager sees only their outlet's stock & prices.
- Analytics: per outlet (exists) + brand roll-up in the weekly report (Stage 9).
- Mirage: each outlet stays its own restaurant — no Mirage schema change. Optional "Our branches"
  list in the contact sheet linking sibling outlets.

## Billing options (needs a decision)

| Option | How | Trade-off |
|---|---|---|
| A. Per outlet | each outlet has its own subscription, as today | simplest, nothing new in payments |
| B. Brand plan | one subscription covers N outlets, price per outlet with discount | better deal to sell, needs new plan + entitlement per outlet |

Recommendation: ship **A** first, with a manual "multi-outlet discount" via the existing comp/manual tools.

## Migration outline

1. Add `Brand` model + nullable `Catalog.brandId`, `Catalog.outletName`.
2. Replace unique index `{ userId }` with a partial unique on `{ userId }` where `brandId: null`,
   plus unique `{ brandId, outletName }`. Run in maintenance window; verify no duplicates first.
3. "Convert to multi-branch" in the app: creates a Brand, moves the existing catalog's products to
   master, creates overrides = none. Reversible while only one outlet exists.
4. Every query that does `findOwnedCatalog(userId)` must learn which outlet — audit list first
   (grep `findOwnedCatalog`, `Catalog.findOne({ userId`).

## Open questions (answer first)

1. How many real clients have asked for branches, and how many outlets each?
2. Billing option A or B?
3. Does each outlet need a different theme (Stage 2), or brand-wide only?
4. Does a rep onboard branches separately (one standee pool each)?

## Done when (for this design stage)

- [ ] Questions answered and recorded here.
- [ ] Index migration rehearsed on a copy of the production database.
- [ ] Coding prompts written as Stage 16a (data + migration), 16b (authoring), 16c (publish + app).
