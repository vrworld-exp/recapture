// tests/subscription-sweep.test.ts
//
// The lifecycle sweep (Stage 5). What this file exists to pin, in order:
//   • THE CLOCK RULE (D3): a sweep one second BEFORE `periodEnd` / `graceEndsAt`
//     changes nothing; one AT it moves the row. Late is fine; early never.
//   • `graceEndsAt` is EACH row's own `periodEnd + graceDays` (AC-3.1), not
//     "now + graceDays" — a sweep that ran hours late must not extend grace.
//   • ONE pause job per pause, and none for a row that paid under us (D4).
//   • The sweep never calls Mirage and never touches the catalog (AC-4.1,
//     D5): the only thing it enqueues is a job, and the only thing it writes
//     is the subscription row and the reminder rows.
//   • Reminders: one per catalog per milestone per period, deduped through
//     ReminderLog, carrying `expiresAt` (E44), with the right noun (E16).
//
// The clock is a fixed `now` handed to the sweep — the same thing the worker
// does with `new Date(nowMs)`, without fake timers under the Mongo driver.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Catalog } from '@/models/Catalog';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { Job } from '@/models/Job';
import { Notification } from '@/models/Notification';
import { ReminderLog } from '@/models/ReminderLog';
import { SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE } from '@/models/types/job.types';
import { User } from '@/models/User';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import { runSubscriptionSweep } from '@/services/subscription/lifecycleSweep';
import { FakeMirage } from './fixtures/mirageFake';
import { DAY_MS, emitted, makeUser, seedCatalog, seedSubscription } from './helpers/subscriptionPayments';

let mongod: MongoMemoryServer;
const mirage = new FakeMirage();
const GRACE_MS = DEFAULT_PLAN_CATALOG.graceDays * DAY_MS;

/** A fixed instant, so every "T − 1 s" below is exact. */
const T = new Date('2026-10-01T03:00:00.000Z');
const before = (when: Date, ms = 1000): Date => new Date(when.getTime() - ms);
const after = (when: Date, ms: number): Date => new Date(when.getTime() + ms);

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
  mirage.reset();
  setMirageClient(mirage);
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  resetMirageClient();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    Job.deleteMany({}),
    Notification.deleteMany({}),
    ReminderLog.deleteMany({}),
  ]);
});

async function ownerWithCatalog() {
  const owner = await makeUser();
  const catalogId = await seedCatalog(owner.id);
  return { owner, catalogId };
}

const pauseJobs = () =>
  Job.find({ jobType: SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE }).lean().exec();

describe('→ GRACE at periodEnd (D3, AC-3.1)', () => {
  it.each(['ACTIVE', 'TRIAL', 'COMPED'] as const)(
    '%s: nothing at T−1s; GRACE at T with graceEndsAt = T + graceDays and graceFrom set',
    async (status) => {
      const { owner, catalogId } = await ownerWithCatalog();
      await seedSubscription(catalogId, owner.id, status, {
        periodStart: before(T, 30 * DAY_MS),
        periodEnd: T,
      });

      const early = await runSubscriptionSweep(before(T));
      expect(early.toGrace).toBe(0);
      expect((await CatalogSubscription.findOne({ catalogId }).lean())?.status).toBe(status);

      const onTime = await runSubscriptionSweep(T);
      expect(onTime.toGrace).toBe(1);
      const row = await CatalogSubscription.findOne({ catalogId }).lean();
      expect(row?.status).toBe('GRACE');
      expect(row?.graceEndsAt?.getTime()).toBe(T.getTime() + GRACE_MS);
      expect(row?.graceFrom).toBe(status);
      expect(row?.periodEnd.getTime()).toBe(T.getTime());

      expect(emitted('subscription_state_changed')).toEqual([
        { catalog_id: catalogId.toHexString(), from: status, to: 'GRACE', by: 'SWEEP' },
      ]);
      // Grace is not a pause: no job, no Mirage.
      expect(await pauseJobs()).toHaveLength(0);
      expect(mirage.calls).toHaveLength(0);
    }
  );

  it('a LATE sweep anchors graceEndsAt on periodEnd, not on now', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await seedSubscription(catalogId, owner.id, 'ACTIVE', { periodEnd: T });

    await runSubscriptionSweep(after(T, 5 * 3_600_000)); // five hours late

    const row = await CatalogSubscription.findOne({ catalogId }).lean();
    expect(row?.graceEndsAt?.getTime()).toBe(T.getTime() + GRACE_MS);
  });

  it('leaves PAUSED, CANCELLED and GRACE rows with a past periodEnd alone', async () => {
    for (const status of ['PAUSED', 'CANCELLED'] as const) {
      const { owner, catalogId } = await ownerWithCatalog();
      await seedSubscription(catalogId, owner.id, status, { periodEnd: before(T, DAY_MS) });
    }
    const report = await runSubscriptionSweep(T);
    expect(report.toGrace).toBe(0);
    expect(await CatalogSubscription.countDocuments({ status: 'GRACE' })).toBe(0);
  });

  it('is idempotent: a second sweep at the same instant changes nothing', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await seedSubscription(catalogId, owner.id, 'ACTIVE', { periodEnd: T });

    await runSubscriptionSweep(T);
    const again = await runSubscriptionSweep(T);

    expect(again.toGrace).toBe(0);
    expect(await CatalogSubscription.countDocuments({ status: 'GRACE' })).toBe(1);
  });
});

