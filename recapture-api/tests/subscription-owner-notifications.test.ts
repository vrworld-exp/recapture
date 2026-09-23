// tests/subscription-owner-notifications.test.ts
//
// The owner's side of the subscription (`services/subscription/
// ownerNotifications.ts`): every lifecycle event reaches the bell exactly
// once, addressed to the owner alone, in words that do not leak.
//
// WHAT THIS FILE EXISTS TO PIN, in order:
//   • ONE MESSAGE PER EVENT. Every helper is keyed, so the replay each caller
//     is built to survive — a re-delivered webhook, a second sweep instance,
//     an admin pressing twice — writes nothing the second time.
//   • THE ACTIVATION MESSAGE IS KEYED ON THE PAYMENT, not on the clock. The
//     reconciler re-applies a half-applied period with a FRESH `paidAt`; the
//     owner must still be told once. This is the case the key was changed for.
//   • ADDRESSED, NEVER BROADCAST. `audienceType: 'USERS'` with exactly the
//     owner in it — a notification can name one restaurant's overdue invoice.
//   • THE ADMIN'S NOTE NEVER TRAVELS. A rejected cash payment tells the owner
//     what is true; the reason we could not find the money is ours.
//   • NOTHING HERE CAN FAIL ITS CALLER. A store that refuses the write leaves
//     the state change intact and the caller's answer unchanged.
//   • THE ANALYTICS CARRY THE EVENT, NEVER THE SENTENCE.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import { Catalog } from '@/models/Catalog';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { Notification } from '@/models/Notification';
import { PaymentRecord } from '@/models/PaymentRecord';
import { ReminderLog } from '@/models/ReminderLog';
import { User } from '@/models/User';
import {
  notifyCompGranted,
  notifyGraceExtended,
  notifyManualPaymentRejected,
  notifyManualPaymentSubmitted,
  notifyNoPlanYet,
  notifyPageDeactivated,
  notifyPaymentWindowOpened,
  notifyPlanActivated,
  notifyRefundIssued,
  notifyThreeDPaused,
  notifyTrialStarted,
  SUBSCRIPTION_ACTION_ROUTE,
} from '@/services/subscription/ownerNotifications';
import { runSubscriptionSweep } from '@/services/subscription/lifecycleSweep';
import { applyPaidPeriod, startTrial } from '@/services/subscription/subscriptionService';
import { DAY_MS, emitted, makeUser, seedCatalog } from './helpers/subscriptionPayments';

let mongod: MongoMemoryServer;

const T = new Date('2026-10-01T03:00:00.000Z');
const TASTE = DEFAULT_PLAN_CATALOG.plans.TASTE;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([
    Catalog.syncIndexes(),
    CatalogSubscription.syncIndexes(),
    Notification.syncIndexes(),
    PaymentRecord.syncIndexes(),
  ]);
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    Notification.deleteMany({}),
    PaymentRecord.deleteMany({}),
    ReminderLog.deleteMany({}),
  ]);
});

async function ownerWithCatalog() {
  const owner = await makeUser();
  const catalogId = await seedCatalog(owner.id);
  return { owner, catalogId };
}

const feedFor = (userId: Types.ObjectId) =>
  Notification.find({ audienceUserIds: userId }).sort({ createdAt: 1 }).lean().exec();

// ── One message per event ────────────────────────────────────────────────────

describe('every helper is keyed: the second call writes nothing', () => {
  it('a re-delivered activation is one message', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    const paymentRecordId = new Types.ObjectId();
    const args = {
      catalogId,
      ownerUserId: owner.id,
      paymentRecordId,
      plan: TASTE,
      interval: 'MONTHLY' as const,
      amountPaise: TASTE.priceMonthlyPaise,
      periodEnd: new Date(T.getTime() + 30 * DAY_MS),
      resumedThreeD: false,
      restoredPage: false,
    };

    expect(await notifyPlanActivated(args)).toBe(true);
    expect(await notifyPlanActivated(args)).toBe(false);

    expect(await feedFor(owner.id)).toHaveLength(1);
  });

  it('the activation key is the PAYMENT, so the reconciler’s fresh clock changes nothing', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    const paymentRecordId = new Types.ObjectId();
    const base = {
      catalogId,
      ownerUserId: owner.id,
      paymentRecordId,
      plan: TASTE,
      interval: 'MONTHLY' as const,
      amountPaise: TASTE.priceMonthlyPaise,
      resumedThreeD: false,
      restoredPage: false,
    };

    // The webhook applied a period and crashed before stamping `appliedAt`;
    // the reconciler re-applies it an hour later, so every DATE differs.
    await notifyPlanActivated({ ...base, periodEnd: new Date(T.getTime() + 30 * DAY_MS) });
    await notifyPlanActivated({
      ...base,
      periodEnd: new Date(T.getTime() + 30 * DAY_MS + 3_600_000),
    });

    expect(await feedFor(owner.id)).toHaveLength(1);
  });

  it('two sweep instances pausing the same row send one message', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    const pausedAt = T;
    await notifyThreeDPaused({ catalogId, ownerUserId: owner.id, pausedAt });
    await notifyThreeDPaused({ catalogId, ownerUserId: owner.id, pausedAt });
    expect(await feedFor(owner.id)).toHaveLength(1);
  });

  it('a LATER pause on the same catalog is its own message', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await notifyThreeDPaused({ catalogId, ownerUserId: owner.id, pausedAt: T });
    // Paid, lapsed again, paused again a month on: a different event.
    await notifyThreeDPaused({
      catalogId,
      ownerUserId: owner.id,
      pausedAt: new Date(T.getTime() + 40 * DAY_MS),
    });
    expect(await feedFor(owner.id)).toHaveLength(2);
  });
});

