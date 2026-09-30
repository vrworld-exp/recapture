# Stage 16a — Multi-branch: data model + index migration

**Side:** recapture-api only. **Depends on:** [Stage 16 design](stage-16-multi-branch-design.md).
**Size:** S–M, but the index migration is the riskiest step of the whole feature.
**Ship first, alone.** After 16a nothing visible changes: every catalog is still standalone.

## Goal

Let one owner hold one MAIN catalog plus up to 10 BRANCH catalogs, without changing anything for
today's standalone catalogs.

## Build

1. **`models/Catalog.ts`** — add, all optional:
   - `brandRole?: 'MASTER' | 'BRANCH'` (absent = standalone, today's catalogs);
   - `masterCatalogId?: ObjectId` (BRANCH only — the main outlet);
   - `outletName?: string` (≤ 40; BRANCH required, MASTER optional, e.g. "Koregaon Park").
2. **`models/CatalogProduct.ts` / `CatalogCategory.ts`** — add optional `masterProductId` /
   `masterCategoryId` (branch rows only) and `overriddenFields?: string[]` (branch rows only; the
   fields the branch changed itself — see 16b).
3. **Indexes** — replace `CatalogSchema.index({ userId: 1 }, { unique: true })` with:
   ```ts
   CatalogSchema.index({ userId: 1 }, { unique: true, partialFilterExpression: { brandRole: { $ne: 'BRANCH' } } });
   CatalogSchema.index({ masterCatalogId: 1, outletName: 1 },
     { unique: true, partialFilterExpression: { brandRole: 'BRANCH' } });
   ```
   ⚠ `$ne` is not allowed in a partial filter on older MongoDB versions. If the Atlas tier refuses
   it, use `partialFilterExpression: { isBranch: false }` with a required boolean `isBranch`
   (default false, back-filled) instead — decide during the rehearsal.
4. **Migration script** `scripts/multi-branch/migrate-catalog-index.ts` (idempotent, dry-run by
   default, `--apply` to write):
   - count catalogs per `userId` — must all be 1 (report and stop otherwise);
   - (if the `isBranch` variant is chosen) back-fill `isBranch: false`;
   - create the two new indexes **before** dropping the old one; then drop `userId_1`;
   - print the final index list.
   Wire it like `config/legacyIndexes.ts` does for the stale-index cleanup, but run it by hand —
   never at boot.
5. **Guards** (services):
   - `createCatalog` keeps refusing a second standalone catalog (the partial index still enforces it);
   - `deleteCatalog` refuses a MASTER that still has live branches (`409 HAS_BRANCHES`);
   - a BRANCH can never be converted to MASTER and vice versa in 16a (no API yet).
6. **Tests**: indexes accept one standalone per owner, one MASTER + N BRANCH per owner, refuse a
   second standalone and a duplicate branch name under one master; the migration dry-run reports
   duplicates and `--apply` is idempotent (run twice → same indexes).

## Rehearsal (required before production)

1. Restore the latest production backup into a scratch Atlas cluster (never run against prod first).
2. `npx ts-node scripts/multi-branch/migrate-catalog-index.ts` (dry run) → must report 0 duplicates.
3. `--apply`, then run the full API test suite against the scratch cluster's copy, and time the
   index build on the real catalog count.
4. Record the result and the chosen variant (`$ne` vs `isBranch`) in the Stage 16 doc.
5. Production: maintenance window (index build is online, but do it at low traffic), same commands.

## As built (2026-09-30)

- **Index variant: neither `$ne` nor `isBranch`.** `{ userId: 1, branchKey: 1 }` unique, where
  `branchKey` is absent on the main / standalone catalog (a missing field indexes as null, so every
  owner still has exactly one) and is the lower-cased outlet name on a branch (so branch names are
  unique per owner). No partial filter, no back-fill. Plus `{ masterCatalogId: 1 }` sparse.
- Branch rows: `masterProductId` / `masterCategoryId` + `masterSync` (the values copy-down last
  wrote) instead of `overriddenFields` — see 16b "As built". Unique `{ catalogId, masterProductId }`
  (and the category equivalent) so two overlapping copy-downs cannot clone a dish twice.
- Migration: `src/services/brand/catalogIndexMigration.ts` (tested) + thin
  `scripts/multi-branch/migrate-catalog-index.ts` (dry run by default, `--apply`). It builds the new
  index before dropping `userId_1`, refuses when an owner has two main catalogs, and prints the
  timing. `config/legacyIndexes.ts` also drops `userId_1` at boot, but **only once
  `userId_1_branchKey_1` exists** (new `requiresIndex` guard), so boot can never leave the rule
  unenforced.
- Guards: `deleteCatalog` → `409 HAS_BRANCHES` for a main outlet with live branches.
- Tests: `tests/multi-branch.test.ts` (16a/16b/16c, 11 cases).

## Done when

- [ ] Rehearsal recorded; production indexes migrated; nothing visible changed for any catalog.
