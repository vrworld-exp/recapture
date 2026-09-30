// src/services/brand/catalogIndexMigration.ts
//
// Stage 16a — the one risky migration of multi-branch: `catalogs.userId_1`
// (unique, one catalog per owner) → `userId_1_branchKey_1` (unique, one MAIN
// catalog per owner plus uniquely-named branches).
//
// Order matters: the new index is built BEFORE the old one is dropped, so the
// "one main catalog per owner" rule is enforced at every instant. Idempotent —
// a second run finds the new index present and the old one gone and does
// nothing. Dry run by default; the script passes `apply: true` for `--apply`.
import mongoose from 'mongoose';

export interface CatalogIndexMigrationReport {
  /** Owners holding more than one non-branch catalog — must be empty to apply. */
  duplicateOwners: string[];
  created: boolean;
  dropped: boolean;
  indexes: string[];
}

const NEW_INDEX = 'userId_1_branchKey_1';
const OLD_INDEX = 'userId_1';

export async function migrateCatalogIndex(
  opts: { apply: boolean },
  db: mongoose.mongo.Db = mongoose.connection.db!
): Promise<CatalogIndexMigrationReport> {
  const coll = db.collection('catalogs');
  const dupes = await coll
    .aggregate<{ _id: unknown; n: number }>([
      { $match: { $or: [{ branchKey: null }, { branchKey: { $exists: false } }] } },
      { $group: { _id: '$userId', n: { $sum: 1 } } },
      { $match: { n: { $gt: 1 } } },
    ])
    .toArray();
  const duplicateOwners = dupes.map((d) => String(d._id));

  const before = await coll.indexes();
  const hasNew = before.some((ix) => ix.name === NEW_INDEX);
  const hasOld = before.some((ix) => ix.name === OLD_INDEX);

  let created = false;
  let dropped = false;
  if (opts.apply && duplicateOwners.length === 0) {
    if (!hasNew) {
      await coll.createIndex({ userId: 1, branchKey: 1 }, { unique: true, name: NEW_INDEX });
      created = true;
    }
    if (hasOld) {
      await coll.dropIndex(OLD_INDEX);
      dropped = true;
    }
  }

  const indexes = (await coll.indexes()).map((ix) => String(ix.name));
  return { duplicateOwners, created, dropped, indexes };
}
