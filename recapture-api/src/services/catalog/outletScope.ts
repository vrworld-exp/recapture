// src/services/catalog/outletScope.ts
//
// Stage 16 — WHICH OUTLET is this request about?
//
// Before Stage 16 an owner had exactly one catalog, so "the owner's catalog"
// was `Catalog.findOne({ userId })` in ~50 places. With branches an owner holds
// a MAIN catalog plus up to 10 BRANCH catalogs, and every one of those lookups
// must land on the outlet the caller is editing.
//
// Rather than thread an `outletId` argument through every service signature,
// the request carries it: a per-request store (AsyncLocalStorage) opened by
// `outletContext` at the top of the app, holding
//   - `header`   — the raw `X-Outlet-Id` the owner's app sent, if any;
//   - `outletId` — an outlet a trusted resolver pinned (rep / staff grant,
//                  worker job), which wins over the header.
// `ownerCatalogFilter(userId)` turns that into a Mongo filter. It always keeps
// `userId` in the filter, so a header naming someone else's catalog matches
// nothing — the ownership check is the query itself, never a separate read.
//
// No store (unit tests calling services directly, scripts) and no header =
// the MAIN / only catalog: exactly the pre-Stage-16 behaviour.
import { AsyncLocalStorage } from 'node:async_hooks';
import type { NextFunction, Request, Response } from 'express';
import { Types } from 'mongoose';

interface OutletStore {
  header?: string;
  outletId?: string;
}

const storage = new AsyncLocalStorage<OutletStore>();

/** The header the app sends. Lower-case: Express normalises header names. */
export const OUTLET_HEADER = 'x-outlet-id';

/** App-level middleware: opens the per-request store. */
export function outletContext(req: Request, _res: Response, next: NextFunction): void {
  const raw = req.header(OUTLET_HEADER);
  const header = typeof raw === 'string' && raw.trim().length > 0 ? raw.trim() : undefined;
  storage.run({ header }, next);
}

/**
 * Pins the outlet for the rest of this request. Called by the resolvers that
 * already proved access to one specific catalog (rep delegation, staff grant):
 * from then on every owner-scoped service call in the request lands on it.
 * Outside a request (no store) it is a no-op — use `withOutlet` there.
 */
export function pinOutlet(catalogId: Types.ObjectId | string): void {
  const store = storage.getStore();
  if (store) store.outletId = String(catalogId);
}

/** Runs `fn` scoped to one outlet — for worker jobs and scripts. */
export function withOutlet<T>(catalogId: Types.ObjectId | string, fn: () => T): T {
  return storage.run({ outletId: String(catalogId) }, fn);
}

/** The outlet this request is scoped to, or null for "the main / only one". */
export function currentOutletId(): string | null {
  const store = storage.getStore();
  return store?.outletId ?? store?.header ?? null;
}

/** True when the request named an outlet the caller cannot possibly own. */
export function outletHeaderMalformed(): boolean {
  const store = storage.getStore();
  return !!store?.header && !store.outletId && !Types.ObjectId.isValid(store.header);
}

// Matches no document: a malformed outlet id must never fall back to the main
// catalog (the owner would silently edit the wrong outlet).
const NO_MATCH = new Types.ObjectId('000000000000000000000000');

/**
 * The filter for "the caller's catalog" — the scoped outlet if one is set,
 * otherwise the main / standalone catalog (`branchKey` absent). Soft-deleted
 * catalogs never match, as before.
 */
export function ownerCatalogFilter(userId: Types.ObjectId | string): Record<string, unknown> {
  const owner = typeof userId === 'string' ? new Types.ObjectId(userId) : userId;
  const outlet = currentOutletId();
  if (outlet) {
    const _id = Types.ObjectId.isValid(outlet) ? new Types.ObjectId(outlet) : NO_MATCH;
    return { _id, userId: owner, deletedAt: null };
  }
  return { userId: owner, branchKey: null, deletedAt: null };
}

/** Same as `ownerCatalogFilter` but for the MAIN catalog regardless of scope. */
export function mainCatalogFilter(userId: Types.ObjectId | string): Record<string, unknown> {
  const owner = typeof userId === 'string' ? new Types.ObjectId(userId) : userId;
  return { userId: owner, branchKey: null, deletedAt: null };
}
