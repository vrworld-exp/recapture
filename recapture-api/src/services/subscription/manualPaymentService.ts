// src/services/subscription/manualPaymentService.ts
//
// Door 3 — cash, cheque, bank transfer, a UPI paid to the rep's phone. Two
// halves, two roles, and the line between them is the whole design (AC-6):
//   • a REP SUBMITS: a MANUAL row in PENDING_VERIFICATION, and NOTHING on the
//     subscription. A rep cannot activate a restaurant by typing.
//   • an ADMIN DECIDES: the one transition the ledger allows
//     (PENDING_VERIFICATION → VERIFIED | REJECTED), conditional so it happens
//     once, and only VERIFIED calls `applyPaidPeriod`.
// Both actors are stored even when they are the same person (AC-6.4) — the
// audit question is "who verified", not "was it someone else".
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { PaymentRecord, type IPaymentRecord } from '@/models/PaymentRecord';
import { User } from '@/models/User';
import type {
  Actor,
  BillingInterval,
  ManualMethod,
  PlanId,
  VerificationStatus,
} from '@/models/types/subscription.types';
import { quoteFor } from '@/services/subscription/checkoutService';
import { receiptNoFor } from '@/services/subscription/paymentLedgerService';
import {
  notifyManualPaymentRejected,
  notifyManualPaymentSubmitted,
} from '@/services/subscription/ownerNotifications';
import { getPlanCatalog } from '@/services/subscription/planCatalogService';
import {
  applyPaidPeriod,
  type ApplyPeriodResult,
} from '@/services/subscription/subscriptionService';
import type { ManualPaymentRequestInput } from '@/validation/subscriptionSchemas';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { toDisplayName } from '@/utils/catalogNames';
import { hashIdentifier } from '@/utils/otp';

/** An override of a quote mismatch must be explained (E12). */
export const OVERRIDE_NOTE_MIN_CHARS = 20;

// ── DTO ─────────────────────────────────────────────────────────────────────

interface ActorDto {
  userId: string;
  role: Actor['role'];
}

/** What the rep and the admin see of a manual entry. Opaque ids, no contact. */
export interface ManualPaymentDto {
  id: string;
  catalogId: string;
  planId: PlanId;
  interval: BillingInterval;
  /** What the plan costs — the number the admin compares `amountPaise` to. */
  quotedPaise: number;
  amountPaise: number;
  amountMatchesQuote: boolean;
  method: ManualMethod;
  reference: string;
  note: string | null;
  verificationStatus: VerificationStatus;
  initiatedBy: ActorDto;
  collectedBy: ActorDto | null;
  verifiedBy: ActorDto | null;
  /** ISO. */
  verifiedAt: string | null;
  createdAt: string;
  receiptNo: string;
}

function actorDto(a: Actor | undefined | null): ActorDto | null {
  return a ? { userId: String(a.userId), role: a.role } : null;
}

export function toManualPaymentDto(row: IPaymentRecord): ManualPaymentDto {
  return {
    id: String(row._id),
    catalogId: String(row.catalogId),
    planId: row.quote!.planId,
    interval: row.quote!.interval,
    quotedPaise: row.quote!.totalPaise,
    amountPaise: row.amountPaise,
    amountMatchesQuote: row.amountPaise === row.quote!.totalPaise,
    method: row.method!,
    reference: row.reference ?? '',
    note: row.note ?? null,
    verificationStatus: row.verificationStatus!,
    initiatedBy: actorDto(row.initiatedBy)!,
    collectedBy: actorDto(row.collectedBy),
    verifiedBy: actorDto(row.verifiedBy),
    verifiedAt: row.verifiedAt?.toISOString() ?? null,
    createdAt: row.createdAt.toISOString(),
    receiptNo: receiptNoFor(row._id as Types.ObjectId),
  };
}

// ── Submit (rep, or admin via CREATE_AND_VERIFY) ────────────────────────────

