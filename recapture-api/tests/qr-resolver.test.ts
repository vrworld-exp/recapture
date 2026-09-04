// tests/qr-resolver.test.ts
//
// Stage 3: the public resolver — GET /r/:code, the first customer-facing
// surface in this API and the only one whose client is a phone camera.
//
// TWO ASSERTIONS HERE CARRY THE SUITE.
//
// The first is that a THROWN ERROR still renders HTML. The whole envelope
// carve-out exists so that a database outage shows a diner a sentence instead
// of `{"status":"error","code":"INTERNAL_ERROR"}`, and nothing else in the
// suite proves the router's terminal handler actually catches — delete the
// four-argument signature and every other test here still passes.
//
// The second is that the redirect Location contains no `/r/`. Activation writes
// the resolver's own URL into `catalog.publicUrl`, so a resolver that redirects
// there redirects to itself; the browser follows it to its redirect limit and
// every standee in the field is a dead link. That loop is invisible to a unit
// test that only checks for a 302 — it shows up as an error page on a phone in
// a restaurant. (C6 in the same-day-activation preflight.)
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { QrCode } from '@/models/QrCode';
import { QrCodeAssignment } from '@/models/QrCodeAssignment';
import { QrScanDaily } from '@/models/QrScanDaily';
import { utcDay } from '@/services/qrResolverService';

const app = createApp();
let mongod: MongoMemoryServer;

const RESOLVER_BASE = 'https://scan.test';
const MIRAGE_BASE = 'https://menu.test';
const WEB_APP_BASE = 'https://app.test';

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  // The scan rollup is an upsert against a unique index; without the index a
  // concurrent-scan regression would silently pass here.
  await QrCode.syncIndexes();
  await QrScanDaily.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  Object.assign(env, {
    PUBLIC_RESOLVER_BASE_URL: RESOLVER_BASE,
    MIRAGE_PUBLIC_BASE_URL: MIRAGE_BASE,
    WEB_APP_BASE_URL: WEB_APP_BASE,
  });
  // The analytics sink echoes to console outside production, and the resolver
  // logs its swallowed failures — neither is under test here.
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  await QrCode.deleteMany({});
  await QrCodeAssignment.deleteMany({});
  await QrScanDaily.deleteMany({});
  await Catalog.deleteMany({});
});

/** A minted, unassigned code — a standee sitting in a box. */
async function mint(code: string): Promise<Types.ObjectId> {
  const doc = await QrCode.create({
    code,
    batchId: new Types.ObjectId(),
    state: 'UNASSIGNED',
    deletedAt: null,
  });
  return doc._id as Types.ObjectId;
}

/**
 * Points a minted code at a catalog, the way stage 4's activation does: opens a
 * ledger row, caches its id on the code, and — crucially for the C6 test —
 * writes the RESOLVER's own URL into `catalog.publicUrl`. A resolver that
 * redirected to `publicUrl` would therefore self-redirect, which is exactly
 * what the Location assertions below catch.
 */
async function activate(
  code: string,
  opts: { mirageRestaurantId?: string } = {}
): Promise<{ catalogId: Types.ObjectId; assignmentId: Types.ObjectId }> {
  const userId = new Types.ObjectId();
  const catalog = await Catalog.create({
    userId,
    name: `Catalog ${code}`,
    ...(opts.mirageRestaurantId
      ? {
          mirageRestaurantId: opts.mirageRestaurantId,
          mirageProvisionedAt: new Date(),
          publicUrlScheme: 'MIRAGE_OBJECT_ID' as const,
        }
      : {}),
    publicUrl: `${RESOLVER_BASE}/r/${code}`,
  });

  const qr = await QrCode.findOne({ code }).exec();
  if (!qr) throw new Error(`test setup: ${code} was never minted`);

  const assignment = await QrCodeAssignment.create({
    qrCodeId: qr._id,
    catalogId: catalog._id,
    assignedAt: new Date(),
    assignedByUserId: userId,
  });

  qr.state = 'ACTIVE';
  qr.catalogId = catalog._id as Types.ObjectId;
  qr.currentAssignmentId = assignment._id as Types.ObjectId;
  qr.activatedAt = new Date();
  await qr.save();

  return {
    catalogId: catalog._id as Types.ObjectId,
    assignmentId: assignment._id as Types.ObjectId,
  };
}

/** True when the body is a JSON document — the one thing a diner must never get. */
function parsesAsJson(body: string): boolean {
  try {
    JSON.parse(body);
    return true;
  } catch {
    return false;
  }
}

