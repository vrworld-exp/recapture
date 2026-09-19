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
import { signWebhookBody, type RazorpayClient } from '@/providers/razorpay';

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
    ...overrides,
  };
  return client as typeof client & RazorpayClient;
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
