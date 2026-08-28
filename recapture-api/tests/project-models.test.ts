// tests/project-models.test.ts
//
// The staff-triggered Meshy "Create Model" surface: POST /admin/projects/:id/model,
// its history + approve routes, the owner-facing projection, and the regression
// that a generation job must not shadow the capture job.
//
// Hermetic: in-memory MongoDB; the S3 client is scripted; Meshy is never called
// (the create endpoint only enqueues — the worker does the talking).
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { User, type UserRole } from '@/models/User';
import { Project } from '@/models/Project';
import { Job, MESHY_MODEL_GENERATION_JOB_TYPE } from '@/models/Job';
import { ProjectModel } from '@/models/ProjectModel';
import { RateWindow } from '@/models/RateWindow';
import { buildJobKeyPrefix } from '@/utils/s3Keys';
import { buildProjectExport } from '@/services/adminProjectsService';
import { createMeshyModelRequest } from '@/services/projectModelsService';

const app = createApp();
let mongod: MongoMemoryServer;

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

afterEach(async () => {
  await User.deleteMany({});
  await Project.deleteMany({});
  await Job.deleteMany({});
  await ProjectModel.deleteMany({});
  await RateWindow.deleteMany({});
  vi.restoreAllMocks();
});

async function makeUser(
  role: UserRole | undefined
): Promise<{ id: string; auth: { Authorization: string } }> {
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

async function makeProject(ownerId: string, status = 'PROCESSING') {
  return Project.create({
    userId: new Types.ObjectId(ownerId),
    name: `P-${new Types.ObjectId().toHexString().slice(-6)}`,
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status,
  });
}

async function makeFinalizedJob(ownerId: string, projectId: string) {
  const jobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({ projectName: 'Project models fixture', projectId, jobId: jobId.toHexString() });
  const job = await Job.create({
    _id: jobId,
    projectId: new Types.ObjectId(projectId),
    userId: new Types.ObjectId(ownerId),
    state: 'QUEUED',
    objectSize: 'MEDIUM',
    queuedAt: new Date(),
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount: 49,
      uploadedFilesCount: 49,
      checksumAlgo: 'md5',
      rawBucket: 'recapture-test-raw',
      rawPrefix: prefix,
      manifestKey: `${prefix}capture_manifest.json`,
    },
  });
  return { job, prefix };
}

/** Minimal List/Head scripting for the export path used by the shadowing test. */
function mockS3(keys: string[]): void {
  vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
    input: { Prefix?: string };
  }) => {
    if (cmd.constructor.name === 'ListObjectsV2Command') {
      const prefix = cmd.input.Prefix as string;
      return {
        Contents: keys.filter((k) => k.startsWith(prefix)).map((k) => ({ Key: k, Size: 10 })),
        IsTruncated: false,
      };
    }
    return {};
  }) as never);
}

const KEYS = ['images/EYE/eye_0001.jpg', 'images/EYE/eye_0002.jpg', 'images/TOP/top_0001.jpg'];

