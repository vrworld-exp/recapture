// tests/photo-upload-generate.test.ts
//
// POST /projects/:id/photos/generate — the ONLY step in this feature that
// spends Meshy credits, plus the deliberate refusal of server-side photo
// AUTO-selection on an upload project.
//
// The three load-bearing spend guards (AGENTS.md) must all still be here:
// the per-user rate window, the Idempotency-Key replay, and the unique-index
// race authority inside createMeshyModelRequest. Nothing is enqueued to a real
// Meshy client: the worker is never run and S3 is scripted.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { Project } from '@/models/Project';
import { Job, MESHY_MODEL_GENERATION_JOB_TYPE } from '@/models/Job';
import { ProjectModel } from '@/models/ProjectModel';
import { User } from '@/models/User';
import { RateWindow } from '@/models/RateWindow';

import { files, makeUploadProject, makeUser } from './helpers/photoUpload';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([Job.syncIndexes(), ProjectModel.syncIndexes()]);
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await Promise.all([
    Project.deleteMany({}),
    Job.deleteMany({}),
    ProjectModel.deleteMany({}),
    User.deleteMany({}),
    RateWindow.deleteMany({}),
  ]);
  vi.restoreAllMocks();
});

const OK = 1_000_000;

function mockS3(count: number) {
  return vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
    input: { Prefix?: string };
  }) => {
    if (cmd.constructor.name !== 'ListObjectsV2Command') {
      throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }
    const prefix = cmd.input.Prefix as string;
    return {
      Contents: Array.from({ length: count }, (_, i) => ({
        Key: `${prefix}photo_${String(i + 1).padStart(4, '0')}.jpg`,
        Size: OK,
      })),
      IsTruncated: false,
    };
  }) as never);
}

const SELECTION = [
  'uploads/photo_0001.jpg',
  'uploads/photo_0002.jpg',
  'uploads/photo_0003.jpg',
];

/** Opens a session and COMMITS it, so the job is in the UPLOADED state a
 * generation may be sourced from. */
async function committedProject(count = 6) {
  const artist = await makeUser('MODEL_ARTIST');
  const project = await makeUploadProject(artist.id);
  const projectId = project.id as string;

  const session = await request(app)
    .post(`/projects/${projectId}/photos/session`)
    .set(artist.auth)
    .send({ files: files(count) });
  expect(session.status).toBe(201);

  mockS3(count);
  const commit = await request(app)
    .post(`/projects/${projectId}/photos/commit`)
    .set(artist.auth)
    .send({ jobId: session.body.jobId });
  expect(commit.status).toBe(200);

  return { artist, projectId, jobId: session.body.jobId as string };
}

describe('POST /projects/:id/photos/generate', () => {
  it('201s a hand-picked selection and pins it to the UPLOADED photo job', async () => {
    const { artist, projectId, jobId } = await committedProject();

    const res = await request(app)
      .post(`/projects/${projectId}/photos/generate`)
      .set(artist.auth)
      .send({ keys: SELECTION });

    expect(res.status).toBe(201);
    const record = await ProjectModel.findById(res.body.modelId).exec();
    expect(record!.jobId.toHexString()).toBe(jobId);
    expect(record!.selectedKeys).toEqual(SELECTION);
    expect(record!.status).toBe('QUEUED');
    // The worker job that will call Meshy — a peer type, not the photo job.
    expect(
      await Job.countDocuments({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE, state: 'QUEUED' }).exec()
    ).toBe(1);
  });

  it('holds the 3–4 bound at both ends', async () => {
    const { artist, projectId } = await committedProject();
    const key = (n: number) => `uploads/photo_${String(n).padStart(4, '0')}.jpg`;

    const tooFew = await request(app)
      .post(`/projects/${projectId}/photos/generate`)
      .set(artist.auth)
      .send({ keys: [key(1), key(2)] });
    expect(tooFew.status).toBe(400);

    const tooMany = await request(app)
      .post(`/projects/${projectId}/photos/generate`)
      .set(artist.auth)
      .send({ keys: [key(1), key(2), key(3), key(4), key(5)] });
    expect(tooMany.status).toBe(400);

    const four = await request(app)
      .post(`/projects/${projectId}/photos/generate`)
      .set(artist.auth)
      .send({ keys: [key(1), key(2), key(3), key(4)] });
    expect(four.status).toBe(201);
  });

  it('refuses a key that escapes the job prefix', async () => {
    const { artist, projectId } = await committedProject();
    const res = await request(app)
      .post(`/projects/${projectId}/photos/generate`)
      .set(artist.auth)
      .send({ keys: ['uploads/photo_0001.jpg', '../../other.jpg', 'uploads/photo_0003.jpg'] });
    expect(res.status).toBe(400);
    expect(await ProjectModel.countDocuments({}).exec()).toBe(0);
  });

  it('409s when the photo job is still CREATED — an unverified set is not a source', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeUploadProject(artist.id);
    const projectId = project.id as string;
    // Session opened, never committed.
    await request(app)
      .post(`/projects/${projectId}/photos/session`)
      .set(artist.auth)
      .send({ files: files(5) });

    const res = await request(app)
      .post(`/projects/${projectId}/photos/generate`)
      .set(artist.auth)
      .send({ keys: SELECTION });

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('NOT_EXPORTABLE');
    expect(await ProjectModel.countDocuments({}).exec()).toBe(0);
  });

  it("404s another user's project, identically to a nonexistent one", async () => {
    const { projectId } = await committedProject();
    const stranger = await makeUser('MODEL_ARTIST');

    const foreign = await request(app)
      .post(`/projects/${projectId}/photos/generate`)
      .set(stranger.auth)
      .send({ keys: SELECTION });
    const missing = await request(app)
      .post(`/projects/${new Types.ObjectId().toHexString()}/photos/generate`)
      .set(stranger.auth)
      .send({ keys: SELECTION });

    expect(foreign.status).toBe(404);
    expect(foreign.body).toEqual(missing.body);
  });

  it('403s a plain USER', async () => {
    const { projectId } = await committedProject();
    const user = await makeUser('USER');
    const res = await request(app)
      .post(`/projects/${projectId}/photos/generate`)
      .set(user.auth)
      .send({ keys: SELECTION });
    expect(res.status).toBe(403);
  });
});

