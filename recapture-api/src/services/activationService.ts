// src/services/activationService.ts
//
// A rep standing in a restaurant turns a printed standee into a live catalog.
//
// TWO RULES GOVERN EVERY LINE OF THIS FILE:
//
//  1. THE RESTAURANT OWNS THE CATALOG. Not the rep. `Catalog.userId` is the
//     restaurant's user id from the first second, which is why the unique index
//     on it, every `userId`-scoped query in the authoring services, and
//     `resolveOwnedModel`'s ownership proof all keep working unweakened. The
//     rep's access is a CatalogDelegation row and nothing else — revocable, and
//     re-read on every request.
//  2. NOTHING HERE IS A TRANSACTION, and none is needed. Every step that could
//     race is a single-document conditional update whose guard IS the lock —
//     the same pattern as `activePublishRunId` in catalogPublishService and
//     refresh-token rotation. Two reps scanning the same standee produce one
//     winner and one clean 409.
import { Types } from 'mongoose';

import { env } from '@/config/env';
import { Catalog, type ICatalog } from '@/models/Catalog';
import { QrCode, type IQrCode } from '@/models/QrCode';
import { QrCodeAssignment } from '@/models/QrCodeAssignment';
import { User, type IUser } from '@/models/User';
import { grantDelegation } from '@/services/catalogDelegationService';
import { isDuplicateKeyError } from '@/services/catalogService';
import { consumeRateWindow } from '@/utils/rateLimit';
import { hashIdentifier } from '@/utils/otp';
import { track, AnalyticsEvent } from '@/utils/analytics';
import type { CatalogContact } from '@/models/types/catalog.types';
import { randomUUID } from 'crypto';

export type ActivationResult =
  | { outcome: 'ACTIVATED'; catalog: ICatalog; code: string; publicUrl: string }
  /** A re-run of an activation that already succeeded — same code, same catalog. */
  | { outcome: 'ALREADY_ACTIVE'; catalog: ICatalog; code: string; publicUrl: string }
  | { outcome: 'CODE_NOT_FOUND' }
  /** Retired, or already pointing at somebody else's catalog. */
  | { outcome: 'CODE_UNAVAILABLE' }
  | { outcome: 'RESOLVER_NOT_CONFIGURED' }
  | { outcome: 'RATE_LIMITED'; retryAfter: number };

/**
 * The restaurant's own account, created on the rep's word rather than on an OTP.
 *
 * `phoneVerified` STAYS FALSE. Nobody proved possession of this number — a rep
 * typed it — and shortcutting the flag would make an unverified assertion
 * indistinguishable from a verified one everywhere downstream. When the owner
 * later signs in with that number through the normal OTP flow,
 * `verifyOtpService.resolveUser` finds THIS EXACT USER by phone and flips the
 * flag: they simply are the owner. No migration, no claim step, no account
 * merge, no "link your catalog" screen.
 *
 * That hand-off works only because `phone` is normalised identically on both
 * sides — the route parses it through the SAME `phoneField` the OTP schemas
 * use. See the comment on that export; it is the highest-consequence detail in
 * the feature.
 *
 * An existing user is REUSED rather than collided with: a restaurant that
 * already has an account and is being re-signed by a rep must land on its
 * existing catalog.
 */
async function resolveOrCreateRestaurantUser(
  phone: string
): Promise<{ user: IUser; isNewUser: boolean }> {
  const existing = await User.findOne({ phone }).exec();
  if (existing) return { user: existing, isNewUser: false };

  try {
    const user = await User.create({
      authProvider: 'custom',
      // The same identity shape verifyOtpService creates on first login: a
      // random authUid, because nothing external issued one.
      authUid: randomUUID(),
      phone,
      phoneVerified: false,
    });
    return { user, isNewUser: true };
  } catch (err) {
    if (!isDuplicateKeyError(err)) throw err;
    // Two activations for the same restaurant at once. Replay the winner.
    const winner = await User.findOne({ phone }).exec();
    if (!winner) throw err;
    return { user: winner, isNewUser: false };
  }
}

