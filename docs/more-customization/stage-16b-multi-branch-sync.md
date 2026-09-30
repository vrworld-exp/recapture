# Stage 16b — Multi-branch: branches and copy-down from the main outlet

**Side:** recapture-api. **Depends on:** 16a. **Size:** M–L.

## Goal

An owner can add branches. The main outlet's menu is copied to each branch, and every later edit
on the main outlet flows down automatically — except what a branch changed itself.

## Build

1. **`services/brand/branchService.ts`**
   - `addBranch(mainCatalog, { outletName, address?, phone? })`: marks the catalog `MASTER` (first
     time), creates a `BRANCH` catalog for the same `userId` (`masterCatalogId`, `outletName`,
     `status: DRAFT`, its own contact / hours), then **clones** every live category and product
     (not archived / deleted) with `masterCategoryId` / `masterProductId` and fresh
     `syncStatus: NEVER` (branches publish to their own Mirage restaurant). Images: reuse the same
     S3 keys (read-only sharing is safe — keys are never overwritten in place; check the product
     image cleanup sweep does not delete a key another catalog still references — **it does today,
     prefix-based per catalog; make the branch copy its own key by server-side `copyObject`**).
   - `listOutlets(owner)`: main + branches with name, status, draft/published revisions.
   - Cap: 10 branches.
2. **`services/brand/copyDown.ts`** — called after every successful write on a MASTER catalog's
   product, category or brand-wide field (hook it into the existing write paths:
   `catalogProductsService` update / create / archive / delete, `catalogCategoriesService`,
   `applyCatalogPatch` for the brand-wide fields listed below):
   - product/category create on master → create on every branch (linked);
   - update → for each linked branch row, `$set` every changed field **not** in its
     `overriddenFields`; bump each touched branch's `draftRevision` once per request;
   - archive / delete on master → **archive** the branch row (never hard-delete);
   - brand-wide catalog fields, copied always (Q3 — no branch override): `appearance`, `coverImageKey`,
     `badges`, `languages`, `i18n`, `arBranding`, `qrStyle`, `plate`, `aiTone`, `spotlight` (mapped
     to branch product ids), `engagement.reviewUrl` excluded (each outlet has its own Google page).
   - Per-outlet, never copied: contact, address, hours, announcement, links, customers, offers,
     staff, subscription, standees, slug.
3. **Overrides** — when an owner / manager / staff edits a **branch** row's field directly (product
   editor, Today prices / stock), add that field to `overriddenFields`. A "Reset to main outlet"
   action (per product) removes the override and re-copies the master value.
   Today's stock toggles on a branch always override (stock is naturally per outlet).
4. **Routes** (owner): `GET /catalog/outlets`, `POST /catalog/outlets` (add branch),
   `POST /catalog/outlets/:id/reset-product/:productId`, `POST /catalog/outlets/publish-all`
   (one publish per outlet, returns per-outlet outcome).
5. **Tests**: add branch clones rows with links; master price change reaches branches except one
   with a price override; archive on master archives on branches; brand-wide appearance copied,
   branch `hours` untouched; reset-to-main restores; images copied to the branch's own keys and the
   branch's image cleanup never removes the master's object.

## As built (2026-09-30)

- **No per-write-path hooks.** Every authoring write already ends in a draft bump (D6);
  `bumpDraftRevision` now returns `brandRole` from the same round trip and, for a MASTER only,
  runs `brand/copyDown.ts` `scheduleCopyDown` — an idempotent, diff-based reconcile of every branch
  (single-flight per master in-process; never throws into the owner's edit). The inline bumps in
  `applyCatalogPatch` / branding commit / AI tone call the same hook. So the editor, Today, AI,
  import, reorder, rep and staff writes all copy down without knowing branches exist.
- **Overrides by snapshot, not bookkeeping:** each branch row stores `masterSync` (what copy-down
  last wrote). A branch field that differs from it is an override and is left alone; "Reset to main
  outlet" clears the snapshot and re-copies. `overriddenFields` is derived for the product DTO
  (`product.branch = { followsMain, overriddenFields }`).
- Never copied: availability (stock is per outlet), contact, address, hours, announcement, links,
  customers, offers, staff, subscription, standees, slug, the review link, and the catalog **name**
  (branch = "Blue Cafe · Baner", because Mirage adopts restaurants by name).
- Product images: copied server-side (`copyObject`) into the branch's own
  `catalog/{branchId}/products/{branchProductId}/` keys on clone and whenever the main photo
  changes. Logo / cover keys are shared (brand-wide, under the master's prefix; the master cannot be
  deleted while branches exist).
- Routes: `GET/POST /catalog/outlets`, `POST /catalog/outlets/publish-all`,
  `POST /catalog/outlets/:id/products/:productId/reset` (`routes/outletRoutes.ts`).

## Done when

- [ ] An owner with 3 outlets changes a dish price on the main outlet once and sees it on all three
      after "Publish all outlets"; the branch that set its own price keeps it.
