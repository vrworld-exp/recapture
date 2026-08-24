// tests/photo-upload-transfer.test.ts
//
// THE REGRESSION THAT MATTERS.
//
// The whole artist photo-upload feature rests on one claim: the existing,
// UNMODIFIED per-file transport — POST /jobs/:jobId/uploads/{initiate,part-url,
// complete} — already accepts an `uploads/photo_0001.jpg` key. Its shared guard
// (`loadUploadableJob`, jobsService.ts) applies no jobType filter, and its
// capture-ring containment check fires only when the job-relative key's FIRST
// segment is `images/`.
//
// If this suite ever fails, the "zero transport changes" claim is dead and the
// design needs revisiting — do not "fix" it by loosening the guard.
//
// Hermetic: in-memory MongoDB; the ONE S3 network call
// (CreateMultipartUpload/CompleteMultipartUpload) is spied on the shared
// client, while presigning runs the REAL local SigV4 signer.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { s3Client } from '@/config/s3';
import { Project } from '@/models/Project';
import { Job } from '@/models/Job';
import { User } from '@/models/User';
import { RateWindow } from '@/models/RateWindow';

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

const TWELVE_MIB = 12 * 1024 * 1024;

/** Opens a real photo-upload session; returns the job id + the assigned keys. */
async function openSession(count = 3) {
  const artist = await makeUser('MODEL_ARTIST');
  const project = await makeUploadProject(artist.id);
  const res = await request(app)
    .post(`/projects/${project.id as string}/photos/session`)
    .set(artist.auth)
    .send({ files: files(count) });
  expect(res.status).toBe(201);
  return {
    artist,
    project,
    jobId: res.body.jobId as string,
    keyPrefix: res.body.uploadPlan.keyPrefix as string,
    keys: (res.body.files as Array<{ key: string }>).map((f) => f.key),
  };
}

function mockS3(uploadId = 'photo-upload-id') {
  return vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
  }) => {
    switch (cmd.constructor.name) {
      case 'CreateMultipartUploadCommand':
        return { UploadId: uploadId };
      case 'CompleteMultipartUploadCommand':
        // The route requires an ETag back from S3 — a complete without one is
        // a real 500 (see s3MultipartService), so the fake must supply it.
        return { ETag: '"object-etag"' };
      default:
        throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }
  }) as never);
}

describe('the UNMODIFIED /jobs upload transport accepts an uploads/ key', () => {
  it('initiate 201s for uploads/photo_0001.jpg and flips the job to UPLOADING', async () => {
    const { artist, jobId, keys } = await openSession();
    mockS3();

    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(artist.auth)
      .send({ key: keys[0], fileSize: TWELVE_MIB, partCount: 3 });

    expect(res.status).toBe(201);
    expect(res.body.key).toBe(keys[0]);
    expect(res.body.parts).toHaveLength(3);
    for (const part of res.body.parts) {
      expect(part.url).toContain('X-Amz-Signature=');
    }
    // The EXISTING route owns this transition — the photo path adds none.
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it('part-url 200s for the same key', async () => {
    const { artist, jobId, keys } = await openSession();
    mockS3();
    await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(artist.auth)
      .send({ key: keys[0], fileSize: TWELVE_MIB, partCount: 3 });

    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/part-url`)
      .set(artist.auth)
      .send({ key: keys[0], uploadId: 'photo-upload-id', partNumber: 2 });

    expect(res.status).toBe(200);
    expect(res.body.url).toContain('X-Amz-Signature=');
  });

  it('complete 200s for the same key', async () => {
    const { artist, jobId, keys } = await openSession();
    mockS3();
    await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(artist.auth)
      .send({ key: keys[0], fileSize: TWELVE_MIB, partCount: 1 });

    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/complete`)
      .set(artist.auth)
      .send({
        key: keys[0],
        uploadId: 'photo-upload-id',
        parts: [{ partNumber: 1, etag: 'abc123' }],
      });

    expect(res.status).toBe(200);
  });

  it('every assigned key of the set passes the guard', async () => {
    const { artist, jobId, keys } = await openSession(5);
    mockS3();
    for (const key of keys) {
      const res = await request(app)
        .post(`/jobs/${jobId}/uploads/initiate`)
        .set(artist.auth)
        .send({ key, fileSize: 1024, partCount: 1 });
      expect(res.status).toBe(201);
    }
  });
});

describe('the guard is still a guard', () => {
  it('400s a key OUTSIDE the job prefix', async () => {
    const { artist, jobId } = await openSession();
    mockS3();
    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(artist.auth)
      .send({ key: 'dev/other_project/other_job/uploads/photo_0001.jpg', fileSize: 1024, partCount: 1 });
    expect(res.status).toBe(400);
  });

  it('400s a traversal inside the prefix', async () => {
    const { artist, jobId, keyPrefix } = await openSession();
    mockS3();
    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(artist.auth)
      .send({ key: `${keyPrefix}uploads/../../escape.jpg`, fileSize: 1024, partCount: 1 });
    expect(res.status).toBe(400);
  });

  it("404s another user's job — ownership still comes from the token", async () => {
    const { jobId, keys } = await openSession();
    const stranger = await makeUser('MODEL_ARTIST');
    mockS3();

    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(stranger.auth)
      .send({ key: keys[0], fileSize: 1024, partCount: 1 });

    expect(res.status).toBe(404);
  });

  it('the capture RING check still rejects an images/ key on a photo-upload job', async () => {
    // A photo-upload job has no captureVariant, so it falls back to the default
    // ring set — an images/ key is therefore judged by the SAME rule a capture
    // job's is. What matters is that the check still fires at all: nothing about
    // the uploads/ namespace disabled it.
    const { artist, jobId, keyPrefix } = await openSession();
    mockS3();
    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(artist.auth)
      .send({ key: `${keyPrefix}images/NOPE/x.jpg`, fileSize: 1024, partCount: 1 });
    expect(res.status).toBe(400);
  });
});
