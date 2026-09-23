// tests/subscription-models.test.ts
//
// The two subscription documents' schema rules — the ones the database, not a
// service, enforces: one subscription per catalog, one ledger row per
// idempotency key (and any number without one), integer money.
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { CatalogSubscription, isEntitledTo3D } from '@/models/CatalogSubscription';
import { PaymentRecord } from '@/models/PaymentRecord';
import {
  SUBSCRIPTION_STATUSES,
  UNCAPPED_THREE_D,
  isUncapped,
  type SubscriptionStatus,
} from '@/models/types/subscription.types';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';

let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await CatalogSubscription.syncIndexes();
  await PaymentRecord.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await Promise.all([CatalogSubscription.deleteMany({}), PaymentRecord.deleteMany({})]);
});

const NOW = new Date('2026-09-18T00:00:00.000Z');

function trialRow(catalogId = new Types.ObjectId()) {
  return {
    catalogId,
    userId: new Types.ObjectId(),
    status: 'TRIAL' as const,
    source: 'TRIAL' as const,
    periodStart: NOW,
    periodEnd: new Date(NOW.getTime() + 30 * 86_400_000),
    threeDDishCap: 10,
  };
}

function ledgerRow(overrides: Record<string, unknown> = {}) {
  return {
    catalogId: new Types.ObjectId(),
    userId: new Types.ObjectId(),
    subscriptionId: new Types.ObjectId(),
    kind: 'PAID' as const,
    amountPaise: 119_900,
    initiatedBy: { userId: new Types.ObjectId(), role: 'USER' as const },
    ...overrides,
  };
}

describe('CatalogSubscription', () => {
  it('rejects a second row for the same catalog with E11000', async () => {
    const catalogId = new Types.ObjectId();
    await CatalogSubscription.create(trialRow(catalogId));

    await expect(CatalogSubscription.create(trialRow(catalogId))).rejects.toMatchObject({
      code: 11000,
    });
    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(1);
  });

  it('defaults the standee allocation to nothing issued', async () => {
    const row = await CatalogSubscription.create(trialRow());
    expect(row.standeeAllocation).toMatchObject({ included: 0, issued: 0 });
  });

  it('stores a frozen plan snapshot and a plan id', async () => {
    const plan = DEFAULT_PLAN_CATALOG.plans.SIGNATURE;
    const row = await CatalogSubscription.create({
      ...trialRow(),
      status: 'ACTIVE',
      source: 'ONLINE',
      planId: 'SIGNATURE',
      planSnapshot: plan,
      billingInterval: 'MONTHLY',
      threeDDishCap: plan.threeDDishCap,
    });

    const stored = await CatalogSubscription.findById(row._id).lean().exec();
    expect(stored?.planSnapshot).toMatchObject({
      planId: 'SIGNATURE',
      priceMonthlyPaise: 179_900,
      threeDDishCap: 15,
      features: ['whatsapp_instagram_buttons'],
    });
  });

  it('accepts -1 as the uncapped sentinel and nothing more negative', async () => {
    const comped = await CatalogSubscription.create({
      ...trialRow(),
      status: 'COMPED',
      source: 'COMP',
      threeDDishCap: UNCAPPED_THREE_D,
    });
    expect(isUncapped(comped.threeDDishCap)).toBe(true);

    await expect(
      CatalogSubscription.create({ ...trialRow(), threeDDishCap: -2 })
    ).rejects.toThrow(/validation/i);
  });

  it('refuses fractional money on the plan snapshot', async () => {
    await expect(
      CatalogSubscription.create({
        ...trialRow(),
        planSnapshot: { ...DEFAULT_PLAN_CATALOG.plans.TASTE, priceMonthlyPaise: 1199.5 },
      })
    ).rejects.toThrow(/validation/i);
  });

  it('isEntitledTo3D is true for exactly TRIAL, PENDING_PAYMENT, ACTIVE, GRACE and COMPED', () => {
    const entitled = SUBSCRIPTION_STATUSES.filter((status: SubscriptionStatus) =>
      isEntitledTo3D(status)
    );
    // PENDING_PAYMENT is entitled on purpose (requirement 2): the rep's publish
    // leaves a WORKING standee on the table, 3D included, before anybody pays.
    // What limits it is the cap on the row and the deadline, not this function.
    expect(entitled).toEqual(['TRIAL', 'PENDING_PAYMENT', 'ACTIVE', 'GRACE', 'COMPED']);
  });
});

describe('PaymentRecord', () => {
  it('rejects a duplicate idempotencyKey with E11000', async () => {
    await PaymentRecord.create(ledgerRow({ idempotencyKey: 'order-1' }));

    await expect(
      PaymentRecord.create(ledgerRow({ idempotencyKey: 'order-1' }))
    ).rejects.toMatchObject({ code: 11000 });
  });

  it('allows any number of rows with no idempotencyKey', async () => {
    await PaymentRecord.create(ledgerRow({ kind: 'COMP', amountPaise: 0 }));
    await PaymentRecord.create(ledgerRow({ kind: 'MANUAL', method: 'CASH' }));
    await PaymentRecord.create(ledgerRow({ idempotencyKey: null }));

    expect(await PaymentRecord.countDocuments({})).toBe(3);
  });

  it('rejects a duplicate providerOrderId of the same kind, and allows many without one', async () => {
    await PaymentRecord.create(ledgerRow({ providerOrderId: 'rzp_1' }));
    await PaymentRecord.create(ledgerRow({}));
    await PaymentRecord.create(ledgerRow({}));

    await expect(
      PaymentRecord.create(ledgerRow({ providerOrderId: 'rzp_1' }))
    ).rejects.toMatchObject({ code: 11000 });
    expect(await PaymentRecord.countDocuments({})).toBe(3);
  });

  it('lets the CHECKOUT_CREATED and PAID rows of one order share its providerOrderId', async () => {
    await PaymentRecord.create(
      ledgerRow({ kind: 'CHECKOUT_CREATED', providerOrderId: 'rzp_2', expiresAt: NOW })
    );
    await PaymentRecord.create(ledgerRow({ kind: 'PAID', providerOrderId: 'rzp_2' }));
    expect(await PaymentRecord.countDocuments({ providerOrderId: 'rzp_2' })).toBe(2);
  });

  it('refuses a negative or fractional amount', async () => {
    await expect(PaymentRecord.create(ledgerRow({ amountPaise: -1 }))).rejects.toThrow(
      /validation/i
    );
    await expect(PaymentRecord.create(ledgerRow({ amountPaise: 10.5 }))).rejects.toThrow(
      /validation/i
    );
  });

  it('defaults the currency to INR and records the actor with a role', async () => {
    const row = await PaymentRecord.create(ledgerRow());
    expect(row.currency).toBe('INR');
    expect(row.initiatedBy.role).toBe('USER');
  });
});