/**
 * The restaurant's catalog, created if they have none.
 *
 * The unique index on `Catalog.userId` IS the one-per-user rule, so this
 * upserts and lets the index arbitrate rather than reading first — two
 * concurrent creates would both pass a read-then-write check. Same shape as
 * `catalogService.createCatalog`.
 *
 * NOTE the index counts soft-deleted rows, so a restaurant that deleted its
 * catalog is returned that row rather than given a second one with a different
 * public URL. That is deliberate upstream and inherited here.
 */
async function resolveOrCreateCatalog(
  ownerId: Types.ObjectId,
  input: { name: string; businessName?: string; contact?: CatalogContact }
): Promise<{ catalog: ICatalog; isNewCatalog: boolean }> {
  const existing = await Catalog.findOne({ userId: ownerId }).exec();
  if (existing) return { catalog: existing, isNewCatalog: false };

  try {
    const created = await Catalog.create({
      userId: ownerId,
      name: input.name,
      ...(input.businessName ? { businessName: input.businessName } : {}),
      ...(input.contact ? { contact: input.contact } : {}),
    });
    return { catalog: created, isNewCatalog: true };
  } catch (err) {
    if (!isDuplicateKeyError(err)) throw err;
    const winner = await Catalog.findOne({ userId: ownerId }).exec();
    if (!winner) throw err;
    return { catalog: winner, isNewCatalog: false };
  }
}

/**
 * Freezes the standee's URL onto the catalog — ONCE.
 *
 * Guarded on `publicUrl: null` (which in Mongo matches an absent field too), so
 * an already-activated catalog keeps its FIRST URL forever. That is feature 32:
 * a second code attached later, a rename, a republish and product churn all
 * leave this string alone, and the remapping happens on the QrCode row instead.
 *
 * Returns the URL the catalog actually carries, which on a lost race is the
 * winner's rather than ours.
 */
async function freezePublicUrl(catalogId: Types.ObjectId, code: string): Promise<string> {
  const url = `${env.PUBLIC_RESOLVER_BASE_URL}/r/${code}`;

  const updated = await Catalog.findOneAndUpdate(
    { _id: catalogId, publicUrl: null },
    { $set: { publicUrl: url, publicUrlScheme: 'RECAPTURE_SHORT_CODE' } },
    { new: true }
  ).exec();
  if (updated?.publicUrl) return updated.publicUrl;

  const current = await Catalog.findOne({ _id: catalogId }).exec();
  return current?.publicUrl ?? url;
}

/**
 * Opens the ledger row for a live mapping and caches its id on the code.
 *
 * Idempotent: a re-run finds the open row and re-points nothing. The cached
 * `currentAssignmentId` is what keeps the public resolver's hot path at two
 * reads (stage 3) — without it every scan would have to query this ledger.
 */
async function openAssignment(
  qrCodeId: Types.ObjectId,
  catalogId: Types.ObjectId,
  assignedByUserId: Types.ObjectId
): Promise<Types.ObjectId> {
  const open = await QrCodeAssignment.findOne({
    qrCodeId,
    catalogId,
    unassignedAt: null,
  }).exec();

  const assignmentId =
    (open?._id as Types.ObjectId | undefined) ??
    ((
      await QrCodeAssignment.create({
        qrCodeId,
        catalogId,
        assignedAt: new Date(),
        assignedByUserId,
      })
    )._id as Types.ObjectId);

  await QrCode.updateOne({ _id: qrCodeId }, { $set: { currentAssignmentId: assignmentId } }).exec();
  return assignmentId;
}

/**
 * Everything that must be true once a code is bound to a catalog, whether this
 * request bound it or an earlier one did.
 *
 * Written as one function precisely so the fresh path and the re-run path
 * cannot drift: a re-run after a crash mid-activation is how a half-finished
 * activation gets FINISHED, so it has to do the same work, not a subset.
 */
