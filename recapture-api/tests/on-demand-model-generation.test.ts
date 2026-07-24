// tests/on-demand-model-generation.test.ts
//
// The "Generate 3D model" button: the same server-side selection as automatic
// generation, triggered by a person. Every test here is either about NOT
// spending money twice, or about the trace that makes a refusal diagnosable.
//
// The manifest is the COMMITTED PACKER FIXTURE, not a hand-written one. A
// hand-written manifest drifts from what the app actually ships, and this
// feature exists precisely to find out what real captures look like.
//
// Hermetic: in-memory MongoDB, scripted S3, no Meshy.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { ClientConfig } from '@/models/ClientConfig';
import { Job, MESHY_MODEL_GENERATION_JOB_TYPE } from '@/models/Job';
import { Project } from '@/models/Project';
import { ProjectModel } from '@/models/ProjectModel';
import { RateWindow } from '@/models/RateWindow';
import { User, type UserRole } from '@/models/User';
import { buildJobKeyPrefix } from '@/utils/s3Keys';
import { AUTO_MODEL_FLAG_KEY } from '@/services/autoModelGenerationService';
import {
  generateModelOnDemand,
  manualGenerationIdempotencyKey,
  MANUAL_MODEL_FLAG_KEY,
} from '@/services/onDemandModelGenerationService';

const app = createApp();
let mongod: MongoMemoryServer;

/** The manifest the bundle packer actually produces. */
const PACKER_MANIFEST = readFileSync(
  join(__dirname, 'fixtures', 'packer-capture-manifest.json'),
  'utf-8'
);
const PACKER_IMAGE_KEYS: string[] = (
  JSON.parse(PACKER_MANIFEST) as { photos: { imagePath: string }[] }
).photos.map((p) => p.imagePath);

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Job.syncIndexes();
  await ProjectModel.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  // The button ships dark; every test that wants it on says so explicitly.
  vi.spyOn(env, 'MANUAL_MODEL_GENERATION_ENABLED', 'get').mockReturnValue(true);
  // And AUTOMATIC generation stays OFF throughout — the two gates are
  // independent, and this suite proves the button works without it.
  vi.spyOn(env, 'AUTO_MODEL_GENERATION_ENABLED', 'get').mockReturnValue(false);
});

afterEach(async () => {
  await User.deleteMany({});
  await Project.deleteMany({});
  await Job.deleteMany({});
  await ProjectModel.deleteMany({});
  await RateWindow.deleteMany({});
  await ClientConfig.deleteMany({});
  vi.restoreAllMocks();
});

// ── Fixtures ─────────────────────────────────────────────────────────────────

async function makeUser(role?: UserRole) {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    ...(role ? { role } : {}),
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

/** A project with one finalized capture job, S3-scripted with the packer bundle. */
async function makeCapturedProject(ownerId: string) {
  const project = await Project.create({
    userId: new Types.ObjectId(ownerId),
    name: 'On-demand test',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status: 'COMPLETED',
  });
  const jobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({
    userId: ownerId,
    projectId: project.id as string,
    jobId: jobId.toHexString(),
  });
  const job = await Job.create({
    _id: jobId,
    projectId: project._id,
    userId: new Types.ObjectId(ownerId),
    state: 'QUEUED',
    objectSize: 'MEDIUM',
    queuedAt: new Date(),
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount: 37,
      uploadedFilesCount: 37,
      checksumAlgo: 'md5',
      rawBucket: 'recapture-test-raw',
      rawPrefix: prefix,
      manifestKey: `${prefix}capture_manifest.json`,
    },
  });
  return { project, job, prefix };
}

/**
 * Scripts S3 for one job prefix. ListObjectsV2 returns ABSOLUTE bucket keys —
 * the shape S3 really returns — so the service's relative-key conversion is
 * genuinely exercised rather than assumed (live-readiness fix B2).
 */