describe('POST /admin/projects/:id/model', () => {
  it('MODEL_ARTIST creates a QUEUED meshy record and enqueues exactly one generation job', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    const { job } = await makeFinalizedJob(owner.id, project.id as string);
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model`)
      .set(artist.auth)
      .send({ keys: KEYS });

    expect(res.status).toBe(201);
    expect(res.body.status).toBe('success');
    expect(res.body.model.status).toBe('QUEUED');
    // The origin flag that drives the client's "Created by Meshy AI" badge.
    expect(res.body.model.source).toBe('meshy');
    expect(res.body.model.selectedKeys).toEqual(KEYS);
    // The record points at the CAPTURE job the photos came from.
    expect(res.body.model.jobId).toBe(job.id);

    const queued = await Job.find({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE }).exec();
    expect(queued).toHaveLength(1);
    expect(queued[0]!.state).toBe('QUEUED');
    expect(queued[0]!.payload).toEqual({ modelId: res.body.model.id });

    // Analytics: hashed ids + a count. Never a key, never a presigned URL.
    // The analytics sink logs the name and the props as SEPARATE console args.
    const emitted = logSpy.mock.calls.map((c) => c.map(String).join(' ')).join(' ');
    expect(emitted).toContain('model_generation_requested');
    expect(emitted).toContain('"key_count":3');
    expect(emitted).not.toContain('eye_0001.jpg');
  });

  it('rejects a caller below MODEL_ARTIST and enqueues nothing', async () => {
    const owner = await makeUser('USER');
    const plain = await makeUser('USER');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model`)
      .set(plain.auth)
      .send({ keys: KEYS });

    expect(res.status).toBe(403);
    expect(await Job.countDocuments({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE })).toBe(0);
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it.each([
    ['too few', ['images/EYE/eye_0001.jpg', 'images/EYE/eye_0002.jpg']],
    ['too many', [...KEYS, 'images/TOP/top_0002.jpg', 'images/LOW/low_0001.jpg']],
  ])('refuses a selection with %s photos', async (_label, keys) => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model`)
      .set(artist.auth)
      .send({ keys });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    expect(await Job.countDocuments({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE })).toBe(0);
  });

  it('counts DISTINCT photos — a padded duplicate selection is really 2 photos', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model`)
      .set(artist.auth)
      .send({ keys: ['images/EYE/a.jpg', 'images/EYE/a.jpg', 'images/EYE/b.jpg'] });

    expect(res.status).toBe(400);
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it.each([
    ['traversal', '../../../etc/passwd'],
    ['absolute', '/etc/passwd'],
    ['the reserved deleted/ namespace', 'deleted/images/EYE/eye_0001.jpg'],
  ])('refuses a key escaping the job prefix via %s, and never echoes it', async (_l, badKey) => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model`)
      .set(artist.auth)
      .send({ keys: [KEYS[0]!, KEYS[1]!, badKey] });

    expect(res.status).toBe(400);
    expect(JSON.stringify(res.body)).not.toContain(badKey);
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it('404s an unknown project and 409s one with no finalized upload', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');

    const missing = await request(app)
      .post(`/admin/projects/${new Types.ObjectId().toHexString()}/model`)
      .set(artist.auth)
      .send({ keys: KEYS });
    expect(missing.status).toBe(404);

    const draft = await makeProject(owner.id, 'DRAFT');
    const notExportable = await request(app)
      .post(`/admin/projects/${draft.id}/model`)
      .set(artist.auth)
      .send({ keys: KEYS });
    expect(notExportable.status).toBe(409);
    expect(notExportable.body.code).toBe('NOT_EXPORTABLE');
  });

  it('an Idempotency-Key double-tap replays the first record — one generation, not two', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const owner = await makeUser('USER');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);
    vi.spyOn(console, 'log').mockImplementation(() => {});

    const send = () =>
      request(app)
        .post(`/admin/projects/${project.id}/model`)
        .set(artist.auth)
        .set('Idempotency-Key', 'tap-once')
        .send({ keys: KEYS });

    const first = await send();
    const second = await send();

    expect(first.status).toBe(201);
    // 200, not 201 — nothing new was enqueued.
    expect(second.status).toBe(200);
    expect(second.body.model.id).toBe(first.body.model.id);
    // THE POINT: one record and one job, so Meshy is paid exactly once.
    expect(await ProjectModel.countDocuments({})).toBe(1);
    expect(await Job.countDocuments({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE })).toBe(1);
  });

  it('rate-limits per staff user once the window is spent', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const owner = await makeUser('USER');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);
    vi.spyOn(console, 'log').mockImplementation(() => {});

    // Burn the window directly rather than issuing MESHY_CREATE_MAX_PER_WINDOW
    // real requests (each of which would insert a record).
    await RateWindow.create({
      key: `meshy-create:${artist.id}`,
      windowStartedAt: new Date(),
      count: env.MESHY_CREATE_MAX_PER_WINDOW,
      purgeAt: new Date(Date.now() + 3_600_000),
    });

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model`)
      .set(artist.auth)
      .send({ keys: KEYS });

    expect(res.status).toBe(429);
    expect(res.body.code).toBe('RATE_LIMITED');
    expect(res.body.retryAfter).toBeGreaterThan(0);
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });
});

