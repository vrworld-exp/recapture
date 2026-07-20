// tests/admin-delete-project.test.ts
//
// DELETE /admin/projects/:id — the ADMIN "bad capture" curation delete.
// Verifies the ADMIN-only gate, the server-enforced confirmName for BOTH modes,
// SOFT's recoverable + idempotent flag flip, and HARD's full purge: S3 objects
// (raw + artifacts prefixes), model records, jobs, then the project row.
//
// Hermetic: in-memory MongoDB; S3 scripted on the shared client as a mutable
// Set of absolute keys (bucket-agnostic — raw and artifacts prefixes share the
// key namespace here, which is fine: the assertions only care that everything
// under the job prefix is gone).
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
import { Job } from '@/models/Job';
import { ProjectModel } from '@/models/ProjectModel';
import { RateWindow } from '@/models/RateWindow';
import { buildJobKeyPrefix } from '@/utils/s3Keys';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Job.syncIndexes();
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
    name: `P-${status}-${new Types.ObjectId().toHexString().slice(-6)}`,
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status,
  });
}

/** A finalized (QUEUED) job with the canonical prefix persisted; returns the prefix. */
async function makeFinalizedJob(ownerId: string, projectId: string) {
  const jobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({ userId: ownerId, projectId, jobId: jobId.toHexString() });
  const job = await Job.create({
    _id: jobId,
    projectId: new Types.ObjectId(projectId),
    userId: new Types.ObjectId(ownerId),
    state: 'QUEUED',
    objectSize: 'MEDIUM',
    queuedAt: new Date(),
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount: 2,
      uploadedFilesCount: 2,
      checksumAlgo: 'md5',
      rawBucket: 'recapture-test-raw',
      rawPrefix: prefix,
      manifestKey: `${prefix}capture_manifest.json`,
    },
  });
  return { job, prefix };
}

/** Scripts List/Delete against a mutable Set of absolute keys. */
function mockS3Store(initialKeys: string[]): Set<string> {
  const store = new Set(initialKeys);
  vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
    input: { Key?: string; Prefix?: string };
  }) => {
    const name = cmd.constructor.name;
    if (name === 'DeleteObjectCommand') {
      store.delete(cmd.input.Key as string);
      return {};
    }
    if (name === 'ListObjectsV2Command') {
      const prefix = cmd.input.Prefix as string;
      return {
        Contents: [...store]
          .filter((k) => k.startsWith(prefix))
          .map((k) => ({ Key: k, Size: 1000 })),
        IsTruncated: false,
      };
    }
    throw new Error(`unexpected S3 command: ${name}`);
  }) as never);
  return store;
}

describe('DELETE /admin/projects/:id — gate + confirmation', () => {
  it('refuses a MODEL_ARTIST (ADMIN-only), touching nothing', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app)
      .delete(`/admin/projects/${project.id}`)
      .set(artist.auth)
      .send({ mode: 'SOFT', confirmName: project.name });

    expect(res.status).toBe(403);
    const untouched = await Project.findById(project._id).exec();
    expect(untouched?.deletedAt ?? null).toBeNull();
  });

  it('422s a wrong confirmName in BOTH modes without mutating anything', async () => {
    const owner = await makeUser('USER');
    const admin = await makeUser('ADMIN');
    const project = await makeProject(owner.id);

    for (const mode of ['SOFT', 'HARD']) {
      const res = await request(app)
        .delete(`/admin/projects/${project.id}`)
        .set(admin.auth)
        .send({ mode, confirmName: 'wrong name' });
      expect(res.status).toBe(422);
      expect(res.body.code).toBe('CONFIRMATION_REQUIRED');
    }

    const untouched = await Project.findById(project._id).exec();
    expect(untouched).not.toBeNull();
    expect(untouched?.deletedAt ?? null).toBeNull();
  });

  it('404s an unknown project id', async () => {
    const admin = await makeUser('ADMIN');
    const res = await request(app)
      .delete(`/admin/projects/${new Types.ObjectId().toHexString()}`)
      .set(admin.auth)
      .send({ mode: 'SOFT', confirmName: 'anything' });
    expect(res.status).toBe(404);
  });
});

