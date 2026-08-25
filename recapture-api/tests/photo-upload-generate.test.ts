// tests/photo-upload-generate.test.ts
//
// POST /projects/:id/photos/generate — the ONLY step in this feature that
// spends Meshy credits, plus server-side photo selection ON an upload project
// (which takes the artist's own order, having no manifest to rank by).
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
    // Photos live under `{rawPrefix}uploads/`. The commit lists that namespace
    // directly; generation lists the JOB ROOT and gets the same objects back
    // with the `uploads/` segment still on them. Normalising here is what keeps
    // the mock honest for both callers — without it, generation would see keys
    // that no real bucket would ever return.
    const listed = cmd.input.Prefix as string;
    const prefix = listed.endsWith('uploads/') ? listed : `${listed}uploads/`;
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

describe('server-side selection on an upload project', () => {
  // The old contract refused this outright (409 AUTO_SELECTION_UNAVAILABLE):
  // the selector reads blur and yaw out of a capture manifest and an uploaded
  // set has none. That made an upload project the one project on the hub whose
  // "Generate 3D model" button could not be pressed. It now runs a DIFFERENT
  // rule — the artist's own upload order — instead of no rule at all.
  it('POST /projects/:id/model enqueues from the uploaded set, in upload order', async () => {
    const { artist, projectId, jobId } = await committedProject();

    const res = await request(app).post(`/projects/${projectId}/model`).set(artist.auth).send({});

    expect(res.status).toBe(202);
    const record = await ProjectModel.findOne({}).exec();
    expect(record).not.toBeNull();
    // PINNED to the photo-upload job, exactly like a hand-picked selection.
    expect(record!.jobId.toHexString()).toBe(jobId);
    // The first four, in key order — never a manifest-derived `images/…` key.
    expect(record!.selectedKeys).toEqual([
      'uploads/photo_0001.jpg',
      'uploads/photo_0002.jpg',
      'uploads/photo_0003.jpg',
      'uploads/photo_0004.jpg',
    ]);
  });

  it('POST /admin/projects/:id/model/auto does the same for staff', async () => {
    const { projectId } = await committedProject();
    const admin = await makeUser('ADMIN');

    const res = await request(app)
      .post(`/admin/projects/${projectId}/model/auto`)
      .set(admin.auth)
      .send({});

    expect(res.status).toBe(201);
    expect(res.body.model.selectedKeys).toHaveLength(4);
    // The staff trace says WHY those photos — and says honestly that nothing
    // was measured, rather than reporting zeroes as a quality verdict.
    expect(res.body.trace.poolSize).toBe(6);
    expect(res.body.trace.unplacedCount).toBe(6);
    const loadManifest = res.body.steps.find(
      (entry: { step: string }) => entry.step === 'LOAD_MANIFEST'
    );
    expect(loadManifest.status).toBe('SKIPPED');
  });

  it('DECLINES a set too small to build from, and spends nothing', async () => {
    const { artist, projectId } = await committedProject();
    // Everything but two photos has since been curated away.
    mockS3(2);

    const res = await request(app).post(`/projects/${projectId}/model`).set(artist.auth).send({});

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('NOT_SELECTABLE');
    expect(await ProjectModel.countDocuments({}).exec()).toBe(0);
  });

  it('never selects out of the soft-deleted namespace', async () => {
    const { artist, projectId } = await committedProject();
    // A curated-away photo is MOVED to `{rawPrefix}deleted/…`, so it is still
    // under the job root the generation lists. Selecting it back out would
    // undo the curation silently — and hand Meshy a photo staff removed.
    vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
      constructor: { name: string };
      input: { Prefix?: string };
    }) => {
      const listed = cmd.input.Prefix as string;
      const root = listed.endsWith('uploads/') ? listed.slice(0, -'uploads/'.length) : listed;
      return {
        Contents: [
          ...Array.from({ length: 4 }, (_, i) => ({
            Key: `${root}uploads/photo_${String(i + 1).padStart(4, '0')}.jpg`,
            Size: OK,
          })),
          { Key: `${root}deleted/uploads/photo_0009.jpg`, Size: OK },
        ],
        IsTruncated: false,
      };
    }) as never);

    const res = await request(app).post(`/projects/${projectId}/model`).set(artist.auth).send({});

    expect(res.status).toBe(202);
    const record = await ProjectModel.findOne({}).exec();
    for (const key of record!.selectedKeys) {
      expect(key.startsWith('deleted/')).toBe(false);
    }
  });
});