describe('→ PAUSED at graceEndsAt (D3, D4)', () => {
  const G = after(T, GRACE_MS);

  async function inGrace() {
    const { owner, catalogId } = await ownerWithCatalog();
    await seedSubscription(catalogId, owner.id, 'GRACE', {
      periodEnd: T,
      graceEndsAt: G,
      graceFrom: 'ACTIVE',
    });
    return { owner, catalogId };
  }

  it('nothing at G−1s; PAUSED at G with ONE { enabled: false } job; a second sweep adds none', async () => {
    const { owner, catalogId } = await inGrace();

    const early = await runSubscriptionSweep(before(G));
    expect(early.toPaused).toBe(0);
    expect(await pauseJobs()).toHaveLength(0);

    const onTime = await runSubscriptionSweep(G);
    expect(onTime.toPaused).toBe(1);
    expect(onTime.pausesEnqueued).toBe(1);
    expect(onTime.resumesEnqueued).toBe(0);

    const row = await CatalogSubscription.findOne({ catalogId }).lean();
    expect(row?.status).toBe('PAUSED');
    expect(row?.pausedAt?.getTime()).toBe(G.getTime());

    const jobs = await pauseJobs();
    expect(jobs).toHaveLength(1);
    expect(jobs[0]).toMatchObject({
      state: 'QUEUED',
      userId: owner.id,
      priority: 10,
      payload: { catalogId: catalogId.toHexString(), enabled: false, reason: 'GRACE_EXPIRED' },
    });
    expect(jobs[0]?.projectId ?? null).toBeNull();

    const again = await runSubscriptionSweep(after(G, 600_000));
    expect(again.toPaused).toBe(0);
    expect(await pauseJobs()).toHaveLength(1);

    expect(emitted('subscription_state_changed')).toEqual([
      { catalog_id: catalogId.toHexString(), from: 'GRACE', to: 'PAUSED', by: 'SWEEP' },
    ]);
    // The sweep itself never talks to Mirage — the job does, later.
    expect(mirage.calls).toHaveLength(0);
  });

  it('a row that paid between the find and the update is not paused and gets no job (D4)', async () => {
    const { catalogId } = await inGrace();

    // Simulate the payment landing mid-sweep: the pause scan's read sees
    // GRACE, the conditional update then finds ACTIVE.
    const original = CatalogSubscription.find.bind(CatalogSubscription);
    vi.spyOn(CatalogSubscription, 'find').mockImplementation((...args) => {
      const query = original(...(args as Parameters<typeof original>));
      const filter = args[0] as { status?: unknown } | undefined;
      if (filter?.status !== 'GRACE') return query;
      const exec = query.exec.bind(query);
      query.exec = (async () => {
        const rows = await exec();
        await CatalogSubscription.updateOne(
          { catalogId },
          { $set: { status: 'ACTIVE', graceEndsAt: null, graceFrom: null } }
        ).exec();
        return rows;
      }) as typeof query.exec;
      return query;
    });

    const report = await runSubscriptionSweep(G);

    expect(report.toPaused).toBe(0);
    expect((await CatalogSubscription.findOne({ catalogId }).lean())?.status).toBe('ACTIVE');
    expect(await pauseJobs()).toHaveLength(0);
  });

  it('two sweeps at once move each row once and enqueue each job once', async () => {
    const rows = await Promise.all([inGrace(), inGrace(), inGrace()]);

    const [a, b] = await Promise.all([runSubscriptionSweep(G), runSubscriptionSweep(G)]);

    expect(a.toPaused + b.toPaused).toBe(rows.length);
    expect(await CatalogSubscription.countDocuments({ status: 'PAUSED' })).toBe(rows.length);
    expect(await pauseJobs()).toHaveLength(rows.length);
  });

  it('never touches the catalog document, its status, or its publish lock (D5, AC-4.1)', async () => {
    const { catalogId } = await inGrace();
    await Catalog.updateOne(
      { _id: catalogId },
      { $set: { status: 'PUBLISHED', publishedRevision: 3, activePublishRunId: new Types.ObjectId() } }
    ).exec();
    const beforeSweep = await Catalog.findById(catalogId).lean().exec();

    await runSubscriptionSweep(after(G, DAY_MS));

    const afterSweep = await Catalog.findById(catalogId).lean().exec();
    expect(afterSweep).toEqual(beforeSweep);
    expect(mirage.writes).toHaveLength(0);
  });

  it('a COMPED grandfather window lapses through GRACE to PAUSED like any plan (README C4)', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await seedSubscription(catalogId, owner.id, 'COMPED', {
      source: 'COMP',
      threeDDishCap: -1,
      periodEnd: T,
    });

    await runSubscriptionSweep(T);
    expect((await CatalogSubscription.findOne({ catalogId }).lean())?.status).toBe('GRACE');

    await runSubscriptionSweep(after(T, GRACE_MS));
    expect((await CatalogSubscription.findOne({ catalogId }).lean())?.status).toBe('PAUSED');
    expect(await pauseJobs()).toHaveLength(1);
  });

  it('emits subscription_sweep_ran with the counts, zeros included', async () => {
    const report = await runSubscriptionSweep(T);
    expect(report).toMatchObject({ toGrace: 0, toPaused: 0, remindersSent: 0 });
    const [event] = emitted('subscription_sweep_ran');
    expect(event).toMatchObject({ to_grace: 0, to_paused: 0 });
    expect(typeof event?.duration_ms).toBe('number');
  });
});

