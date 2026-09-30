# Stage 16c — Multi-branch: outlet scope, rep onboarding, app

**Side:** recapture-api + Flutter (+ optional small Mirage-fe). **Depends on:** 16a, 16b. **Size:** L.

## Goal

The owner switches between outlets in the app; every existing screen works on the selected
outlet; reps can onboard a branch; the weekly report adds a brand roll-up.

## Build — API

1. **Outlet scope middleware** (`middleware/outletScope.ts`) on the `/catalog` router: reads
   `X-Outlet-Id`; if present, verifies the caller owns that catalog (it is their MASTER or a BRANCH
   whose `masterCatalogId` is their MASTER) → `req.outletId`; if absent → the main / only catalog
   (today's behaviour). 404 `OUTLET_NOT_FOUND` otherwise.
2. `findOwnedCatalog(userId)` → `findOwnedCatalog(userId, outletId?)` and thread `req.outletId`
   through every call site in the Stage 16 audit table (~50 sites, 11 files). Keep the default =
   main catalog so nothing breaks while call sites are converted; add a guardrail test that greps
   `src/` for `findOwnedCatalog(` calls without the second argument in route handlers.
3. **Rep onboarding (Q4)**: `activationService.activate` for an owner who already has a MASTER /
   standalone catalog offers "Add as a branch of <restaurant>" → creates a BRANCH (16b
   `addBranch`) and activates the standee on it — **its own standee pool**, its own delegation.
4. **Subscription (Q2 = per outlet)**: nothing new — each outlet's catalog has its own
   `CatalogSubscription`; the subscription screen already works per catalog once scoped. Admin
   comp tool note in the runbook for multi-outlet discounts.
5. **Weekly report**: the MASTER's report gains one line — "All outlets: 3,410 menu views
   (▲ 12%)" — summed from each outlet's stored report for the same week.
6. Staff (Stage 14) stay per outlet: a grant is per catalog already.

## Build — Flutter

1. `selectedOutletProvider` (persisted id) + `outletsProvider` (`GET /catalog/outlets`); a Dio
   interceptor adds `X-Outlet-Id` to `/catalog/*` requests when an outlet is selected.
2. Outlet switcher at the top of the catalog screen (only when branches exist): "Koregaon Park ▾".
3. "Add branch" (⋮ menu on the main outlet): name, address, phone → creates it and switches to it.
4. Brand-wide screens (Appearance, badges, languages, AR style, QR style) on a branch: read-only
   with "Set on your main outlet — switch" instead of the editor.
5. Product editor on a branch: fields that follow the main outlet show a small "From main outlet"
   label; editing one marks it overridden; "Reset to main outlet" per product.
6. "Publish all outlets" on the main outlet's publish screen.
7. Every provider that caches catalog data must be invalidated on outlet switch (catalog, products,
   categories, profile, subscription, analytics, reports, offers, customers, Today).

## Optional — Mirage-fe

"Our other branches" in the contact sheet: publish sibling outlets (name + public URL) through the
Stage 12 `links` block (`links.branches`) and render them as a list.

## Tests

- Outlet scope: missing header = main catalog; foreign outlet id = 404; branch of someone else = 404.
- Every owner route works on a branch via the header (table-driven over the audit list).
- Rep activates a branch standee → new BRANCH with its own standee count and delegation.
- Flutter: switcher changes scope and invalidates providers; brand-wide screens read-only on a branch.

## As built (2026-09-30)

- **Outlet scope = AsyncLocalStorage, not a new argument on ~50 call sites.**
  `services/catalog/outletScope.ts`: `outletContext` (app-level) stores the `X-Outlet-Id` header;
  `ownerCatalogFilter(userId)` keeps `userId` in every filter, so a foreign id matches nothing.
  `findOwnedCatalog` and every `Catalog.findOne({ userId })` owner lookup use it; no header = the
  main / only catalog. `resolveDelegatedCatalog` / `resolveStaffCatalog` **pin** the outlet they
  proved (rep and staff routes pass the owner's userId to owner services). Worker paths use
  `withOutlet(catalogId, …)` (availability sweep publish, model-promotion publish). A `/catalog`
  middleware turns a bad header into `404 OUTLET_NOT_FOUND`.
- Brand-wide fields on a branch: `409 BRAND_WIDE_FIELD` (profile / catalog PATCH, logo / cover);
  `engagement` on a branch is narrowed to its own review link.
- DTO: `catalog.outlet = { role, outletName, mainCatalogId }` only for multi-branch restaurants.
- Rep onboarding: `POST /rep/activations` takes optional `branchName` → the standee goes to that
  branch (created with the full menu if new), with its own delegation and standee pool.
- Weekly report: `report.allOutlets = { outlets, menuViews, deltaPct }` on a main outlet with
  branches (read-time sum of each outlet's stored report).
- Flutter: `selectedOutletIdProvider` + `OutletInterceptor` (adds the header to `/catalog…` only;
  in-memory — the app opens on the main outlet), `switchOutlet()` drops every catalog-scoped
  provider, `OutletsScreen` (`/catalog/outlets`: switch, Add branch, Publish all outlets), outlet
  chip on the catalog header, `BrandWideGate` on Appearance / Badges / Languages / AR style / QR
  style / My plate, `BranchLinkCard` ("From main outlet" + Reset) in the dish editor, error copy.
- Not built: Mirage-fe "Our other branches" (optional), persisted outlet selection.

## Done when

- [ ] Owner with 3 outlets switches between them; stock and prices differ per outlet; one menu edit
      reaches all three; each outlet's QR opens its own page; each outlet is billed separately.