describe('the four code states', () => {
  it('ACTIVE + published redirects to the Mirage menu', async () => {
    await mint('ABCD2345');
    await activate('ABCD2345', { mirageRestaurantId: '507f1f77bcf86cd799439011' });

    const res = await request(app).get('/r/ABCD2345');

    expect(res.status).toBe(302);
    expect(res.headers.location).toBe(`${MIRAGE_BASE}/507f1f77bcf86cd799439011`);
  });

  it('UNASSIGNED renders the "not live yet" page, not a redirect', async () => {
    await mint('BBBB2222');

    const res = await request(app).get('/r/BBBB2222');

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/^text\/html/);
    expect(res.text).toContain('live yet');
  });

  it('RETIRED renders the "replaced" page', async () => {
    await mint('CCCC3333');
    await QrCode.updateOne({ code: 'CCCC3333' }, { state: 'RETIRED' }).exec();

    const res = await request(app).get('/r/CCCC3333');

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/^text\/html/);
    expect(res.text).toContain('been replaced');
  });

  it('an unknown code renders a page, never a 404', async () => {
    const res = await request(app).get('/r/DDDD4444');

    // A 404 here would fall through to `notFound` and hand the diner the JSON
    // envelope off a printed standee.
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/^text\/html/);
  });
});

describe('the redirect target (C6 — the self-redirect loop)', () => {
  it('derives the Location from mirageRestaurantId and never from publicUrl', async () => {
    await mint('EEEE5555');
    await activate('EEEE5555', { mirageRestaurantId: '507f1f77bcf86cd799439022' });

    const res = await request(app).get('/r/EEEE5555');
    const location = res.headers.location;

    // `catalog.publicUrl` is `https://scan.test/r/EEEE5555` — the request that
    // just arrived. All three assertions are the same bug seen three ways.
    expect(location).not.toContain('/r/');
    expect(location).not.toContain('/r/EEEE5555');
    expect(location).toBe(`${MIRAGE_BASE}/507f1f77bcf86cd799439022`);
  });

  it('is a 302, not a 301', async () => {
    await mint('FFFF6666');
    await activate('FFFF6666', { mirageRestaurantId: '507f1f77bcf86cd799439033' });

    const res = await request(app).get('/r/FFFF6666');

    // A 301 is cached by the browser more or less forever: it would survive the
    // code being retired or repointed, with no request ever reaching us.
    expect(res.status).toBe(302);
    expect(res.status).not.toBe(301);
  });

  it('an activated but unpublished catalog renders "not live yet", not a broken redirect', async () => {
    await mint('GGGG7777');
    await activate('GGGG7777'); // provisioned nothing — no mirageRestaurantId

    const res = await request(app).get('/r/GGGG7777');

    // The normal state for the first minutes of a rep visit. A 302 here would
    // point at `undefined/undefined`.
    expect(res.status).toBe(200);
    expect(res.headers.location).toBeUndefined();
    expect(res.text).toContain('live yet');
  });
});

describe('never JSON', () => {
  it.each([
    ['UNASSIGNED', 'HHHH8888', async () => void (await mint('HHHH8888'))],
    [
      'RETIRED',
      'JJJJ9999',
      async () => {
        await mint('JJJJ9999');
        await QrCode.updateOne({ code: 'JJJJ9999' }, { state: 'RETIRED' }).exec();
      },
    ],
    ['unknown', 'KKKK0000', async () => undefined],
  ])('%s answers text/html with a body that does not parse as JSON', async (_label, code, setup) => {
    await setup();

    const res = await request(app).get(`/r/${code}`);

    expect(res.headers['content-type']).toMatch(/^text\/html/);
    // Explicit rather than a snapshot: this is the brief's non-negotiable and
    // it should fail by name, not as a diff nobody reads.
    expect(parsesAsJson(res.text)).toBe(false);
    expect(res.text).toContain('<!doctype html>');
  });
});

