// tests/subscription-pending-payment.test.ts
//
// Requirement 2: a rep or staff member publishes a restaurant nobody has paid
// for. The publish goes through, a deadline runs, and when it expires the
// CUSTOMER PAGE is switched off.
//
// What this file exists to pin, in order of how much a mistake would cost:
//   • A PAID restaurant's page can never be taken down by this feature. That is
//     one code path (`status: 'PENDING_PAYMENT'`), guarded twice — the sweep's
//     conditional update and the processor's re-read — and AC-4's promise
//     depends on both.
//   • One window ever, per OWNER, across deleted catalogs — the `trialUsedAt`
//     rule applied to `pendingPaymentUsedAt`, so delete-and-republish does not
//     mint a fresh free week.
//   • An owner publishing their own catalog gets NO window. If they did, the
//     paywall would be decorative.
//   • The window is entitled to 3D but CAPPED, so a rep cannot publish thirty
//     free 3D dishes on a restaurant that owes us money.
//   • Paying, comping or starting a trial clears the deadline AND brings the
//     page back.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Catalog } from '@/models/Catalog';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { Job } from '@/models/Job';
import { Notification } from '@/models/Notification';
import { PaymentRecord } from '@/models/PaymentRecord';
import { ReminderLog } from '@/models/ReminderLog';
import {
  SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE,
  SUBSCRIPTION_PAGE_STATE_JOB_TYPE,
} from '@/models/types/job.types';
import { User } from '@/models/User';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import { evaluateSubscriptionGate } from '@/services/subscription/subscriptionGate';
import { runSubscriptionSweep } from '@/services/subscription/lifecycleSweep';
import {
  applyComp,
  applyPaidPeriod,
  getSubscriptionStatus,
  startTrial,
} from '@/services/subscription/subscriptionService';
import {
  openPendingPaymentWindowForPublish,
  roleMayOpenPendingPayment,
  startPendingPayment,
} from '@/services/subscription/pendingPaymentService';
import {
  desiredPageStateFor,
  type PageStateJobPayload,
} from '@/services/subscription/pageStateJobs';
import { DAY_MS, makeUser, seedCatalog, seedSubscription } from './helpers/subscriptionPayments';

let mongod: MongoMemoryServer;

/** A fixed instant, so every "T − 1 s" below is exact. */
const T = new Date('2026-10-01T03:00:00.000Z');
const WINDOW_MS = DEFAULT_PLAN_CATALOG.pendingPaymentDays * DAY_MS;
const before = (when: Date, ms = 1000): Date => new Date(when.getTime() - ms);

const repActor = (id: Types.ObjectId) => ({ userId: id, role: 'SALES_REP' as const });
const ownerActor = (id: Types.ObjectId) => ({ userId: id, role: 'USER' as const });

async function pageStateJobs(): Promise<PageStateJobPayload[]> {
  const jobs = await Job.find({ jobType: SUBSCRIPTION_PAGE_STATE_JOB_TYPE })
    .sort({ createdAt: 1 })
    .lean()
    .exec();
  return jobs.map((j) => j.payload as unknown as PageStateJobPayload);
}

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([
    Catalog.syncIndexes(),
    CatalogSubscription.syncIndexes(),
    Job.syncIndexes(),
    ReminderLog.syncIndexes(),
    Notification.syncIndexes(),
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
    PaymentRecord.deleteMany({}),
    Job.deleteMany({}),
    ReminderLog.deleteMany({}),
    Notification.deleteMany({}),
  ]);
});

// ── Who may open one ────────────────────────────────────────────────────────

describe('who may open a window', () => {
  it('is everyone at or above SALES_REP, and no plain USER', () => {
    expect(roleMayOpenPendingPayment('SALES_REP')).toBe(true);
    expect(roleMayOpenPendingPayment('MODEL_ARTIST')).toBe(true);
    expect(roleMayOpenPendingPayment('ADMIN')).toBe(true);
    // THE LOAD-BEARING ONE. An owner who could mint their own free week by
    // pressing Publish would make the whole paywall decorative.
    expect(roleMayOpenPendingPayment('USER')).toBe(false);
  });

  it('opens nothing for an owner publishing their own catalog', async () => {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    const opened = await openPendingPaymentWindowForPublish(
      catalogId,
      owner.id,
      ownerActor(owner.id),
      T
    );
    expect(opened).toBe(false);
    expect(await CatalogSubscription.findOne({ catalogId })).toBeNull();
  });
});

// ── Opening one ─────────────────────────────────────────────────────────────

