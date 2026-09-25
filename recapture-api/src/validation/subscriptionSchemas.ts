// src/validation/subscriptionSchemas.ts
//
// Request shapes for the subscription routes — the owner's checkout, the rep's
// cash request, and the admin's money actions. Every body is `.strict()`: a
// key the schema does not name is a 400, never a silent drop.
import { z } from 'zod';
import {
  BILLING_INTERVALS,
  MANUAL_METHODS,
  PLAN_IDS,
  VERIFICATION_STATUSES,
} from '@/models/types/subscription.types';

const OBJECT_ID_RE = /^[a-fA-F0-9]{24}$/;
const objectId = (what: string) => z.string().regex(OBJECT_ID_RE, `Invalid ${what}`);

/**
 * The trial route takes NO body: the plan and the length are config, and a
 * client that thinks it can pass either is one deploy away from a free year.
 * `.strict()` makes any key a 400; `.optional()` accepts a request with no
 * body at all (the body parser hands those through as `undefined` or `{}`).
 */
export const startTrialSchema = z.object({}).strict().optional();

/**
 * POST /rep/catalogs/:id/subscription/notify-owner — same shape and the same
 * reason: what the nudge says is chosen server-side from the subscription
 * status, never typed by a rep. A message or a phone in the body is a 400.
 */
export const notifyOwnerSchema = z.object({}).strict().optional();

// ── Door 2: in-app checkout ─────────────────────────────────────────────────

/**
 * POST /catalog/subscription/order. The plan and the interval are the ONLY
 * inputs — the price comes from the server's plan catalog, never the body.
 */
export const createOrderSchema = z
  .object({
    planId: z.enum(PLAN_IDS),
    interval: z.enum(BILLING_INTERVALS),
  })
  .strict();
export type CreateOrderInput = z.infer<typeof createOrderSchema>;

/**
 * POST /catalog/subscription/verify — exactly what the Razorpay sheet's success
 * handler returned. No amount and no plan: those come from Razorpay and the
 * frozen quote, never the body.
 */
export const verifyPaymentSchema = z
  .object({
    orderId: z.string().min(1).max(64),
    paymentId: z.string().min(1).max(64),
    signature: z.string().min(1).max(256),
  })
  .strict();
export type VerifyPaymentInput = z.infer<typeof verifyPaymentSchema>;

/** POST /catalog/subscription/autopay — the same two choices as a one-time order. */
export const startAutopaySchema = createOrderSchema;

/**
 * POST /catalog/subscription/autopay/verify — what the sheet's success handler
 * returned for a SUBSCRIPTION checkout (`razorpay_subscription_id` instead of
 * an order id). No amount and no plan: the charge is read off Razorpay's
 * invoice, never the body.
 */
export const verifyAutopaySchema = z
  .object({
    subscriptionId: z.string().min(1).max(64),
    paymentId: z.string().min(1).max(64),
    signature: z.string().min(1).max(256),
  })
  .strict();
export type VerifyAutopayInput = z.infer<typeof verifyAutopaySchema>;

// ── Door 3: manual payments ─────────────────────────────────────────────────

const manualPaymentFields = {
  planId: z.enum(PLAN_IDS),
  interval: z.enum(BILLING_INTERVALS),
  /** Integer paise, what was actually handed over — compared to the quote on VERIFY (E12). */
  amountPaise: z.number().int().positive(),
  method: z.enum(MANUAL_METHODS),
  /** A UPI txn id, a cheque number, a receipt book number. Never a phone or a name. */
  reference: z.string().trim().min(1).max(200),
  note: z.string().trim().max(1000).optional(),
  /** Who physically took the money, when not the caller. */
  collectedByUserId: objectId('collectedByUserId').optional(),
};

/** POST /rep/catalogs/:id/subscription/manual-payment-request. */
export const manualPaymentRequestSchema = z.object(manualPaymentFields).strict();
export type ManualPaymentRequestInput = z.infer<typeof manualPaymentRequestSchema>;

/**
 * POST /admin/catalogs/:id/subscription/manual-payment — one route, three
 * actions. A REJECT must say why (the rep reads it). An `override` is how an
 * admin verifies an amount that does not match the quote, and it must come
 * with a note of at least 20 characters — that rule needs the record, so the
 * service enforces it (422 AMOUNT_MISMATCH).
 */
export const adminManualPaymentSchema = z.discriminatedUnion('action', [
  z
    .object({
      action: z.literal('VERIFY'),
      paymentRecordId: objectId('paymentRecordId'),
      note: z.string().trim().max(1000).optional(),
      override: z.boolean().optional(),
    })
    .strict(),
  z
    .object({
      action: z.literal('REJECT'),
      paymentRecordId: objectId('paymentRecordId'),
      note: z.string().trim().min(1).max(1000),
    })
    .strict(),
  z
    .object({
      action: z.literal('CREATE_AND_VERIFY'),
      ...manualPaymentFields,
      override: z.boolean().optional(),
    })
    .strict(),
]);
export type AdminManualPaymentInput = z.infer<typeof adminManualPaymentSchema>;

/** GET /admin/subscriptions/manual-payments query. */
export const adminManualPaymentsQuerySchema = z
  .object({
    status: z.enum(VERIFICATION_STATUSES).default('PENDING_VERIFICATION'),
    limit: z.coerce.number().int().min(1).max(200).default(100),
  })
  .strict();

// ── Door 4 + admin actions ──────────────────────────────────────────────────

/** POST /admin/catalogs/:id/subscription/comp. `until` must be in the future. */
export const compSchema = z
  .object({
    until: z
      .string()
      .datetime({ offset: true })
      .transform((v) => new Date(v))
      .refine((d) => d.getTime() > Date.now(), { message: 'until must be in the future' }),
    note: z.string().trim().min(1).max(1000),
  })
  .strict();
