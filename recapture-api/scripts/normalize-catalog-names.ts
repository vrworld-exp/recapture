// scripts/normalize-catalog-names.ts
//
// ONE-OFF BACKFILL: rewrites existing catalog, category and product names into
// the slug form the API now stores (utils/catalogNames.ts), so rows written
// before that change stop disagreeing with Mirage — "Testing 02" here and
// "testing_02" there.
//
// Run with:
//   npx tsx scripts/normalize-catalog-names.ts            # DRY RUN — writes nothing
//   npx tsx scripts/normalize-catalog-names.ts --apply    # actually writes
//
// Needs .env (MONGODB_URI etc. — same loader as the API).
//
// TWO THINGS IT REFUSES TO DO, and both are reported rather than guessed at:
//
//   1. BLANK A NAME. A name made entirely of punctuation or emoji slugs down to
//      `''`. Storing that would leave a row nothing can address, so it is left
//      exactly as it is and listed under "unnameable" for a human to rename.
//
//   2. MERGE TWO ROWS INTO ONE NAME. "Garden Chair" and "garden chair" both slug
//      to "garden_chair". For categories that is a unique-index violation; for
//      products it is the duplicate Mirage refuses at publish. Either way the
//      script cannot know which one the business meant to keep, so it skips the
//      WHOLE colliding group — including a row that already holds the target
//      name — and lists it. Rename one by hand and re-run.
//
// Products also get `publishedSnapshot.name` rewritten alongside `name`. That is
// a CORRECTION, not a cover-up: Mirage slugged the name on the way in, so the
// snapshot's spaced copy was never what Mirage actually held. Leaving it would
// make the next publish diff every product on a name change that changes nothing
// on the public page.
import mongoose, { Types } from 'mongoose';
import { env } from '../src/config/env';
import { Catalog } from '../src/models/Catalog';
import { CatalogCategory } from '../src/models/CatalogCategory';
import { CatalogProduct } from '../src/models/CatalogProduct';
import { toCatalogSlug } from '../src/utils/catalogNames';

/** Field bounds, copied from the models — slugging must not shorten past them. */
const CATALOG_NAME_MAX = 120;
const CATEGORY_NAME_MAX = 80;
const PRODUCT_NAME_MAX = 120;

interface Row {
  _id: Types.ObjectId;
  name: string;
  catalogId?: Types.ObjectId;
  hasSnapshot?: boolean;
}

interface Plan {
  /** Rows to rewrite: id → the new name. */
  updates: Map<string, { row: Row; to: string }>;
  /** Rows whose name slugs to nothing. Left alone. */
  unnameable: Row[];
  /** Colliding groups, as `scope → target name → the rows fighting over it`. */
  collisions: { scope: string; target: string; rows: Row[] }[];
}

/**
 * Decides what to do with one collection's rows.
 *
 * [scopeOf] returns the key uniqueness is judged within — the catalog id for a
 * category or product, and the row's own id for a catalog (whose name is not
 * unique at all, so nothing can collide with it).
 */
function planRows(rows: Row[], maxLength: number, scopeOf: (row: Row) => string): Plan {
  const plan: Plan = { updates: new Map(), unnameable: [], collisions: [] };

  // Every row's TARGET name, grouped by scope — including rows that are already
  // correct, because a row that needs no change is still something a renamed row
  // can collide with.
  const byScope = new Map<string, Map<string, Row[]>>();

  for (const row of rows) {
    const target = toCatalogSlug(row.name, { maxLength });
    if (!target) {
      plan.unnameable.push(row);
      continue;
    }

    const scope = scopeOf(row);
    let targets = byScope.get(scope);
    if (!targets) {
      targets = new Map();
      byScope.set(scope, targets);
    }
    const holders = targets.get(target) ?? [];
    holders.push(row);
    targets.set(target, holders);
  }

  for (const [scope, targets] of byScope) {
    for (const [target, holders] of targets) {
      if (holders.length > 1) {
        plan.collisions.push({ scope, target, rows: holders });
        continue;
      }
      const row = holders[0] as Row;
      if (row.name !== target) {
        plan.updates.set(row._id.toHexString(), { row, to: target });
      }
    }
  }

  return plan;
}