function mockS3(prefix: string, opts: { manifest?: string | null; images?: string[] } = {}) {
  const manifestBody = opts.manifest === undefined ? PACKER_MANIFEST : opts.manifest;
  const images = opts.images ?? PACKER_IMAGE_KEYS;
  vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
  }) => {
    switch (cmd.constructor.name) {
      case 'GetObjectCommand': {
        if (manifestBody === null) {
          const err = Object.assign(new Error('NoSuchKey'), { name: 'NoSuchKey' });
          throw err;
        }
        return { Body: { transformToString: async () => manifestBody } };
      }
      case 'ListObjectsV2Command':
        return {
          Contents: [
            `${prefix}capture_manifest.json`,
            ...images.map((k) => `${prefix}${k}`),
          ].map((Key) => ({ Key })),
          IsTruncated: false,
        };
      default:
        throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }
  }) as never);
}

/** Sets (or clears) the live kill switch on the ops config document. */
async function setKillSwitch(key: string, value: boolean | undefined) {
  await ClientConfig.deleteMany({});
  if (value !== undefined) await ClientConfig.create({ [key]: value });
}

// ── The service ──────────────────────────────────────────────────────────────

describe('generateModelOnDemand', () => {
  it('selects photos and enqueues a generation, with the whole decision traced', async () => {
    const owner = await makeUser();
    const staff = await makeUser('MODEL_ARTIST');
    const { project, job, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    const result = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: staff.id, role: 'MODEL_ARTIST' },
    });

    expect(result.outcome).toBe('ENQUEUED');
    if (result.outcome !== 'ENQUEUED') return;

    // The six synchronous steps, in the order they run and all inside one
    // request — nothing here is ever streamed.
    expect(result.steps.map((s) => s.step)).toEqual([
      'RESOLVE_JOB',
      'LOAD_MANIFEST',
      'LIST_OBJECTS',
      'SELECT_PHOTOS',
      'GUARDS',
      'ENQUEUE',
    ]);
    expect(result.steps.every((s) => s.status === 'OK')).toBe(true);

    // The trace answers "which four, from where, how sharp".
    expect(result.trace.chosen).toHaveLength(4);
    expect(result.trace.ringUsed).toBe('EYE');
    expect(result.trace.segmentCountUsed).toBe(16);

    const record = await ProjectModel.findById(result.modelId).exec();
    expect(record?.status).toBe('QUEUED');
    expect(record?.selectedKeys).toHaveLength(4);
    expect(record?.createdByManualButton).toBe(true);
    expect(record?.createdBySystem).toBeUndefined();
    // PINNED to the capture job the photos came from (live-readiness fix B4).
    expect(record?.jobId.toHexString()).toBe(job._id.toHexString());

    // Persisted, not response-only: an hour later this is still answerable.
    expect(record?.generationTrace?.requestedBy).toBe('MANUAL');
    expect(record?.generationTrace?.steps.map((s) => s.step)).toContain('ENQUEUE');
    expect(record?.generationTrace?.selection).toBeTruthy();

    const queued = await Job.findOne({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE }).exec();
    expect((queued?.payload as { modelId?: string })?.modelId).toBe(result.modelId);
  });

  // REGRESSION (live-readiness fix B2): S3 lists ABSOLUTE keys. Handing those to
  // the selector matches nothing the manifest derives, so every candidate is
  // dropped and 100% of real captures decline. mockS3 returns absolute keys, so
  // a selection succeeding at all is the assertion — but pin the keys too.
  it('compares availability using keys RELATIVE to the job prefix', async () => {
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    // Only four objects exist. If the comparison were absolute, none would
    // match and this would decline instead of picking exactly these.
    const present = ['eye_0001.jpg', 'eye_0005.jpg', 'eye_0009.jpg', 'eye_0013.jpg'].map(
      (f) => `images/EYE/${f}`
    );
    mockS3(prefix, { images: present });

    const result = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: owner.id, role: 'USER' },
    });

    if (result.outcome !== 'ENQUEUED') throw new Error(`expected ENQUEUED, got ${result.outcome}`);
    const record = await ProjectModel.findById(result.modelId).exec();
    expect(record?.selectedKeys.sort()).toEqual([...present].sort());
  });

  // ── Declining costs nothing ───────────────────────────────────────────────

  it('declines a capture with no sharpness data and spends NOTHING', async () => {
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    // Exactly the pre-2026-07-21 packer output: no quality block at all.
    const parsed = JSON.parse(PACKER_MANIFEST) as { photos: Record<string, unknown>[] };
    for (const p of parsed.photos) delete p.quality;
    mockS3(prefix, { manifest: JSON.stringify(parsed) });

    const result = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: owner.id, role: 'USER' },
    });

    expect(result.outcome).toBe('DECLINED');
    if (result.outcome !== 'DECLINED') return;
    expect(result.reason).toBe('NO_USABLE_PHOTOS');
    // The counter that distinguishes "old capture" from "broken selector".
    expect(result.trace.droppedNoBlurScore).toBeGreaterThan(0);
    expect(result.steps.find((s) => s.step === 'SELECT_PHOTOS')?.status).toBe('FAILED');

    // The money assertion.
    expect(await ProjectModel.countDocuments({})).toBe(0);
    expect(await Job.countDocuments({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE })).toBe(0);
  });

  it('declines an unreadable manifest with a trace rather than throwing', async () => {
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix, { manifest: 'not json at all' });

    const result = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: owner.id, role: 'USER' },
    });

    expect(result.outcome).toBe('DECLINED');
    if (result.outcome !== 'DECLINED') return;
    expect(result.reason).toBe('MANIFEST_UNREADABLE');
    expect(result.steps.find((s) => s.step === 'LOAD_MANIFEST')?.status).toBe('FAILED');
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it('declines when the manifest object is gone', async () => {
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix, { manifest: null });

    const result = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: owner.id, role: 'USER' },
    });

    expect(result.outcome).toBe('DECLINED');
  });

  // ── Blocked ───────────────────────────────────────────────────────────────

  it('blocks when the env gate is off', async () => {
    vi.spyOn(env, 'MANUAL_MODEL_GENERATION_ENABLED', 'get').mockReturnValue(false);
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    const result = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: owner.id, role: 'USER' },
    });

    expect(result).toMatchObject({ outcome: 'BLOCKED', reason: 'DISABLED' });
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it('blocks when the live kill switch is false', async () => {
    await setKillSwitch(MANUAL_MODEL_FLAG_KEY, false);
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    const result = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: owner.id, role: 'USER' },
    });

    expect(result).toMatchObject({ outcome: 'BLOCKED', reason: 'DISABLED' });
  });

  // The whole reason there are two flags: this button must be usable while
  // unattended per-capture spend stays switched off.
  it('runs while the AUTOMATIC gate and its kill switch are both off', async () => {
    await setKillSwitch(AUTO_MODEL_FLAG_KEY, false);
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    const result = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: owner.id, role: 'USER' },
    });

    expect(result.outcome).toBe('ENQUEUED');
  });

  it('blocks an unknown project', async () => {
    const owner = await makeUser();
    const result = await generateModelOnDemand({
      projectId: new Types.ObjectId().toHexString(),
      actor: { userId: owner.id, role: 'USER' },
    });
    expect(result).toMatchObject({ outcome: 'BLOCKED', reason: 'PROJECT_NOT_FOUND' });
  });

  it('blocks a project with no finalized capture', async () => {
    const owner = await makeUser();
    const project = await Project.create({
      userId: new Types.ObjectId(owner.id),
      name: 'Draft',
      objectSize: 'MEDIUM',
      mode: 'GUIDED',
      status: 'DRAFT',
    });

    const result = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: owner.id, role: 'USER' },
    });

    expect(result).toMatchObject({ outcome: 'BLOCKED', reason: 'NOT_EXPORTABLE' });
  });

  // ── Idempotency: the button is not a payment button ───────────────────────

  it('replays on a second press instead of paying again', async () => {
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);
    const actor = { userId: owner.id, role: 'USER' as const };

    const first = await generateModelOnDemand({ projectId: project.id as string, actor });
    const second = await generateModelOnDemand({ projectId: project.id as string, actor });

    expect(first.outcome).toBe('ENQUEUED');
    expect(second.outcome).toBe('REPLAYED');
    if (first.outcome !== 'ENQUEUED' || second.outcome !== 'REPLAYED') return;
    expect(second.modelId).toBe(first.modelId);
    expect(await ProjectModel.countDocuments({})).toBe(1);
    expect(await Job.countDocuments({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE })).toBe(1);
  });

  it('derives the idempotency key from the capture job', async () => {
    const owner = await makeUser();
    const { project, job, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: owner.id, role: 'USER' },
    });

    const record = await ProjectModel.findOne({}).exec();
    expect(record?.idempotencyKey).toBe(manualGenerationIdempotencyKey(job._id));
  });

  it('force mints a fresh key and pays for a second generation', async () => {
    const staff = await makeUser('ADMIN');
    const { project, prefix } = await makeCapturedProject(staff.id);
    mockS3(prefix);
    const actor = { userId: staff.id, role: 'ADMIN' as const };

    await generateModelOnDemand({ projectId: project.id as string, actor });
    const forced = await generateModelOnDemand({
      projectId: project.id as string,
      actor,
      force: true,
    });

    expect(forced.outcome).toBe('ENQUEUED');
    expect(await ProjectModel.countDocuments({})).toBe(2);
    expect(await Job.countDocuments({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE })).toBe(2);
  });

  it('lets the unique index settle two concurrent presses', async () => {
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);
    const actor = { userId: owner.id, role: 'USER' as const };

    const [a, b] = await Promise.all([
      generateModelOnDemand({ projectId: project.id as string, actor }),
      generateModelOnDemand({ projectId: project.id as string, actor }),
    ]);

    expect([a.outcome, b.outcome].sort()).toEqual(['ENQUEUED', 'REPLAYED']);
    expect(await ProjectModel.countDocuments({})).toBe(1);
  });

  // ── The shared 24h ceiling ────────────────────────────────────────────────

  /** Backfills prior server-selected generations attributed to [userId]. */
  async function backfill(userId: string, count: number, kind: 'auto' | 'manual') {
    await ProjectModel.insertMany(
      Array.from({ length: count }, () => ({
        projectId: new Types.ObjectId(),
        jobId: new Types.ObjectId(),
        source: 'meshy',
        status: 'SUCCEEDED',
        selectedKeys: ['images/EYE/a.jpg'],
        createdByUserId: new Types.ObjectId(userId),
        createdByRole: 'USER',
        ...(kind === 'auto' ? { createdBySystem: true } : { createdByManualButton: true }),
      }))
    );
  }

  it('counts AUTOMATIC generations against the button ceiling — one budget', async () => {
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);
    await backfill(owner.id, env.MANUAL_MODEL_MAX_PER_USER_PER_DAY, 'auto');

    const result = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: owner.id, role: 'USER' },
    });

    expect(result).toMatchObject({ outcome: 'BLOCKED', reason: 'USER_CAP_REACHED' });
    expect(await Job.countDocuments({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE })).toBe(0);
  });

  it('gives staff a HIGHER ceiling, not an exemption', async () => {
    const staff = await makeUser('MODEL_ARTIST');
    const { project, prefix } = await makeCapturedProject(staff.id);
    mockS3(prefix);
    // Past the owner ceiling, under the staff one.
    await backfill(staff.id, env.MANUAL_MODEL_MAX_PER_USER_PER_DAY, 'manual');

    const allowed = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: staff.id, role: 'MODEL_ARTIST' },
    });
    expect(allowed.outcome).toBe('ENQUEUED');

    // …and the staff ceiling itself still bites.
    await backfill(staff.id, env.MANUAL_MODEL_MAX_PER_STAFF_PER_DAY, 'manual');
    const blocked = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: staff.id, role: 'MODEL_ARTIST' },
      force: true,
    });
    expect(blocked).toMatchObject({ outcome: 'BLOCKED', reason: 'USER_CAP_REACHED' });
  });

  it('ignores hand-curated staff selections when counting the ceiling', async () => {
    const staff = await makeUser('ADMIN');
    const { project, prefix } = await makeCapturedProject(staff.id);
    mockS3(prefix);
    // Neither flag set — a human picked these photos, and they have their own
    // rate window rather than this cap.
    await ProjectModel.insertMany(
      Array.from({ length: env.MANUAL_MODEL_MAX_PER_STAFF_PER_DAY + 5 }, () => ({
        projectId: project._id,
        jobId: new Types.ObjectId(),
        source: 'meshy',
        status: 'SUCCEEDED',
        selectedKeys: ['images/EYE/a.jpg'],
        createdByUserId: new Types.ObjectId(staff.id),
        createdByRole: 'ADMIN',
      }))
    );

    const result = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: staff.id, role: 'ADMIN' },
    });

    expect(result.outcome).toBe('ENQUEUED');
  });
});

