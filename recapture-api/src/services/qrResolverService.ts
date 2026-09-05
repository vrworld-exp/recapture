// src/services/qrResolverService.ts
//
// What a scanned standee resolves to — the decision behind GET /r/:code.
//
// THE HOT PATH IS EXACTLY TWO READS: the code, then its catalog. Everything
// else is either free (normalisation, in memory) or off the critical path (the
// scan rollup, which is awaited but can never fail the resolve). This is the
// only unauthenticated, publicly-advertised, printed-on-physical-objects
// surface in the API, and it shares an event loop with the worker — so its cost
// per request is a property worth defending, not an implementation detail.
//
// It returns a DECISION, never a response. Status codes, headers and HTML live
// in routes/public.ts; the carve-out that lets that router speak HTML instead
// of the JSON envelope is documented in AGENTS.md.
import { Types } from 'mongoose';

import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { QrCode } from '@/models/QrCode';
import { QrScanDaily } from '@/models/QrScanDaily';
import { mintPublicUrl } from '@/services/catalogProvisioningService';
import type { FallbackKind } from '@/services/qrFallbackPage';
import { normalizeQrCode } from '@/utils/qrCodes';

export type ResolveOutcome =
  | { kind: 'REDIRECT'; url: string }
  | { kind: 'FALLBACK'; fallback: FallbackKind };

/** Shorthand — the fallback branches are most of this file. */
const fallback = (kind: FallbackKind): ResolveOutcome => ({ kind: 'FALLBACK', fallback: kind });

/**
 * The `YYYY-MM-DD` bucket a scan counts against.
 *
 * UTC, NOT LOCAL — matching the field comment on QrScanDaily.day. A local-time
 * bucket would make "which day is this scan in" depend on where the process
 * happens to be running, and a redeploy into another region would silently
 * re-bucket. `toISOString()` is UTC by definition, which is the whole reason it
 * is used here rather than any date formatting.
 */
export function utcDay(at: Date): string {
  return at.toISOString().slice(0, 10);
}

/**
 * One `$inc` upsert against QrScanDaily's unique index.
 *
 * NEVER ON THE CRITICAL PATH. Every failure is caught and swallowed at warn
 * level: a metrics write must not be able to take a restaurant's menu down. The
 * caller awaits it only so the count is durable before the diner leaves — not
 * because the redirect depends on it.
 *
 * `assignmentId` is part of the bucket identity, not a decoration. Scans stay
 * attributed to the mapping that was live when they happened, so repointing a
 * standee to a second restaurant does not retroactively move yesterday's
 * traffic onto the new one.
 */
async function recordScan(qrCodeId: Types.ObjectId, assignmentId: Types.ObjectId): Promise<void> {
  try {
    const day = utcDay(new Date());
    await QrScanDaily.updateOne(
      { qrCodeId, assignmentId, day },
      { $inc: { count: 1 }, $setOnInsert: { qrCodeId, assignmentId, day } },
      { upsert: true }
    ).exec();
  } catch (err) {
    console.warn('[qr-resolver] scan rollup failed (redirect unaffected)', err);
  }
}

/**
 * Where a printed code sends a phone.
 *
 * The order below is the order of cost, cheapest first, and each step's reason
 * is load-bearing:
 *
 *  1. Normalise. A code that cannot exist NEVER REACHES THE DATABASE — which is
 *     what keeps a scan-flood of garbage against a public URL from becoming a
 *     query-flood against Mongo.
 *  2/3/4. State, not existence. UNASSIGNED and unknown deliberately produce the
 *     same outcome; see routes/public.ts for why that is a security property.
 *  5. A catalog with no `mirageRestaurantId` is ACTIVATED BUT NOT YET
 *     PUBLISHED, which is the normal state for the first minutes of a rep
 *     visit. It is what the "not live yet" page is for — not an error.
 *  6. The redirect target is derived from `mirageRestaurantId`, NEVER from
 *     `catalog.publicUrl`: activation writes `{PUBLIC_RESOLVER_BASE_URL}/r/
 *     {code}` INTO publicUrl, so redirecting there would send the browser back
 *     to this very request until it hit its redirect limit — every standee in
 *     the field a dead link. See C6 in the same-day-activation preflight, and
 *     the test that asserts the Location header contains no `/r/`.
 */
export async function resolveCode(rawCode: string): Promise<ResolveOutcome> {
  const code = normalizeQrCode(rawCode);
  if (!code) return fallback('UNKNOWN');

  const qrCode = await QrCode.findOne({ code, deletedAt: null }).exec();
  if (!qrCode) return fallback('UNKNOWN');

  if (qrCode.state === 'RETIRED') return fallback('REPLACED');
  if (qrCode.state === 'UNASSIGNED' || !qrCode.catalogId) return fallback('NOT_YET_LIVE');

  const catalog = await Catalog.findOne({ _id: qrCode.catalogId, deletedAt: null }).exec();
  if (!catalog || !catalog.mirageRestaurantId) return fallback('NOT_YET_LIVE');

  // A mapped catalog can only exist if provisioning ran, and provisioning
  // refuses to run without MIRAGE_PUBLIC_BASE_URL — so reaching this line means
  // the variable was REMOVED from a live deployment. Rendering the error page
  // is right (the diner sees something honest) but this is an operator fault,
  // not a catalog state, so it is logged as one rather than dressed up as "not
  // live yet". `undefined/<id>` must never reach a browser.
  if (!env.MIRAGE_PUBLIC_BASE_URL) {
    console.error(
      '[qr-resolver] MIRAGE_PUBLIC_BASE_URL is unset — a published catalog cannot be resolved'
    );
    return fallback('ERROR');
  }

  // `currentAssignmentId` is the denormalised head of the QrCodeAssignment
  // ledger, cached on the code so the hot path stays at two reads. Its absence
  // on a code activated before that field existed costs the rollup, never the
  // redirect — the menu is what the diner came for.
  if (qrCode.currentAssignmentId) {
    await recordScan(qrCode._id as Types.ObjectId, qrCode.currentAssignmentId);
  } else {
    console.warn('[qr-resolver] active code has no currentAssignmentId — scan not recorded');
  }

  return { kind: 'REDIRECT', url: mintPublicUrl(catalog.mirageRestaurantId) };
}