describe('a generation job must not shadow the capture job', () => {
  it('export still resolves the CAPTURE job after a model is requested', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    const { prefix } = await makeFinalizedJob(owner.id, project.id as string);
    vi.spyOn(console, 'log').mockImplementation(() => {});

    const created = await request(app)
      .post(`/admin/projects/${project.id}/model`)
      .set(artist.auth)
      .send({ keys: KEYS });
    expect(created.status).toBe(201);

    // The generation Job is NEWER than the capture job and passes through the
    // same post-QUEUED states. Resolving "newest finalized job" without a
    // jobType filter would pick it — and it has no upload block, so every
    // export / preview-gallery / soft-delete call would break with
    // NOT_EXPORTABLE.
    mockS3([`${prefix}images/EYE/eye_0001.jpg`]);
    const result = await buildProjectExport(project.id as string);

    expect(result.outcome).toBe('EXPORTED');
  });
});

describe('createMeshyModelRequest — which capture job the keys resolve against', () => {
  /** A second finalized capture job, unambiguously newer than the first. */
  async function makeNewerFinalizedJob(ownerId: string, projectId: string) {
    const { job, prefix } = await makeFinalizedJob(ownerId, projectId);
    await Job.collection.updateOne(
      { _id: job._id },
      { $set: { createdAt: new Date(Date.now() + 60_000) } }
    );
    return { job, prefix };
  }

  it('with NO jobId, still resolves the NEWEST exportable job (staff path unchanged)', async () => {
    // The staff surface curates a project's current state at request time, so
    // "newest" is the intended rule there — B4 must not have shifted it.
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);
    const { job: newer } = await makeNewerFinalizedJob(owner.id, project.id as string);

    const result = await createMeshyModelRequest({
      projectId: project.id as string,
      keys: KEYS,
      actor: { userId: artist.id, role: 'MODEL_ARTIST' },
    });

    expect(result.outcome).toBe('CREATED');
    if (result.outcome !== 'CREATED') return;
    expect(result.model.jobId.toHexString()).toBe(newer._id.toHexString());
  });

  it('with a jobId, pins to THAT job even when a newer one exists', async () => {
    const owner = await makeUser('USER');
    const project = await makeProject(owner.id);
    const { job: older } = await makeFinalizedJob(owner.id, project.id as string);
    const { job: newer } = await makeNewerFinalizedJob(owner.id, project.id as string);

    const result = await createMeshyModelRequest({
      projectId: project.id as string,
      keys: KEYS,
      actor: { userId: owner.id, role: 'USER' },
      jobId: older._id,
    });

    expect(result.outcome).toBe('CREATED');
    if (result.outcome !== 'CREATED') return;
    expect(result.model.jobId.toHexString()).toBe(older._id.toHexString());
    expect(result.model.jobId.toHexString()).not.toBe(newer._id.toHexString());
  });

  it('NOT_EXPORTABLE when the named job has no upload block', async () => {
    const owner = await makeUser('USER');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string); // a valid newer-or-equal job exists
    const noUpload = await Job.create({
      projectId: project._id,
      userId: new Types.ObjectId(owner.id),
      state: 'PROCESSING',
      objectSize: 'MEDIUM',
    });

    const result = await createMeshyModelRequest({
      projectId: project.id as string,
      keys: KEYS,
      actor: { userId: owner.id, role: 'USER' },
      jobId: noUpload._id,
    });

    // Explicitly NOT a silent fallback to the exportable job — the caller named
    // a job, and that job cannot serve the keys.
    expect(result).toEqual({ outcome: 'NOT_EXPORTABLE' });
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it('NOT_EXPORTABLE when the named job belongs to another project', async () => {
    const owner = await makeUser('USER');
    const mine = await makeProject(owner.id);
    const theirs = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, mine.id as string);
    const { job: foreign } = await makeFinalizedJob(owner.id, theirs.id as string);

    const result = await createMeshyModelRequest({
      projectId: mine.id as string,
      keys: KEYS,
      actor: { userId: owner.id, role: 'USER' },
      jobId: foreign._id,
    });

    expect(result).toEqual({ outcome: 'NOT_EXPORTABLE' });
  });
});