// ── The staff route ──────────────────────────────────────────────────────────

describe('POST /admin/projects/:id/model/auto', () => {
  it('enqueues and returns the steps + trace for a staff caller', async () => {
    const owner = await makeUser();
    const staff = await makeUser('MODEL_ARTIST');
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model/auto`)
      .set(staff.auth)
      .send({});

    expect(res.status).toBe(201);
    expect(res.body.status).toBe('success');
    expect(res.body.model.selectedKeys).toHaveLength(4);
    expect(res.body.steps.map((s: { step: string }) => s.step)).toContain('SELECT_PHOTOS');
    expect(res.body.trace.chosen).toHaveLength(4);
    // The persisted trace rides on the staff DTO too, so a later reader gets it.
    expect(res.body.model.generationTrace.requestedBy).toBe('MANUAL');
  });

  it('rejects a non-staff caller', async () => {
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model/auto`)
      .set(owner.auth)
      .send({});

    expect(res.status).toBe(403);
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it('answers 422 NOT_SELECTABLE with the numbers behind the refusal', async () => {
    const owner = await makeUser();
    const staff = await makeUser('ADMIN');
    const { project, prefix } = await makeCapturedProject(owner.id);
    const parsed = JSON.parse(PACKER_MANIFEST) as { photos: Record<string, unknown>[] };
    for (const p of parsed.photos) delete p.quality;
    mockS3(prefix, { manifest: JSON.stringify(parsed) });

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model/auto`)
      .set(staff.auth)
      .send({});

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('NOT_SELECTABLE');
    expect(res.body.reason).toBe('NO_USABLE_PHOTOS');
    expect(res.body.trace.droppedNoBlurScore).toBeGreaterThan(0);
  });

  it('answers 200 (not 201) on a repeat press', async () => {
    const owner = await makeUser();
    const staff = await makeUser('ADMIN');
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    await request(app).post(`/admin/projects/${project.id}/model/auto`).set(staff.auth).send({});
    const res = await request(app)
      .post(`/admin/projects/${project.id}/model/auto`)
      .set(staff.auth)
      .send({});

    expect(res.status).toBe(200);
    expect(await ProjectModel.countDocuments({})).toBe(1);
  });

  it('answers 409 when the feature is switched off', async () => {
    vi.spyOn(env, 'MANUAL_MODEL_GENERATION_ENABLED', 'get').mockReturnValue(false);
    const owner = await makeUser();
    const staff = await makeUser('ADMIN');
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model/auto`)
      .set(staff.auth)
      .send({});

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('DISABLED');
  });

  it('leaves the explicit-keys route alone', async () => {
    // The Prepare-Images contract must be untouched by this feature.
    const owner = await makeUser();
    const staff = await makeUser('ADMIN');
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model`)
      .set(staff.auth)
      .send({ keys: PACKER_IMAGE_KEYS.slice(0, 3) });

    expect(res.status).toBe(201);
    const record = await ProjectModel.findById(res.body.model.id).exec();
    // A hand-picked selection is neither system nor button — it must not land
    // in the shared 24h pool.
    expect(record?.createdByManualButton).toBeUndefined();
    expect(record?.createdBySystem).toBeUndefined();
  });
});

// ── The owner route ──────────────────────────────────────────────────────────

describe('POST /projects/:id/model', () => {
  it('accepts the owner request and returns owner-safe state only', async () => {
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    const res = await request(app).post(`/projects/${project.id}/model`).set(owner.auth).send({});

    expect(res.status).toBe(202);
    expect(res.body.generation.status).toBe('QUEUED');

    // The exposure assertion, made on the SERIALIZED body rather than the DTO
    // type: an owner must not learn our key layout, our step names, or that
    // Meshy exists.
    const serialized = JSON.stringify(res.body);
    expect(serialized).not.toContain('trace');
    expect(serialized).not.toContain('steps');
    expect(serialized).not.toContain('images/EYE');
    expect(serialized).not.toContain('SELECT_PHOTOS');
    expect(serialized.toLowerCase()).not.toContain('meshy');
  });

  it('404s a project the caller does not own — same as any missing project', async () => {
    const owner = await makeUser();
    const stranger = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    const res = await request(app)
      .post(`/projects/${project.id}/model`)
      .set(stranger.auth)
      .send({});

    expect(res.status).toBe(404);
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it('a plain repeat replays, but { regenerate: true } forces a NEW version', async () => {
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    // First press: the one record for this capture.
    const first = await request(app).post(`/projects/${project.id}/model`).set(owner.auth).send({});
    expect(first.status).toBe(202);
    expect(await ProjectModel.countDocuments({})).toBe(1);

    // A plain repeat is idempotent — no second spend, still one record.
    const replay = await request(app)
      .post(`/projects/${project.id}/model`)
      .set(owner.auth)
      .send({});
    expect(replay.status).toBe(202);
    expect(await ProjectModel.countDocuments({})).toBe(1);

    // The explicit regenerate is a deliberate new version: a second record,
    // still bounded by the per-user daily cap (2 of 5 here).
    const regen = await request(app)
      .post(`/projects/${project.id}/model`)
      .set(owner.auth)
      .send({ regenerate: true });
    expect(regen.status).toBe(202);
    expect(await ProjectModel.countDocuments({})).toBe(2);
  });

  it('gives a decline plain, actionable copy and no internal reason code', async () => {
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    const parsed = JSON.parse(PACKER_MANIFEST) as {
      photos: { segmentIndex: number; ringName: string }[];
    };
    // Everything from one side of the object.
    parsed.photos = parsed.photos
      .filter((p) => p.ringName === 'EYE')
      .map((p) => ({ ...p, segmentIndex: 0 }));
    mockS3(prefix, { manifest: JSON.stringify(parsed) });

    const res = await request(app).post(`/projects/${project.id}/model`).set(owner.auth).send({});

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('NOT_SELECTABLE');
    expect(res.body.message).toContain('around');
    expect(JSON.stringify(res.body)).not.toContain('INSUFFICIENT_SPREAD');
  });

  it('is gated by the same env flag as the staff route', async () => {
    vi.spyOn(env, 'MANUAL_MODEL_GENERATION_ENABLED', 'get').mockReturnValue(false);
    const owner = await makeUser();
    const { project, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    const res = await request(app).post(`/projects/${project.id}/model`).set(owner.auth).send({});

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('GENERATION_UNAVAILABLE');
  });
});