describe('the terminal error handler (the carve-out)', () => {
  it('renders the fallback page when the resolver throws', async () => {
    vi.spyOn(QrCode, 'findOne').mockImplementation(() => {
      throw new Error('database is down');
    });

    const res = await request(app).get('/r/KKKK1111');

    // THE MOST IMPORTANT ASSERTION IN THE STAGE. Without the router's own
    // four-argument handler this is a 500 carrying the JSON envelope.
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/^text\/html/);
    expect(res.text).toContain('Something went wrong');
    expect(parsesAsJson(res.text)).toBe(false);
  });

  it('sends no-store on the error page too', async () => {
    vi.spyOn(QrCode, 'findOne').mockImplementation(() => {
      throw new Error('database is down');
    });

    const res = await request(app).get('/r/MMMM2222');

    // Asserted alongside the copy so this cannot quietly pass by rendering some
    // OTHER fallback that also sends no-store.
    expect(res.text).toContain('Something went wrong');
    expect(res.headers['cache-control']).toBe('no-store');
  });
});

describe('enumeration safety', () => {
  it('renders byte-identical pages for an unminted and a minted-but-unassigned code', async () => {
    // With no web app configured there is no code interpolated anywhere, so the
    // two responses are identical down to the byte.
    Object.assign(env, { WEB_APP_BASE_URL: undefined });
    await mint('NNNN3333');

    const unassigned = await request(app).get('/r/NNNN3333');
    const unknown = await request(app).get('/r/PPPP4444');

    expect(unknown.status).toBe(unassigned.status);
    expect(unknown.headers['content-type']).toBe(unassigned.headers['content-type']);
    expect(unknown.text).toBe(unassigned.text);
  });

  it('differs only by the scanned code once the rep link is configured', async () => {
    await mint('QQQQ5555');

    const unassigned = await request(app).get('/r/QQQQ5555');
    const unknown = await request(app).get('/r/RRRR6666');

    expect(unknown.status).toBe(unassigned.status);
    expect(unknown.headers['content-type']).toBe(unassigned.headers['content-type']);
    // The rep activation link carries the code — the value the scanner put in
    // the URL and therefore already knows. Fold it out and nothing else is
    // left: the response says nothing about which codes have been minted.
    expect(unknown.text.replace('RRRR6666', '<CODE>')).toBe(
      unassigned.text.replace('QQQQ5555', '<CODE>')
    );
    expect(unknown.text.length).toBe(unassigned.text.length);
  });
});

describe('input handling', () => {
  it('never queries the database for a code that cannot exist', async () => {
    const findOne = vi.spyOn(QrCode, 'findOne');

    const bad = await request(app).get('/r/!!!');
    const short = await request(app).get('/r/ABC');

    // This is what keeps a scan-flood of garbage against a public URL from
    // becoming a query-flood against Mongo.
    expect(findOne).not.toHaveBeenCalled();
    expect(bad.status).toBe(200);
    expect(short.status).toBe(200);
    expect(bad.headers['content-type']).toMatch(/^text\/html/);
    expect(short.headers['content-type']).toMatch(/^text\/html/);
  });

  it('resolves the printed form of a code — lowercase and hyphenated', async () => {
    await mint('ABCD2345');
    await activate('ABCD2345', { mirageRestaurantId: '507f1f77bcf86cd799439044' });

    const res = await request(app).get('/r/abcd-2345');

    expect(res.status).toBe(302);
    expect(res.headers.location).toBe(`${MIRAGE_BASE}/507f1f77bcf86cd799439044`);
  });
});