async function finishActivation(
  qrCode: IQrCode,
  catalog: ICatalog,
  code: string,
  repUserId: Types.ObjectId
): Promise<string> {
  const catalogId = catalog._id as Types.ObjectId;
  const publicUrl = await freezePublicUrl(catalogId, code);
  await openAssignment(qrCode._id as Types.ObjectId, catalogId, repUserId);
  await grantDelegation(repUserId, catalogId);
  return publicUrl;
}

/**
 * Turn one printed standee into a live, delegated catalog.
 *
 * ORDER, AND WHY:
 *
 *  1. Refuse without PUBLIC_RESOLVER_BASE_URL — BEFORE any write. Activating
 *     against a guessed host would freeze `undefined/r/CODE` onto a catalog
 *     permanently, and `publicUrl` is the one field nothing may rewrite.
 *  2. Rate-limit per rep. `/rep` gets its own window because role inheritance
 *     means MODEL_ARTIST and ADMIN pass this gate too — the window is part of
 *     what makes that inheritance auditable rather than unbounded.
 *  3. Load the code. A RETIRED or someone-else's code is refused here, BEFORE
 *     a user or catalog is created, so a rejected activation writes nothing.
 *  4/5. Resolve-or-create the restaurant and its catalog.
 *  6. CLAIM THE CODE — the conditional update whose guard is the lock.
 *  7. Freeze the URL, open the ledger row, grant the delegation.
 *
 * ⚠ DEVIATION FROM THE STAGE DOC, DELIBERATE: the doc freezes `publicUrl`
 * (its step 6) BEFORE claiming the code (its step 7). That ordering can write
 * an unrewritable URL pointing at a code this request then loses the race for —
 * a catalog permanently advertising a standee that belongs to a different
 * restaurant. Claiming first strictly removes that failure mode and preserves
 * the doc's stated one: dying between the claim and the grant leaves a live
 * catalog the rep cannot yet edit, which a re-run repairs.
 */
export async function activate(params: {
  repUserId: Types.ObjectId;
  code: string;
  restaurantName: string;
  restaurantPhone: string;
  businessName?: string;
  contact?: CatalogContact;
}): Promise<ActivationResult> {
  // ── 1) Configuration, before anything is written ──────────────────────────
  if (!env.PUBLIC_RESOLVER_BASE_URL) return { outcome: 'RESOLVER_NOT_CONFIGURED' };

  // ── 2) Per-rep rate limit ─────────────────────────────────────────────────
  const limit = await consumeRateWindow(
    `activation:${params.repUserId.toHexString()}`,
    env.ACTIVATION_MAX_PER_WINDOW,
    env.ACTIVATION_WINDOW_SECONDS
  );
  if (limit.limited) return { outcome: 'RATE_LIMITED', retryAfter: limit.retryAfter };

  // ── 3) The code ───────────────────────────────────────────────────────────
  // `params.code` is already normalised by the route's schema (qrCodeParam), so
  // a malformed code never reaches this service at all.
  const qrCode = await QrCode.findOne({ code: params.code, deletedAt: null }).exec();
  if (!qrCode) return { outcome: 'CODE_NOT_FOUND' };
  if (qrCode.state === 'RETIRED') return { outcome: 'CODE_UNAVAILABLE' };

  if (qrCode.state === 'ACTIVE') {
    // A RE-RUN, or somebody else's standee. The two are told apart WITHOUT
    // creating anything: compare the bound catalog's owner against the phone
    // this request would have resolved to. Creating a user first and comparing
    // afterwards would leave an orphan account behind every mistyped code.
    const bound = qrCode.catalogId
      ? await Catalog.findOne({ _id: qrCode.catalogId, deletedAt: null }).exec()
      : null;
    const owner = await User.findOne({ phone: params.restaurantPhone }).exec();
    if (!bound || !owner || !bound.userId.equals(owner._id as Types.ObjectId)) {
      return { outcome: 'CODE_UNAVAILABLE' };
    }

    const publicUrl = await finishActivation(qrCode, bound, params.code, params.repUserId);
    trackActivation(params.repUserId, 'ALREADY_ACTIVE');
    return { outcome: 'ALREADY_ACTIVE', catalog: bound, code: params.code, publicUrl };
  }

  // ── 4/5) The restaurant and its catalog ───────────────────────────────────
  const { user } = await resolveOrCreateRestaurantUser(params.restaurantPhone);
  const ownerId = user._id as Types.ObjectId;
  const { catalog } = await resolveOrCreateCatalog(ownerId, {
    name: params.restaurantName,
    businessName: params.businessName,
    contact: params.contact,
  });
  const catalogId = catalog._id as Types.ObjectId;

  // ── 6) THE CLAIM. The guard IS the mutual exclusion ───────────────────────
  const claimed = await QrCode.findOneAndUpdate(
    { _id: qrCode._id, state: 'UNASSIGNED', deletedAt: null },
    {
      $set: {
        state: 'ACTIVE',
        catalogId,
        activatedAt: new Date(),
        activatedByUserId: params.repUserId,
      },
    },
    { new: true }
  ).exec();

  if (!claimed) {
    // Someone else won between the read and the write. If they bound it to the
    // SAME catalog — two reps signing one restaurant at once — that is the
    // idempotent outcome, not a conflict.
    const current = await QrCode.findOne({ _id: qrCode._id }).exec();
    if (current?.state === 'ACTIVE' && current.catalogId?.equals(catalogId)) {
      const publicUrl = await finishActivation(current, catalog, params.code, params.repUserId);
      trackActivation(params.repUserId, 'ALREADY_ACTIVE');
      return { outcome: 'ALREADY_ACTIVE', catalog, code: params.code, publicUrl };
    }
    trackActivation(params.repUserId, 'CODE_UNAVAILABLE');
    return { outcome: 'CODE_UNAVAILABLE' };
  }

  // ── 7) Freeze the URL, open the ledger, grant access ──────────────────────
  const publicUrl = await finishActivation(claimed, catalog, params.code, params.repUserId);
  trackActivation(params.repUserId, 'ACTIVATED');
  return { outcome: 'ACTIVATED', catalog, code: params.code, publicUrl };
}

