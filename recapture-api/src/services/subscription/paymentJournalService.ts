// src/services/subscription/paymentJournalService.ts
//
// The admin's PAYMENT JOURNAL: every online payment attempt — one entry per
// Razorpay order — with the pipeline it went through spelled out step by step:
//
//   STARTED  → someone pressed Pay and we minted an order (CHECKOUT_CREATED)
//   PROVIDER → Razorpay captured the money (the PAID row's existence)
//   RECORDED → it landed on our ledger, and by which path (`recordedVia`)
//   APPLIED  → the activation primitive ran (`appliedAt`, no refusal `note`)
//   CATALOG  → the subscription row actually shows it
//
// The last step is a CHECK, not a flag anyone sets: `applyRecordedPayment`
// hands the same `now` to the activation primitive (as `paidAt` =
// `periodStart`) and to the `appliedAt` stamp, so "this payment set the current period" is an
// exact equality between two stored dates. A row whose `periodStart` is EARLIER
// than the payment's apply time is money that never reached the catalog —
// whatever the reason — and that is the case the admin's fix button exists for.
//
// Two fixes, so an admin never has to leave the app:
//   • `syncPaymentWithProvider` asks Razorpay about ONE order now and runs the
//     exact record/apply the webhook would have. No judgement, idempotent,
//     safe to press twice (the webhook's own idempotency key decides).
//   • `forceApplyPayment` applies a payment the machine refused (a flag) or
//     that never reached the subscription row, with a written reason. The one
//     human override, claimed exactly once on the PAID row.
//
// Nothing here writes a period: both fixes call the webhook service's own
// functions (the override is `applyPaymentByAdmin`, which lives there), so
// AGENTS.md's "one activation primitive, called from two services" holds.
//
// PII: owners and actors are the list-safe `AdminOwnerSummary` (a name, no
// contact). The raw contact stays behind `GET /admin/users/:id`.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { PaymentRecord, type IPaymentRecord } from '@/models/PaymentRecord';
import {
  REFUSAL_NOTES,
  type Actor,
  type BillingInterval,
  type PaymentVia,
  type PlanCatalog,
  type PlanId,
  type RefusalNote,
  type SubscriptionStatus,
} from '@/models/types/subscription.types';
import type { PaymentAdminResolution, PaymentQuote } from '@/models/PaymentRecord';
import { quoteFor } from '@/services/subscription/checkoutService';
import { getPlanCatalog } from '@/services/subscription/planCatalogService';
import { getRazorpayClient, isRazorpayConfigured } from '@/providers/razorpay';
import { summarizeOwners, type AdminOwnerSummary } from '@/services/adminUsersService';
import { HALF_APPLIED_AFTER_MS } from '@/services/subscription/reconcileService';
import {
  applyPaymentByAdmin,
  applyRecordedPayment,
  recordOnlinePayment,
  type OnlinePaymentOutcome,
} from '@/services/subscription/webhookService';
import type { PaymentJournalFilter } from '@/validation/subscriptionSchemas';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { toDisplayName } from '@/utils/catalogNames';
import { decodeCursor, encodeCursor } from '@/utils/cursor';
import { hashIdentifier } from '@/utils/otp';
import { consumeRateWindow } from '@/utils/rateLimit';

const DAY_MS = 86_400_000;

/** The refusal notes `applyRecordedPayment` writes — "recorded, not activated". */
export const FLAGGED_NOTES = REFUSAL_NOTES;
type FlaggedNote = RefusalNote;

function isFlagged(note: string | null | undefined): note is FlaggedNote {
  return typeof note === 'string' && (FLAGGED_NOTES as readonly string[]).includes(note);
}

/** Provider checks per admin per window — each press is two Razorpay calls. */
const SYNC_MAX_PER_WINDOW = 30;
const SYNC_WINDOW_SECONDS = 300;

// ── The DTO ─────────────────────────────────────────────────────────────────

export type PaymentAttemptStage =
  /** The order is open and nothing is paid yet — the owner may be paying now. */
  | 'IN_PROGRESS'
  /** The order expired with no payment on our ledger. */
  | 'NOT_COMPLETED'
  /** Money recorded, the plan not applied yet (the apply step died or is running). */
  | 'PAID_NOT_APPLIED'
  /** Recorded, and refused by a rule — `outcomeNote` says which. */
  | 'FLAGGED'
  /** Applied, but the subscription row does not show it. */
  | 'NOT_REFLECTED'
  /** Applied and reflected (or since replaced by a later period). */
  | 'COMPLETED'
  /** An admin applied it by hand. */
  | 'RESOLVED'
  | 'REFUNDED';

const ATTENTION_STAGES: readonly PaymentAttemptStage[] = [
  'PAID_NOT_APPLIED',
  'FLAGGED',
  'NOT_REFLECTED',
];

export type JournalStepKey = 'STARTED' | 'PROVIDER' | 'RECORDED' | 'APPLIED' | 'CATALOG';
export type JournalStepState = 'DONE' | 'WAITING' | 'FAILED' | 'UNKNOWN' | 'SKIPPED';

export interface JournalStep {
  key: JournalStepKey;
  state: JournalStepState;
  /** ISO, when the step happened; null for a step that has not. */
  at: string | null;
  /** One sentence for the admin. Ids and amounts only — no contact. */
  detail: string;
}

/** Who did something, list-safe: an id, a role, and a name when the account has one. */
export interface JournalActor {
  userId: string;
  role: Actor['role'];
  displayName: string | null;
}

export type CatalogReflection = 'CURRENT' | 'SUPERSEDED' | 'NOT_REFLECTED';