export type SubmitManualPaymentResult =
  | { outcome: 'CREATED'; record: ManualPaymentDto }
  /** A request is already awaiting verification; it is returned unchanged (§7 rule 3). */
  | { outcome: 'EXISTING'; record: ManualPaymentDto }
  /** `collectedByUserId` names nobody. */
  | { outcome: 'COLLECTOR_NOT_FOUND' };

async function pendingFor(catalogId: Types.ObjectId): Promise<IPaymentRecord | null> {
  return PaymentRecord.findOne({
    catalogId,
    kind: 'MANUAL',
    verificationStatus: 'PENDING_VERIFICATION',
  })
    .sort({ createdAt: -1 })
    .exec();
}

async function insertManualRow(
  catalogId: Types.ObjectId,
  ownerUserId: Types.ObjectId,
  actor: Actor,
  input: ManualPaymentRequestInput
): Promise<IPaymentRecord | 'COLLECTOR_NOT_FOUND'> {
  let collectedBy: Actor = actor;
  if (input.collectedByUserId) {
    const collector = await User.findById(input.collectedByUserId)
      .select({ role: 1 })
      .lean()
      .exec();
    if (!collector) return 'COLLECTOR_NOT_FOUND';
    collectedBy = { userId: collector._id as Types.ObjectId, role: collector.role };
  }

  const [plans, subscription] = await Promise.all([
    getPlanCatalog(),
    CatalogSubscription.findOne({ catalogId }).select({ _id: 1 }).lean().exec(),
  ]);
  const quote = quoteFor(plans, input.planId, input.interval);

  const row = await PaymentRecord.create({
    catalogId,
    userId: ownerUserId,
    ...(subscription ? { subscriptionId: subscription._id } : {}),
    kind: 'MANUAL',
    amountPaise: input.amountPaise,
    currency: 'INR',
    quote,
    method: input.method,
    reference: input.reference,
    ...(input.note ? { note: input.note } : {}),
    initiatedBy: actor,
    collectedBy,
    verificationStatus: 'PENDING_VERIFICATION',
  });

  track(AnalyticsEvent.SUBSCRIPTION_MANUAL_PAYMENT_SUBMITTED, {
    catalog_id: catalogId.toHexString(),
    actor_id_hash: hashIdentifier(actor.userId.toHexString()),
    method: input.method,
    amount_paise: input.amountPaise,
  });
  return row;
}

/** The catalog's request still awaiting verification, if any — the rep card's read. */
export async function getPendingManualPayment(
  catalogId: Types.ObjectId
): Promise<ManualPaymentDto | null> {
  const row = await pendingFor(catalogId);
  return row ? toManualPaymentDto(row) : null;
}

/**
 * The rep's door. Writes a PENDING row and nothing else (AC-6.1). One pending
 * request per catalog at a time: a second submit returns the first.
 */
export async function submitManualPaymentRequest(
  catalogId: Types.ObjectId,
  ownerUserId: Types.ObjectId,
  actor: Actor,
  input: ManualPaymentRequestInput
): Promise<SubmitManualPaymentResult> {
  const existing = await pendingFor(catalogId);
  if (existing) return { outcome: 'EXISTING', record: toManualPaymentDto(existing) };

  const row = await insertManualRow(catalogId, ownerUserId, actor, input);
  if (row === 'COLLECTOR_NOT_FOUND') return { outcome: 'COLLECTOR_NOT_FOUND' };

  // Door 3 is the door with a HUMAN STEP in it: the money is taken, and
  // nothing on the owner's screen moves until an admin verifies. An owner who
  // is not told reads their own unchanged status as the payment having been
  // lost. `createAndVerifyManualPayment` does NOT come through here — it
  // activates in the same call and sends the activation message instead.
  await notifyManualPaymentSubmitted({
    catalogId,
    ownerUserId,
    paymentRecordId: row._id as Types.ObjectId,
    amountPaise: row.amountPaise,
    method: row.method ?? 'CASH',
  });

  return { outcome: 'CREATED', record: toManualPaymentDto(row) };
}