describe('DELETE /admin/projects/:id — SOFT', () => {
  it('flags deletedAt, hides the project from the admin list, and replays idempotently', async () => {
    const owner = await makeUser('USER');
    const admin = await makeUser('ADMIN');
    const project = await makeProject(owner.id);
    vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app)
      .delete(`/admin/projects/${project.id}`)
      .set(admin.auth)
      .send({ mode: 'SOFT', confirmName: project.name });

    expect(res.status).toBe(200);
    expect(res.body.mode).toBe('SOFT');
    expect(res.body.wasAlreadyDeleted).toBe(false);

    // Every byte is still there — only the flag flipped (recoverable).
    const flagged = await Project.findById(project._id).exec();
    expect(flagged?.deletedAt).toBeInstanceOf(Date);

    const list = await request(app).get('/admin/projects').set(admin.auth);
    expect(list.status).toBe(200);
    expect(list.body.items.map((p: { id: string }) => p.id)).not.toContain(project.id);

    // Repeat: idempotent, and the original timestamp survives.
    const again = await request(app)
      .delete(`/admin/projects/${project.id}`)
      .set(admin.auth)
      .send({ mode: 'SOFT', confirmName: project.name });
    expect(again.status).toBe(200);
    expect(again.body.wasAlreadyDeleted).toBe(true);
    const after = await Project.findById(project._id).exec();
    expect(after?.deletedAt?.getTime()).toBe(flagged?.deletedAt?.getTime());
  });
});

describe('DELETE /admin/projects/:id — HARD', () => {
  it('purges S3 objects, model records, jobs, and the project row', async () => {
    const owner = await makeUser('USER');
    const admin = await makeUser('ADMIN');
    const project = await makeProject(owner.id);
    const { job, prefix } = await makeFinalizedJob(owner.id, project.id as string);
    const model = await ProjectModel.create({
      projectId: project._id,
      jobId: job._id,
      source: 'meshy',
      status: 'SUCCEEDED',
      selectedKeys: ['images/EYE/eye_0001.jpg'],
      createdByUserId: new Types.ObjectId(admin.id),
      createdByRole: 'ADMIN',
      artifacts: {
        glbKey: `${prefix}models/m1/model.glb`,
        cdnUrls: { glb: 'https://test.cloudfront.net/k/model.glb' },
      },
    });
    const store = mockS3Store([
      `${prefix}capture_manifest.json`,
      `${prefix}images/EYE/eye_0001.jpg`,
      // A curated-away photo parked under deleted/ must be purged too.
      `${prefix}deleted/images/EYE/eye_0002.jpg`,
      // The re-hosted Meshy artifact (artifacts bucket shares the prefix).
      `${prefix}models/${model.id}/model.glb`,
    ]);
    vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app)
      .delete(`/admin/projects/${project.id}`)
      .set(admin.auth)
      .send({ mode: 'HARD', confirmName: project.name });

    expect(res.status).toBe(200);
    expect(res.body.mode).toBe('HARD');
    expect(res.body.objectsDeleted).toBe(4);
    expect(res.body.jobsDeleted).toBe(1);
    expect(res.body.modelsDeleted).toBe(1);

    expect(store.size).toBe(0);
    expect(await Project.findById(project._id).exec()).toBeNull();
    expect(await Job.countDocuments({ projectId: project._id }).exec()).toBe(0);
    expect(await ProjectModel.countDocuments({ projectId: project._id }).exec()).toBe(0);
  });

  it('hard-deletes a project that was soft-deleted first (soft → purge workflow)', async () => {
    const owner = await makeUser('USER');
    const admin = await makeUser('ADMIN');
    const project = await makeProject(owner.id);
    project.deletedAt = new Date();
    await project.save();
    vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app)
      .delete(`/admin/projects/${project.id}`)
      .set(admin.auth)
      .send({ mode: 'HARD', confirmName: project.name });

    expect(res.status).toBe(200);
    expect(await Project.findById(project._id).exec()).toBeNull();
  });
});