describe('caching', () => {
  it('sends no-store on the redirect', async () => {
    await mint('SSSS7777');
    await activate('SSSS7777', { mirageRestaurantId: '507f1f77bcf86cd799439055' });

    const res = await request(app).get('/r/SSSS7777');

    // A code activated five minutes from now must not be shadowed by a cached
    // response sitting in a phone browser or a CDN.
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('sends no-store on every fallback', async () => {
    await mint('TTTT8888');
    await mint('VVVV9999');
    await QrCode.updateOne({ code: 'VVVV9999' }, { state: 'RETIRED' }).exec();

    for (const code of ['TTTT8888', 'VVVV9999', 'WWWW0000']) {
      const res = await request(app).get(`/r/${code}`);
      expect(res.headers['cache-control']).toBe('no-store');
    }
  });
});

describe('the fallback pages themselves', () => {
  it('make no external request', async () => {
    await mint('XXXX1111');

    const res = await request(app).get('/r/XXXX1111');

    // No stylesheet, no font, no script, no image, no beacon: a diner on a bad
    // restaurant wifi must get the whole page in one response.
    expect(res.text).not.toMatch(/<link\b/i);
    expect(res.text).not.toMatch(/<script\b/i);
    expect(res.text).not.toMatch(/<img\b/i);
    expect(res.text).not.toMatch(/@import/i);
    expect(res.text).not.toMatch(/url\(\s*['"]?https?:/i);
    // The only absolute URL on the page is the rep's activation link — a
    // navigation the diner never takes, not a subresource the page fetches.
    const absolute = res.text.match(/https?:\/\/[^\s"'<>]+/g) ?? [];
    expect(absolute).toEqual([`${WEB_APP_BASE}/rep/activate?code=XXXX1111`]);
  });

  it('drops the rep link rather than rendering a broken one when the web app is unconfigured', async () => {
    Object.assign(env, { WEB_APP_BASE_URL: undefined });
    await mint('YYYY2222');

    const res = await request(app).get('/r/YYYY2222');

    expect(res.text).not.toContain('undefined');
    expect(res.text).not.toContain('/rep/activate');
    expect(res.text).toContain('live yet');
  });
});

describe('scan recording', () => {
  it('counts a scan against the assignment that was live when it happened', async () => {
    await mint('ZZZZ3333');
    const first = await activate('ZZZZ3333', { mirageRestaurantId: '507f1f77bcf86cd799439066' });

    await request(app).get('/r/ZZZZ3333');

    // Repoint the standee at a second restaurant, the way replacing a mapping
    // does: close the open ledger row, open a new one, move the cached head.
    const secondUserId = new Types.ObjectId();
    const secondCatalog = await Catalog.create({
      userId: secondUserId,
      name: 'The second restaurant',
      mirageRestaurantId: '507f1f77bcf86cd799439077',
      mirageProvisionedAt: new Date(),
      publicUrl: `${RESOLVER_BASE}/r/ZZZZ3333`,
      publicUrlScheme: 'MIRAGE_OBJECT_ID',
    });
    await QrCodeAssignment.updateOne({ _id: first.assignmentId }, { unassignedAt: new Date() });
    const qr = await QrCode.findOne({ code: 'ZZZZ3333' }).exec();
    const secondAssignment = await QrCodeAssignment.create({
      qrCodeId: qr!._id,
      catalogId: secondCatalog._id,
      assignedAt: new Date(),
      assignedByUserId: secondUserId,
    });
    qr!.catalogId = secondCatalog._id as Types.ObjectId;
    qr!.currentAssignmentId = secondAssignment._id as Types.ObjectId;
    await qr!.save();

    await request(app).get('/r/ZZZZ3333');

    const rows = await QrScanDaily.find({ qrCodeId: qr!._id }).lean().exec();
    expect(rows).toHaveLength(2);

    const firstRow = rows.find((r) => String(r.assignmentId) === String(first.assignmentId));
    const secondRow = rows.find(
      (r) => String(r.assignmentId) === String(secondAssignment._id)
    );
    // Repointing a code must not retroactively move history onto the new
    // restaurant: the first row is untouched, the second starts from scratch.
    expect(firstRow?.count).toBe(1);
    expect(secondRow?.count).toBe(1);
    expect(firstRow?.day).toBe(utcDay(new Date()));
  });

  it('accumulates repeat scans into one row per code, assignment and UTC day', async () => {
    await mint('AAAA4444');
    const { assignmentId } = await activate('AAAA4444', {
      mirageRestaurantId: '507f1f77bcf86cd799439088',
    });

    await request(app).get('/r/AAAA4444');
    await request(app).get('/r/AAAA4444');
    await request(app).get('/r/AAAA4444');

    const rows = await QrScanDaily.find({ assignmentId }).lean().exec();
    expect(rows).toHaveLength(1);
    expect(rows[0].count).toBe(3);
  });

  it('cannot break the redirect when it fails', async () => {
    await mint('BBBB5555');
    await activate('BBBB5555', { mirageRestaurantId: '507f1f77bcf86cd799439099' });

    vi.spyOn(QrScanDaily, 'updateOne').mockReturnValue({
      exec: () => Promise.reject(new Error('rollup write failed')),
    } as unknown as ReturnType<typeof QrScanDaily.updateOne>);

    const res = await request(app).get('/r/BBBB5555');

    // A metrics write must never be able to take a restaurant's menu down.
    expect(res.status).toBe(302);
    expect(res.headers.location).toBe(`${MIRAGE_BASE}/507f1f77bcf86cd799439099`);
  });

  it('records nothing for a code that never resolves', async () => {
    await mint('CCCC6666');

    await request(app).get('/r/CCCC6666');
    await request(app).get('/r/DDDD7777');

    expect(await QrScanDaily.countDocuments({})).toBe(0);
  });
});