export interface PaymentAttemptDto {
  orderId: string;
  catalog: { id: string; name: string; deleted: boolean };
  /** The catalog's owner — the restaurant that pays. Null when the account is gone. */
  owner: AdminOwnerSummary | null;
  /** Who pressed Pay. Null only for an order that never reached our ledger (E3). */
  initiatedBy: JournalActor | null;
  planId: PlanId | null;
  planName: string | null;
  interval: BillingInterval | null;
  /** What the order was for, in paise. */
  quotedPaise: number | null;
  /** What Razorpay captured, in paise; null until a payment is recorded. */
  paidPaise: number | null;
  providerPaymentId: string | null;
  /** ISO: when the order was opened (or the payment recorded, for an E3 order). */
  startedAt: string;
  expiresAt: string | null;
  /** The PAID ledger row, once there is one. */
  paymentRecordId: string | null;
  recordedAt: string | null;
  recordedVia: PaymentVia | null;
  appliedAt: string | null;
  /** The refusal note on the PAID row (AMOUNT_MISMATCH / ORPHAN_PAYMENT / DUPLICATE_SUSPECTED). */
  outcomeNote: string | null;
  resolution: { at: string; note: string; by: JournalActor } | null;
  refunded: boolean;
  catalogReflects: CatalogReflection | null;
  /** The catalog's subscription row as it stands now; null when it has none. */
  subscription: {
    status: SubscriptionStatus;
    planId: PlanId | null;
    periodStart: string;
    periodEnd: string;
  } | null;
  stage: PaymentAttemptStage;
  needsAttention: boolean;
  steps: JournalStep[];
  /** "Check with Razorpay" can change something here. */
  canSync: boolean;
  /** "Apply to catalog" is allowed — see {@link forceApplyPayment}. */
  canForceApply: boolean;
  /**
   * Edge case #5: what the order was priced at vs what the same plan and
   * interval cost TODAY; null when they agree. A ₹3 testing-price order found
   * after go-live is the case this exists for — recording or applying it then
   * needs `acceptQuotedPrice`.
   */
  priceChange: { quotedPaise: number; currentPaise: number } | null;
  /**
   * Edge case #3: days left on the running period that "Apply to catalog"
   * would throw away (the new period starts today). 0 when nothing is running.
   */
  daysForfeitedOnApply: number;
  /** A captured payment with no refund yet — Refund is possible from here. */
  canRefund: boolean;
  /** Refunding needs the override and 30 characters (a flagged duplicate does not). */
  refundNeedsOverride: boolean;
}

// ── Formatting (admin-facing sentences) ─────────────────────────────────────

const RUPEES = new Intl.NumberFormat('en-IN', { maximumFractionDigits: 2 });

/** "₹1,199" / "₹1,199.5" — the journal's one money formatter. */
export function formatPaise(paise: number): string {
  return `₹${RUPEES.format(paise / 100)}`;
}

/**
 * The zone the journal's SENTENCES name dates in. The business and its admins
 * are in India; a UTC date read at 02:00 IST is "yesterday" (edge case #10).
 * Exact times still come from each step's `at`, which the app shows in the
 * device's own zone.
 */
const JOURNAL_TIME_ZONE = 'Asia/Kolkata';
// Numeric parts, named here: ICU's short month names vary by version ("Sep" /
// "Sept"), and a sentence must read the same on every server.
const DAY_PARTS = new Intl.DateTimeFormat('en-US', {
  timeZone: JOURNAL_TIME_ZONE,
  day: 'numeric',
  month: 'numeric',
  year: 'numeric',
});
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** "24 Sep 2026", in India time. */
export function day(d: Date): string {
  const parts = Object.fromEntries(
    DAY_PARTS.formatToParts(d).map((p) => [p.type, p.value])
  ) as Record<string, string>;
  return `${parts.day} ${MONTHS[Number(parts.month) - 1]} ${parts.year}`;
}

function actorLabel(actor: JournalActor | null): string {
  if (!actor) return 'an unknown account';
  const who = actor.displayName ?? `account …${actor.userId.slice(-6)}`;
  return `${who} (${actor.role})`;
}

const VIA_LABEL: Record<PaymentVia, string> = {
  WEBHOOK: "by Razorpay's webhook",
  CLIENT: 'by the app right after checkout (signature verified with Razorpay)',
  RECONCILE: "by the reconciler's check with Razorpay",
  ADMIN: "by an admin's check with Razorpay",
};

// ── Hydration ───────────────────────────────────────────────────────────────

type LeanRow = IPaymentRecord & { _id: Types.ObjectId };

type SubRow = { status: SubscriptionStatus; planId?: PlanId; periodStart: Date; periodEnd: Date };

interface HydrationContext {
  checkouts: Map<string, LeanRow>;
  paids: Map<string, LeanRow>;
  refunded: Set<string>;
  catalogs: Map<string, { name: string; userId: Types.ObjectId; deletedAt?: Date | null }>;
  subs: Map<string, SubRow>;
  people: Map<string, AdminOwnerSummary>;
  /** Today's prices — for the #5 price-change check. */
  plans: PlanCatalog;
}

/** The order's price vs today's for the same plan and interval; null when equal. */
function priceChangeOf(
  quote: PaymentQuote | null,
  plans: PlanCatalog
): { quotedPaise: number; currentPaise: number } | null {
  if (!quote || !plans.plans[quote.planId]) return null;
  const currentPaise = quoteFor(plans, quote.planId, quote.interval).totalPaise;
  return currentPaise === quote.totalPaise ? null : { quotedPaise: quote.totalPaise, currentPaise };
}

/** Statuses whose period an early apply cuts short. */
const RUNNING: readonly SubscriptionStatus[] = ['ACTIVE', 'TRIAL', 'COMPED', 'GRACE'];

/** Whole days left on a running period, rounded up; 0 when nothing is running. */
function daysLeftOnRunning(sub: SubRow | undefined, now: Date): number {
  if (!sub || !RUNNING.includes(sub.status)) return 0;
  const ms = sub.periodEnd.getTime() - now.getTime();
  return ms > 0 ? Math.ceil(ms / DAY_MS) : 0;
}

function reflectionOf(
  sub: SubRow | undefined,
  appliedAt: Date
): CatalogReflection {
  if (!sub) return 'NOT_REFLECTED';
  const start = sub.periodStart.getTime();
  const at = appliedAt.getTime();
  if (start === at) return 'CURRENT';
  return start > at ? 'SUPERSEDED' : 'NOT_REFLECTED';
}

function journalActor(
  actor: Actor | undefined,
  people: Map<string, AdminOwnerSummary>
): JournalActor | null {
  if (!actor) return null;
  const userId = String(actor.userId);
  return { userId, role: actor.role, displayName: people.get(userId)?.displayName ?? null };
}