// ── Decide (admin) ──────────────────────────────────────────────────────────

export type DecideManualPaymentResult =
  | { outcome: 'VERIFIED'; record: ManualPaymentDto; applied: ApplyPeriodResult }
  | { outcome: 'REJECTED'; record: ManualPaymentDto }
  /** No MANUAL row with that id on this catalog. */
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'ALREADY_DECIDED' }
  /** The catalog is gone; the request has been auto-rejected (E37). */
  | { outcome: 'CATALOG_DELETED' }
  /** Amount ≠ quote and no adequate override (E12). */
  | { outcome: 'AMOUNT_MISMATCH'; quotedPaise: number; amountPaise: number }
  | { outcome: 'COLLECTOR_NOT_FOUND' }
  /**
   * The reference is a Razorpay payment id our ledger already recorded as an
   * online payment — activating it again would give two periods for one
   * payment. `orderId` is where the admin can see (and fix) that payment.
   */
  | { outcome: 'ALREADY_RECORDED_ONLINE'; orderId: string | null; catalogId: string }
  /** The same reference already activated (or awaits) a cash entry. */
  | { outcome: 'DUPLICATE_REFERENCE' };

/** A Razorpay payment id as an admin would paste it. */
const RAZORPAY_PAYMENT_ID_RE = /^pay_[A-Za-z0-9]+$/;

/**
 * Whether `reference` is money that already activated through another door:
 *   • a `pay_…` id our ledger holds as a PAID row (any catalog) — the owner
 *     paid online and it was recorded; use the journal, not a second period;
 *   • a `pay_…` id already on another live cash entry (any catalog) — a
 *     Razorpay payment is one payment, wherever it was typed in;
 *   • any other reference already on a live cash entry OF THIS CATALOG —
 *     receipt-book numbers repeat across reps, so only the same restaurant.
 * "Live" = PENDING or VERIFIED; a REJECTED entry never took money.
 */
async function referenceConflict(
  catalogId: Types.ObjectId,
  reference: string,
  excludeId?: Types.ObjectId
): Promise<Extract<
  DecideManualPaymentResult,
  { outcome: 'ALREADY_RECORDED_ONLINE' | 'DUPLICATE_REFERENCE' }
> | null> {
  const ref = reference.trim();
  const isRazorpay = RAZORPAY_PAYMENT_ID_RE.test(ref);
  if (isRazorpay) {
    const online = await PaymentRecord.findOne({ kind: 'PAID', providerPaymentId: ref })
      .select({ providerOrderId: 1, catalogId: 1 })
      .lean<{ providerOrderId?: string; catalogId: Types.ObjectId }>()
      .exec();
    if (online) {
      return {
        outcome: 'ALREADY_RECORDED_ONLINE',
        orderId: online.providerOrderId ?? null,
        catalogId: online.catalogId.toHexString(),
      };
    }
  }
  const manual = await PaymentRecord.exists({
    kind: 'MANUAL',
    reference: ref,
    verificationStatus: { $in: ['PENDING_VERIFICATION', 'VERIFIED'] },
    ...(isRazorpay ? {} : { catalogId }),
    ...(excludeId ? { _id: { $ne: excludeId } } : {}),
  }).exec();
  return manual ? { outcome: 'DUPLICATE_REFERENCE' } : null;
}

export interface VerifyInput {
  action: 'VERIFY';
  paymentRecordId: string;
  note?: string;
  override?: boolean;
}
export interface RejectInput {
  action: 'REJECT';
  paymentRecordId: string;
  note: string;
}

async function catalogIsLive(catalogId: Types.ObjectId): Promise<boolean> {
  return (await Catalog.exists({ _id: catalogId, deletedAt: null }).exec()) !== null;
}