/**
 * The activation event.
 *
 * NEVER THE CODE AND NEVER THE PHONE. A code is a public identifier for one
 * restaurant's menu and a phone identifies a person; the rep is hashed per the
 * house rule, and the outcome is the only other thing carried.
 */
function trackActivation(
  repUserId: Types.ObjectId,
  outcome: 'ACTIVATED' | 'ALREADY_ACTIVE' | 'CODE_UNAVAILABLE'
): void {
  track(AnalyticsEvent.QR_CODE_ACTIVATED, {
    actor_id_hash: hashIdentifier(repUserId.toHexString()),
    outcome,
  });
}

// ── Replacement standees and retirement ────────────────────────────────────

export type AttachCodeResult =
  | { outcome: 'ATTACHED'; code: string }
  | { outcome: 'CODE_NOT_FOUND' }
  | { outcome: 'CODE_UNAVAILABLE' }
  /** Already this catalog's code — nothing to do. */
  | { outcome: 'ALREADY_ATTACHED'; code: string }
  /** The code is live on a catalog that has already published. See below. */
  | { outcome: 'SOURCE_CATALOG_PUBLISHED' };

/**
 * Attaches a SECOND code to a catalog — the lost-or-damaged-standee path.
 *
 * `publicUrl` IS NOT TOUCHED. That is the whole reason the resolver exists: the
 * catalog keeps advertising its first URL, the new standee carries a different
 * code, and both resolve to the same menu until the old one is retired. Feature
 * 32 satisfied rather than worked around.
 *
 * The catalog's previously-open assignment row is CLOSED and a new one opened,
 * so scan history splits at the swap: counts recorded against the old standee
 * stay on the old row forever and the replacement starts from zero. Retiring
 * the old code is a SEPARATE call, deliberately — "print a spare" and "kill the
 * lost one" are two decisions and a rep may well want only the first.
 *
 * CROSS-CATALOG REPOINTING is refused once the source catalog has published.
 * Moving a live code from catalog A to catalog B leaves A's frozen `publicUrl`
 * pointing at a standee that no longer resolves to A — a dead link on printed
 * material, which is the one outcome the whole feature forbids. While A is
 * still DRAFT nothing has been printed or shared, so the move is safe and
 * allowed. The rule lives HERE rather than in the route, so every future caller
 * inherits it.
 */