function report(label: string, total: number, plan: Plan): void {
  console.log(`\n── ${label} ─────────────────────────────`);
  console.log(`  scanned:    ${total}`);
  console.log(`  to rewrite: ${plan.updates.size}`);

  for (const { row, to } of plan.updates.values()) {
    console.log(`    ${row._id.toHexString()}  ${JSON.stringify(row.name)} → ${JSON.stringify(to)}`);
  }

  if (plan.unnameable.length > 0) {
    console.log(`  UNNAMEABLE (left as-is, rename by hand): ${plan.unnameable.length}`);
    for (const row of plan.unnameable) {
      console.log(`    ${row._id.toHexString()}  ${JSON.stringify(row.name)}`);
    }
  }

  if (plan.collisions.length > 0) {
    console.log(`  COLLISIONS (whole group skipped): ${plan.collisions.length}`);
    for (const { scope, target, rows } of plan.collisions) {
      const names = rows
        .map((r) => `${r._id.toHexString()}=${JSON.stringify(r.name)}`)
        .join(', ');
      console.log(`    in ${scope} → ${JSON.stringify(target)}: ${names}`);
    }
  }
}

async function main(): Promise<void> {
  const apply = process.argv.slice(2).includes('--apply');

  await mongoose.connect(env.MONGODB_URI);
  try {
    // Soft-deleted rows are INCLUDED for catalogs and products (their names are
    // still theirs, and a restore must not bring back a spaced name) but the
    // category unique index only covers live rows, so collisions are judged on
    // the live set — see the filters below.
    const catalogs = await Catalog.find({}, { name: 1 }).lean().exec();
    const categories = await CatalogCategory.find({ deletedAt: null }, { name: 1, catalogId: 1 })
      .lean()
      .exec();
    const products = await CatalogProduct.find(
      { deletedAt: null },
      { name: 1, catalogId: 1, publishedSnapshot: 1 }
    )
      .lean()
      .exec();

    const catalogRows: Row[] = catalogs.map((c) => ({ _id: c._id, name: c.name }));
    const categoryRows: Row[] = categories.map((c) => ({
      _id: c._id,
      name: c.name,
      catalogId: c.catalogId,
    }));
    const productRows: Row[] = products.map((p) => ({
      _id: p._id,
      name: p.name,
      catalogId: p.catalogId,
      hasSnapshot: Boolean(p.publishedSnapshot),
    }));

    const inCatalog = (row: Row): string => row.catalogId?.toHexString() ?? 'orphan';

    const catalogPlan = planRows(catalogRows, CATALOG_NAME_MAX, (row) =>
      row._id.toHexString()
    );
    const categoryPlan = planRows(categoryRows, CATEGORY_NAME_MAX, inCatalog);
    const productPlan = planRows(productRows, PRODUCT_NAME_MAX, inCatalog);

    report('Catalogs', catalogRows.length, catalogPlan);
    report('Categories', categoryRows.length, categoryPlan);
    report('Products', productRows.length, productPlan);

    const total =
      catalogPlan.updates.size + categoryPlan.updates.size + productPlan.updates.size;

    if (!apply) {
      console.log(`\nDRY RUN — nothing written. ${total} row(s) would change.`);
      console.log('Re-run with --apply to write.');
      return;
    }

    if (total === 0) {
      console.log('\nNothing to write.');
      return;
    }

    // No `draftRevision` bump: the name Mirage holds is unchanged by this (it
    // slugged on the way in), so this is ReCapture catching up with what was
    // already published — not an unpublished edit the badge should light up for.
    const catalogWrites = [...catalogPlan.updates.values()].map(({ row, to }) => ({
      updateOne: { filter: { _id: row._id }, update: { $set: { name: to } } },
    }));
    const categoryWrites = [...categoryPlan.updates.values()].map(({ row, to }) => ({
      updateOne: { filter: { _id: row._id }, update: { $set: { name: to } } },
    }));
    const productWrites = [...productPlan.updates.values()].map(({ row, to }) => ({
      updateOne: {
        filter: { _id: row._id },
        update: {
          $set: row.hasSnapshot ? { name: to, 'publishedSnapshot.name': to } : { name: to },
        },
      },
    }));

    if (catalogWrites.length > 0) await Catalog.bulkWrite(catalogWrites);
    if (categoryWrites.length > 0) await CatalogCategory.bulkWrite(categoryWrites);
    if (productWrites.length > 0) await CatalogProduct.bulkWrite(productWrites);

    console.log(
      `\nWrote ${catalogWrites.length} catalog(s), ${categoryWrites.length} category(ies), ` +
        `${productWrites.length} product(s).`
    );
  } finally {
    await mongoose.disconnect();
  }
}

main().catch((err) => {
  console.error(
    'normalize-catalog-names failed:',
    err instanceof Error ? err.message : err
  );
  process.exit(1);
});
