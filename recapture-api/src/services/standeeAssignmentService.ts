// src/services/standeeAssignmentService.ts
//
// WHO IS CARRYING WHICH STANDEE.
//
// Until now nothing recorded it. `QrCode.activatedByUserId` is a post-hoc audit
// field — it answers "who used this" after the fact, which is no help to the rep
// standing at a table wondering whether the sheet in their folder is still free.
// So an admin handed codes out by sending PDFs, and two reps could be sent the
// same one and discover it in front of a customer as the "already in use"
// branch.
//
// ADVISORY BY DESIGN. This service does not gate activation and must not start
// to: `activationService` never reads `assignedToUserId`, so an unassigned code
// still works for any rep, and a code assigned to rep A can still be activated
// by rep B. What assignment changes is what each side can SEE — the rep's own
// stock list and the recommendations on their activation screen, and the
// admin's view of where a batch went. If that ever becomes a hard lock it is a
// change to the activation path, not to this file, and it needs its own think
// about the walk-up standee nobody assigned.
//
// PII: a rep summary carries a display name and a MASKED contact, never a raw
// phone or email — same stance as `GET /auth/me`, and the reason
// `maskIdentifier` is imported here rather than reimplemented.
import { Types } from 'mongoose';

import { QrCode, type IQrCode } from '@/models/QrCode';
import { User, type UserRole } from '@/models/User';
import { maskIdentifier } from '@/utils/maskIdentifier';
import { resolverUrlFor } from '@/services/qrCodeService';
import type { QrCodeState } from '@/models/types/qr.types';

/**
 * A staff member an admin may hand a standee to.
 *
 * `contactMasked` is what makes this list USABLE: display names are optional
 * and reps set them rarely, so without it an admin picking from a list of
 * accounts is choosing between several rows reading "Sales rep" with nothing to
 * tell them apart. It is null when the identifier is missing or too short to
 * mask safely — `maskIdentifier` never falls back to a partial raw value.
 */
export interface AssignableRep {
  id: string;
  displayName: string | null;
  contactMasked: string | null;
  role: UserRole;
}

/**
 * Everyone who can actually act on an assignment.
 *
 * The set is defined by CAPABILITY, not by an exact role match: `/rep` is gated
 * with `requireRole('SALES_REP')`, which is inclusive upward, so a MODEL_ARTIST
 * or an ADMIN can use the rep surface too. Listing only `role === 'SALES_REP'`
 * would let an admin who also does field visits be invisible in their own
 * picker; worse, it would be an exact-equality role check, which AGENTS.md
 * calls a bug for exactly this reason. The `role` field rides along on each row
 * so the picker can label the non-obvious ones.
 */
const ASSIGNABLE_ROLES: readonly UserRole[] = ['SALES_REP', 'MODEL_ARTIST', 'ADMIN'];

/**
 * Staff who may be handed a standee.
 *
 * Unpaged and unfiltered, deliberately. This is the internal staff roster — a
 * handful of people, not a user directory — and the admin user-management
 * feature that WOULD need paging and search is on hold precisely because the
 * roster is that small. If this list ever needs a search box, that decision has
 * changed and belongs in AGENTS.md, not in a quiet `.limit()` here.
 */
export async function listAssignableReps(): Promise<AssignableRep[]> {
  const users = await User.find(
    { role: { $in: ASSIGNABLE_ROLES } },
    { displayName: 1, phone: 1, email: 1, role: 1 }
  )
    .sort({ displayName: 1, _id: 1 })
    .lean()
    .exec();

  return users.map(toAssignableRep);
}

/** Projection → DTO, shared by every path that returns a rep summary. */
function toAssignableRep(doc: {
  _id: unknown;
  displayName?: string | null;
  phone?: string | null;
  email?: string | null;
  role: UserRole;
}): AssignableRep {
  return {
    id: String(doc._id),
    displayName: doc.displayName ?? null,
    contactMasked: maskIdentifier({ phone: doc.phone, email: doc.email }),
    role: doc.role,
  };
}

/**
 * One staff member, by id, if they may hold a standee at all.
 *
 * Exported because the MINT path needs to ask this question BEFORE it mints.
 * The role filter is the same one `assignCode` applies: an assignment to a plain
 * USER would produce a row nobody can ever open, since `/rep` is closed to them.
 */