async function hydrate(orderIds: readonly string[]): Promise<HydrationContext> {
  const rows = orderIds.length
    ? await PaymentRecord.find({
        providerOrderId: { $in: [...orderIds] },
        kind: { $in: ['CHECKOUT_CREATED', 'PAID'] },
      })
        .lean<LeanRow[]>()
        .exec()
    : [];
  const checkouts = new Map<string, LeanRow>();
  const paids = new Map<string, LeanRow>();
  for (const row of rows) {
    (row.kind === 'PAID' ? paids : checkouts).set(row.providerOrderId!, row);
  }

  const paidIds = [...paids.values()].map((r) => r._id);
  const catalogIds = [...new Set(rows.map((r) => String(r.catalogId)))].map(
    (id) => new Types.ObjectId(id)
  );
  const [refunds, catalogs, subs, plans] = await Promise.all([
    paidIds.length
      ? PaymentRecord.find({ kind: 'REFUNDED', refundsPaymentId: { $in: paidIds } })
          .select({ refundsPaymentId: 1 })
          .lean<{ refundsPaymentId: Types.ObjectId }[]>()
          .exec()
      : Promise.resolve([]),
    catalogIds.length
      ? Catalog.find({ _id: { $in: catalogIds } })
          .select({ name: 1, userId: 1, deletedAt: 1 })
          .lean<{ _id: Types.ObjectId; name: string; userId: Types.ObjectId; deletedAt?: Date }[]>()
          .exec()
      : Promise.resolve([]),
    catalogIds.length
      ? CatalogSubscription.find({ catalogId: { $in: catalogIds } })
          .select({ catalogId: 1, status: 1, planId: 1, periodStart: 1, periodEnd: 1 })
          .lean<
            {
              catalogId: Types.ObjectId;
              status: SubscriptionStatus;
              planId?: PlanId;
              periodStart: Date;
              periodEnd: Date;
            }[]
          >()
          .exec()
      : Promise.resolve([]),
    getPlanCatalog(),
  ]);

  const userIds: string[] = [];
  for (const c of catalogs) userIds.push(String(c.userId));
  for (const r of rows) {
    userIds.push(String(r.userId), String(r.initiatedBy.userId));
    if (r.adminResolution) userIds.push(String(r.adminResolution.by.userId));
  }

  return {
    checkouts,
    paids,
    refunded: new Set(refunds.map((r) => String(r.refundsPaymentId))),
    catalogs: new Map(catalogs.map((c) => [String(c._id), c])),
    subs: new Map(subs.map((s) => [String(s.catalogId), s])),
    people: await summarizeOwners(userIds),
    plans,
  };
}

// ── Building one entry ──────────────────────────────────────────────────────

function buildAttempt(orderId: string, ctx: HydrationContext, now: Date): PaymentAttemptDto | null {
  const checkout = ctx.checkouts.get(orderId);
  const paid = ctx.paids.get(orderId);
  const anchor = checkout ?? paid;
  if (!anchor) return null;

  const quote = checkout?.quote ?? paid?.quote ?? null;
  const planName = quote?.planSnapshot.displayName ?? null;
  const intervalWord = quote ? quote.interval.toLowerCase() : null;
  const catalogId = String(anchor.catalogId);
  const catalog = ctx.catalogs.get(catalogId);
  const deleted = !catalog || Boolean(catalog.deletedAt);
  const ownerId = catalog ? String(catalog.userId) : String(anchor.userId);
  const sub = ctx.subs.get(catalogId);
  const refunded = paid ? ctx.refunded.has(String(paid._id)) : false;
  const resolution = paid?.adminResolution ?? null;
  const flagged = paid ? isFlagged(paid.note) : false;
  const initiatedBy = journalActor(checkout?.initiatedBy, ctx.people);

  // The time the period was applied with — the resolution's when an admin
  // applied it, else the machine's. Only meaningful once it WAS applied.
  const appliedWith = resolution?.at ?? (paid?.appliedAt && !flagged ? paid.appliedAt : null);
  const reflects = appliedWith ? reflectionOf(sub, appliedWith) : null;

  let stage: PaymentAttemptStage;
  if (refunded) stage = 'REFUNDED';
  else if (!paid) stage = checkout?.expiresAt && checkout.expiresAt > now ? 'IN_PROGRESS' : 'NOT_COMPLETED';
  else if (resolution) stage = reflects === 'NOT_REFLECTED' ? 'NOT_REFLECTED' : 'RESOLVED';
  else if (!paid.appliedAt) stage = 'PAID_NOT_APPLIED';
  else if (flagged) stage = 'FLAGGED';
  else stage = reflects === 'NOT_REFLECTED' ? 'NOT_REFLECTED' : 'COMPLETED';

  const steps: JournalStep[] = [];

  // 1. Started.
  steps.push(
    checkout
      ? {
          key: 'STARTED',
          state: 'DONE',
          at: checkout.createdAt.toISOString(),
          detail:
            `Order ${orderId} for ${formatPaise(checkout.amountPaise)}` +
            (planName ? ` — ${planName}, ${intervalWord}` : '') +
            `. Started by ${actorLabel(initiatedBy)}.`,
        }
      : {
          key: 'STARTED',
          state: 'DONE',
          at: null,
          detail:
            `Order ${orderId} is not on our ledger — our insert failed after Razorpay created ` +
            "it, so the plan was rebuilt from the order's notes (E3).",
        }
  );

  // 2. Razorpay.
  if (paid) {
    const mismatch = quote && paid.amountPaise !== quote.totalPaise;
    steps.push({
      key: 'PROVIDER',
      state: 'DONE',
      at: paid.createdAt.toISOString(),
      detail:
        `Razorpay captured ${formatPaise(paid.amountPaise)} as payment ${paid.providerPaymentId}` +
        (mismatch ? ` — the order was for ${formatPaise(quote.totalPaise)}.` : '.'),
    });
  } else if (stage === 'IN_PROGRESS') {
    steps.push({
      key: 'PROVIDER',
      state: 'WAITING',
      at: null,
      detail:
        'No payment yet. The owner may still be paying; the order stays payable until ' +
        `${day(checkout!.expiresAt!)}.`,
    });
  } else {
    steps.push({
      key: 'PROVIDER',
      state: 'UNKNOWN',
      at: null,
      detail:
        'No payment reached our ledger before the order expired' +
        (checkout?.expiresAt ? ` on ${day(checkout.expiresAt)}` : '') +
        '. If the owner says they paid, press "Check with Razorpay".',
    });
  }

  // 3. Recorded.
  steps.push(
    paid
      ? {
          key: 'RECORDED',
          state: 'DONE',
          at: paid.createdAt.toISOString(),
          detail: paid.recordedVia
            ? `Recorded ${VIA_LABEL[paid.recordedVia]}.`
            : 'Recorded (the path was not tracked when this payment arrived).',
        }
      : {
          key: 'RECORDED',
          state: stage === 'IN_PROGRESS' ? 'WAITING' : 'SKIPPED',
          at: null,
          detail: 'Nothing recorded — there is no payment to record.',
        }
  );

  // 4. Applied.
  if (!paid) {
    steps.push({
      key: 'APPLIED',
      state: stage === 'IN_PROGRESS' ? 'WAITING' : 'SKIPPED',
      at: null,
      detail: 'No plan applied — nothing was paid.',
    });
  } else if (resolution) {
    const by = journalActor(resolution.by, ctx.people);
    steps.push({
      key: 'APPLIED',
      state: 'DONE',
      at: resolution.at.toISOString(),
      detail:
        `Applied by hand by ${actorLabel(by)}` +
        (paid.note ? ` over the ${paid.note} flag` : '') +
        `: “${resolution.note}”`,
    });
  } else if (!paid.appliedAt) {
    const stuck = now.getTime() - paid.createdAt.getTime() > HALF_APPLIED_AFTER_MS;
    steps.push({
      key: 'APPLIED',
      state: stuck ? 'FAILED' : 'WAITING',
      at: null,
      detail: stuck
        ? 'Recorded but never applied — the apply step did not finish. "Check with Razorpay" ' +
          'finishes it now (the reconciler also retries every few minutes).'
        : 'Applying…',
    });
  } else if (flagged) {
    steps.push({
      key: 'APPLIED',
      state: 'FAILED',
      at: paid.appliedAt.toISOString(),
      detail: flaggedDetail(paid.note as FlaggedNote, paid, deleted),
    });
  } else {
    const end = new Date(
      paid.appliedAt.getTime() + (quote?.interval === 'YEARLY' ? 365 : 30) * DAY_MS
    );
    steps.push({
      key: 'APPLIED',
      state: 'DONE',
      at: paid.appliedAt.toISOString(),
      detail:
        `${planName ?? 'The plan'}` +
        (intervalWord ? `, ${intervalWord},` : '') +
        ` applied: ${day(paid.appliedAt)} → ${day(end)}.`,
    });
  }

  // 5. The catalog.
  steps.push(catalogStep(stage, reflects, sub, refunded, deleted));

  // Allowed where the machine did not make the plan real: a flag nobody has
  // decided, or a period the subscription row does not show. The second case
  // includes an admin's OWN earlier apply that never landed (edge case #1: the
  // process died between the claim and the apply) — otherwise that payment
  // would be stuck with no button.
  const canForceApply =
    Boolean(paid?.appliedAt) &&
    !refunded &&
    !deleted &&
    quote !== null &&
    (resolution ? reflects === 'NOT_REFLECTED' : flagged || reflects === 'NOT_REFLECTED');

  return {
    orderId,
    catalog: { id: catalogId, name: catalog ? toDisplayName(catalog.name) : '', deleted },
    owner: ctx.people.get(ownerId) ?? null,
    initiatedBy,
    planId: quote?.planId ?? null,
    planName,
    interval: quote?.interval ?? null,
    quotedPaise: quote?.totalPaise ?? checkout?.amountPaise ?? null,
    paidPaise: paid?.amountPaise ?? null,
    providerPaymentId: paid?.providerPaymentId ?? null,
    startedAt: anchor.createdAt.toISOString(),
    expiresAt: checkout?.expiresAt?.toISOString() ?? null,
    paymentRecordId: paid ? String(paid._id) : null,
    recordedAt: paid?.createdAt.toISOString() ?? null,
    recordedVia: paid?.recordedVia ?? null,
    appliedAt: paid?.appliedAt?.toISOString() ?? null,
    outcomeNote: paid?.note ?? null,
    resolution: resolution
      ? {
          at: resolution.at.toISOString(),
          note: resolution.note,
          by: journalActor(resolution.by, ctx.people)!,
        }
      : null,
    refunded,
    catalogReflects: reflects,
    subscription: sub
      ? {
          status: sub.status,
          planId: sub.planId ?? null,
          periodStart: sub.periodStart.toISOString(),
          periodEnd: sub.periodEnd.toISOString(),
        }
      : null,
    stage,
    needsAttention: ATTENTION_STAGES.includes(stage),
    steps,
    canSync: stage === 'IN_PROGRESS' || stage === 'NOT_COMPLETED' || stage === 'PAID_NOT_APPLIED',
    canForceApply,
    priceChange: priceChangeOf(quote, ctx.plans),
    daysForfeitedOnApply: canForceApply ? daysLeftOnRunning(sub, now) : 0,
    canRefund: Boolean(paid?.providerPaymentId) && !refunded,
    refundNeedsOverride: paid?.note !== 'DUPLICATE_SUSPECTED',
  };
}

