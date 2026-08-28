// tests/photo-upload-commit.test.ts
//
// POST /projects/:id/photos/commit + GET/DELETE /projects/:id/photos.
//
// The commit is where the byte cap becomes real (presigning cannot enforce a
// size) and where the state flip has to be race-safe. Hermetic: in-memory
// MongoDB; S3 is scripted on the shared client — no network.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { Project } from '@/models/Project';
import { Job } from '@/models/Job';
import { User } from '@/models/User';
import { RateWindow } from '@/models/RateWindow';
import { LIVE_PROJECT_STATUSES } from '@/services/adminProjectsService';

import { files, makeUploadProject, makeUser } from './helpers/photoUpload';

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

async function openSession(count = 4) {
  const artist = await makeUser('MODEL_ARTIST');
  const project = await makeUploadProject(artist.id);
  const res = await request(app)
    .post(`/projects/${project.id as string}/photos/session`)
    .set(artist.auth)
    .send({ files: files(count) });
  expect(res.status).toBe(201);
  return {
    artist,
    projectId: project.id as string,
    jobId: res.body.jobId as string,
    keyPrefix: res.body.uploadPlan.keyPrefix as string,
    keys: (res.body.files as Array<{ key: string }>).map((f) => f.key),
  };
}

/**
 * Scripts S3 for the commit path: ListObjectsV2 returns [sizes.length] photo
 * objects under the requested prefix. DeleteObject is recorded so the
 * over-cap-object assertion can prove the deletion actually happened.
 */
function mockS3(sizes: number[], deleted: string[] = []) {
  return vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
    input: { Prefix?: string; Key?: string };
  }) => {
    switch (cmd.constructor.name) {
      case 'ListObjectsV2Command': {
        const prefix = cmd.input.Prefix as string;
        return {
          Contents: sizes.map((size, i) => ({
            Key: `${prefix}photo_${String(i + 1).padStart(4, '0')}.jpg`,
            Size: size,
          })),
          IsTruncated: false,
        };
      }
      case 'DeleteObjectCommand':
        deleted.push(cmd.input.Key as string);
        return {};
      case 'HeadObjectCommand':
        return { ContentLength: 1 };
      case 'CopyObjectCommand':
        return {};
      default:
        throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }
  }) as never);
}

const OK = 1_000_000;

