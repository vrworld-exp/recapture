// scripts/multi-branch/migrate-catalog-index.ts
//
// Stage 16a: replaces the catalogs `userId_1` unique index with
// `userId_1_branchKey_1` so an owner can hold branch outlets. The logic lives
// in src/services/brand/catalogIndexMigration.ts (tested there).
//
// Run by hand, never at boot — rehearse on a restored copy of production first
// (steps in docs/more-customization/stage-16a-multi-branch-data.md):
//   npx tsx scripts/multi-branch/migrate-catalog-index.ts           # dry run
//   npx tsx scripts/multi-branch/migrate-catalog-index.ts --apply   # write
//
// Needs .env (MONGODB_URI — same loader as the API).
import mongoose from 'mongoose';
import { env } from '../../src/config/env';
import { migrateCatalogIndex } from '../../src/services/brand/catalogIndexMigration';

async function main(): Promise<void> {
  const apply = process.argv.includes('--apply');
  await mongoose.connect(env.MONGODB_URI);
  const started = Date.now();
  const report = await migrateCatalogIndex({ apply });
  const ms = Date.now() - started;

  if (report.duplicateOwners.length > 0) {
    console.error(
      `✗ ${report.duplicateOwners.length} owner(s) hold more than one main catalog — fix these first:`
    );
    for (const id of report.duplicateOwners) console.error(`   ${id}`);
    process.exitCode = 1;
  } else {
    console.log('✓ 0 duplicate owners');
  }
  console.log(apply ? `Applied in ${ms} ms` : 'Dry run — pass --apply to write');
  console.log(`created userId_1_branchKey_1: ${report.created}`);
  console.log(`dropped userId_1:             ${report.dropped}`);
  console.log(`indexes now: ${report.indexes.join(', ')}`);
  await mongoose.disconnect();
}

main().catch(async (err) => {
  console.error(err);
  await mongoose.disconnect();
  process.exit(1);
});