// ── Addressing and content ───────────────────────────────────────────────────

describe('addressed to the owner, and nothing else rides along', () => {
  it('is a USERS audience of exactly one, pointing at the subscription screen', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    const other = await makeUser();

    await notifyTrialStarted({
      catalogId,
      ownerUserId: owner.id,
      endsAt: new Date(T.getTime() + 30 * DAY_MS),
      trialDays: 30,
      threeDDishCap: 10,
    });

    const [row] = await feedFor(owner.id);
    expect(row.audienceType).toBe('USERS');
    expect(row.audienceUserIds.map(String)).toEqual([owner.id.toHexString()]);
    expect(row.action?.url).toBe(SUBSCRIPTION_ACTION_ROUTE);
    // Not a broadcast: the other account's feed is empty.
    expect(await feedFor(other.id)).toHaveLength(0);
  });

  it('the activation message names the plan, the amount and the next due date', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await notifyPlanActivated({
      catalogId,
      ownerUserId: owner.id,
      paymentRecordId: new Types.ObjectId(),
      plan: TASTE,
      interval: 'MONTHLY',
      amountPaise: 119_900,
      periodEnd: new Date('2026-10-31T03:00:00.000Z'),
      resumedThreeD: false,
      restoredPage: false,
    });

    const [row] = await feedFor(owner.id);
    expect(row.kind).toBe('PAYMENT_ACTIVATE');
    expect(row.message).toContain('Rs. 1,199.00');
    expect(row.message).toContain(TASTE.displayName);
    expect(row.message).toContain('31 Oct 2026');
    expect(row.message).toContain('next payment is due');
    // Its own dates make it stale: it must not outlive the period it describes.
    expect(row.expiresAt?.getTime()).toBe(new Date('2026-10-31T03:00:00.000Z').getTime());
  });

  it('says the live page is back only when this payment actually restored it', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    const base = {
      catalogId,
      ownerUserId: owner.id,
      plan: TASTE,
      interval: 'MONTHLY' as const,
      amountPaise: TASTE.priceMonthlyPaise,
      periodEnd: new Date(T.getTime() + 30 * DAY_MS),
    };

    await notifyPlanActivated({
      ...base,
      paymentRecordId: new Types.ObjectId(),
      resumedThreeD: true,
      restoredPage: true,
    });
    await notifyPlanActivated({
      ...base,
      paymentRecordId: new Types.ObjectId(),
      resumedThreeD: true,
      restoredPage: false,
    });
    await notifyPlanActivated({
      ...base,
      paymentRecordId: new Types.ObjectId(),
      resumedThreeD: false,
      restoredPage: false,
    });

    const [dark, paused, ordinary] = await feedFor(owner.id);
    expect(dark.message).toContain('live menu is back on');
    expect(paused.message).toContain('3D menu is live again');
    expect(ordinary.message).not.toContain('back on');
    expect(ordinary.message).not.toContain('live again');
  });

  it('the page-off message never repeats the pause message’s promise', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await notifyThreeDPaused({ catalogId, ownerUserId: owner.id, pausedAt: T });
    await notifyPageDeactivated({ catalogId, ownerUserId: owner.id, deactivatedAt: T });

    const [paused, off] = await feedFor(owner.id);
    // The pause keeps the photo menu; the page-off is the one case it does not.
    expect(paused.message).toContain('photo menu is still live');
    expect(off.message).not.toContain('still live');
    expect(off.message).toContain('no longer opens');
  });

  it('a rejected cash payment says what is true and not why', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await notifyManualPaymentRejected({
      catalogId,
      ownerUserId: owner.id,
      paymentRecordId: new Types.ObjectId(),
      amountPaise: 119_900,
      method: 'BANK_TRANSFER',
    });

    const [row] = await feedFor(owner.id);
    expect(row.message).toContain('Bank transfer');
    expect(row.message).toContain('no plan has been started');
    // There is no argument here for the admin's note, and no seam it could
    // arrive through: the helper takes no note parameter at all.
    expect(row.detail).toBeUndefined();
  });

  it('a refund says the period is unchanged', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await notifyRefundIssued({
      catalogId,
      ownerUserId: owner.id,
      paymentRecordId: new Types.ObjectId(),
      amountPaise: 119_900,
      manual: false,
    });
    const [row] = await feedFor(owner.id);
    expect(row.message).toContain('unchanged');
    expect(row.message).toContain('5–7 working days');
  });

  it('the window message counts the page down, never the 3D on it', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await notifyPaymentWindowOpened({
      catalogId,
      ownerUserId: owner.id,
      paymentDueAt: new Date(T.getTime() + 7 * DAY_MS),
      windowDays: 7,
    });
    const [row] = await feedFor(owner.id);
    expect(row.kind).toBe('PAYMENT_DUE');
    expect(row.message).toContain('live page switches off');
    expect(row.message).not.toContain('3D');
    expect(row.expiresAt?.getTime()).toBe(T.getTime() + 7 * DAY_MS);
  });

  it('a comp never implies money moved, and a grace extension names the new date', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await notifyCompGranted({
      catalogId,
      ownerUserId: owner.id,
      grantedAt: T,
      until: new Date('2026-12-01T03:00:00.000Z'),
    });
    await notifyGraceExtended({
      catalogId,
      ownerUserId: owner.id,
      graceEndsAt: new Date('2026-10-08T03:00:00.000Z'),
      days: 7,
    });

    const [comp, grace] = await feedFor(owner.id);
    expect(comp.message).toContain('no charge');
    expect(comp.message).toContain('1 Dec 2026');
    expect(grace.message).toContain('7 days more');
    expect(grace.message).toContain('8 Oct 2026');
  });

  it('a cash submission tells the owner an admin still has to confirm it', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await notifyManualPaymentSubmitted({
      catalogId,
      ownerUserId: owner.id,
      paymentRecordId: new Types.ObjectId(),
      amountPaise: 119_900,
      method: 'CASH',
    });
    const [row] = await feedFor(owner.id);
    expect(row.kind).toBe('INFO');
    expect(row.message).toContain('Cash');
    expect(row.message).toContain('confirms it');
  });
});

