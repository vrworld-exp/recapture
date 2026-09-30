# ✅ Stage 16 — Multi-branch restaurants (design — decided 2026-09-30)

> **Status: built 2026-09-30 (16a + 16b + 16c), tests green.** The four questions are answered
> (below); the build followed [16a](stage-16a-multi-branch-data.md),
> [16b](stage-16b-multi-branch-sync.md) and [16c](stage-16c-multi-branch-app.md) — see "As built"
> at the end of each for where it differs from the prompt.
> **Still open before production:** rehearse the index migration on a copy of the production
> database (steps in 16a) — it needs production data access, so it was not done here.

## Decisions (answered 2026-09-30)

| # | Question | Answer | What it means for the design |
|---|---|---|---|
| 1 | How many clients asked? | **2–5 clients** | Real demand; build after launch, sized for 2–5 outlets per brand (cap 10). |
| 2 | Billing | **A — per outlet** | Every outlet keeps its own `CatalogSubscription`, as today. No new plan. A multi-outlet discount is given by hand with the existing comp / manual-payment tools. |
| 3 | Theme per outlet? | **Brand-wide only** | Look (appearance, fonts, badges library, AR branding, QR style) is set once, on the main outlet, and copied to branches; a branch cannot change it. |
| 4 | Standees | **One pool per outlet** | Each outlet is activated with its own QR standees and its own count — exactly how a separate restaurant works today. |

## The constraint (unchanged)

- `Catalog.userId` is unique — one catalog per account (index `{ userId: 1 }` unique, `Catalog.ts`).
- `publicUrl` / `mirageRestaurantId` are per catalog and frozen — printed QRs depend on them.
- Subscription, standee quota, staff grants, offers, weekly report, customers, Today — all keyed by
  `catalogId`.

## Chosen model: the main outlet is the master; branches are synced copies

The original proposal (a separate master menu + per-outlet overrides merged at publish time) would
have to teach every catalog-scoped query — products, categories, publish planner, offers, Today,
analytics joins, AI import — to read a merged view. The audit (below) found ~50 call sites in 11
API files that assume one catalog per account, and every product query is `catalogId`-scoped.

For 2–5 outlets that all look the same, a **sync-down** model changes far less:

```
Owner (User)
 └─ Main outlet = Catalog { brandRole: 'MASTER' }        ← the owner's existing catalog, unchanged URL/QR
      ├─ Branch  = Catalog { brandRole: 'BRANCH', masterCatalogId, outletName }
      └─ Branch  = Catalog { … }                          ← own publicUrl, QR, standees, subscription
```

- **Every branch is an ordinary Catalog** with its own products and categories. Publish, the
  planner, Mirage, Today (stock/prices), staff, offers, customers, weekly report and QR standees work
  per outlet with **no change** — they already key on `catalogId`.
- Each branch product carries `masterProductId` (and each branch category `masterCategoryId`). An
  edit on the main outlet is **copied down** to every linked branch row, field by field — except the
  fields the branch has **overridden** (`overriddenFields: ['price', 'availability', …]`).
- Branch-only dishes are allowed (no `masterProductId`); dishes removed on the main outlet are
  archived on branches (never hard-deleted, so a branch that published it unpublishes it cleanly).
- **Brand-wide look (Q3):** appearance, fonts, cover, badges library, AR branding, QR style and
  languages live on the main outlet and are copied to branches on save; branch screens show
  "Set on your main outlet". Contact, address, hours, announcement stay per outlet.
- A copy-down bumps each affected branch's `draftRevision` (it shows "unpublished changes");
  "Publish all outlets" runs one publish per outlet (the existing single-flight guard per catalog
  stays valid).
- Standalone restaurants (everyone today): `brandRole` absent → **zero change**.

## Owner scope: which outlet am I editing?

The app sends `X-Outlet-Id: <catalogId>` on catalog calls. A middleware resolves it to a catalog
the caller owns (the main outlet or one of its branches) and puts it on the request;
`findOwnedCatalog(userId)` becomes `findOwnedCatalog(userId, outletId?)` — **absent header = the
main / only catalog**, so every existing client and every standalone restaurant behaves exactly as
today. Rep and staff routes already carry a catalog id in the path and need no header.

### Audit — code that resolves "the owner's catalog" from a user id (2026-09-30)

API (`recapture-api/src`), ~50 call sites:

| File | What to change |
|---|---|
| `routes/catalog.ts` (18× `findOwnedCatalog`) | pass `req.outletId` |
| `services/catalogProductsService.ts` (12×) | accept an optional outlet id |
| `services/catalogOffersService.ts` (7×) | same |
| `services/catalogService.ts` (6× + `Catalog.findOne({ userId })`) | same; `deleteCatalog` must refuse a main outlet that still has branches |
| `services/catalogCategoriesService.ts` (5×) | same |
| `services/catalogSlugService.ts`, `customersService.ts`, `catalogAnalyticsService.ts` (`scopeFor`), `catalogActivityService.ts`, `catalogPublishService.ts` (`ownCatalog`), `weeklyReportService.ts` (`catalogIdForOwner`) | same |
| `services/activationService.ts` (2× by userId) | rep "Add branch": create a BRANCH catalog for the same owner instead of refusing because the owner already has one |
| `routes/aiCatalogRoutes.ts`, `routes/todayRoutes.ts` (owner mounts) | resolver passes the outlet |

App (Flutter): `catalogProvider` (one catalog per account) → a selected-outlet provider + an
outlet switcher on the catalog screen; a Dio interceptor adds `X-Outlet-Id`.

## Unique index change (the one risky migration)

`{ userId: 1 }` unique → two partial uniques:
- `{ userId: 1 }` unique where `brandRole` is not `'BRANCH'` (one standalone-or-main catalog per owner — today's rule);
- `{ masterCatalogId: 1, outletName: 1 }` unique where `brandRole: 'BRANCH'`.

Steps and the rehearsal are in [16a](stage-16a-multi-branch-data.md).

## Out of scope (later, if asked)

- A brand plan with one bill for N outlets (Q2 option B).
- Per-outlet themes (Q3 said brand-wide).
- A shared standee pool (Q4 said per outlet).
- Mirage "Our other branches" list in the contact sheet — easy follow-up once branches exist
  (publish sibling outlets' names + URLs in the Stage 12 `links` block).

## Done when (design stage)

- [x] Questions answered and recorded here.
- [ ] Index migration rehearsed on a copy of the production database (needs prod access — 16a step 2).
- [x] Coding prompts written as Stage 16a (data + migration), 16b (sync-down authoring), 16c (outlet
      scope, publish, app).

---

## Appendix — the original proposal (superseded by the design above)


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