/** The ONE transition. Null when the row was not PENDING any more. */
async function transition(
  recordId: Types.ObjectId,
  to: 'VERIFIED' | 'REJECTED',
  admin: Actor | null,
  note: string | undefined,
  now: Date
): Promise<IPaymentRecord | null> {
  return PaymentRecord.findOneAndUpdate(
    { _id: recordId, kind: 'MANUAL', verificationStatus: 'PENDING_VERIFICATION' },
    {
      $set: {
        verificationStatus: to,
        verifiedAt: now,
        ...(admin ? { verifiedBy: admin } : {}),
        ...(note ? { note } : {}),
      },
    },
    { new: true }
  ).exec();
}

async function decideOnRow(
  row: IPaymentRecord,
  admin: Actor,
  input: VerifyInput | RejectInput,
  now: Date
): Promise<DecideManualPaymentResult> {
  const catalogId = row.catalogId;
  if (row.verificationStatus !== 'PENDING_VERIFICATION') return { outcome: 'ALREADY_DECIDED' };

  if (!(await catalogIsLive(catalogId))) {
    await transition(row._id as Types.ObjectId, 'REJECTED', admin, 'CATALOG_DELETED', now);
    return { outcome: 'CATALOG_DELETED' };
  }

  // A VERIFY activates. It must not activate money that already activated
  // through another door (the admin journal's edge case #2).
  if (input.action === 'VERIFY' && row.reference) {
    const conflict = await referenceConflict(catalogId, row.reference, row._id as Types.ObjectId);
    if (conflict) return conflict;
  }

  if (input.action === 'REJECT') {
    const rejected = await transition(
      row._id as Types.ObjectId,
      'REJECTED',
      admin,
      input.note,
      now
    );
    if (!rejected) return { outcome: 'ALREADY_DECIDED' };
    track(AnalyticsEvent.SUBSCRIPTION_MANUAL_PAYMENT_DECIDED, {
      catalog_id: catalogId.toHexString(),
      decision: 'REJECTED',
      admin_id_hash: hashIdentifier(admin.userId.toHexString()),
      same_actor: String(row.initiatedBy.userId) === String(admin.userId),
    });
    // The owner was told this payment was recorded; they are owed the other
    // half. `input.note` is NOT passed on — it is written for us, about a
    // payment we could not find, and it is not the restaurant's to read.
    // The CATALOG_DELETED auto-reject above deliberately never reaches here:
    // there is no catalog left to notify anybody about.
    await notifyManualPaymentRejected({
      catalogId,
      ownerUserId: rejected.userId,
      paymentRecordId: rejected._id as Types.ObjectId,
      amountPaise: rejected.amountPaise,
      method: rejected.method ?? 'CASH',
    });
    return { outcome: 'REJECTED', record: toManualPaymentDto(rejected) };
  }

  const quote = row.quote!;
  if (row.amountPaise !== quote.totalPaise) {
    const explained =
      input.override === true && (input.note?.length ?? 0) >= OVERRIDE_NOTE_MIN_CHARS;
    if (!explained) {
      return {
        outcome: 'AMOUNT_MISMATCH',
        quotedPaise: quote.totalPaise,
        amountPaise: row.amountPaise,
      };
    }
  }

  const verified = await transition(row._id as Types.ObjectId, 'VERIFIED', admin, input.note, now);
  if (!verified) return { outcome: 'ALREADY_DECIDED' };

  // Only on THAT transition (AC-6.3): the conditional update above is what
  // makes a double VERIFY apply one period.
  const applied = await applyPaidPeriod({
    catalogId,
    ownerUserId: row.userId,
    planId: quote.planId,
    interval: quote.interval,
    source: 'MANUAL',
    paidAt: now,
    planSnapshot: quote.planSnapshot,
    standeeIncluded: quote.planSnapshot.includedStandeeCount,
    amountPaise: row.amountPaise,
    paymentRecordId: verified._id as Types.ObjectId,
    via: 'ADMIN',
  });

  track(AnalyticsEvent.SUBSCRIPTION_MANUAL_PAYMENT_DECIDED, {
    catalog_id: catalogId.toHexString(),
    decision: 'VERIFIED',
    admin_id_hash: hashIdentifier(admin.userId.toHexString()),
    same_actor: String(row.initiatedBy.userId) === String(admin.userId),
  });
  return { outcome: 'VERIFIED', record: toManualPaymentDto(verified), applied };
}