function flaggedDetail(note: FlaggedNote, paid: LeanRow, deleted: boolean): string {
  switch (note) {
    case 'AMOUNT_MISMATCH':
      return (
        `Not applied: ${formatPaise(paid.amountPaise)} was captured against an order for ` +
        `${paid.quote ? formatPaise(paid.quote.totalPaise) : 'an unknown amount'}. ` +
        'Refund it, or apply the plan anyway.'
      );
    case 'ORPHAN_PAYMENT':
      return deleted
        ? 'Not applied: the catalog was deleted before the money arrived. Refund it.'
        : 'Not applied: the catalog was deleted when the money arrived, and is live again. ' +
            'Apply the plan, or refund it.';
    case 'DUPLICATE_SUSPECTED':
      return (
        'Not applied: the period was already paid for when this arrived — likely a double ' +
        'payment. Refund it, or apply it as a new period.'
      );
  }
}

function catalogStep(
  stage: PaymentAttemptStage,
  reflects: CatalogReflection | null,
  sub: SubRow | undefined,
  refunded: boolean,
  deleted: boolean
): JournalStep {
  const now = sub
    ? `${sub.status}${sub.planId ? ` on ${sub.planId}` : ''} until ${day(sub.periodEnd)}`
    : 'no subscription';
  if (refunded) {
    // Edge case #7: a refund never ends a period (AC-5.4). When this payment
    // DID buy the current period, say so — the restaurant keeps a plan it no
    // longer paid for until the period runs out.
    return reflects === 'CURRENT'
      ? {
          key: 'CATALOG',
          state: 'FAILED',
          at: null,
          detail:
            `Refunded, but the period it bought is still running: ${now}. A refund never ` +
            'ends a period; the restaurant keeps the plan until then.',
        }
      : { key: 'CATALOG', state: 'SKIPPED', at: null, detail: `Refunded. The catalog is ${now}.` };
  }
  if (deleted) {
    return { key: 'CATALOG', state: 'SKIPPED', at: null, detail: 'The catalog has been deleted.' };
  }
  switch (reflects) {
    case 'CURRENT':
      return {
        key: 'CATALOG',
        state: 'DONE',
        at: sub!.periodStart.toISOString(),
        detail: `The catalog shows this payment: ${now}.`,
      };
    case 'SUPERSEDED':
      return {
        key: 'CATALOG',
        state: 'DONE',
        at: sub!.periodStart.toISOString(),
        detail: `Applied, and since replaced by a later period — the catalog is ${now}.`,
      };
    case 'NOT_REFLECTED':
      return {
        key: 'CATALOG',
        state: 'FAILED',
        at: null,
        detail:
          `The catalog does NOT show this payment — it is ${now}` +
          (sub ? ` (period started ${day(sub.periodStart)})` : '') +
          '. Use "Apply to catalog".',
      };
    case null:
      return {
        key: 'CATALOG',
        state: stage === 'IN_PROGRESS' || stage === 'PAID_NOT_APPLIED' ? 'WAITING' : 'SKIPPED',
        at: null,
        detail: `Not changed by this order — the catalog is ${now}.`,
      };
  }
}