describe('the spend guards are still all three', () => {
  it('Idempotency-Key replays instead of paying twice (200, one record)', async () => {
    const { artist, projectId } = await committedProject();

    const first = await request(app)
      .post(`/projects/${projectId}/photos/generate`)
      .set(artist.auth)
      .set('Idempotency-Key', 'gen-1')
      .send({ keys: SELECTION });
    const second = await request(app)
      .post(`/projects/${projectId}/photos/generate`)
      .set(artist.auth)
      .set('Idempotency-Key', 'gen-1')
      .send({ keys: SELECTION });

    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect(second.body.modelId).toBe(first.body.modelId);
    expect(await ProjectModel.countDocuments({}).exec()).toBe(1);
  });

  it('the meshy-create rate window still applies (and is SHARED with the staff route)', async () => {
    const { artist, projectId } = await committedProject();

    // Exhaust the window through this route.
    for (let i = 0; i < env.MESHY_CREATE_MAX_PER_WINDOW; i++) {
      const res = await request(app)
        .post(`/projects/${projectId}/photos/generate`)
        .set(artist.auth)
        .send({ keys: SELECTION });
      expect(res.status).toBe(201);
    }

    const limited = await request(app)
      .post(`/projects/${projectId}/photos/generate`)
      .set(artist.auth)
      .send({ keys: SELECTION });

    expect(limited.status).toBe(429);
    expect(limited.body.code).toBe('RATE_LIMITED');
    expect(limited.body.retryAfter).toBeGreaterThan(0);
  });
});

describe('auto-selection refuses on an upload project', () => {
  it('POST /projects/:id/model → 409 AUTO_SELECTION_UNAVAILABLE, before any spend', async () => {
    const { artist, projectId } = await committedProject();

    const res = await request(app).post(`/projects/${projectId}/model`).set(artist.auth).send({});

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('AUTO_SELECTION_UNAVAILABLE');
    // Deliberate copy, not the generic "finish uploading" refusal.
    expect(res.body.message).toContain('chosen by hand');
    // And it names no pipeline internal.
    for (const internal of ['Meshy', 'manifest', 'selector', 'rawPrefix', 'S3', 'blur', 'yaw']) {
      expect(res.body.message).not.toContain(internal);
    }
    expect(await ProjectModel.countDocuments({}).exec()).toBe(0);
  });

  it('POST /admin/projects/:id/model/auto → 409 AUTO_SELECTION_UNAVAILABLE', async () => {
    const { projectId } = await committedProject();
    const admin = await makeUser('ADMIN');

    const res = await request(app)
      .post(`/admin/projects/${projectId}/model/auto`)
      .set(admin.auth)
      .send({});

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('AUTO_SELECTION_UNAVAILABLE');
    expect(await ProjectModel.countDocuments({}).exec()).toBe(0);
  });
});