export async function findAssignableRep(
  repUserId: Types.ObjectId
): Promise<AssignableRep | null> {
  const rep = await User.findOne(
    { _id: repUserId, role: { $in: ASSIGNABLE_ROLES } },
    { displayName: 1, phone: 1, email: 1, role: 1 }
  )
    .lean()
    .exec();
  return rep ? toAssignableRep(rep) : null;
}

/** What a bulk assignment moved. */
export interface AssignBatchResult {
  assigned: number;
  /** Codes left alone because they cannot be printed or activated. */
  skippedRetired: number;
}

/**
 * Hands every usable code in a batch to one rep, in a single write.
 *
 * WHY THIS IS NOT A LOOP OVER [assignCode]. That function reads and saves one
 * document at a time, which is right for one standee and catastrophic for a
 * batch: QR_BATCH_MAX_SIZE is 2,000 by default and 10,000 at the ceiling, so the
 * loop would be up to 20,000 round trips for a screen whose whole promise is
 * that the admin does NOT have to do this one at a time.
 *
 * THE CALLER MUST HAVE VALIDATED THE REP. This does no role check of its own —
 * it takes an id it was told is good — because the mint path has to reject a
 * stale picker selection BEFORE committing a print run, and re-checking here
 * would be a second lookup that can only agree.
 *
 * RETIRED codes are skipped rather than refused. A batch is a mixed bag once it
 * has been in service, and failing the whole assignment because one sheet was
 * replaced months ago would make the bulk path unusable exactly when it is most
 * wanted. `assignCode` refuses a single retired code for the opposite reason:
 * there, the retired code IS the request.
 *
 * Overwrites existing holders, matching [assignCode] — a batch handed to a new
 * rep is a batch that moved, and the truth is whoever holds it now.
 */
export async function assignBatchCodes(params: {
  batchId: Types.ObjectId;
  repUserId: Types.ObjectId;
  actorUserId: Types.ObjectId;
}): Promise<AssignBatchResult> {
  const assignable = { batchId: params.batchId, deletedAt: null, state: { $ne: 'RETIRED' } };

  const result = await QrCode.updateMany(assignable, {
    $set: {
      assignedToUserId: params.repUserId,
      assignedAt: new Date(),
      assignedByUserId: params.actorUserId,
    },
  }).exec();

  // Counted separately rather than inferred from `batch.count`, which is what
  // was REQUESTED at mint and says nothing about what the collection holds now.
  const skippedRetired = await QrCode.countDocuments({
    batchId: params.batchId,
    deletedAt: null,
    state: 'RETIRED',
  }).exec();

  return { assigned: result.modifiedCount, skippedRetired };
}

export type AssignCodeResult =
  | { outcome: 'CODE_NOT_FOUND' }
  | { outcome: 'CODE_RETIRED' }
  | { outcome: 'REP_NOT_FOUND' }
  | { outcome: 'ASSIGNED'; code: string; rep: AssignableRep };

/**
 * Hands one standee to one rep, overwriting any previous holder.
 *
 * REASSIGNMENT IS A PLAIN OVERWRITE and that is the intended behaviour: a
 * standee physically moves between people (it was in the wrong folder, a rep
 * left, a territory changed), and the truth is simply whoever holds it now.
 * There is no ledger to close because — unlike `QrCodeAssignment`, which
 * records what a code POINTS AT and is load-bearing for scan attribution —
 * nothing downstream reads the history of who carried it.
 *
 * A RETIRED code is refused. It cannot be printed (`renderStandeeSheet` says
 * so) and cannot be activated, so handing one to a rep gives them a row they
 * can do nothing with; the refusal happens here so the admin finds out at the
 * moment of assigning rather than the rep finding out later.
 *
 * An ACTIVE code is NOT refused. A code that is live on a restaurant still has
 * a rep responsible for that restaurant, and the assignment is how the rep's
 * list shows it — the state on the row is what tells them it is already in use.
 */