// ── "Not opted in yet" ───────────────────────────────────────────────────────

describe('the catalog that never chose anything', () => {
  const NO_PLAN_DAYS = 3;
  /**
   * A catalog created N days before `T`. Through the RAW driver: Mongoose
   * marks a timestamped `createdAt` immutable, so a model-level update is
   * silently dropped and every catalog would read as brand new.
   */
  async function agedCatalog(ownerId: Types.ObjectId, ageDays: number) {
    const catalogId = await seedCatalog(ownerId);
    await Catalog.collection.updateOne(
      { _id: catalogId },
      { $set: { createdAt: new Date(T.getTime() - ageDays * DAY_MS) } }
    );
    return catalogId;
  }

  it('is silent while the catalog is younger than the delay, then sends once', async () => {
    const owner = await makeUser();
    const catalogId = await agedCatalog(owner.id, NO_PLAN_DAYS - 1);

    expect((await runSubscriptionSweep(T)).noPlanNudges).toBe(0);
    expect(await feedFor(owner.id)).toHaveLength(0);

    // A day later the catalog has aged past the delay.
    const later = new Date(T.getTime() + DAY_MS);
    expect((await runSubscriptionSweep(later)).noPlanNudges).toBe(1);

    const [row] = await feedFor(owner.id);
    expect(row.title).toContain('not chosen a plan');
    expect(row.action?.url).toBe(SUBSCRIPTION_ACTION_ROUTE);
    expect(row.key).toBe(`sub-no-plan:${catalogId.toHexString()}`);
  });

  it('NEVER repeats, however many times the sweep re-finds it', async () => {
    const owner = await makeUser();
    await agedCatalog(owner.id, NO_PLAN_DAYS + 1);

    expect((await runSubscriptionSweep(T)).noPlanNudges).toBe(1);
    expect((await runSubscriptionSweep(new Date(T.getTime() + 600_000))).noPlanNudges).toBe(0);
    expect((await runSubscriptionSweep(new Date(T.getTime() + 1_200_000))).noPlanNudges).toBe(0);

    expect(await feedFor(owner.id)).toHaveLength(1);
  });

  it('skips a catalog that HAS opted in, in any status', async () => {
    for (const status of ['TRIAL', 'ACTIVE', 'PENDING_PAYMENT', 'PAUSED', 'CANCELLED'] as const) {
      const owner = await makeUser();
      const catalogId = await agedCatalog(owner.id, NO_PLAN_DAYS + 1);
      await CatalogSubscription.create({
        catalogId,
        userId: owner.id,
        status,
        source: 'ONLINE',
        periodStart: new Date(T.getTime() - 20 * DAY_MS),
        periodEnd: new Date(T.getTime() + 10 * DAY_MS),
        threeDDishCap: 15,
      });
    }

    // Reminders may fire for those rows; the no-plan scan must not.
    expect((await runSubscriptionSweep(T)).noPlanNudges).toBe(0);
    expect(await Notification.countDocuments({ key: /^sub-no-plan:/ })).toBe(0);
  });

  it('leaves a long-abandoned catalog alone — the scan is bounded', async () => {
    const owner = await makeUser();
    await agedCatalog(owner.id, 200);
    expect((await runSubscriptionSweep(T)).noPlanNudges).toBe(0);
    expect(await feedFor(owner.id)).toHaveLength(0);
  });

  it('says nothing about 3D pausing — there is nothing running to pause', async () => {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    await notifyNoPlanYet({ catalogId, ownerUserId: owner.id });

    const [row] = await feedFor(owner.id);
    expect(row.message).not.toContain('pause');
    expect(row.message).toContain('cannot go live');
    // It stays true until the owner acts, so it does not expire.
    expect(row.expiresAt).toBeUndefined();
  });
});