describe('in-app reminders (E14, E16, E44)', () => {
  const G = after(T, GRACE_MS);

  const ownerNotifications = (ownerId: Types.ObjectId) =>
    Notification.find({ audienceUserIds: ownerId }).sort({ createdAt: 1 }).lean().exec();

  it('sends T−7d once, T−1d once, GRACE_STARTED once, GRACE_MIDPOINT once — and nothing twice', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await seedSubscription(catalogId, owner.id, 'ACTIVE', {
      planId: 'TASTE',
      planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
      periodEnd: T,
    });

    // Eight days out: too early for anything.
    expect((await runSubscriptionSweep(before(T, 8 * DAY_MS))).remindersSent).toBe(0);

    // Seven days out, twice: one reminder.
    expect((await runSubscriptionSweep(before(T, 7 * DAY_MS))).remindersSent).toBe(1);
    expect((await runSubscriptionSweep(before(T, 6 * DAY_MS))).remindersSent).toBe(0);

    // One day out.
    expect((await runSubscriptionSweep(before(T, DAY_MS))).remindersSent).toBe(1);
    expect((await runSubscriptionSweep(before(T, 3_600_000))).remindersSent).toBe(0);

    // Lapse → GRACE_STARTED in the same sweep that moved the row.
    const lapse = await runSubscriptionSweep(T);
    expect(lapse.toGrace).toBe(1);
    expect(lapse.remindersSent).toBe(1);
    expect((await runSubscriptionSweep(after(T, DAY_MS))).remindersSent).toBe(0);

    // Midpoint of grace.
    expect((await runSubscriptionSweep(after(T, GRACE_MS / 2))).remindersSent).toBe(1);
    expect((await runSubscriptionSweep(after(T, GRACE_MS / 2 + DAY_MS))).remindersSent).toBe(0);

    const rows = await ownerNotifications(owner.id);
    expect(rows).toHaveLength(4);
    expect(rows.map((n) => n.title)).toEqual([
      'Your plan ends in 7 days',
      'Your plan ends in 1 day',
      'Payment overdue — 3D menu pauses soon',
      '3D menu pauses in 4 days',
    ]);
    for (const row of rows) {
      expect(row.kind).toBe('PAYMENT_DUE');
      expect(row.audienceType).toBe('USERS');
      expect(row.action).toMatchObject({ url: '/catalog/subscription' });
      // E44: nothing outlives the grace it is about.
      expect(row.expiresAt?.getTime()).toBe(G.getTime());
    }

    const log = await ReminderLog.find({ catalogId }).lean().exec();
    expect(log.map((r) => r.milestone).sort()).toEqual(
      ['GRACE_MIDPOINT', 'GRACE_STARTED', 'T_MINUS_1D', 'T_MINUS_7D'].sort()
    );
    expect(log.every((r) => r.channel === 'IN_APP')).toBe(true);
  });

  it('a trial says "free trial", a comp says "complimentary period" (E16)', async () => {
    const trial = await ownerWithCatalog();
    await seedSubscription(trial.catalogId, trial.owner.id, 'TRIAL', { periodEnd: T });
    const comp = await ownerWithCatalog();
    await seedSubscription(comp.catalogId, comp.owner.id, 'COMPED', {
      source: 'COMP',
      threeDDishCap: -1,
      periodEnd: T,
    });

    await runSubscriptionSweep(before(T, 7 * DAY_MS));
    await runSubscriptionSweep(T);

    const trialRows = await ownerNotifications(trial.owner.id);
    expect(trialRows.map((n) => n.title)).toEqual([
      'Your free trial ends in 7 days',
      'Your free trial has ended',
    ]);
    const compRows = await ownerNotifications(comp.owner.id);
    expect(compRows.map((n) => n.title)).toEqual([
      'Your complimentary period ends in 7 days',
      'Your complimentary period has ended',
    ]);
  });

  it('a first sweep after a long sleep sends the LATEST due milestone, not all four (E17)', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await seedSubscription(catalogId, owner.id, 'ACTIVE', { periodEnd: T });

    // The worker was asleep from T−8d until T+5d: the row lapses now, and
    // grace is already past its midpoint.
    const report = await runSubscriptionSweep(after(T, 5 * DAY_MS));

    expect(report.toGrace).toBe(1);
    expect(report.remindersSent).toBe(1);
    const rows = await ownerNotifications(owner.id);
    expect(rows.map((n) => n.title)).toEqual(['3D menu pauses in 2 days']);
  });

  it('a renewed period gets its reminders again — the key includes periodEnd', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await seedSubscription(catalogId, owner.id, 'ACTIVE', { periodEnd: T });
    await runSubscriptionSweep(before(T, 7 * DAY_MS));

    const nextEnd = after(T, 30 * DAY_MS);
    await CatalogSubscription.updateOne({ catalogId }, { $set: { periodEnd: nextEnd } }).exec();
    const report = await runSubscriptionSweep(before(nextEnd, 7 * DAY_MS));

    expect(report.remindersSent).toBe(1);
    expect(await ReminderLog.countDocuments({ catalogId, milestone: 'T_MINUS_7D' })).toBe(2);
  });

  it('two sweeps at once send each reminder once (the log row is the authority)', async () => {
    const { owner, catalogId } = await ownerWithCatalog();
    await seedSubscription(catalogId, owner.id, 'ACTIVE', { periodEnd: T });

    const at = before(T, 7 * DAY_MS);
    const [a, b] = await Promise.all([runSubscriptionSweep(at), runSubscriptionSweep(at)]);

    expect(a.remindersSent + b.remindersSent).toBe(1);
    expect(await ownerNotifications(owner.id)).toHaveLength(1);
  });
});