async function attemptsFor(orderIds: readonly string[], now: Date): Promise<PaymentAttemptDto[]> {
  const ctx = await hydrate(orderIds);
  return orderIds
    .map((id) => buildAttempt(id, ctx, now))
    .filter((a): a is PaymentAttemptDto => a !== null);
}

// ── Reads ───────────────────────────────────────────────────────────────────

/** One order's journal entry, or null when no order or payment carries that id. */
export async function getPaymentAttempt(
  orderId: string,
  now: Date = new Date()
): Promise<PaymentAttemptDto | null> {
  const [attempt] = await attemptsFor([orderId], now);
  return attempt ?? null;
}

/** A catalog's last few attempts, newest first — for the per-catalog panel. */
export async function listAttemptsForCatalog(
  catalogId: Types.ObjectId,
  limit = 20,
  now: Date = new Date()
): Promise<PaymentAttemptDto[]> {
  const rows = await PaymentRecord.find({
    catalogId,
    kind: { $in: ['CHECKOUT_CREATED', 'PAID'] },
    providerOrderId: { $type: 'string' },
  })
    .sort({ createdAt: -1, _id: -1 })
    .limit(limit * 2)
    .select({ providerOrderId: 1 })
    .lean<{ providerOrderId: string }[]>()
    .exec();
  const orderIds = [...new Set(rows.map((r) => r.providerOrderId))].slice(0, limit);
  return attemptsFor(orderIds, now);
}

export type ListPaymentAttemptsResult =
  | { outcome: 'OK'; items: PaymentAttemptDto[]; nextCursor: string | null }
  | { outcome: 'INVALID_CURSOR' };

/**
 * The journal, newest first, keyset-paginated on `(createdAt, _id)` of the
 * row each filter is anchored on — orders for ALL / NOT_COMPLETED, payments
 * for SUCCEEDED / ATTENTION. ATTENTION is decided in the database with the
 * same three rules the stage uses, so a page is never short of rows that
 * belong on it.
 */
export async function listPaymentAttempts(
  filter: PaymentJournalFilter,
  cursor: string | undefined,
  limit: number,
  now: Date = new Date()
): Promise<ListPaymentAttemptsResult> {
  const decoded = cursor ? decodeCursor(cursor) : null;
  if (cursor && !decoded) return { outcome: 'INVALID_CURSOR' };

  const anchorKind = filter === 'ALL' || filter === 'NOT_COMPLETED' ? 'CHECKOUT_CREATED' : 'PAID';
  const match: Record<string, unknown> = {
    kind: anchorKind,
    providerOrderId: { $type: 'string' },
  };
  if (decoded) {
    match.$or = [
      { createdAt: { $lt: decoded.updatedAt } },
      { createdAt: decoded.updatedAt, _id: { $lt: new Types.ObjectId(decoded.id) } },
    ];
  }

  const payments = PaymentRecord.collection.name;
  const subscriptions = CatalogSubscription.collection.name;
  const pipeline: Record<string, unknown>[] = [
    { $match: match },
    { $sort: { createdAt: -1, _id: -1 } },
  ];

  if (filter === 'NOT_COMPLETED') {
    pipeline.push(
      {
        $lookup: {
          from: payments,
          let: { oid: '$providerOrderId' },
          pipeline: [
            {
              $match: {
                $expr: {
                  $and: [{ $eq: ['$kind', 'PAID'] }, { $eq: ['$providerOrderId', '$$oid'] }],
                },
              },
            },
            { $limit: 1 },
            { $project: { _id: 1 } },
          ],
          as: 'paid',
        },
      },
      { $match: { paid: { $size: 0 } } }
    );
  }

  if (filter === 'ATTENTION') {
    pipeline.push(
      {
        $lookup: {
          from: payments,
          let: { pid: '$_id' },
          pipeline: [
            {
              $match: {
                $expr: {
                  $and: [{ $eq: ['$kind', 'REFUNDED'] }, { $eq: ['$refundsPaymentId', '$$pid'] }],
                },
              },
            },
            { $limit: 1 },
            { $project: { _id: 1 } },
          ],
          as: 'refunds',
        },
      },
      { $match: { refunds: { $size: 0 } } },
      {
        $lookup: {
          from: subscriptions,
          localField: 'catalogId',
          foreignField: 'catalogId',
          as: 'sub',
        },
      },
      {
        $match: {
          $or: [
            // Recorded, never applied.
            { appliedAt: null },
            // Refused by a rule, and nobody has decided it yet.
            { note: { $in: [...FLAGGED_NOTES] }, adminResolution: null },
            // Applied (by the machine or by hand) and the row does not show it.
            {
              $expr: {
                $and: [
                  { $ne: [{ $ifNull: ['$appliedAt', null] }, null] },
                  {
                    $or: [
                      { $not: [{ $in: [{ $ifNull: ['$note', ''] }, [...FLAGGED_NOTES]] }] },
                      { $ne: [{ $ifNull: ['$adminResolution', null] }, null] },
                    ],
                  },
                  {
                    $or: [
                      { $eq: [{ $size: '$sub' }, 0] },
                      {
                        $lt: [
                          { $arrayElemAt: ['$sub.periodStart', 0] },
                          { $ifNull: ['$adminResolution.at', '$appliedAt'] },
                        ],
                      },
                    ],
                  },
                ],
              },
            },
          ],
        },
      }
    );
  }

  pipeline.push(
    { $limit: limit + 1 },
    { $project: { _id: 1, createdAt: 1, providerOrderId: 1 } }
  );

  const rows = await PaymentRecord.aggregate<{
    _id: Types.ObjectId;
    createdAt: Date;
    providerOrderId: string;
  }>(pipeline as never[]).exec();
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  const nextCursor =
    rows.length > limit && last ? encodeCursor(last.createdAt, String(last._id)) : null;

  return {
    outcome: 'OK',
    items: await attemptsFor(
      page.map((r) => r.providerOrderId),
      now
    ),
    nextCursor,
  };
}

// ── Shared guards for the fixes ─────────────────────────────────────────────

/** What Razorpay says about one order, at the moment the admin asked. */
export interface ProviderSnapshot {
  orderStatus: 'created' | 'attempted' | 'paid';
  orderAmountPaise: number;
  payments: Array<{ id: string; status: string; amountPaise: number }>;
  checkedAt: string;
}

