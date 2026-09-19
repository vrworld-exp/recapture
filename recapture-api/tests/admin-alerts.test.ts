// tests/admin-alerts.test.ts
//
// G4 — `alertAdmins`. What this file pins:
//   • ONE notification, addressed as a USERS list of every ADMIN — never a
//     broadcast (`audienceType: 'ALL'`), never a rep or an owner.
//   • It NEVER THROWS: no admins → logged, resolves 0; a failed write →
//     logged, resolves 0. Every caller is behind a webhook 200 or a sweep.
//   • Title and message are clipped to the model's caps, not rejected.
//   • The action deep-links the admin panel when a catalog is named.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Notification } from '@/models/Notification';
import { User } from '@/models/User';
import { alertAdmins } from '@/services/subscription/adminAlerts';
import { emitted, makeUser } from './helpers/subscriptionPayments';

let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([User.deleteMany({}), Notification.deleteMany({})]);
});

describe('alertAdmins', () => {
  it('writes one USERS notification naming every ADMIN and nobody else', async () => {
    const a1 = await makeUser('ADMIN');
    const a2 = await makeUser('ADMIN');
    await makeUser('SALES_REP');
    await makeUser('USER');
    await makeUser('MODEL_ARTIST');
    const catalogId = new Types.ObjectId();

    const count = await alertAdmins({
      kind: 'DISPUTE',
      catalogId,
      title: 'Chargeback opened',
      message: 'Dispute disp_1 on payment pay_1.',
      detail: 'amount=119900',
    });

    expect(count).toBe(2);
    const rows = await Notification.find({}).lean().exec();
    expect(rows).toHaveLength(1);
    const row = rows[0]!;
    expect(row.audienceType).toBe('USERS');
    expect(row.audienceUserIds!.map(String).sort()).toEqual([String(a1.id), String(a2.id)].sort());
    expect(row.kind).toBe('SYSTEM');
    expect(row.title).toBe('Chargeback opened');
    expect(row.message).toBe('Dispute disp_1 on payment pay_1.');
    expect(row.detail).toBe('amount=119900');
    expect(row.action).toMatchObject({ url: `/admin/subscriptions/${catalogId.toHexString()}` });
    expect(row.deletedAt).toBeNull();

    expect(console.error).toHaveBeenCalledWith(
      expect.stringContaining(`[subscription-alert] DISPUTE catalog=${catalogId.toHexString()}`)
    );
    expect(emitted('admin_alert_sent')).toEqual([{ kind: 'DISPUTE', recipients: 2 }]);
  });

  it('with no ADMIN users: logs, writes nothing, resolves 0, does not throw', async () => {
    await makeUser('SALES_REP');
    const count = await alertAdmins({
      kind: 'AMOUNT_MISMATCH',
      title: 't',
      message: 'm',
    });
    expect(count).toBe(0);
    expect(await Notification.countDocuments({})).toBe(0);
    expect(console.error).toHaveBeenCalledWith(expect.stringContaining('no ADMIN users'));
    expect(emitted('admin_alert_sent')).toEqual([]);
  });

  it('a failed write is logged and swallowed', async () => {
    await makeUser('ADMIN');
    vi.spyOn(Notification, 'create').mockRejectedValueOnce(new Error('disk on fire'));
    await expect(
      alertAdmins({ kind: 'ENTITLEMENT_FAILED', title: 't', message: 'm' })
    ).resolves.toBe(0);
    expect(console.error).toHaveBeenCalledWith(expect.stringContaining('disk on fire'));
  });

  it('clips an over-long title and message rather than failing validation', async () => {
    await makeUser('ADMIN');
    const count = await alertAdmins({
      kind: 'DUPLICATE_SUSPECTED',
      title: 'T'.repeat(200),
      message: 'M'.repeat(2000),
    });
    expect(count).toBe(1);
    const row = (await Notification.findOne({}).lean().exec())!;
    expect(row.title.length).toBeLessThanOrEqual(80);
    expect(row.message.length).toBeLessThanOrEqual(500);
    expect(row.title.endsWith('…')).toBe(true);
  });

  it('omits the action when no catalog is named', async () => {
    await makeUser('ADMIN');
    await alertAdmins({ kind: 'UNKNOWN_ORDER', title: 't', message: 'm' });
    const row = (await Notification.findOne({}).lean().exec())!;
    expect(row.action ?? null).toBeNull();
  });
});