describe('startPendingPayment', () => {
  it('opens a capped, entitled window whose periodEnd IS the deadline', async () => {
    const owner = await makeUser();
    const rep = await makeUser('SALES_REP');
    const catalogId = await seedCatalog(owner.id);

    const result = await startPendingPayment(catalogId, owner.id, repActor(rep.id), T);
    expect(result.outcome).toBe('STARTED');
    expect(result.paymentDueAt).toEqual(new Date(T.getTime() + WINDOW_MS));

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row).toMatchObject({
      status: 'PENDING_PAYMENT',
      source: 'REP_PUBLISH',
      // No grace behind it: `periodEnd` is the instant the page goes dark.
      periodEnd: new Date(T.getTime() + WINDOW_MS),
      threeDDishCap: DEFAULT_PLAN_CATALOG.trialThreeDCap,
    });
    expect(row?.graceEndsAt).toBeUndefined();
    expect(row?.pendingPaymentUsedAt).toEqual(T);
    expect(row?.pendingPaymentActivatedBy?.role).toBe('SALES_REP');
    // It must NOT spend the restaurant's one free trial.
    expect(row?.trialUsedAt).toBeUndefined();
  });

  it('tells Mirage the deadline, with the page still live', async () => {
    const owner = await makeUser();
    const rep = await makeUser('SALES_REP');
    const catalogId = await seedCatalog(owner.id);
    await startPendingPayment(catalogId, owner.id, repActor(rep.id), T);

    expect(await pageStateJobs()).toEqual([
      {
        catalogId: catalogId.toHexString(),
        isPublished: true,
        paymentDueAt: new Date(T.getTime() + WINDOW_MS).toISOString(),
        reason: 'PENDING_PAYMENT_STARTED',
      },
    ]);
  });

  it('gives one window per OWNER, across a deleted catalog', async () => {
    const owner = await makeUser();
    const rep = await makeUser('SALES_REP');
    const firstCatalog = await seedCatalog(owner.id);
    expect((await startPendingPayment(firstCatalog, owner.id, repActor(rep.id), T)).outcome).toBe(
      'STARTED'
    );

    // DELETE /catalog is a hard delete, but the subscription row outlives it —
    // which is the whole reason `userId` is on that row.
    await Catalog.deleteOne({ _id: firstCatalog });
    const secondCatalog = await seedCatalog(owner.id);
    expect((await startPendingPayment(secondCatalog, owner.id, repActor(rep.id), T)).outcome).toBe(
      'ALREADY_USED'
    );
    expect(await CatalogSubscription.findOne({ catalogId: secondCatalog })).toBeNull();
  });

  it('refuses an owner who has paid before', async () => {
    const owner = await makeUser();
    const rep = await makeUser('SALES_REP');
    const catalogId = await seedCatalog(owner.id);
    await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'PAID',
      amountPaise: 119_900,
      currency: 'INR',
      initiatedBy: { userId: owner.id, role: 'USER' },
    });

    expect((await startPendingPayment(catalogId, owner.id, repActor(rep.id), T)).outcome).toBe(
      'NOT_ELIGIBLE'
    );
  });

  it('is idempotent on a second press: one window, no second deadline', async () => {
    const owner = await makeUser();
    const rep = await makeUser('SALES_REP');
    const catalogId = await seedCatalog(owner.id);

    await startPendingPayment(catalogId, owner.id, repActor(rep.id), T);
    const second = await startPendingPayment(
      catalogId,
      owner.id,
      repActor(rep.id),
      new Date(T.getTime() + 3 * DAY_MS)
    );
    expect(second.outcome).toBe('SUBSCRIPTION_ACTIVE');

    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(1);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    // The deadline did NOT move — a rep pressing Publish every day would
    // otherwise keep the restaurant free forever.
    expect(row?.periodEnd).toEqual(new Date(T.getTime() + WINDOW_MS));
  });

  it('leaves a live subscription alone', async () => {
    const owner = await makeUser();
    const rep = await makeUser('SALES_REP');
    const catalogId = await seedCatalog(owner.id);
    await seedSubscription(catalogId, owner.id, 'ACTIVE', { planId: 'TASTE' }, T);

    expect(
      await openPendingPaymentWindowForPublish(catalogId, owner.id, repActor(rep.id), T)
    ).toBe(false);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row?.status).toBe('ACTIVE');
    expect(row?.pendingPaymentUsedAt).toBeUndefined();
  });
});

// ── The gate ────────────────────────────────────────────────────────────────