/** Options every fix that records or applies money accepts. */
export interface FixOptions {
  /**
   * Edge case #5: the admin has seen that the order's price differs from
   * today's price for the same plan (a ₹3 testing-price order after go-live,
   * or an order from before a re-price) and still wants the plan applied for
   * what was paid.
   */
  acceptQuotedPrice?: boolean;
}

/** The refusal every fix answers when the price moved and nobody accepted it. */
export type PriceChanged = { outcome: 'PRICE_CHANGED'; quotedPaise: number; currentPaise: number };

async function priceGuard(
  quote: PaymentQuote | null | undefined,
  options: FixOptions
): Promise<PriceChanged | null> {
  if (options.acceptQuotedPrice === true || !quote) return null;
  const change = priceChangeOf(quote, await getPlanCatalog());
  return change ? { outcome: 'PRICE_CHANGED', ...change } : null;
}

async function consumeFixRate(admin: Actor, now: Date) {
  return consumeRateWindow(
    `admin-payment-sync:${admin.userId.toHexString()}`,
    SYNC_MAX_PER_WINDOW,
    SYNC_WINDOW_SECONDS,
    now.getTime()
  );
}

async function providerSnapshot(orderId: string, now: Date): Promise<ProviderSnapshot | null> {
  if (!isRazorpayConfigured()) return null;
  try {
    const client = getRazorpayClient();
    const [order, payments] = await Promise.all([
      client.fetchOrder(orderId),
      client.fetchPaymentsForOrder(orderId),
    ]);
    return {
      orderStatus: order.status,
      orderAmountPaise: order.amount,
      payments: payments.map((p) => ({ id: p.id, status: p.status, amountPaise: p.amount })),
      checkedAt: now.toISOString(),
    };
  } catch (err) {
    console.warn(`[journal] provider check failed for order ${orderId}`, err);
    return null;
  }
}

function logFix(admin: Actor, action: 'SYNC' | 'FORCE_APPLY', catalogId: string, outcome: string) {
  track(AnalyticsEvent.SUBSCRIPTION_ADMIN_PAYMENT_FIXED, {
    catalog_id: catalogId,
    admin_id_hash: hashIdentifier(admin.userId.toHexString()),
    action,
    outcome,
  });
}

// ── Fix 1: check with Razorpay ──────────────────────────────────────────────

export type SyncOutcome =
  /** A payment was recorded and/or its plan applied by this press. */
  | 'APPLIED'
  /** Recorded by this press, and refused by a rule (the entry says which). */
  | 'FLAGGED'
  /** Already recorded and applied — nothing to do. */
  | 'ALREADY_DONE'
  /** Razorpay holds no captured payment for the order. */
  | 'NOT_PAID'
  /** Razorpay holds an AUTHORIZED payment that was never captured — see capture. */
  | 'NOT_CAPTURED';

export type SyncPaymentResult =
  | {
      outcome: 'OK';
      result: SyncOutcome;
      provider: ProviderSnapshot | null;
      /**
       * Edge case #6: the authorized payment "Capture payment" would take —
       * present only when its amount is exactly the order's.
       */
      capturable: { paymentId: string; amountPaise: number } | null;
      attempt: PaymentAttemptDto;
    }
  | PriceChanged
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'RATE_LIMITED'; retryAfter: number }
  /** Razorpay is not configured or did not answer, and the answer was needed. */
  | { outcome: 'UNAVAILABLE' };

function syncOutcomeOf(outcome: OnlinePaymentOutcome): SyncOutcome {
  if (outcome === 'APPLIED') return 'APPLIED';
  if (isFlagged(outcome)) return 'FLAGGED';
  return 'ALREADY_DONE';
}

/**
 * "Check with Razorpay": ask about ONE order now and run what the webhook
 * would have. A recorded-but-unapplied payment is finished locally (no
 * provider answer needed — the row carries everything); an order with no
 * payment on the ledger is recorded if Razorpay has captured one. Every path
 * is the webhook's own idempotent function, so pressing it twice, or a
 * webhook landing in between, converges on one row and one activation.
 *
 * Deliberately NOT a way to activate anything Razorpay does not confirm: an
 * authorized-but-uncaptured payment is reported (with what "Capture" would
 * take), not recorded. And an order whose price no longer matches today's is
 * refused with PRICE_CHANGED until the admin accepts the quoted price (#5).
 */
export async function syncPaymentWithProvider(
  orderId: string,
  admin: Actor,
  options: FixOptions = {},
  now: Date = new Date()
): Promise<SyncPaymentResult> {
  const rate = await consumeFixRate(admin, now);
  if (rate.limited) return { outcome: 'RATE_LIMITED', retryAfter: rate.retryAfter };

  const [checkout, paid] = await Promise.all([
    PaymentRecord.findOne({ kind: 'CHECKOUT_CREATED', providerOrderId: orderId })
      .select({ quote: 1 })
      .lean<{ quote?: PaymentQuote }>()
      .exec(),
    PaymentRecord.findOne({ kind: 'PAID', providerOrderId: orderId }).exec(),
  ]);
  if (!checkout && !paid) return { outcome: 'NOT_FOUND' };

  const provider = await providerSnapshot(orderId, now);
  let result: SyncOutcome;
  let capturable: { paymentId: string; amountPaise: number } | null = null;
  if (paid) {
    if (paid.appliedAt) {
      result = 'ALREADY_DONE';
    } else {
      const refused = await priceGuard(paid.quote, options);
      if (refused) return refused;
      result = syncOutcomeOf(await applyRecordedPayment(paid, 'ADMIN', now));
    }
  } else {
    if (!provider) return { outcome: 'UNAVAILABLE' };
    const captured = provider.payments.find((p) => p.status === 'captured');
    if (captured) {
      const refused = await priceGuard(checkout?.quote, options);
      if (refused) return refused;
      const { outcome } = await recordOnlinePayment({
        orderId,
        paymentId: captured.id,
        amountPaise: captured.amountPaise,
        notes: null,
        via: 'ADMIN',
        now,
      });
      result = syncOutcomeOf(outcome);
    } else {
      const authorized = provider.payments.find((p) => p.status === 'authorized');
      result = authorized ? 'NOT_CAPTURED' : 'NOT_PAID';
      if (authorized && checkout?.quote && authorized.amountPaise === checkout.quote.totalPaise) {
        capturable = { paymentId: authorized.id, amountPaise: authorized.amountPaise };
      }
    }
  }

  const attempt = (await getPaymentAttempt(orderId, now))!;
  logFix(admin, 'SYNC', attempt.catalog.id, result);
  console.log(
    `[journal] admin ${hashIdentifier(admin.userId.toHexString())} sync order=${orderId} ` +
      `result=${result} provider=${provider?.orderStatus ?? 'unavailable'}`
  );
  return { outcome: 'OK', result, provider, capturable, attempt };
}