describe('GET /admin/projects/:id/models + approve', () => {
  it('returns the full history newest-first', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    const { job } = await makeFinalizedJob(owner.id, project.id as string);

    const older = await ProjectModel.create({
      projectId: project._id,
      jobId: job._id,
      source: 'meshy',
      status: 'FAILED',
      selectedKeys: KEYS,
      createdByUserId: new Types.ObjectId(artist.id),
      createdByRole: 'MODEL_ARTIST',
      createdAt: new Date(Date.now() - 60_000),
    });
    const newer = await ProjectModel.create({
      projectId: project._id,
      jobId: job._id,
      source: 'meshy',
      status: 'SUCCEEDED',
      selectedKeys: KEYS,
      createdByUserId: new Types.ObjectId(artist.id),
      createdByRole: 'MODEL_ARTIST',
      artifacts: {
        glbKey: 'k/model.glb',
        cdnUrls: { glb: 'https://test.cloudfront.net/k/model.glb' },
      },
    });

    const res = await request(app).get(`/admin/projects/${project.id}/models`).set(artist.auth);

    expect(res.status).toBe(200);
    expect(res.body.models.map((m: { id: string }) => m.id)).toEqual([newer.id, older.id]);
  });

  it('exposes the worker\'s live progress on a PROCESSING record only', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    const { job } = await makeFinalizedJob(owner.id, project.id as string);

    const base = {
      projectId: project._id,
      jobId: job._id,
      source: 'meshy' as const,
      selectedKeys: KEYS,
      createdByUserId: new Types.ObjectId(artist.id),
      createdByRole: 'MODEL_ARTIST' as const,
    };
    // What the worker writes mid-generation (meshyModelProcessor.reportProgress).
    const pending = await ProjectModel.create({
      ...base,
      status: 'PROCESSING',
      progress: { phase: 'GENERATING', percent: 42 },
    });
    // A record from before the progress field existed must still serialize.
    const legacy = await ProjectModel.create({ ...base, status: 'PROCESSING' });

    const res = await request(app).get(`/admin/projects/${project.id}/models`).set(artist.auth);

    expect(res.status).toBe(200);
    const byId = new Map(
      (res.body.models as { id: string; progress?: unknown }[]).map((m) => [m.id, m])
    );
    expect(byId.get(pending.id)?.progress).toEqual({ phase: 'GENERATING', percent: 42 });
    expect(byId.get(legacy.id)).toBeDefined();
    expect(byId.get(legacy.id)?.progress).toBeUndefined();
  });

  it('approves a SUCCEEDED model and refuses a FAILED one', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    const { job } = await makeFinalizedJob(owner.id, project.id as string);
    vi.spyOn(console, 'log').mockImplementation(() => {});

    const base = {
      projectId: project._id,
      jobId: job._id,
      source: 'meshy' as const,
      selectedKeys: KEYS,
      createdByUserId: new Types.ObjectId(artist.id),
      createdByRole: 'MODEL_ARTIST' as const,
    };
    const good = await ProjectModel.create({
      ...base,
      status: 'SUCCEEDED',
      artifacts: {
        glbKey: 'k/model.glb',
        cdnUrls: { glb: 'https://test.cloudfront.net/k/model.glb' },
      },
    });
    const bad = await ProjectModel.create({ ...base, status: 'FAILED' });

    const ok = await request(app)
      .post(`/admin/projects/${project.id}/models/${good.id}/approve`)
      .set(artist.auth);
    expect(ok.status).toBe(200);
    expect(ok.body.model.approved.at).toBeTruthy();

    const nope = await request(app)
      .post(`/admin/projects/${project.id}/models/${bad.id}/approve`)
      .set(artist.auth);
    expect(nope.status).toBe(409);
    expect(nope.body.code).toBe('NOT_APPROVABLE');

    const missing = await request(app)
      .post(`/admin/projects/${project.id}/models/${new Types.ObjectId().toHexString()}/approve`)
      .set(artist.auth);
    expect(missing.status).toBe(404);
  });
});