describe('the publish gate over a window', () => {
  it('lets the publish through — that is the whole point', () => {
    const gates = evaluateSubscriptionGate({
      subscription: {
        status: 'PENDING_PAYMENT',
        threeDDishCap: 10,
        planId: undefined,
        planSnapshot: undefined,
      },
      threeDDishCount: 10,
    });
    expect(gates).toEqual([]);
  });

  it('still enforces the cap, so a rep cannot publish thirty free 3D dishes', () => {
    const gates = evaluateSubscriptionGate({
      subscription: {
        status: 'PENDING_PAYMENT',
        threeDDishCap: 10,
        planId: undefined,
        planSnapshot: undefined,
      },
      threeDDishCount: 11,
    });
    expect(gates).toHaveLength(1);
    expect(gates[0]?.code).toBe('SUBSCRIPTION_CAPACITY_EXCEEDED');
  });
});

// ── Expiry ──────────────────────────────────────────────────────────────────

describe('the sweep closing a window', () => {
  async function windowEndingAt(due: Date) {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    await seedSubscription(
      catalogId,
      owner.id,
      'PENDING_PAYMENT',
      {
        source: 'REP_PUBLISH',
        periodStart: new Date(due.getTime() - WINDOW_MS),
        periodEnd: due,
        threeDDishCap: 10,
        pendingPaymentUsedAt: new Date(due.getTime() - WINDOW_MS),
      },
      T
    );
    return { owner, catalogId };
  }

  it('changes nothing one second early (the D3 clock rule)', async () => {
    const { catalogId } = await windowEndingAt(T);
    const report = await runSubscriptionSweep(before(T));
    expect(report.toPageOff).toBe(0);
    expect((await CatalogSubscription.findOne({ catalogId }).lean())?.status).toBe(
      'PENDING_PAYMENT'
    );
    expect(await pageStateJobs()).toEqual([]);
  });

  it('switches the page off AT the deadline, and takes 3D with it', async () => {
    const { catalogId } = await windowEndingAt(T);
    const report = await runSubscriptionSweep(T);
    expect(report.toPageOff).toBe(1);
    expect(report.pageOffsEnqueued).toBe(1);
    // NOT counted as a pause: one means "a plan lapsed", the other means "a
    // live link died", and the runbook watches for the second.
    expect(report.toPaused).toBe(0);

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row?.status).toBe('PAUSED');
    expect(row?.pageDeactivatedAt).toEqual(T);

    expect(await pageStateJobs()).toEqual([
      {
        catalogId: catalogId.toHexString(),
        isPublished: false,
        paymentDueAt: T.toISOString(),
        reason: 'PENDING_PAYMENT_EXPIRED',
      },
    ]);
    const arJobs = await Job.find({ jobType: SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE }).lean().exec();
    expect(arJobs).toHaveLength(1);
    expect(arJobs[0]?.payload).toMatchObject({ enabled: false });
  });

  it('never routes a window through GRACE — no free extra week', async () => {
    const { catalogId } = await windowEndingAt(T);
    await runSubscriptionSweep(T);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row?.status).not.toBe('GRACE');
    expect(row?.graceEndsAt).toBeUndefined();
    expect(row?.graceFrom).toBeUndefined();
  });

  it('is idempotent: a second sweep enqueues nothing more', async () => {
    await windowEndingAt(T);
    await runSubscriptionSweep(T);
    const second = await runSubscriptionSweep(new Date(T.getTime() + DAY_MS));
    expect(second.toPageOff).toBe(0);
    expect(await pageStateJobs()).toHaveLength(1);
  });

  it('NEVER takes down a page whose plan merely lapsed (AC-4)', async () => {
    // The promise this protects: a restaurant that has paid keeps its photo menu
    // at the printed QR forever. The only route to `isPublished: false` is a row
    // that was PENDING_PAYMENT, and this one never was.
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    await seedSubscription(
      catalogId,
      owner.id,
      'GRACE',
      {
        planId: 'TASTE',
        periodEnd: new Date(T.getTime() - 8 * DAY_MS),
        graceEndsAt: new Date(T.getTime() - DAY_MS),
        graceFrom: 'ACTIVE',
      },
      T
    );

    const report = await runSubscriptionSweep(T);
    expect(report.toPaused).toBe(1);
    expect(report.toPageOff).toBe(0);
    expect(await pageStateJobs()).toEqual([]);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row?.pageDeactivatedAt).toBeUndefined();
  });
});