// ── The analytics seam ───────────────────────────────────────────────────────

describe('analytics', () => {
  it('carries the catalog and the event, and never the words', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await notifyThreeDPaused({ catalogId, ownerUserId: owner.id, pausedAt: T });

    expect(emitted('subscription_owner_notified')).toEqual([
      { catalog_id: catalogId.toHexString(), event: 'THREE_D_PAUSED' },
    ]);
  });

  it('emits nothing when the key already existed', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await notifyThreeDPaused({ catalogId, ownerUserId: owner.id, pausedAt: T });
    vi.mocked(console.log).mockClear();
    await notifyThreeDPaused({ catalogId, ownerUserId: owner.id, pausedAt: T });
    expect(emitted('subscription_owner_notified')).toEqual([]);
  });
});

// ── The never-throws contract ────────────────────────────────────────────────

describe('a message that cannot be written never fails its caller', () => {
  it('swallows a store failure and logs it', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    const create = vi
      .spyOn(Notification, 'create')
      .mockRejectedValueOnce(new Error('replica set is down') as never);

    await expect(
      notifyThreeDPaused({ catalogId, ownerUserId: owner.id, pausedAt: T })
    ).resolves.toBe(false);
    expect(create).toHaveBeenCalledOnce();
    expect(vi.mocked(console.warn).mock.calls.flat().join(' ')).toContain('THREE_D_PAUSED');
  });
});

// ── Wired into the real paths ────────────────────────────────────────────────

describe('the callers actually send them', () => {
  it('startTrial tells the owner when the trial ends', async () => {
    const { owner, catalogId } = await ownerWithCatalog();

    const result = await startTrial(
      catalogId,
      owner.id,
      { userId: owner.id, role: 'ADMIN' },
      'ADMIN',
      T
    );
    expect(result.outcome).toBe('STARTED');

    const [row] = await feedFor(owner.id);
    expect(row.title).toContain('free trial has started');
    expect(row.message).toContain(`${DEFAULT_PLAN_CATALOG.trialDays}-day`);
    expect(row.message).toContain(`${DEFAULT_PLAN_CATALOG.trialThreeDCap} 3D dishes`);
  });

  it('applyPaidPeriod tells the owner the payment landed, once per payment', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    const paymentRecordId = new Types.ObjectId();
    const input = {
      catalogId,
      ownerUserId: owner.id,
      planId: 'TASTE' as const,
      interval: 'MONTHLY' as const,
      source: 'ONLINE' as const,
      paidAt: T,
      planSnapshot: TASTE,
      standeeIncluded: TASTE.includedStandeeCount,
      amountPaise: TASTE.priceMonthlyPaise,
      paymentRecordId,
      via: 'WEBHOOK' as const,
    };

    await applyPaidPeriod(input);
    // The same payment applied again — a replayed webhook, or the reconciler.
    await applyPaidPeriod({ ...input, paidAt: new Date(T.getTime() + 3_600_000) });

    const feed = await feedFor(owner.id);
    expect(feed).toHaveLength(1);
    expect(feed[0].title).toContain('Payment received');
  });
});
