// tests/remote-config-tilt-bands.test.ts
//
// GET /remote-config — the 0–180° camera-tilt pitch bands (BOTTOM=low [0,40) /
// EYE=mid [40,110) / TOP=high [110,180]) and their wire shape. The band
// entries use the CLIENT's exact keys (`id`/`minDegrees`/`maxDegrees`/
// `segments`) so `CaptureConfig.fromMap` parses the payload with no mapping
// layer — this file is the cross-codebase contract test for that shape.
// Hermetic: in-memory MongoDB backs the ClientConfig store.
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import request from 'supertest';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { ClientConfig } from '@/models/ClientConfig';
import {
  remoteConfigSchema,
  DEFAULT_REMOTE_CONFIG,
} from '@/validation/remoteConfigSchema';

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

// Asserted as LITERAL numbers on purpose — this is the cross-codebase contract
// with the client's bundled `CaptureConfig` defaults, not a derived value.
const EXPECTED_PITCH_BANDS = [
  { id: 'low', minDegrees: 0, maxDegrees: 40, segments: 12 },
  { id: 'mid', minDegrees: 40, maxDegrees: 110, segments: 10 },
  { id: 'high', minDegrees: 110, maxDegrees: 180, segments: 8 },
];

describe('remoteConfigSchema — 0–180° tilt bands', () => {
  it('accepts the baked defaults (self-consistency)', () => {
    const parsed = remoteConfigSchema.safeParse(DEFAULT_REMOTE_CONFIG);
    expect(parsed.success).toBe(true);
  });

  it('the baked default bands are exactly the new-scale values, tiling [0, 180]', () => {
    expect(DEFAULT_REMOTE_CONFIG.pitchBands).toEqual(EXPECTED_PITCH_BANDS);
    // No gap/overlap: each band's max is the next band's min.
    const [low, mid, high] = DEFAULT_REMOTE_CONFIG.pitchBands;
    expect(low.maxDegrees).toBe(mid.minDegrees);
    expect(mid.maxDegrees).toBe(high.minDegrees);
    expect(low.minDegrees).toBe(0);
    expect(high.maxDegrees).toBe(180);
  });

  it('accepts degrees up to 180 (the old ≤90 assumption is gone)', () => {
    const cfg = {
      ...DEFAULT_REMOTE_CONFIG,
      pitchBands: [{ id: 'high', minDegrees: 110, maxDegrees: 180, segments: 8 }],
    };
    expect(remoteConfigSchema.safeParse(cfg).success).toBe(true);
  });

  it('rejects degrees outside [0, 180] and the legacy {min,max,label} shape', () => {
    const over = {
      ...DEFAULT_REMOTE_CONFIG,
      pitchBands: [{ id: 'high', minDegrees: 110, maxDegrees: 181, segments: 8 }],
    };
    expect(remoteConfigSchema.safeParse(over).success).toBe(false);

    const negative = {
      ...DEFAULT_REMOTE_CONFIG,
      pitchBands: [{ id: 'low', minDegrees: -20, maxDegrees: 20, segments: 12 }],
    };
    expect(remoteConfigSchema.safeParse(negative).success).toBe(false);

    const legacyShape = {
      ...DEFAULT_REMOTE_CONFIG,
      pitchBands: [{ min: -20, max: 20, label: 'EYE' }],
    };
    expect(remoteConfigSchema.safeParse(legacyShape).success).toBe(false);
  });
});

describe('GET /remote-config — served tilt bands', () => {
  it('an empty store serves the new default bands (version bumped for cache rollover)', async () => {
    const res = await request(app).get('/remote-config');

    expect(res.status).toBe(200);
    expect(res.body.pitchBands).toEqual(EXPECTED_PITCH_BANDS);
    expect(res.body.version).toBeGreaterThanOrEqual(2);
  });

  it('a stored config on the OLD scale/shape rejects to the new defaults (never 5xx)', async () => {
    await ClientConfig.create({
      version: 1,
      pitchBands: [
        { min: -20, max: 20, label: 'EYE' },
        { min: 20, max: 60, label: 'TOP' },
        { min: -60, max: -20, label: 'LOW' },
      ],
      thresholds: DEFAULT_REMOTE_CONFIG.thresholds,
      segmentCounts: DEFAULT_REMOTE_CONFIG.segmentCounts,
      guided_capture_variant_segments:
        DEFAULT_REMOTE_CONFIG.guided_capture_variant_segments,
    });

    const res = await request(app).get('/remote-config');

    expect(res.status).toBe(200); // reject-to-defaults, not an error
    expect(res.body.pitchBands).toEqual(EXPECTED_PITCH_BANDS);
    expect(res.body.version).toBe(DEFAULT_REMOTE_CONFIG.version);
  });
});