// ── The first-publish ordering ──────────────────────────────────────────────

describe('a window opened before the restaurant exists', () => {
  it('no-ops at enqueue time, because there is nothing provisioned to write to', async () => {
    // THE FLOW THE WHOLE FEATURE IS ABOUT. `requestPublish` opens the window at
    // the top — before provisioning, because the row it writes is the row the
    // gate is about to read — so the job it enqueues names a catalog with no
    // `mirageRestaurantId`. Pinned here so the provisioning hook that covers it
    // (catalogProvisioningService.syncPageStateIfAnythingDue) cannot be deleted
    // as redundant.
    const owner = await makeUser();
    const rep = await makeUser('SALES_REP');
    const catalogId = await seedCatalog(owner.id);

    await startPendingPayment(catalogId, owner.id, repActor(rep.id), T);

    const catalog = await Catalog.findById(catalogId).lean().exec();
    expect(catalog?.mirageRestaurantId).toBeUndefined();
    // The job exists and is correct; it simply has nowhere to land yet.
    expect((await pageStateJobs())[0]).toMatchObject({
      isPublished: true,
      paymentDueAt: new Date(T.getTime() + WINDOW_MS).toISOString(),
    });
  });

  it('a DRAFT catalog still has a deadline to write — the page flag is what is withheld', async () => {
    // The desired state does not depend on `Catalog.status`; the processor
    // decides separately whether `isPublished` is ITS field to write. A first
    // publish provisions while the catalog is still DRAFT, and the banner has to
    // reach the page anyway.
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    await seedSubscription(
      catalogId,
      owner.id,
      'PENDING_PAYMENT',
      { source: 'REP_PUBLISH', periodEnd: new Date(T.getTime() + WINDOW_MS) },
      T
    );
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(desiredPageStateFor(row!)).toEqual({
      isPublished: true,
      paymentDueAt: new Date(T.getTime() + WINDOW_MS),
    });
  });
});

// ── The processor's desired state ───────────────────────────────────────────

describe('desiredPageStateFor', () => {
  it('keeps a running window live, with its deadline', () => {
    expect(
      desiredPageStateFor({ status: 'PENDING_PAYMENT', periodEnd: T })
    ).toEqual({ isPublished: true, paymentDueAt: T });
  });

  it('keeps an expired one dark, deadline retained for the copy', () => {
    expect(
      desiredPageStateFor({ status: 'PAUSED', periodEnd: T, pageDeactivatedAt: T })
    ).toEqual({ isPublished: false, paymentDueAt: T });
  });

  it('leaves a merely-lapsed row LIVE with nothing due', () => {
    // The second guard under AC-4: even if a stale expiry job somehow named this
    // catalog, the processor recomputes from the row and refuses to unpublish.
    expect(desiredPageStateFor({ status: 'PAUSED', periodEnd: T })).toEqual({
      isPublished: true,
      paymentDueAt: null,
    });
    expect(desiredPageStateFor({ status: 'ACTIVE', periodEnd: T })).toEqual({
      isPublished: true,
      paymentDueAt: null,
    });
  });
});

// ── Clearing the debt ───────────────────────────────────────────────────────