describe('POST /projects/:id/photos/commit', () => {
  it('verifies the set, flips CREATED → UPLOADED and never touches QUEUED', async () => {
    const { artist, projectId, jobId } = await openSession(4);
    mockS3([OK, OK, OK, OK]);

    const res = await request(app)
      .post(`/projects/${projectId}/photos/commit`)
      .set(artist.auth)
      .send({ jobId });

    expect(res.status).toBe(200);
    expect(res.body.photoCount).toBe(4);

    const job = await Job.findById(jobId).exec();
    expect(job!.state).toBe('UPLOADED');
    expect(job!.upload!.uploadedFilesCount).toBe(4);
    // The worker claims `state: 'QUEUED'` documents. This job must never be one.
    expect(await Job.countDocuments({ state: 'QUEUED' }).exec()).toBe(0);
  });

  it('writes stats.totalPhotos so the Hub card does not read "0 photos"', async () => {
    const { artist, projectId, jobId } = await openSession(6);
    mockS3(Array(6).fill(OK));

    await request(app).post(`/projects/${projectId}/photos/commit`).set(artist.auth).send({ jobId });

    const project = await Project.findById(projectId).exec();
    expect(project!.stats!.totalPhotos).toBe(6);
    expect(project!.stats!.lastCaptureAt).toBeInstanceOf(Date);
  });

  it('promotes the project to PROCESSING — a finished upload is a LIVE project', async () => {
    // The point of the promotion: PROCESSING is in LIVE_PROJECT_STATUSES, so
    // this is what puts an artist's upload in front of every other artist and
    // admin, and what turns on Preview / Export / Generate. Left in DRAFT it
    // was a private draft nobody else could ever see or work on.
    const { artist, projectId, jobId } = await openSession(6);
    mockS3(Array(6).fill(OK));

    await request(app).post(`/projects/${projectId}/photos/commit`).set(artist.auth).send({ jobId });

    const project = await Project.findById(projectId).exec();
    expect(project!.status).toBe('PROCESSING');
    expect(project!.statusUpdatedAt).toBeInstanceOf(Date);
    // And it is in the set the staff Live list queries for.
    expect(LIVE_PROJECT_STATUSES).toContain(project!.status);
  });

  it('re-asserts PROCESSING on a replay, so a crashed first commit self-heals', async () => {
    const { artist, projectId, jobId } = await openSession(6);
    mockS3(Array(6).fill(OK));
    await request(app).post(`/projects/${projectId}/photos/commit`).set(artist.auth).send({ jobId });

    // Simulate the gap: the job flipped to UPLOADED but the status write never
    // landed. The replay must not shrug and return the stored counts.
    await Project.updateOne({ _id: projectId }, { $set: { status: 'DRAFT' } }).exec();

    const replay = await request(app)
      .post(`/projects/${projectId}/photos/commit`)
      .set(artist.auth)
      .send({ jobId });

    expect(replay.status).toBe(200);
    expect((await Project.findById(projectId).exec())!.status).toBe('PROCESSING');
  });

  it('413s an over-cap object AND deletes it — the cap is only real here', async () => {
    const { artist, projectId, jobId } = await openSession(4);
    const deleted: string[] = [];
    mockS3([OK, env.PROJECT_PHOTO_MAX_BYTES + 1, OK, OK], deleted);

    const res = await request(app)
      .post(`/projects/${projectId}/photos/commit`)
      .set(artist.auth)
      .send({ jobId });

    expect(res.status).toBe(413);
    expect(res.body.code).toBe('PHOTO_TOO_LARGE');
    expect(deleted).toHaveLength(1);
    expect(deleted[0]).toContain('photo_0002.jpg');
    // Refused, so the job did NOT advance.
    expect((await Job.findById(jobId).exec())!.state).toBe('CREATED');
  });

  it('400s when fewer than PROJECT_PHOTO_MIN_COUNT objects arrived', async () => {
    const { artist, projectId, jobId } = await openSession(4);
    mockS3(Array(env.PROJECT_PHOTO_MIN_COUNT - 1).fill(OK));

    const res = await request(app)
      .post(`/projects/${projectId}/photos/commit`)
      .set(artist.auth)
      .send({ jobId });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('TOO_FEW_PHOTOS');
    expect((await Job.findById(jobId).exec())!.state).toBe('CREATED');
  });

  it('a second commit replays WITHOUT re-listing S3', async () => {
    const { artist, projectId, jobId } = await openSession(4);
    const spy = mockS3([OK, OK, OK, OK]);

    await request(app).post(`/projects/${projectId}/photos/commit`).set(artist.auth).send({ jobId });
    const listCallsAfterFirst = spy.mock.calls.length;

    const second = await request(app)
      .post(`/projects/${projectId}/photos/commit`)
      .set(artist.auth)
      .send({ jobId });

    expect(second.status).toBe(200);
    expect(second.body.alreadyCommitted).toBe(true);
    expect(second.body.photoCount).toBe(4);
    expect(spy.mock.calls.length).toBe(listCallsAfterFirst); // no new S3 traffic
  });

  it('two CONCURRENT commits: both succeed, exactly one performs the flip', async () => {
    const { artist, projectId, jobId } = await openSession(4);
    mockS3([OK, OK, OK, OK]);

    const [a, b] = await Promise.all([
      request(app).post(`/projects/${projectId}/photos/commit`).set(artist.auth).send({ jobId }),
      request(app).post(`/projects/${projectId}/photos/commit`).set(artist.auth).send({ jobId }),
    ]);

    expect(a.status).toBe(200);
    expect(b.status).toBe(200);
    // The conditional findOneAndUpdate is the race authority: one request wins
    // it and reports alreadyCommitted false; the loser reports true.
    expect([a.body.alreadyCommitted, b.body.alreadyCommitted].sort()).toEqual([false, true]);
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADED');
  });

  it("404s a jobId belonging to another project — identical to a missing project", async () => {
    const { artist, projectId } = await openSession();
    const other = await openSession();

    const foreignJob = await request(app)
      .post(`/projects/${projectId}/photos/commit`)
      .set(artist.auth)
      .send({ jobId: other.jobId });
    const missingProject = await request(app)
      .post(`/projects/${new Types.ObjectId().toHexString()}/photos/commit`)
      .set(artist.auth)
      .send({ jobId: new Types.ObjectId().toHexString() });

    expect(foreignJob.status).toBe(404);
    expect(foreignJob.body).toEqual(missingProject.body);
  });

  it('403s a plain USER', async () => {
    const { projectId, jobId } = await openSession();
    const user = await makeUser('USER');
    const res = await request(app)
      .post(`/projects/${projectId}/photos/commit`)
      .set(user.auth)
      .send({ jobId });
    expect(res.status).toBe(403);
  });
});

