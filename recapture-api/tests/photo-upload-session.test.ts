// tests/photo-upload-session.test.ts
//
// POST /projects/:id/photos/session — the artist's upload session. Hermetic:
// in-memory MongoDB, no S3 call at all (opening a session presigns nothing; it
// only mints a job and assigns keys).
//
// What this pins:
//   • the role gate is per-route and inclusive upward (USER 403, MODEL_ARTIST
//     201, ADMIN 201) — the /projects router must NOT have become staff-only;
//   • the count bounds at MIN-1 / MIN / MAX / MAX+1;
//   • Idempotency-Key replays the ORIGINAL key set (not a re-derived one);
//   • another user's project is an IDENTICAL 404 to a nonexistent one;
//   • a capture project refuses with 409 NOT_AN_UPLOAD_PROJECT.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Project } from '@/models/Project';
import { Job, PHOTO_UPLOAD_JOB_TYPE } from '@/models/Job';
import { User } from '@/models/User';
import { RateWindow } from '@/models/RateWindow';
import { UPLOADED_PHOTOS_KEY_PREFIX } from '@/utils/s3Keys';

import { files, makeCaptureProject, makeUploadProject, makeUser } from './helpers/photoUpload';

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
  await Promise.all([
    Project.deleteMany({}),
    Job.deleteMany({}),
    User.deleteMany({}),
    RateWindow.deleteMany({}),
  ]);
  vi.restoreAllMocks();
});

function sessionUrl(projectId: string) {
  return `/projects/${projectId}/photos/session`;
}

describe('POST /projects/:id/photos/session — role gate', () => {
  it('403s a plain USER (the /projects router must stay open to USER elsewhere)', async () => {
    const user = await makeUser('USER');
    const project = await makeUploadProject(user.id);

    const res = await request(app)
      .post(sessionUrl(project.id as string))
      .set(user.auth)
      .send({ files: files(5) });

    expect(res.status).toBe(403);
    expect(res.body.code).toBe('FORBIDDEN');
  });

  it('201s a MODEL_ARTIST', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeUploadProject(artist.id);

    const res = await request(app)
      .post(sessionUrl(project.id as string))
      .set(artist.auth)
      .send({ files: files(5) });

    expect(res.status).toBe(201);
    expect(res.body.files).toHaveLength(5);
  });

  it('201s an ADMIN — privilege is inclusive upward, never exact-equality', async () => {
    const admin = await makeUser('ADMIN');
    const project = await makeUploadProject(admin.id);

    const res = await request(app)
      .post(sessionUrl(project.id as string))
      .set(admin.auth)
      .send({ files: files(3) });

    expect(res.status).toBe(201);
  });

  it('leaves the owner routes open to a plain USER (per-route gating, not router.use)', async () => {
    const user = await makeUser('USER');
    const res = await request(app).get('/projects').set(user.auth);
    expect(res.status).toBe(200);
  });
});

describe('POST /projects/:id/photos/session — the assigned keys', () => {
  it('assigns server-side keys under {rawPrefix}uploads/, 1-based and zero-padded', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeUploadProject(artist.id);

    const res = await request(app)
      .post(sessionUrl(project.id as string))
      .set(artist.auth)
      .send({
        files: [
          { contentType: 'image/jpeg', size: 100 },
          { contentType: 'image/png', size: 100 },
          { contentType: 'image/webp', size: 100 },
        ],
      });

    expect(res.status).toBe(201);
    const prefix = res.body.uploadPlan.keyPrefix as string;
    expect(res.body.files.map((f: { key: string }) => f.key)).toEqual([
      `${prefix}${UPLOADED_PHOTOS_KEY_PREFIX}photo_0001.jpg`,
      `${prefix}${UPLOADED_PHOTOS_KEY_PREFIX}photo_0002.png`,
      `${prefix}${UPLOADED_PHOTOS_KEY_PREFIX}photo_0003.webp`,
    ]);
  });

  it('persists a PHOTO_UPLOAD job in CREATED with NO manifestKey and NO QUEUED flip', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeUploadProject(artist.id);

    const res = await request(app)
      .post(sessionUrl(project.id as string))
      .set(artist.auth)
      .send({ files: files(4) });

    const job = await Job.findById(res.body.jobId).exec();
    expect(job!.jobType).toBe(PHOTO_UPLOAD_JOB_TYPE);
    expect(job!.state).toBe('CREATED');
    expect(job!.upload!.expectedFilesCount).toBe(4); // no manifest to add
    expect(job!.upload!.manifestKey).toBeUndefined();
    expect(job!.upload!.rawPrefix).toBe(res.body.uploadPlan.keyPrefix);
  });

  it('leaves the project DRAFT — an upload project has no new status', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeUploadProject(artist.id);

    await request(app)
      .post(sessionUrl(project.id as string))
      .set(artist.auth)
      .send({ files: files(3) });

    expect((await Project.findById(project.id).exec())!.status).toBe('DRAFT');
  });
});