/** VERIFY or REJECT an existing request on this catalog. */
export async function decideManualPayment(
  catalogId: Types.ObjectId,
  admin: Actor,
  input: VerifyInput | RejectInput,
  now: Date = new Date()
): Promise<DecideManualPaymentResult> {
  const row = await PaymentRecord.findOne({
    _id: new Types.ObjectId(input.paymentRecordId),
    catalogId,
    kind: 'MANUAL',
  }).exec();
  if (!row) return { outcome: 'NOT_FOUND' };
  return decideOnRow(row, admin, input, now);
}

/**
 * The admin took the money themselves: one call, both halves, both actors
 * the same person and both stored (AC-6.4). Never short-circuits on an
 * existing pending request — that one is the rep's and stays theirs.
 */
export async function createAndVerifyManualPayment(
  catalogId: Types.ObjectId,
  ownerUserId: Types.ObjectId,
  admin: Actor,
  input: ManualPaymentRequestInput & { override?: boolean },
  now: Date = new Date()
): Promise<DecideManualPaymentResult> {
  if (!(await catalogIsLive(catalogId))) return { outcome: 'CATALOG_DELETED' };
  // Checked BEFORE the insert, so a refused "Start plan" leaves no row behind.
  const conflict = await referenceConflict(catalogId, input.reference);
  if (conflict) return conflict;
  const { override, ...request } = input;
  const row = await insertManualRow(catalogId, ownerUserId, admin, request);
  if (row === 'COLLECTOR_NOT_FOUND') return { outcome: 'COLLECTOR_NOT_FOUND' };
  return decideOnRow(
    row,
    admin,
    { action: 'VERIFY', paymentRecordId: String(row._id), note: input.note, override },
    now
  );
}

/**
 * `DELETE /catalog` calls this beside `cancelOnCatalogDelete` (E37): every
 * request still awaiting verification is REJECTED with the reason, so an
 * admin a week later cannot activate a catalog that no longer exists. No
 * `verifiedBy` — nobody decided; the delete did.
 */
export async function rejectPendingOnCatalogDelete(
  catalogId: Types.ObjectId,
  now: Date = new Date()
): Promise<number> {
  const result = await PaymentRecord.updateMany(
    { catalogId, kind: 'MANUAL', verificationStatus: 'PENDING_VERIFICATION' },
    { $set: { verificationStatus: 'REJECTED', verifiedAt: now, note: 'CATALOG_DELETED' } }
  ).exec();
  return result.modifiedCount;
}

// ── The queue (admin) ───────────────────────────────────────────────────────

export interface ManualPaymentQueueItem extends ManualPaymentDto {
  /** De-slugged for display; the opaque id is what the client navigates with. */
  catalogName: string;
}

/** Newest first. Catalog names joined in one query; no owner contact anywhere. */
export async function listManualPayments(
  status: VerificationStatus,
  limit: number
): Promise<ManualPaymentQueueItem[]> {
  const rows = await PaymentRecord.find({ kind: 'MANUAL', verificationStatus: status })
    .sort({ createdAt: -1, _id: -1 })
    .limit(limit)
    .lean<IPaymentRecord[]>()
    .exec();
  if (rows.length === 0) return [];

  const catalogs = await Catalog.find({ _id: { $in: rows.map((r) => r.catalogId) } })
    .select({ name: 1 })
    .lean<{ _id: Types.ObjectId; name: string }[]>()
    .exec();
  const names = new Map(catalogs.map((c) => [String(c._id), toDisplayName(c.name)]));

  return rows.map((row) => ({
    ...toManualPaymentDto(row),
    catalogName: names.get(String(row.catalogId)) ?? '',
  }));
}
