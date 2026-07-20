// tests/admin-model-images.test.ts
//
// POST /admin/projects/:id/model-images/upload-urls — presigned PUT slots for
// staff-EDITED Meshy input copies (the Prepare-Images screen). Verifies the
// staff gate, the reserved `model-input/` key namespace, count bounds, the
// 404/409 mappings, the rate window, hashed-only analytics — and the two
// integration contracts the namespace exists for: Create-Model ACCEPTS the
// returned keys, and the export manifest NEVER lists model-input objects.
//
// Hermetic: in-memory MongoDB. Presigning is local SigV4 (no network, no
// s3Client.send), so the presign path needs no S3 scripting; the export
// integration case scripts ListObjectsV2 like the other admin suites.
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

async function makeProject(ownerId: string, status: string) {
  return Project.create({
    userId: new Types.ObjectId(ownerId),
    name: `P-${status}-${new Types.ObjectId().toHexString().slice(-6)}`,
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status,
  });
}

/** A finalized (QUEUED) job with the canonical prefix persisted; returns the prefix. */
async function makeFinalizedJob(ownerId: string, projectId: string, state = 'QUEUED') {
  const jobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({ userId: ownerId, projectId, jobId: jobId.toHexString() });
  const job = await Job.create({
    _id: jobId,
    projectId: new Types.ObjectId(projectId),
    userId: new Types.ObjectId(ownerId),
    state,
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

describe('POST /admin/projects/:id/model-images/upload-urls', () => {
  it('MODEL_ARTIST gets presigned PUT slots under model-input/ — hashed-only analytics, no URL/key leak', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id, 'PROCESSING');
    const { prefix } = await makeFinalizedJob(owner.id, project.id as string);

    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model-images/upload-urls`)
      .set(artist.auth)
      .send({ count: 3 });

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('success');
    expect(res.body.uploads).toHaveLength(3);
    expect(Date.parse(res.body.expiresAt)).toBeGreaterThan(Date.now());

    const keys = res.body.uploads.map((u: { key: string }) => u.key);
    for (const key of keys) {
      // Job-root-RELATIVE, inside the reserved namespace, jpg-only.
      expect(key).toMatch(/^model-input\/[0-9a-f-]+\/photo_\d\.jpg$/);
    }
    // One session id per request; slots numbered within it.
    expect(new Set(keys.map((k: string) => k.split('/')[1])).size).toBe(1);
    expect(keys[0]).not.toBe(keys[1]);

    for (const upload of res.body.uploads) {
      // The PUT URL targets the job's ABSOLUTE key in the raw bucket, with the
      // Content-Type locked into the signature.
      expect(upload.url).toContain('recapture-test-raw');
      expect(upload.url).toContain(encodeURIComponent(`${prefix}${upload.key}`).replace(/%2F/gi, '/'));
      expect(upload.url).toContain('X-Amz-Signature=');
    }

    // Analytics: hashed ids + counts only — never a presigned URL or a key.
    const events = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] model_image_uploads_generated')
    );
    expect(events).toHaveLength(1);
    const props = JSON.parse(String(events[0]![1]));
    expect(props.file_count).toBe(3);
    expect(props.project_id_hash).not.toBe(project.id);
    const serialized = String(events[0]![1]);
    expect(serialized).not.toContain('model-input/');
    expect(serialized).not.toContain('X-Amz-Signature');
  });

  it('count bounds: 0 and 5 → 400; missing body → 400', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id, 'PROCESSING');
    await makeFinalizedJob(owner.id, project.id as string);

    for (const count of [0, 5]) {
      const res = await request(app)
        .post(`/admin/projects/${project.id}/model-images/upload-urls`)
        .set(artist.auth)
        .send({ count });
      expect(res.status).toBe(400);
      expect(res.body.code).toBe('INVALID_REQUEST');
    }

    const empty = await request(app)
      .post(`/admin/projects/${project.id}/model-images/upload-urls`)
      .set(artist.auth)
      .send({});
    expect(empty.status).toBe(400);
  });

  it('USER → 403; no token → 401', async () => {
    const owner = await makeUser('USER');
    const project = await makeProject(owner.id, 'PROCESSING');
    await makeFinalizedJob(owner.id, project.id as string);

    const user = await makeUser('USER');
    const forbidden = await request(app)
      .post(`/admin/projects/${project.id}/model-images/upload-urls`)
      .set(user.auth)
      .send({ count: 3 });
    expect(forbidden.status).toBe(403);

    const noAuth = await request(app)
      .post(`/admin/projects/${project.id}/model-images/upload-urls`)
      .send({ count: 3 });
    expect(noAuth.status).toBe(401);
  });

  it('unknown project → 404; project without a finalized upload → 409 NOT_EXPORTABLE', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');

    const missing = await request(app)
      .post(`/admin/projects/${new Types.ObjectId().toHexString()}/model-images/upload-urls`)
      .set(artist.auth)
      .send({ count: 3 });
    expect(missing.status).toBe(404);

    const noJob = await makeProject(owner.id, 'PROCESSING');
    const notExportable = await request(app)
      .post(`/admin/projects/${noJob.id}/model-images/upload-urls`)
      .set(artist.auth)
      .send({ count: 3 });
    expect(notExportable.status).toBe(409);
    expect(notExportable.body.code).toBe('NOT_EXPORTABLE');
  });

  it('rate window trips with 429 + retryAfter once the cap is spent', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id, 'PROCESSING');
    await makeFinalizedJob(owner.id, project.id as string);

    // Pre-spend the whole window rather than issuing MAX requests.
    await RateWindow.create({
      key: `model-image-uploads:${artist.id}`,
      windowStartedAt: new Date(),
      count: env.MODEL_IMAGE_UPLOAD_MAX_PER_WINDOW,
      purgeAt: new Date(Date.now() + env.MODEL_IMAGE_UPLOAD_WINDOW_SECONDS * 1000),
    });

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model-images/upload-urls`)
      .set(artist.auth)
      .send({ count: 3 });
    expect(res.status).toBe(429);
    expect(res.body.code).toBe('RATE_LIMITED');
    expect(res.body.retryAfter).toBeGreaterThan(0);
  });

  it('Create-Model accepts the returned model-input keys (containment integration)', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id, 'PROCESSING');
    await makeFinalizedJob(owner.id, project.id as string);

    const slots = await request(app)
      .post(`/admin/projects/${project.id}/model-images/upload-urls`)
      .set(artist.auth)
      .send({ count: 3 });
    expect(slots.status).toBe(200);
    const keys = slots.body.uploads.map((u: { key: string }) => u.key);

    const create = await request(app)
      .post(`/admin/projects/${project.id}/model`)
      .set(artist.auth)
      .set('Idempotency-Key', 'prep-session-1')
      .send({ keys });
    expect(create.status).toBe(201);
    expect(create.body.model.selectedKeys).toEqual(keys);
  });

  it('model-input objects never appear in the export manifest (Preview gallery stays capture-only)', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id, 'COMPLETED');
    const { prefix } = await makeFinalizedJob(owner.id, project.id as string, 'COMPLETED');

    vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
      constructor: { name: string };
      input: { Prefix?: string };
    }) => {
      if (cmd.constructor.name !== 'ListObjectsV2Command') {
        throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
      }
      const all = [
        `${prefix}capture_manifest.json`,
        `${prefix}images/EYE/eye_0001.jpg`,
        `${prefix}model-input/abc/photo_1.jpg`,
        `${prefix}deleted/images/EYE/eye_0002.jpg`,
      ];
      return {
        Contents: all
          .filter((k) => k.startsWith(cmd.input.Prefix as string))
          .map((k) => ({ Key: k, Size: 1000 })),
        IsTruncated: false,
      };
    }) as never);

    const exp = await request(app).get(`/admin/projects/${project.id}/export`).set(artist.auth);
    expect(exp.status).toBe(200);
    const keys = exp.body.export.files.map((f: { key: string }) => f.key);
    expect(keys).toContain('capture_manifest.json');
    expect(keys).toContain('images/EYE/eye_0001.jpg');
    expect(keys.some((k: string) => k.startsWith('model-input/'))).toBe(false);
    expect(keys.some((k: string) => k.startsWith('deleted/'))).toBe(false);
    expect(exp.body.export.fileCount).toBe(2);
  });
});
