// tests/remote-config-variants.test.ts
//
// GET /remote-config — the guided_capture_variant_segments block (per
// capture-flow-variant segment counts, keyed by the CLIENT's band ids
// mid/high/low) plus the endpoint's caching contract around the payload
// change: ETag/304 still correct, defaults-fallback never 5xx. Hermetic:
// in-memory MongoDB backs the ClientConfig store.
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import request from 'supertest';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { ClientConfig } from '@/models/ClientConfig';
import { DEFAULT_REMOTE_CONFIG } from '@/validation/remoteConfigSchema';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await ClientConfig.deleteMany({});
});

// The block the client's bundled defaults mirror — asserted as LITERAL numbers
// on purpose (this is the cross-codebase contract, not a derived value).
const EXPECTED_VARIANT_SEGMENTS = {
  with_bottom: { mid: 16, high: 16, low: 16 },
  without_bottom: { mid: 24, high: 24 },
};

/** A stored config that satisfies the full served schema. */
function storedConfig(overrides: Record<string, unknown> = {}) {
  return {
    version: 7,
    pitchBands: DEFAULT_REMOTE_CONFIG.pitchBands,
    thresholds: DEFAULT_REMOTE_CONFIG.thresholds,
    segmentCounts: DEFAULT_REMOTE_CONFIG.segmentCounts,
    guided_capture_variant_segments: EXPECTED_VARIANT_SEGMENTS,
    ...overrides,
  };
}

describe('GET /remote-config — guided_capture_variant_segments', () => {
  it('the baked defaults carry the block with exactly the bundled numbers', async () => {
    const res = await request(app).get('/remote-config'); // empty store → defaults

    expect(res.status).toBe(200);
    expect(res.body.guided_capture_variant_segments).toEqual(EXPECTED_VARIANT_SEGMENTS);
    // The exported default matches what was served (one source of truth).
    expect(DEFAULT_REMOTE_CONFIG.guided_capture_variant_segments).toEqual(
      EXPECTED_VARIANT_SEGMENTS
    );
  });

  it('a stored config with a valid block is served as stored (remote override works)', async () => {
    await ClientConfig.create(
      storedConfig({
        guided_capture_variant_segments: {
          with_bottom: { mid: 10, high: 10, low: 10 },
          without_bottom: { mid: 15, high: 15 },
        },
      })
    );

    const res = await request(app).get('/remote-config');

    expect(res.status).toBe(200);
    expect(res.body.version).toBe(7);
    expect(res.body.guided_capture_variant_segments.without_bottom).toEqual({
      mid: 15,
      high: 15,
    });
  });

  it('a stored config MISSING the block fails validation → whole-document fallback to defaults (never 5xx)', async () => {
    const doc = storedConfig();
    delete (doc as Record<string, unknown>).guided_capture_variant_segments;
    await ClientConfig.create(doc);

    const res = await request(app).get('/remote-config');

    expect(res.status).toBe(200); // reject-to-defaults, not an error
    expect(res.body.version).toBe(DEFAULT_REMOTE_CONFIG.version);
    expect(res.body.guided_capture_variant_segments).toEqual(EXPECTED_VARIANT_SEGMENTS);
  });

  it('a malformed block (non-positive count) also rejects to defaults', async () => {
    await ClientConfig.create(
      storedConfig({
        guided_capture_variant_segments: {
          with_bottom: { mid: 0, high: 12, low: 12 },
          without_bottom: { mid: 18, high: 18 },
        },
      })
    );

    const res = await request(app).get('/remote-config');

    expect(res.status).toBe(200);
    expect(res.body.guided_capture_variant_segments).toEqual(EXPECTED_VARIANT_SEGMENTS);
  });
});

describe('GET /remote-config — ETag/304 across the payload change', () => {
  it('revalidation still works: matching If-None-Match → bodyless 304', async () => {
    const first = await request(app).get('/remote-config');
    expect(first.status).toBe(200);
    const etag = first.headers.etag;
    expect(etag).toBeTruthy();

    const second = await request(app).get('/remote-config').set('If-None-Match', etag);
    expect(second.status).toBe(304);
    expect(second.body).toEqual({});
  });

  it('the ETag changes when the served payload changes (block included in the hash)', async () => {
    const defaults = await request(app).get('/remote-config');

    await ClientConfig.create(
      storedConfig({
        guided_capture_variant_segments: {
          with_bottom: { mid: 11, high: 11, low: 11 },
          without_bottom: { mid: 17, high: 17 },
        },
      })
    );
    const stored = await request(app).get('/remote-config');

    expect(stored.status).toBe(200);
    expect(stored.headers.etag).not.toBe(defaults.headers.etag);

    // A client holding the OLD etag gets the new body, not a 304.
    const revalidated = await request(app)
      .get('/remote-config')
      .set('If-None-Match', defaults.headers.etag);
    expect(revalidated.status).toBe(200);
    expect(revalidated.body.guided_capture_variant_segments.with_bottom.mid).toBe(11);
  });
});
