// src/config/legacyIndexes.ts
//
// Indexes a model USED to declare and no longer does. Mongoose's autoIndex
// only ever creates what the schema lists — it never drops what the schema
// stopped listing — so a unique index that was narrowed in code stays wide in
// every database that booted the old code, and keeps rejecting writes the new
// code considers legal. Tests never see it: they build indexes on a fresh
// in-memory server.
//
// The one that mattered: Stage 01 declared `paymentrecords.providerOrderId`
// globally unique; Stage 03 scoped it per kind (`{ kind, providerOrderId }`),
// because a checkout's PAID row carries the same order id as its
// CHECKOUT_CREATED row. With the old index still in place every PAID insert
// was an E11000, `recordPaidRow` read it as "a second payment on one order",
// and no online payment could ever activate a plan.
//
// Dropped by exact name AND exact key, so a same-named index someone built
// deliberately with a different shape is left alone. Idempotent: every boot
// runs it; after the first, each entry costs one listIndexes.
import mongoose from 'mongoose';

interface LegacyIndex {
  collection: string;
  name: string;
  key: Record<string, 1 | -1>;
  why: string;
}

export const LEGACY_INDEXES: readonly LegacyIndex[] = [
  {
    collection: 'paymentrecords',
    name: 'providerOrderId_1',
    key: { providerOrderId: 1 },
    why: 'replaced by kind_1_providerOrderId_1 (Stage 03); blocks every PAID row',
  },
];

function sameKey(a: Record<string, unknown>, b: Record<string, unknown>): boolean {
  const ak = Object.keys(a);
  const bk = Object.keys(b);
  return ak.length === bk.length && ak.every((k, i) => k === bk[i] && a[k] === b[k]);
}

/**
 * Drops every [LEGACY_INDEXES] entry present on the connected database.
 * Returns the names dropped. Throws only on a DB error — callers decide
 * whether that is fatal (it is not, at boot).
 */
export async function dropLegacyIndexes(
  db: mongoose.mongo.Db = mongoose.connection.db!
): Promise<string[]> {
  const dropped: string[] = [];
  for (const legacy of LEGACY_INDEXES) {
    const exists = await db.listCollections({ name: legacy.collection }).hasNext();
    if (!exists) continue;
    const coll = db.collection(legacy.collection);
    const indexes = await coll.indexes();
    const found = indexes.find((ix) => ix.name === legacy.name);
    if (!found || !sameKey(found.key, legacy.key)) continue;
    await coll.dropIndex(legacy.name);
    console.log(`🧹 Dropped legacy index ${legacy.collection}.${legacy.name} — ${legacy.why}`);
    dropped.push(`${legacy.collection}.${legacy.name}`);
  }
  return dropped;
}