describe('clearing a window', () => {
  async function expiredWindow() {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    await seedSubscription(
      catalogId,
      owner.id,
      'PENDING_PAYMENT',
      {
        source: 'REP_PUBLISH',
        periodStart: new Date(T.getTime() - WINDOW_MS),
        periodEnd: T,
        threeDDishCap: 10,
        pendingPaymentUsedAt: new Date(T.getTime() - WINDOW_MS),
      },
      T
    );
    await runSubscriptionSweep(T);
    await Job.deleteMany({});
    return { owner, catalogId };
  }

  it('a payment brings the page back and clears the deadline', async () => {
    const { owner, catalogId } = await expiredWindow();
    const paidAt = new Date(T.getTime() + DAY_MS);

    const result = await applyPaidPeriod({
      catalogId,
      ownerUserId: owner.id,
      planId: 'TASTE',
      interval: 'MONTHLY',
      source: 'ONLINE',
      paidAt,
      planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
      standeeIncluded: 10,
      amountPaise: 119_900,
      // The ledger row the owner's "payment received" message is keyed on.
      paymentRecordId: new Types.ObjectId(),
      via: 'WEBHOOK',
    });

    expect(result.needsPageRestore).toBe(true);
    expect(result.needsArResume).toBe(true);

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row?.status).toBe('ACTIVE');
    expect(row?.pageDeactivatedAt).toBeNull();
    // The one-ever flag SURVIVES, exactly as trialUsedAt does.
    expect(row?.pendingPaymentUsedAt).toBeTruthy();

    expect(await pageStateJobs()).toEqual([
      {
        catalogId: catalogId.toHexString(),
        isPublished: true,
        paymentDueAt: null,
        reason: 'PAYMENT',
      },
    ]);
  });

  it('clears the deadline even when the window had not expired yet', async () => {
    // The page is already live here; what is wrong is the BANNER on it. A paid
    // restaurant must not keep telling its diners it switches off on Tuesday.
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    await startPendingPayment(catalogId, owner.id, repActor(owner.id), T);
    await Job.deleteMany({});

    const result = await applyPaidPeriod({
      catalogId,
      ownerUserId: owner.id,
      planId: 'TASTE',
      interval: 'MONTHLY',
      source: 'ONLINE',
      paidAt: new Date(T.getTime() + DAY_MS),
      planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
      standeeIncluded: 10,
      amountPaise: 119_900,
      // The ledger row the owner's "payment received" message is keyed on.
      paymentRecordId: new Types.ObjectId(),
      via: 'WEBHOOK',
    });
    expect(result.needsPageRestore).toBe(true);
    // Nothing to resume: the window was entitled to 3D all along.
    expect(result.needsArResume).toBe(false);
    expect((await pageStateJobs())[0]).toMatchObject({
      isPublished: true,
      paymentDueAt: null,
      reason: 'PAYMENT',
    });
  });

  it('a comp clears it too', async () => {
    const { owner, catalogId } = await expiredWindow();
    const result = await applyComp({
      catalogId,
      ownerUserId: owner.id,
      until: new Date(T.getTime() + 30 * DAY_MS),
      actor: { userId: owner.id, role: 'ADMIN' },
      note: 'pilot',
      now: new Date(T.getTime() + DAY_MS),
    });
    expect(result.needsPageRestore).toBe(true);
    expect((await pageStateJobs())[0]).toMatchObject({
      isPublished: true,
      paymentDueAt: null,
      reason: 'COMP',
    });
  });

  it('a trial SUPERSEDES a running window and clears the deadline', async () => {
    // The "(or free trial limit)" half of the requirement: a rep who published
    // first can still grant the free month afterwards, and must not be told the
    // restaurant "already has an active subscription".
    const owner = await makeUser();
    const rep = await makeUser('SALES_REP');
    const catalogId = await seedCatalog(owner.id);
    await startPendingPayment(catalogId, owner.id, repActor(rep.id), T);
    await Job.deleteMany({});

    const started = await startTrial(
      catalogId,
      owner.id,
      repActor(rep.id),
      'REP',
      new Date(T.getTime() + DAY_MS)
    );
    expect(started.outcome).toBe('STARTED');

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row?.status).toBe('TRIAL');
    expect(row?.trialUsedAt).toBeTruthy();
    expect(row?.pendingPaymentUsedAt).toBeTruthy();

    expect((await pageStateJobs())[0]).toMatchObject({
      isPublished: true,
      paymentDueAt: null,
      reason: 'TRIAL',
    });
  });

  it('the status DTO reports the deadline, then the dark page', async () => {
    const owner = await makeUser();
    const rep = await makeUser('SALES_REP');
    const catalogId = await seedCatalog(owner.id);
    await startPendingPayment(catalogId, owner.id, repActor(rep.id), T);

    const running = await getSubscriptionStatus(catalogId, owner.id, T);
    expect(running.status).toBe('PENDING_PAYMENT');
    expect(running.paymentDueAt).toBe(new Date(T.getTime() + WINDOW_MS).toISOString());
    expect(running.isPageDeactivated).toBe(false);
    expect(running.isEntitledTo3D).toBe(true);
    expect(running.daysLeft).toBe(DEFAULT_PLAN_CATALOG.pendingPaymentDays);

    const expiredAt = new Date(T.getTime() + WINDOW_MS);
    await runSubscriptionSweep(expiredAt);

    const dark = await getSubscriptionStatus(catalogId, owner.id, expiredAt);
    expect(dark.status).toBe('PAUSED');
    expect(dark.isPageDeactivated).toBe(true);
    expect(dark.paymentDueAt).toBe(expiredAt.toISOString());
    expect(dark.isEntitledTo3D).toBe(false);
    // Nothing is counting down any more; the copy says "it is off", not "in N days".
    expect(dark.daysLeft).toBeNull();
  });
});