describe('POST /projects/:id/photos/session — count bounds', () => {
  const cases: Array<[string, number, number]> = [
    ['MIN-1 is a 400', env.PROJECT_PHOTO_MIN_COUNT - 1, 400],
    ['MIN is accepted', env.PROJECT_PHOTO_MIN_COUNT, 201],
    ['MAX is accepted', env.PROJECT_PHOTO_MAX_COUNT, 201],
    ['MAX+1 is a 400', env.PROJECT_PHOTO_MAX_COUNT + 1, 400],
  ];

  for (const [label, count, status] of cases) {
    it(label, async () => {
      const artist = await makeUser('MODEL_ARTIST');
      const project = await makeUploadProject(artist.id);
      const res = await request(app)
        .post(sessionUrl(project.id as string))
        .set(artist.auth)
        .send({ files: files(count) });
      expect(res.status).toBe(status);
    });
  }

  it('rejects a per-file size over PROJECT_PHOTO_MAX_BYTES', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeUploadProject(artist.id);
    const res = await request(app)
      .post(sessionUrl(project.id as string))
      .set(artist.auth)
      .send({ files: files(3, 'image/jpeg', env.PROJECT_PHOTO_MAX_BYTES + 1) });
    expect(res.status).toBe(400);
  });

  it('rejects an unsupported content type', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeUploadProject(artist.id);
    const res = await request(app)
      .post(sessionUrl(project.id as string))
      .set(artist.auth)
      .send({ files: files(3, 'image/gif') });
    expect(res.status).toBe(400);
  });
});

describe('POST /projects/:id/photos/session — Idempotency-Key', () => {
  it('replays the ORIGINAL job and key set (200, one job in the DB)', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeUploadProject(artist.id);
    const body = { files: files(3) };

    const first = await request(app)
      .post(sessionUrl(project.id as string))
      .set(artist.auth)
      .set('Idempotency-Key', 'abc-123')
      .send(body);
    expect(first.status).toBe(201);

    const second = await request(app)
      .post(sessionUrl(project.id as string))
      .set(artist.auth)
      .set('Idempotency-Key', 'abc-123')
      .send(body);

    expect(second.status).toBe(200);
    expect(second.body.jobId).toBe(first.body.jobId);
    expect(second.body.files).toEqual(first.body.files);
    expect(second.body.uploadPlan).toEqual(first.body.uploadPlan);
    expect(await Job.countDocuments({ projectId: project._id }).exec()).toBe(1);
  });

  it('a different key mints a SECOND session', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeUploadProject(artist.id);

    const a = await request(app)
      .post(sessionUrl(project.id as string))
      .set(artist.auth)
      .set('Idempotency-Key', 'key-a')
      .send({ files: files(3) });
    const b = await request(app)
      .post(sessionUrl(project.id as string))
      .set(artist.auth)
      .set('Idempotency-Key', 'key-b')
      .send({ files: files(3) });

    expect(a.body.jobId).not.toBe(b.body.jobId);
    expect(await Job.countDocuments({ projectId: project._id }).exec()).toBe(2);
  });
});

describe('POST /projects/:id/photos/session — ownership and source', () => {
  it("another user's project is an IDENTICAL 404 to a nonexistent one", async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const other = await makeUser('MODEL_ARTIST');
    const foreign = await makeUploadProject(other.id);
    const missing = new Types.ObjectId().toHexString();

    const send = (id: string) =>
      request(app).post(sessionUrl(id)).set(artist.auth).send({ files: files(3) });

    const notOwned = await send(foreign.id as string);
    const notThere = await send(missing);

    expect(notOwned.status).toBe(404);
    expect(notThere.status).toBe(404);
    expect(notOwned.body).toEqual(notThere.body);
  });

  it('409s a CAPTURE project — it must not grow an uploads namespace', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeCaptureProject(artist.id);

    const res = await request(app)
      .post(sessionUrl(project.id as string))
      .set(artist.auth)
      .send({ files: files(3) });

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('NOT_AN_UPLOAD_PROJECT');
    expect(await Job.countDocuments({}).exec()).toBe(0);
  });
});

describe('POST /projects — source', () => {
  it("creates an upload project with NO size/mode and reports source: 'upload'", async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const res = await request(app)
      .post('/projects')
      .set(artist.auth)
      .send({ name: 'Uploaded set', category: 'Sculpture', source: 'upload' });

    expect(res.status).toBe(201);
    expect(res.body.project.source).toBe('upload');
    const saved = await Project.findById(res.body.project.id).exec();
    expect(saved!.objectSize).toBeUndefined();
    expect(saved!.mode).toBeUndefined();
  });

  it('400s an upload project that ALSO sends size/mode (a client bug, not noise)', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const res = await request(app)
      .post('/projects')
      .set(artist.auth)
      .send({ name: 'Bad', source: 'upload', size: 'medium', mode: 'guided' });
    expect(res.status).toBe(400);
  });

  it('still REQUIRES size/mode when source is absent or capture (unchanged)', async () => {
    const user = await makeUser('USER');
    const missing = await request(app).post('/projects').set(user.auth).send({ name: 'No size' });
    expect(missing.status).toBe(400);

    const ok = await request(app)
      .post('/projects')
      .set(user.auth)
      .send({ name: 'Captured', size: 'medium', mode: 'guided' });
    expect(ok.status).toBe(201);
    expect(ok.body.project.source).toBe('capture');
  });

  it('a project written BEFORE this field existed reads as capture (no migration)', async () => {
    const user = await makeUser('USER');
    // Raw insert bypasses mongoose defaults — exactly a pre-migration document.
    const raw = await Project.collection.insertOne({
      userId: new Types.ObjectId(user.id),
      name: 'Legacy',
      objectSize: 'MEDIUM',
      mode: 'GUIDED',
      status: 'DRAFT',
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    const loaded = await Project.findById(raw.insertedId).exec();
    expect(loaded!.source).toBe('capture');

    const res = await request(app).get('/projects').set(user.auth);
    expect(res.body.items[0].source).toBe('capture');
  });
});
