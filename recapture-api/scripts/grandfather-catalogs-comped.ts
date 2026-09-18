// scripts/grandfather-catalogs-comped.ts
//
// ONE-SHOT, LAUNCH DAY (Stage 5): gives every catalog that is already live on
// Mirage a COMPED subscription for the grandfather window, so switching the
// subscription gates on takes nothing dark (RECAPTURE_SUBSCRIPTION_PLAN.md §8
// D1). A catalog that already has a subscription row — any status — is left
// exactly as it is.
//
// Run with:
//   npx tsx scripts/grandfather-catalogs-comped.ts --dry-run   # lists, writes nothing
//   npx tsx scripts/grandfather-catalogs-comped.ts             # writes
//
// Needs .env (MONGODB_URI — same loader as the API). Safe to run twice, and
// safe to run twice AT ONCE: the unique index on `catalogId` is the authority,
// and a row another run just wrote is counted as skipped, not as an error.
//
// DO NOT run this before Stage 5 against a real database. The window starts
// the moment the row is written, and a catalog comped in Stage 1 is a catalog
// whose grace expires before the gates it was protecting from even exist.
import mongoose from 'mongoose';
import { env } from '../src/config/env';
import { grandfatherCatalogsComped } from '../src/services/subscription/grandfatherService';

async function main(): Promise<void> {
  const dryRun = process.argv.slice(2).includes('--dry-run');

  await mongoose.connect(env.MONGODB_URI);
  try {
    const summary = await grandfatherCatalogsComped({ dryRun });

    console.log(`\n── ${dryRun ? 'DRY RUN' : 'Grandfather'} ─────────────────────────────`);
    for (const { catalogId, name } of summary.candidates) {
      console.log(`  ${catalogId.toHexString()}  ${JSON.stringify(name)}`);
    }
    console.log({ scanned: summary.scanned, comped: summary.comped, skipped: summary.skipped });

    if (dryRun) {
      console.log(
        `\nDRY RUN — nothing written. ${summary.candidates.length} catalog(s) would be comped.`
      );
    }
  } finally {
    await mongoose.disconnect();
  }
}

main().catch((err) => {
  console.error('grandfather-catalogs-comped failed:', err instanceof Error ? err.message : err);
  process.exit(1);
});