export async function attachCodeToCatalog(params: {
  repUserId: Types.ObjectId;
  catalog: ICatalog;
  code: string;
}): Promise<AttachCodeResult> {
  const catalogId = params.catalog._id as Types.ObjectId;

  const qrCode = await QrCode.findOne({ code: params.code, deletedAt: null }).exec();
  if (!qrCode) return { outcome: 'CODE_NOT_FOUND' };
  if (qrCode.state === 'RETIRED') return { outcome: 'CODE_UNAVAILABLE' };

  if (qrCode.state === 'ACTIVE') {
    if (qrCode.catalogId?.equals(catalogId)) {
      return { outcome: 'ALREADY_ATTACHED', code: params.code };
    }
    const source = qrCode.catalogId
      ? await Catalog.findOne({ _id: qrCode.catalogId }).exec()
      : null;
    // `publishedRevision` starts at -1 and only ever moves on a successful
    // publish, so this is "has this catalog ever been live", not "is it live
    // right now" — an UNPUBLISHED catalog has still had its URL in the world.
    if (source && source.publishedRevision >= 0) {
      return { outcome: 'SOURCE_CATALOG_PUBLISHED' };
    }
    // Repointing a never-published catalog's code: close its old mapping first,
    // so the ledger never shows one code open against two catalogs.
    await QrCodeAssignment.updateOne(
      { qrCodeId: qrCode._id, unassignedAt: null },
      { $set: { unassignedAt: new Date() } }
    ).exec();
  }

  const claimed = await QrCode.findOneAndUpdate(
    // The guard admits both the fresh code and the repoint the branch above
    // just authorised, and excludes RETIRED — which cannot be revived.
    { _id: qrCode._id, deletedAt: null, state: { $in: ['UNASSIGNED', 'ACTIVE'] } },
    {
      $set: {
        state: 'ACTIVE',
        catalogId,
        activatedAt: new Date(),
        activatedByUserId: params.repUserId,
      },
    },
    { new: true }
  ).exec();
  if (!claimed) return { outcome: 'CODE_UNAVAILABLE' };

  // Close this CATALOG's currently-open mapping before opening the new one, so
  // the replacement standee's scans are counted separately from the old one's.
  await QrCodeAssignment.updateOne(
    { catalogId, unassignedAt: null },
    { $set: { unassignedAt: new Date() } }
  ).exec();

  await openAssignment(claimed._id as Types.ObjectId, catalogId, params.repUserId);
  return { outcome: 'ATTACHED', code: params.code };
}

export type RetireCodeResult =
  | { outcome: 'RETIRED' }
  | { outcome: 'CODE_NOT_FOUND' }
  | { outcome: 'ALREADY_RETIRED' };

/**
 * Takes one standee out of service.
 *
 * RETIRED, never deleted: the code can then never be re-minted onto a different
 * restaurant, its scan history stays attributable, and the public resolver has
 * a state to render the "this code has been replaced" page from (stage 3)
 * instead of the page that means "not set up yet".
 */
export async function retireCode(qrCode: IQrCode): Promise<RetireCodeResult> {
  if (qrCode.state === 'RETIRED') return { outcome: 'ALREADY_RETIRED' };

  const retired = await QrCode.findOneAndUpdate(
    { _id: qrCode._id, deletedAt: null, state: { $ne: 'RETIRED' } },
    { $set: { state: 'RETIRED' } },
    { new: true }
  ).exec();
  if (!retired) return { outcome: 'ALREADY_RETIRED' };

  await QrCodeAssignment.updateOne(
    { qrCodeId: qrCode._id, unassignedAt: null },
    { $set: { unassignedAt: new Date() } }
  ).exec();

  return { outcome: 'RETIRED' };
}