describe('GET /projects/:id/photos', () => {
  it('returns relative keys + presigned URLs + sizes, in key order', async () => {
    const { artist, projectId } = await openSession(3);
    mockS3([OK, OK + 1, OK + 2]);

    const res = await request(app).get(`/projects/${projectId}/photos`).set(artist.auth);

    expect(res.status).toBe(200);
    expect(res.body.items.map((i: { key: string }) => i.key)).toEqual([
      'uploads/photo_0001.jpg',
      'uploads/photo_0002.jpg',
      'uploads/photo_0003.jpg',
    ]);
    for (const item of res.body.items) {
      expect(item.url).toContain('X-Amz-Signature=');
    }
    expect(res.body.items[2].size).toBe(OK + 2);
  });

  it('a project with no photo set is an empty 200, not an error', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeUploadProject(artist.id);
    const res = await request(app)
      .get(`/projects/${project.id as string}/photos`)
      .set(artist.auth);
    expect(res.status).toBe(200);
    expect(res.body.items).toEqual([]);
    expect(res.body.jobId).toBeNull();
  });

  it('403s a plain USER', async () => {
    const { projectId } = await openSession();
    const user = await makeUser('USER');
    expect((await request(app).get(`/projects/${projectId}/photos`).set(user.auth)).status).toBe(403);
  });
});

describe('DELETE /projects/:id/photos', () => {
  it('parks the named photos under deleted/ (a MOVE, never a hard delete)', async () => {
    const { artist, projectId, keyPrefix } = await openSession(4);
    const deleted: string[] = [];
    const spy = mockS3([OK, OK, OK, OK], deleted);

    const res = await request(app)
      .delete(`/projects/${projectId}/photos`)
      .set(artist.auth)
      .send({ keys: ['uploads/photo_0002.jpg'] });

    expect(res.status).toBe(200);
    expect(res.body.deleted).toEqual(['uploads/photo_0002.jpg']);

    const copies = spy.mock.calls
      .map(([cmd]) => cmd as { constructor: { name: string }; input: { Key?: string } })
      .filter((cmd) => cmd.constructor.name === 'CopyObjectCommand');
    expect(copies).toHaveLength(1);
    expect(copies[0]!.input.Key).toBe(`${keyPrefix}deleted/uploads/photo_0002.jpg`);
    // The original is removed only AFTER the copy landed.
    expect(deleted).toEqual([`${keyPrefix}uploads/photo_0002.jpg`]);
  });

  it('FAIL-CLOSED: one escaping key refuses the whole request and moves nothing', async () => {
    const { artist, projectId } = await openSession(4);
    const deleted: string[] = [];
    mockS3([OK, OK, OK, OK], deleted);

    for (const bad of [
      '../escape.jpg',
      '/absolute.jpg',
      'deleted/uploads/photo_0001.jpg',
      'images/EYE/eye_0001.jpg',
      'uploads/photo_1.jpg', // not zero-padded — not a key this builder emits
      'uploads/photo_0001.gif',
    ]) {
      const res = await request(app)
        .delete(`/projects/${projectId}/photos`)
        .set(artist.auth)
        .send({ keys: ['uploads/photo_0001.jpg', bad] });
      expect(res.status).toBe(400);
      expect(res.body.code).toBe('INVALID_KEY');
      // The offending key is never echoed back.
      expect(JSON.stringify(res.body)).not.toContain(bad);
    }
    expect(deleted).toEqual([]);
  });

  it('403s a plain USER', async () => {
    const { projectId } = await openSession();
    const user = await makeUser('USER');
    const res = await request(app)
      .delete(`/projects/${projectId}/photos`)
      .set(user.auth)
      .send({ keys: ['uploads/photo_0001.jpg'] });
    expect(res.status).toBe(403);
  });
});
