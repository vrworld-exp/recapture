// tests/helpers/subscriptionPayments.ts
//
// Shared fixtures for the Stage 3 payment suites: users with roles, a catalog
// (optionally delegated to a rep), subscription rows in a given status, a
// scripted Razorpay client, and a signed webhook body. Each suite still owns
// its own MongoMemoryServer and its own assertions.
import { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { vi } from 'vitest';

import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { User, type UserRole } from '@/models/User';
import type { SubscriptionStatus } from '@/models/types/subscription.types';
import {
  signWebhookBody,
  type RazorpayClient,
  type RazorpayInvoiceSnapshot,
  type RazorpaySubscriptionSnapshot,
} from '@/providers/razorpay';

export const DAY_MS = 86_400_000;

export type Auth = { Authorization: string };

export async function makeUser(
  role: UserRole = 'USER'
): Promise<{ id: Types.ObjectId; auth: Auth }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    role,
  });
  const token = jwt.sign({ userId: user.id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id: user._id as Types.ObjectId, auth: { Authorization: `Bearer ${token}` } };
}

export async function seedCatalog(ownerId: Types.ObjectId): Promise<Types.ObjectId> {
  const catalog = await Catalog.create({
    userId: ownerId,
    name: `cafe_${new Types.ObjectId().toHexString()}`,
    status: 'DRAFT',
  });
  return catalog._id as Types.ObjectId;
}

/** An owner with a catalog, a rep holding it, and an admin. */
export async function delegated() {
  const owner = await makeUser();
  const rep = await makeUser('SALES_REP');
  const admin = await makeUser('ADMIN');
  const catalogId = await seedCatalog(owner.id);
  await CatalogDelegation.create({
    repUserId: rep.id,
    catalogId,
    grantedAt: new Date(),
    revokedAt: null,
  });
  return { owner, rep, admin, catalogId };
}

/** A subscription row in `status`, mid-period unless overridden. */
export async function seedSubscription(
  catalogId: Types.ObjectId,
  ownerId: Types.ObjectId,
  status: SubscriptionStatus,
  overrides: Record<string, unknown> = {},
  now: Date = new Date()
) {
  return CatalogSubscription.create({
    catalogId,
    userId: ownerId,
    status,
    source: status === 'TRIAL' ? 'TRIAL' : 'ONLINE',
    periodStart: new Date(now.getTime() - 20 * DAY_MS),
    periodEnd: new Date(now.getTime() + 10 * DAY_MS),
    threeDDishCap: 15,
    ...overrides,
  });
}

/**
 * A scripted provider. Every method is a vi.fn so a test can assert on calls
 * or re-script one; the defaults mint sequential order ids and answer
 * "created" for everything.
 */
// Process-wide so two fakes in one test never mint the same order id (the
// ledger's unique index would make the second create a "reuse" of the first).
let mintedIds = 0;

export function fakeRazorpay(overrides: Partial<RazorpayClient> = {}) {
  const client = {
    createOrder: vi.fn(async (input: { amountPaise: number }) => ({
      id: `order_test_${++mintedIds}`,
      amount: input.amountPaise,
      status: 'created',
    })),
    fetchOrder: vi.fn(async (orderId: string) => ({
      id: orderId,
      status: 'created' as const,
      amount: 0,
    })),
    fetchPaymentsForOrder: vi.fn(async () => []),
    createRefund: vi.fn(async () => ({ id: `rfnd_test_${++mintedIds}`, status: 'processed' })),
    fetchPayment: vi.fn(async (paymentId: string) => ({
      id: paymentId,
      status: 'created',
      amount: 0,
      orderId: null as string | null,
      notes: {} as Record<string, string>,
    })),
    capturePayment: vi.fn(async (paymentId: string) => ({ id: paymentId, status: 'captured' })),
    // Autopay. A tiny in-memory Razorpay: `createSubscription` stores a
    // `created` subscription; a test moves it with `fakeSubscriptions.set` /
    // `.charge(...)` and the fetches read it back.
    createPlan: vi.fn(async () => ({ id: `plan_test_${++mintedIds}` })),
    createSubscription: vi.fn(
      async (input: { planId: string; startAt?: number }): Promise<RazorpaySubscriptionSnapshot> => {
        const snap: RazorpaySubscriptionSnapshot = {
          id: `sub_test_${++mintedIds}`,
          planId: input.planId,
          status: 'created',
          currentStart: null,
          currentEnd: null,
          chargeAt: input.startAt ?? null,
          startAt: input.startAt ?? null,
          paidCount: 0,
          endedAt: null,
        };
        fakeSubscriptions.subs.set(snap.id, snap);
        fakeSubscriptions.invoices.set(snap.id, []);
        return { ...snap };
      }
    ),
    fetchSubscription: vi.fn(async (id: string): Promise<RazorpaySubscriptionSnapshot> => {
      const snap = fakeSubscriptions.subs.get(id);
      if (!snap) throw new Error(`fake: no subscription ${id}`);
      return { ...snap };
    }),
    cancelSubscription: vi.fn(async (id: string): Promise<RazorpaySubscriptionSnapshot> => {
      const snap = fakeSubscriptions.subs.get(id);
      if (!snap) throw new Error(`fake: no subscription ${id}`);
      snap.status = 'cancelled';
      snap.endedAt = Math.floor(Date.now() / 1000);
      return { ...snap };
    }),
    fetchSubscriptionInvoices: vi.fn(async (id: string): Promise<RazorpayInvoiceSnapshot[]> => [
      ...(fakeSubscriptions.invoices.get(id) ?? []),
    ]),
    ...overrides,
  };
  return client as typeof client & RazorpayClient;
}