export type CompInput = z.infer<typeof compSchema>;

/** POST /admin/catalogs/:id/subscription/extend-grace. */
export const extendGraceSchema = z
  .object({
    days: z.number().int().min(1).max(30),
    note: z.string().trim().min(1).max(1000),
  })
  .strict();
export type ExtendGraceInput = z.infer<typeof extendGraceSchema>;

/**
 * POST /admin/catalogs/:id/subscription/refund. The row must be flagged
 * DUPLICATE_SUSPECTED, or the admin overrides with a note of at least 30
 * characters — the longer floor is checked in the service, where the flag is.
 *
 * `manual: true` records a CASH refund the admin already handed back (E13):
 * no Razorpay call, and `reference` (the receipt or UPI txn id of the money
 * returned) is then required — a ledger row for cash with nothing to point at
 * is a row nobody can audit. Only for a VERIFIED MANUAL row; the service
 * refuses it on an online payment (USE_PROVIDER_REFUND).
 */
export const refundSchema = z
  .object({
    refundsPaymentId: objectId('refundsPaymentId'),
    note: z.string().trim().min(10).max(1000),
    override: z.boolean().optional(),
    manual: z.boolean().optional(),
    reference: z.string().trim().min(1).max(200).optional(),
  })
  .strict()
  .superRefine((body, ctx) => {
    if (body.manual === true && !body.reference) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['reference'],
        message: 'reference is required for a manual refund',
      });
    }
  });
export type RefundInput = z.infer<typeof refundSchema>;

/**
 * PATCH /admin/catalogs/:id/subscription/standees — how many of the plan's
 * complimentary standees have been handed over. An absolute count set by a
 * human, not an increment: two admins updating at once end with the larger
 * of two truths, not the sum of two guesses. The upper bound (`included`) is
 * on the row, so the service enforces it (422 EXCEEDS_INCLUDED).
 */
export const standeesIssuedSchema = z
  .object({
    issued: z.number().int().min(0).max(10_000),
    note: z.string().trim().max(1000).optional(),
  })
  .strict();
export type StandeesIssuedInput = z.infer<typeof standeesIssuedSchema>;

/**
 * The collections list's filter vocabulary. `PAUSED_90D` is the follow-up
 * segment (E23): PAUSED with `pausedAt` at least 90 days ago — an owner who
 * has gone quiet, kept for a call, never purged.
 */
export const ADMIN_SUBSCRIPTION_STATES = [
  // Every subscription row, most recently changed first — the "see them all"
  // view. The other five are collections segments ordered by urgency.
  'ALL',
  'EXPIRING_7D',
  'GRACE',
  'PAUSED',
  'PAUSED_90D',
  'TRIAL',
] as const;
export type AdminSubscriptionState = (typeof ADMIN_SUBSCRIPTION_STATES)[number];

/** GET /admin/subscriptions query. */
export const adminSubscriptionsQuerySchema = z
  .object({
    state: z.enum(ADMIN_SUBSCRIPTION_STATES),
    cursor: z.string().min(1).optional(),
    limit: z.coerce.number().int().min(1).max(100).default(50),
    /** Restaurant name, business name or owner display name — a substring, case-insensitive. */
    q: z.string().trim().min(1).max(60).optional(),
  })
  .strict();
export type AdminSubscriptionsQuery = z.infer<typeof adminSubscriptionsQuerySchema>;

// ── The admin payment journal ───────────────────────────────────────────────

/**
 * GET /admin/subscriptions/payments `filter`:
 *   ATTENTION     — money on the ledger that did not become a plan (not yet
 *                   applied, flagged, or missing from the subscription row);
 *   ALL           — every order anyone opened, newest first;
 *   SUCCEEDED     — every payment Razorpay captured;
 *   NOT_COMPLETED — orders with no payment on the ledger (open or expired).
 */
export const PAYMENT_JOURNAL_FILTERS = ['ATTENTION', 'ALL', 'SUCCEEDED', 'NOT_COMPLETED'] as const;
export type PaymentJournalFilter = (typeof PAYMENT_JOURNAL_FILTERS)[number];

export const adminPaymentJournalQuerySchema = z
  .object({
    filter: z.enum(PAYMENT_JOURNAL_FILTERS).default('ATTENTION'),
    cursor: z.string().min(1).optional(),
    limit: z.coerce.number().int().min(1).max(100).default(30),
  })
  .strict();

/** A Razorpay order id as it rides in a path (`order_…`). Shape only; existence is the service's. */
export const PROVIDER_ORDER_ID_RE = /^[A-Za-z0-9_]{1,64}$/;

/**
 * The sync and the capture take one optional flag: the admin has seen that the
 * order's price differs from today's (a testing-price order after go-live) and
 * accepts it. Without it such an order is refused with QUOTE_PRICE_CHANGED.
 */
export const syncPaymentSchema = z
  .object({ acceptQuotedPrice: z.boolean().optional() })
  .strict()
  .optional();
export type SyncPaymentInput = z.infer<typeof syncPaymentSchema>;

/** GET /admin/subscriptions/payments/lookup?id=order_…|pay_… */
export const paymentLookupQuerySchema = z
  .object({ id: z.string().trim().min(1).max(64) })
  .strict();

/**
 * POST /admin/subscriptions/payments/:orderId/apply — the human override.
 * Same 20-character floor as a mismatched cash VERIFY (E12): it is the same
 * kind of decision, made against what the machine concluded.
 */
export const forceApplyPaymentSchema = z
  .object({
    note: z.string().trim().min(20).max(1000),
    acceptQuotedPrice: z.boolean().optional(),
  })
  .strict();
export type ForceApplyPaymentInput = z.infer<typeof forceApplyPaymentSchema>;