export async function assignCode(params: {
  code: string;
  repUserId: Types.ObjectId;
  actorUserId: Types.ObjectId;
}): Promise<AssignCodeResult> {
  const qrCode = await QrCode.findOne({ code: params.code, deletedAt: null }).exec();
  if (!qrCode) return { outcome: 'CODE_NOT_FOUND' };
  if (qrCode.state === 'RETIRED') return { outcome: 'CODE_RETIRED' };

  // The rep is resolved BEFORE the write, and by role as well as by id: an
  // assignment to a plain USER would produce a row nobody can ever open, since
  // the whole /rep subtree is closed to them. A stale id from an admin's open
  // picker is the realistic way that happens.
  const rep = await findAssignableRep(params.repUserId);
  if (!rep) return { outcome: 'REP_NOT_FOUND' };

  qrCode.assignedToUserId = params.repUserId;
  qrCode.assignedAt = new Date();
  qrCode.assignedByUserId = params.actorUserId;
  await qrCode.save();

  return { outcome: 'ASSIGNED', code: qrCode.code, rep };
}

export type UnassignCodeResult =
  | { outcome: 'CODE_NOT_FOUND' }
  | { outcome: 'UNASSIGNED'; code: string };

/**
 * Takes a standee back off whoever was holding it.
 *
 * IDEMPOTENT — unassigning a code nobody holds succeeds. The admin's intent is
 * "make sure this is not on anybody's list", and that intent is satisfied
 * either way; a 409 here would only ever be reported to someone who already has
 * what they wanted.
 *
 * `assignedByUserId` is cleared with the rest. It audits an assignment that no
 * longer exists, and leaving it behind would make an unassigned code look
 * half-assigned to the next person reading the document.
 */
export async function unassignCode(code: string): Promise<UnassignCodeResult> {
  const updated = await QrCode.findOneAndUpdate(
    { code, deletedAt: null },
    { $unset: { assignedToUserId: '', assignedAt: '', assignedByUserId: '' } },
    { new: true }
  ).exec();

  if (!updated) return { outcome: 'CODE_NOT_FOUND' };
  return { outcome: 'UNASSIGNED', code: updated.code };
}

/** One standee on a rep's own list. */
export interface RepStandeeRow {
  code: string;
  state: QrCodeState;
  /** Exactly what the standee encodes — the composer the vendor CSV uses. */
  url: string;
  assignedAt: Date | null;
}

/**
 * Ordering key for a rep's list: usable stock first.
 *
 * A rep opens the list to answer one question — "which of these can I put on a
 * table right now" — so UNASSIGNED (free) sorts ahead of ACTIVE (already live
 * somewhere), and RETIRED sinks. An unrecognised state sorts last rather than
 * first, the same fail-closed instinct the client's `QrCodeState.unknown`
 * follows: a state this build does not understand must never be presented as
 * the readiest thing in the folder.
 */
const REP_STANDEE_RANK: Record<QrCodeState, number> = {
  UNASSIGNED: 0,
  ACTIVE: 1,
  RETIRED: 2,
};

/**
 * The stock one rep is carrying, unusable codes last.
 *
 * Unpaged: a rep carries a folder of standees, not a batch of two thousand. If
 * that stops being true the fix is the keyset scheme `listBatchCodes` already
 * uses, not a bare `.limit()` that silently hides the tail.
 *
 * The secondary sort is by code, so the order is stable across refreshes and a
 * rep's eye can find a specific sheet in their folder.
 *
 * THROWS `QrResolverNotConfiguredError` when the deployment has no public
 * origin, matching every other path that emits a printable URL.
 */
export async function listRepStandees(repUserId: Types.ObjectId): Promise<RepStandeeRow[]> {
  const codes = await QrCode.find(
    { assignedToUserId: repUserId, deletedAt: null },
    { code: 1, state: 1, assignedAt: 1 }
  )
    .sort({ code: 1 })
    .lean()
    .exec();

  return codes
    .map((c) => ({
      code: c.code,
      state: c.state,
      url: resolverUrlFor(c.code),
      assignedAt: c.assignedAt ?? null,
    }))
    .sort(
      (a, b) =>
        (REP_STANDEE_RANK[a.state] ?? 3) - (REP_STANDEE_RANK[b.state] ?? 3) ||
        a.code.localeCompare(b.code)
    );
}

/**
 * Is this code on this rep's list? The authorization behind the rep's own
 * standee download.
 *
 * Returns the code document so the caller renders from the SAME read that
 * proved the entitlement — re-fetching by code afterwards would open a window
 * where the two disagree.
 */
export async function findRepStandee(
  repUserId: Types.ObjectId,
  code: string
): Promise<IQrCode | null> {
  return QrCode.findOne({
    code,
    assignedToUserId: repUserId,
    deletedAt: null,
  }).exec();
}