/**
 * The fake Razorpay's subscriptions, shared by every fake in the process.
 * `charge` is Razorpay taking one cycle: a paid invoice for [start, end), the
 * subscription ACTIVE on that cycle.
 */
export const fakeSubscriptions = {
  subs: new Map<string, RazorpaySubscriptionSnapshot>(),
  invoices: new Map<string, RazorpayInvoiceSnapshot[]>(),
  reset(): void {
    this.subs.clear();
    this.invoices.clear();
  },
  set(id: string, patch: Partial<RazorpaySubscriptionSnapshot>): void {
    const snap = this.subs.get(id);
    if (!snap) throw new Error(`fake: no subscription ${id}`);
    Object.assign(snap, patch);
  },
  charge(
    id: string,
    input: { amountPaise: number; start: Date; end: Date; paymentId?: string }
  ): string {
    const snap = this.subs.get(id);
    if (!snap) throw new Error(`fake: no subscription ${id}`);
    const n = ++mintedIds;
    const paymentId = input.paymentId ?? `pay_auto_${n}`;
    const secs = (d: Date): number => Math.floor(d.getTime() / 1000);
    this.invoices.get(id)!.push({
      id: `inv_test_${n}`,
      status: 'paid',
      paymentId,
      orderId: `order_inv_${n}`,
      amountPaid: input.amountPaise,
      paidAt: secs(input.start),
      billingStart: secs(input.start),
      billingEnd: secs(input.end),
    });
    Object.assign(snap, {
      status: 'active',
      currentStart: secs(input.start),
      currentEnd: secs(input.end),
      chargeAt: secs(input.end),
      paidCount: snap.paidCount + 1,
    });
    return paymentId;
  },
};

/** A `subscription.*` event, as Razorpay shapes it (the id is all the handler reads). */
export function subscriptionEvent(
  event: string,
  subscriptionId: string,
  paymentId?: string
): Record<string, unknown> {
  return {
    entity: 'event',
    event,
    payload: {
      subscription: { entity: { id: subscriptionId, entity: 'subscription' } },
      ...(paymentId
        ? {
            payment: {
              entity: { id: paymentId, entity: 'payment', invoice_id: 'inv_x', status: 'captured' },
            },
          }
        : {}),
    },
  };
}

/**
 * The exact bytes Razorpay would POST, plus the matching signature header.
 * Returned as a STRING: supertest JSON-serialises a Buffer (it would arrive as
 * `{"type":"Buffer",…}`), while a string goes on the wire verbatim.
 */
export function signedWebhook(
  event: Record<string, unknown>,
  secret = env.RAZORPAY_WEBHOOK_SECRET!
) {
  const body = JSON.stringify(event);
  return { body, signature: signWebhookBody(body, secret) };
}

/** A `payment.captured` event for an order, as Razorpay shapes it. */
export function paymentCaptured(input: {
  orderId: string;
  paymentId: string;
  amountPaise: number;
  notes?: Record<string, string>;
  event?: 'payment.captured' | 'order.paid';
}): Record<string, unknown> {
  return {
    entity: 'event',
    event: input.event ?? 'payment.captured',
    payload: {
      payment: {
        entity: {
          id: input.paymentId,
          entity: 'payment',
          amount: input.amountPaise,
          currency: 'INR',
          status: 'captured',
          order_id: input.orderId,
          method: 'upi',
          captured: true,
          ...(input.notes ? { notes: input.notes } : {}),
        },
      },
      ...(input.event === 'order.paid'
        ? {
            order: {
              entity: {
                id: input.orderId,
                amount: input.amountPaise,
                status: 'paid',
                ...(input.notes ? { notes: input.notes } : {}),
              },
            },
          }
        : {}),
    },
  };
}

/** Analytics echoes parsed off the console sink. */
export function emitted(name: string): Record<string, unknown>[] {
  return vi
    .mocked(console.log)
    .mock.calls.filter((c) => String(c[0]).includes(`[analytics] ${name}`))
    .map((c) => JSON.parse(String(c[1])) as Record<string, unknown>);
}