describe('GET /projects/:id — the owner projection', () => {
  it('surfaces the latest SUCCEEDED model with its origin flag and nothing sensitive', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    const { job } = await makeFinalizedJob(owner.id, project.id as string);
    vi.spyOn(console, 'log').mockImplementation(() => {});

    await ProjectModel.create({
      projectId: project._id,
      jobId: job._id,
      source: 'meshy',
      status: 'SUCCEEDED',
      selectedKeys: KEYS,
      createdByUserId: new Types.ObjectId(artist.id),
      createdByRole: 'MODEL_ARTIST',
      meshyTaskId: 'meshy-task-secret',
      artifacts: {
        glbKey: 'dev/u/p/j/models/m/model.glb',
        cdnUrls: { glb: 'https://test.cloudfront.net/dev/u/p/j/models/m/model.glb' },
      },
    });

    const res = await request(app).get(`/projects/${project.id}`).set(owner.auth);

    expect(res.status).toBe(200);
    expect(res.body.model.source).toBe('meshy');
    expect(res.body.model.glbUrl).toBe(
      'https://test.cloudfront.net/dev/u/p/j/models/m/model.glb'
    );
    expect(res.body.model.approved).toBe(false);

    // The owner must not learn our key layout, who curated their project, the
    // selection, or the Meshy task id.
    const body = JSON.stringify(res.body);
    expect(res.body.model.glbKey).toBeUndefined();
    expect(body).not.toContain('meshy-task-secret');
    expect(body).not.toContain('selectedKeys');
    expect(body).not.toContain(artist.id);
  });

  it('is null while the only generation is still QUEUED, and never leaks another owner`s model', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    const { job } = await makeFinalizedJob(owner.id, project.id as string);
    vi.spyOn(console, 'log').mockImplementation(() => {});

    await ProjectModel.create({
      projectId: project._id,
      jobId: job._id,
      source: 'meshy',
      status: 'QUEUED',
      selectedKeys: KEYS,
      createdByUserId: new Types.ObjectId(artist.id),
      createdByRole: 'MODEL_ARTIST',
    });

    const mine = await request(app).get(`/projects/${project.id}`).set(owner.auth);
    expect(mine.status).toBe(200);
    expect(mine.body.model).toBeNull();

    const stranger = await makeUser('USER');
    const theirs = await request(app).get(`/projects/${project.id}`).set(stranger.auth);
    expect(theirs.status).toBe(404);
  });
});

describe('modelCount on the Project DTO', () => {
  it('counts SUCCEEDED models only, on BOTH the owner list and the admin list', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    const { job } = await makeFinalizedJob(owner.id, project.id as string);

    // One of each terminal/pending state — only the SUCCEEDED pair may count.
    for (const status of ['SUCCEEDED', 'SUCCEEDED', 'FAILED', 'QUEUED', 'PROCESSING']) {
      await ProjectModel.create({
        projectId: project._id,
        jobId: job._id,
        source: 'meshy',
        status,
        selectedKeys: KEYS,
        createdByUserId: new Types.ObjectId(artist.id),
        createdByRole: 'MODEL_ARTIST',
      });
    }

    // Owner list (My projects tab) — staff read their own projects through this.
    const ownerRes = await request(app).get('/projects').set(owner.auth);
    expect(ownerRes.status).toBe(200);
    expect(ownerRes.body.items[0].modelCount).toBe(2);

    // Admin list (Live projects tab).
    const adminRes = await request(app).get('/admin/projects').set(artist.auth);
    expect(adminRes.status).toBe(200);
    const row = adminRes.body.items.find(
      (i: { id: string }) => i.id === (project.id as string)
    );
    expect(row.modelCount).toBe(2);
  });

  it('is 0 for a project whose generations all FAILED — the Models button must not show', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    const { job } = await makeFinalizedJob(owner.id, project.id as string);

    await ProjectModel.create({
      projectId: project._id,
      jobId: job._id,
      source: 'meshy',
      status: 'FAILED',
      selectedKeys: KEYS,
      createdByUserId: new Types.ObjectId(artist.id),
      createdByRole: 'MODEL_ARTIST',
      error: { code: 'MESHY_GENERATION_FAILED', message: 'nope' },
    });

    const res = await request(app).get('/projects').set(owner.auth);
    expect(res.body.items[0].modelCount).toBe(0);
  });

  it('survives a rename — the DTO must not report a stale 0 and hide the button', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    const { job } = await makeFinalizedJob(owner.id, project.id as string);
    await ProjectModel.create({
      projectId: project._id,
      jobId: job._id,
      source: 'meshy',
      status: 'SUCCEEDED',
      selectedKeys: KEYS,
      createdByUserId: new Types.ObjectId(artist.id),
      createdByRole: 'MODEL_ARTIST',
    });

    const res = await request(app)
      .patch(`/projects/${project.id}`)
      .set(owner.auth)
      .send({ name: 'Renamed' });

    expect(res.status).toBe(200);
    expect(res.body.project.modelCount).toBe(1);
  });
});