// ── Fix 1b: capture an authorized payment (edge case #6) ────────────────────

export type CapturePaymentResult =
  | { outcome: 'OK'; result: SyncOutcome; attempt: PaymentAttemptDto }
  | PriceChanged
  | { outcome: 'NOT_FOUND' }
  /** A payment is already recorded on this order — nothing to capture. */
  | { outcome: 'ALREADY_RECORDED' }
  /** Razorpay holds no authorized payment on this order. */
  | { outcome: 'NOTHING_TO_CAPTURE' }
  /** The authorized amount is not the order's — capturing it would be refused anyway. */
  | { outcome: 'CAPTURE_AMOUNT_MISMATCH'; authorizedPaise: number; quotedPaise: number }
  | { outcome: 'RATE_LIMITED'; retryAfter: number }
  | { outcome: 'UNAVAILABLE' };

/**
 * An owner's payment that Razorpay AUTHORIZED but never captured (a capture
 * setting, a timeout) — the money is held, not taken, and Razorpay releases it
 * after about five days. This captures it at Razorpay for exactly the order's
 * amount, then records it through the webhook's own function, so the plan
 * applied is the order's frozen quote like every other path.
 */
export async function capturePaymentForOrder(
  orderId: string,
  admin: Actor,
  options: FixOptions = {},
  now: Date = new Date()
): Promise<CapturePaymentResult> {
  const rate = await consumeFixRate(admin, now);
  if (rate.limited) return { outcome: 'RATE_LIMITED', retryAfter: rate.retryAfter };

  const checkout = await PaymentRecord.findOne({ kind: 'CHECKOUT_CREATED', providerOrderId: orderId })
    .select({ quote: 1 })
    .lean<{ quote?: PaymentQuote }>()
    .exec();
  if (!checkout?.quote) return { outcome: 'NOT_FOUND' };
  if (await PaymentRecord.exists({ kind: 'PAID', providerOrderId: orderId }).exec()) {
    return { outcome: 'ALREADY_RECORDED' };
  }

  const provider = await providerSnapshot(orderId, now);
  if (!provider) return { outcome: 'UNAVAILABLE' };
  const authorized = provider.payments.find((p) => p.status === 'authorized');
  if (!authorized) return { outcome: 'NOTHING_TO_CAPTURE' };
  if (authorized.amountPaise !== checkout.quote.totalPaise) {
    return {
      outcome: 'CAPTURE_AMOUNT_MISMATCH',
      authorizedPaise: authorized.amountPaise,
      quotedPaise: checkout.quote.totalPaise,
    };
  }
  const refused = await priceGuard(checkout.quote, options);
  if (refused) return refused;

  try {
    await getRazorpayClient().capturePayment(authorized.id, authorized.amountPaise);
  } catch (err) {
    console.warn(`[journal] capture failed for payment ${authorized.id}`, err);
    return { outcome: 'UNAVAILABLE' };
  }

  const { outcome } = await recordOnlinePayment({
    orderId,
    paymentId: authorized.id,
    amountPaise: authorized.amountPaise,
    notes: null,
    via: 'ADMIN',
    now,
  });
  const result = syncOutcomeOf(outcome);
  const attempt = (await getPaymentAttempt(orderId, now))!;
  logFix(admin, 'SYNC', attempt.catalog.id, `CAPTURED_${result}`);
  console.log(
    `[journal] admin ${hashIdentifier(admin.userId.toHexString())} capture order=${orderId} ` +
      `payment=${authorized.id} result=${result}`
  );
  return { outcome: 'OK', result, attempt };
}

// ── Fix 2: apply to catalog, by hand ────────────────────────────────────────

export type ForceApplyResult =
  | { outcome: 'APPLIED'; attempt: PaymentAttemptDto }
  | PriceChanged
  /** No PAID row carries that order id — there is no money to apply. */
  | { outcome: 'NOT_FOUND' }
  /** Recorded but not applied yet: "Check with Razorpay" finishes that without an override. */
  | { outcome: 'NOT_APPLIED_YET' }
  | { outcome: 'ALREADY_REFUNDED' }
  | { outcome: 'ALREADY_RESOLVED' }
  | { outcome: 'CATALOG_DELETED' }
  /** The PAID row has no frozen quote, so there is no plan to apply. */
  | { outcome: 'NO_QUOTE' }
  /** Applied cleanly and the catalog shows it (or a later period replaced it). */
  | { outcome: 'NOT_NEEDED' };

/**
 * Apply a recorded payment's plan to its catalog by hand — the one human
 * override on an online payment. Allowed only where the machine did NOT make
 * the plan real:
 *   • the row is flagged (AMOUNT_MISMATCH, DUPLICATE_SUSPECTED, or
 *     ORPHAN_PAYMENT on a catalog that is live again), or
 *   • it was applied, yet the subscription row does not show it — including
 *     an admin's own earlier apply that never landed (edge case #1).
 *
 * The period starts NOW (`periodStart = paidAt`, AC-3.5), exactly as a
 * payment arriving now would; unused days on a running period are forfeited
 * (Assumption A2) and the entry says how many (`daysForfeitedOnApply`). The
 * quote is the frozen one from the ledger; if today's price differs, the
 * admin must accept the quoted price (#5).
 *
 * Exactly once per claim: `applyPaymentByAdmin` claims `adminResolution`
 * (guarded on its previous value) before it applies.
 */
export async function forceApplyPayment(
  orderId: string,
  admin: Actor,
  note: string,
  options: FixOptions = {},
  now: Date = new Date()
): Promise<ForceApplyResult> {
  const paid = await PaymentRecord.findOne({ kind: 'PAID', providerOrderId: orderId }).exec();
  if (!paid) return { outcome: 'NOT_FOUND' };
  if (!paid.appliedAt) return { outcome: 'NOT_APPLIED_YET' };
  if (await PaymentRecord.exists({ kind: 'REFUNDED', refundsPaymentId: paid._id }).exec()) {
    return { outcome: 'ALREADY_REFUNDED' };
  }
  const quote = paid.quote;
  if (!quote) return { outcome: 'NO_QUOTE' };
  const catalog = await Catalog.findOne({ _id: paid.catalogId, deletedAt: null })
    .select({ userId: 1 })
    .lean<{ userId: Types.ObjectId }>()
    .exec();
  if (!catalog) return { outcome: 'CATALOG_DELETED' };

  const r = paid.adminResolution;
  const previous: PaymentAdminResolution | null = r
    ? { action: r.action, by: { userId: r.by.userId, role: r.by.role }, at: r.at, note: r.note }
    : null;
  if (previous || !isFlagged(paid.note)) {
    const sub = await CatalogSubscription.findOne({ catalogId: paid.catalogId })
      .select({ status: 1, periodStart: 1, periodEnd: 1 })
      .lean<SubRow>()
      .exec();
    const reflects = reflectionOf(sub ?? undefined, previous?.at ?? paid.appliedAt);
    if (reflects !== 'NOT_REFLECTED') {
      return { outcome: previous ? 'ALREADY_RESOLVED' : 'NOT_NEEDED' };
    }
  }

  const refused = await priceGuard(quote, options);
  if (refused) return refused;

  // The claim-and-apply lives in the webhook service, beside the machine's
  // own apply, so every activation of an online payment is in one file.
  if (!(await applyPaymentByAdmin(paid, catalog.userId, admin, note, now, previous))) {
    return { outcome: 'ALREADY_RESOLVED' };
  }

  const reason = previous ? 'REAPPLIED' : (paid.note ?? 'NOT_REFLECTED');
  logFix(admin, 'FORCE_APPLY', paid.catalogId.toHexString(), reason);
  console.log(
    `[journal] admin ${hashIdentifier(admin.userId.toHexString())} force-apply order=${orderId} ` +
      `over=${reason} catalog=${paid.catalogId.toHexString()}`
  );
  return { outcome: 'APPLIED', attempt: (await getPaymentAttempt(orderId, now))! };
}

// ── Look up any Razorpay id (edge case #8) ──────────────────────────────────

/** `order_…` or `pay_…`, as copied from the Razorpay dashboard or an owner's SMS. */
export const PROVIDER_LOOKUP_ID_RE = /^(order|pay)_[A-Za-z0-9_]{3,58}$/;

export type LookupResult =
  /** The order is on the ledger — open its journal entry (Check from there). */
  | { outcome: 'ON_LEDGER'; orderId: string }
  /** This Razorpay payment was recorded as a manual ("Start plan") entry. */
  | { outcome: 'CASH_ENTRY'; catalogId: string; catalogName: string }
  /**
   * Razorpay knows it; our ledger does not — the "unknown order" alert's
   * case. `catalog` is resolved from the payment's notes when they name a
   * catalog we have; the admin can then "Start plan" there with this id.
   */
  | {
      outcome: 'NOT_ON_LEDGER';
      provider: {
        id: string;
        status: string;
        amountPaise: number;
        orderId: string | null;
      };
      catalog: { id: string; name: string } | null;
    }
  | { outcome: 'INVALID_ID' }
  | { outcome: 'RATE_LIMITED'; retryAfter: number }
  /** Razorpay is not configured, did not answer, or does not know the id. */
  | { outcome: 'UNAVAILABLE' };

async function catalogNamed(rawId: unknown): Promise<{ id: string; name: string } | null> {
  if (typeof rawId !== 'string' || !Types.ObjectId.isValid(rawId)) return null;
  const catalog = await Catalog.findOne({ _id: new Types.ObjectId(rawId) })
    .select({ name: 1 })
    .lean<{ _id: Types.ObjectId; name: string }>()
    .exec();
  return catalog ? { id: String(catalog._id), name: toDisplayName(catalog.name) } : null;
}

/**
 * "Find a payment": the admin pastes any `order_…` / `pay_…` id and learns
 * where it is. The ledger is asked first (no provider call when we know it);
 * only an id we have never seen goes to Razorpay. Nothing is written — a
 * payment found at Razorpay but not here is shown so the admin can decide
 * (Check the order it belongs to, or Start plan with it as the reference).
 */
export async function lookupProviderId(
  rawId: string,
  admin: Actor,
  now: Date = new Date()
): Promise<LookupResult> {
  const id = rawId.trim();
  if (!PROVIDER_LOOKUP_ID_RE.test(id)) return { outcome: 'INVALID_ID' };

  if (id.startsWith('order_')) {
    const known = await PaymentRecord.exists({
      providerOrderId: id,
      kind: { $in: ['CHECKOUT_CREATED', 'PAID'] },
    }).exec();
    if (known) return { outcome: 'ON_LEDGER', orderId: id };
  } else {
    const paid = await PaymentRecord.findOne({ kind: 'PAID', providerPaymentId: id })
      .select({ providerOrderId: 1 })
      .lean<{ providerOrderId?: string }>()
      .exec();
    if (paid?.providerOrderId) return { outcome: 'ON_LEDGER', orderId: paid.providerOrderId };
    const manual = await PaymentRecord.findOne({
      kind: 'MANUAL',
      reference: id,
      verificationStatus: { $in: ['PENDING_VERIFICATION', 'VERIFIED'] },
    })
      .select({ catalogId: 1 })
      .lean<{ catalogId: Types.ObjectId }>()
      .exec();
    if (manual) {
      const catalog = await catalogNamed(String(manual.catalogId));
      return {
        outcome: 'CASH_ENTRY',
        catalogId: String(manual.catalogId),
        catalogName: catalog?.name ?? '',
      };
    }
  }

  const rate = await consumeFixRate(admin, now);
  if (rate.limited) return { outcome: 'RATE_LIMITED', retryAfter: rate.retryAfter };
  if (!isRazorpayConfigured()) return { outcome: 'UNAVAILABLE' };

  if (id.startsWith('order_')) {
    const snapshot = await providerSnapshot(id, now);
    if (!snapshot) return { outcome: 'UNAVAILABLE' };
    return {
      outcome: 'NOT_ON_LEDGER',
      provider: {
        id,
        status: snapshot.orderStatus,
        amountPaise: snapshot.orderAmountPaise,
        orderId: id,
      },
      catalog: null,
    };
  }

  let payment: Awaited<ReturnType<ReturnType<typeof getRazorpayClient>['fetchPayment']>>;
  try {
    payment = await getRazorpayClient().fetchPayment(id);
  } catch (err) {
    console.warn(`[journal] payment lookup failed for ${id}`, err);
    return { outcome: 'UNAVAILABLE' };
  }
  // The payment belongs to an order we DO know, but was never recorded —
  // send the admin to that entry, where "Check with Razorpay" records it.
  if (
    payment.orderId &&
    (await PaymentRecord.exists({ kind: 'CHECKOUT_CREATED', providerOrderId: payment.orderId }).exec())
  ) {
    return { outcome: 'ON_LEDGER', orderId: payment.orderId };
  }
  return {
    outcome: 'NOT_ON_LEDGER',
    provider: {
      id: payment.id,
      status: payment.status,
      amountPaise: payment.amount,
      orderId: payment.orderId,
    },
    catalog: await catalogNamed(payment.notes.catalogId),
  };
}
