// tests/project-status-lifecycle.test.ts
//
// Project status lifecycle wired into the upload pipeline: POST /jobs moves
// the parent project to UPLOADING, finalize moves it to PROCESSING, and every
// transition stamps statusUpdatedAt via projectsService.updateProjectStatus
// (the single helper both sites call). Hermetic: in-memory MongoDB, S3
// scripted on the shared client (same pattern as tests/jobs-finalize.test.ts).
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { Project } from '@/models/Project';
import { Job } from '@/models/Job';
import { updateProjectStatus } from '@/services/projectsService';
import { NotFoundError } from '@/utils/errors';

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
  await Project.deleteMany({});
  await Job.deleteMany({});
  vi.restoreAllMocks();
});

const userId = new Types.ObjectId().toHexString();
const auth = {
  Authorization: `Bearer ${jwt.sign({ userId, authUid: `test|${userId}` }, env.JWT_SECRET, {
    expiresIn: '15m',
  })}`,
};

async function makeProject(): Promise<string> {
  const p = await Project.create({
    userId: new Types.ObjectId(userId),
    name: 'Brass Vase',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
  });
  return p.id as string;
}

async function createJobFor(projectId: string, idempotencyKey?: string) {
  const req = request(app)
    .post('/jobs')
    .set(auth)
    .send({ projectId, objectSize: 'medium', expectedFilesCount: 37 });
  if (idempotencyKey) req.set('Idempotency-Key', idempotencyKey);
  return req;
}

/** Valid with_bottom manifest: 12 photos on each of EYE/TOP/LOW. */
function validManifestBody(): string {
  const photos = ['EYE', 'TOP', 'LOW'].flatMap((ring) =>
    Array.from({ length: 12 }, (_, i) => ({ photoId: `${ring}_${i}`, ringName: ring }))
  );
  return JSON.stringify({
    summary: { totalPhotos: photos.length, warningsCount: 0, overallComplete: true },
    photos,
  });
}

/** Scripts S3 GET (manifest) + LIST (object count) on the shared client. */
function mockS3(objectCount = 37) {
  const impl = async (cmd: { constructor: { name: string }; input: Record<string, unknown> }) => {
    switch (cmd.constructor.name) {
      case 'GetObjectCommand':
        return { Body: { transformToString: async () => validManifestBody() } };
      case 'ListObjectsV2Command': {
        const prefix = cmd.input.Prefix as string;
        return {
          Contents: Array.from({ length: objectCount }, (_, i) => ({ Key: `${prefix}f_${i}.jpg` })),
          IsTruncated: false,
        };
      }
      default:
        throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }
  };
  return vi.spyOn(s3Client, 'send').mockImplementation(impl as never);
}

describe('createJob → UPLOADING', () => {
  it('moves the parent project to UPLOADING with a fresh statusUpdatedAt (no warn on DRAFT path)', async () => {
    const projectId = await makeProject();
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const before = Date.now();

    const res = await createJobFor(projectId);
    expect(res.status).toBe(201);

    const project = await Project.findById(projectId).exec();
    expect(project!.status).toBe('UPLOADING');
    expect(project!.statusUpdatedAt).toBeInstanceOf(Date);
    expect(project!.statusUpdatedAt!.getTime()).toBeGreaterThanOrEqual(before);

    // Normal DRAFT → UPLOADING must be silent (no transition warning).
    const warns = warnSpy.mock.calls.filter((c) => String(c[0]).includes('[ProjectStatus]'));
    expect(warns).toHaveLength(0);
  });

  it('idempotent replay re-asserts UPLOADING, refreshes statusUpdatedAt, and warns (self-transition)', async () => {
    const projectId = await makeProject();
    const key = 'idem-status-1';

    const first = await createJobFor(projectId, key);
    expect(first.status).toBe(201);
    const firstStamp = (await Project.findById(projectId).exec())!.statusUpdatedAt!;

    await new Promise((r) => setTimeout(r, 5));
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const replay = await createJobFor(projectId, key);
    expect(replay.status).toBe(200); // replayed, not re-created

    const after = (await Project.findById(projectId).exec())!;
    expect(after.status).toBe('UPLOADING');
    expect(after.statusUpdatedAt!.getTime()).toBeGreaterThan(firstStamp.getTime());
    expect(
      warnSpy.mock.calls.some((c) => String(c[0]).includes('UPLOADING → UPLOADING'))
    ).toBe(true);
  });

  it('GET /projects/:id serializes status + statusUpdatedAt', async () => {
    const projectId = await makeProject();
    await createJobFor(projectId);

    const res = await request(app).get(`/projects/${projectId}`).set(auth);
    expect(res.status).toBe(200);
    expect(res.body.project.status).toBe('UPLOADING');
    expect(Date.parse(res.body.project.statusUpdatedAt)).not.toBeNaN();
  });
});

describe('finalizeJob → PROCESSING', () => {
  async function makeUploadingJob(projectId: string): Promise<string> {
    const res = await createJobFor(projectId);
    expect(res.status).toBe(201);
    const jobId = res.body.job.id as string;
    await Job.updateOne({ _id: jobId }, { $set: { state: 'UPLOADING' } });
    return jobId;
  }

  it('moves the project to PROCESSING with statusUpdatedAt later than the UPLOADING stamp', async () => {
    const projectId = await makeProject();
    const jobId = await makeUploadingJob(projectId);
    const uploadingStamp = (await Project.findById(projectId).exec())!.statusUpdatedAt!;
    mockS3();
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.spyOn(console, 'log').mockImplementation(() => {});

    await new Promise((r) => setTimeout(r, 5));
    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);
    expect(res.status).toBe(200);

    const project = await Project.findById(projectId).exec();
    expect(project!.status).toBe('PROCESSING');
    expect(project!.statusUpdatedAt!.getTime()).toBeGreaterThan(uploadingStamp.getTime());

    // Normal UPLOADING → PROCESSING must be silent.
    const warns = warnSpy.mock.calls.filter((c) => String(c[0]).includes('[ProjectStatus]'));
    expect(warns).toHaveLength(0);
  });

  it('duplicate finalize (already QUEUED) re-asserts PROCESSING and refreshes statusUpdatedAt', async () => {
    const projectId = await makeProject();
    const jobId = await makeUploadingJob(projectId);
    mockS3();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'warn').mockImplementation(() => {});

    expect((await request(app).post(`/jobs/${jobId}/finalize`).set(auth)).status).toBe(200);
    const firstStamp = (await Project.findById(projectId).exec())!.statusUpdatedAt!;

    await new Promise((r) => setTimeout(r, 5));
    const replay = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);
    expect(replay.status).toBe(200);
    expect(replay.body.idempotentReplay).toBe(true);

    const after = (await Project.findById(projectId).exec())!;
    expect(after.status).toBe('PROCESSING');
    expect(after.statusUpdatedAt!.getTime()).toBeGreaterThan(firstStamp.getTime());
  });
});

describe('updateProjectStatus helper', () => {
  it('sets status + statusUpdatedAt on a valid project', async () => {
    const projectId = await makeProject();
    await updateProjectStatus(projectId, 'CAPTURING');

    const project = await Project.findById(projectId).exec();
    expect(project!.status).toBe('CAPTURING');
    expect(project!.statusUpdatedAt).toBeInstanceOf(Date);
  });

  it('throws NotFoundError when the project does not exist', async () => {
    const missing = new Types.ObjectId().toHexString();
    await expect(updateProjectStatus(missing, 'UPLOADING')).rejects.toBeInstanceOf(NotFoundError);
  });

  it('warns on an unexpected transition but still updates (soft guard)', async () => {
    const projectId = await makeProject(); // status DRAFT
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    await updateProjectStatus(projectId, 'COMPLETED'); // DRAFT → COMPLETED is unexpected

    expect(
      warnSpy.mock.calls.some((c) => String(c[0]).includes('DRAFT → COMPLETED'))
    ).toBe(true);
    expect((await Project.findById(projectId).exec())!.status).toBe('COMPLETED');
  });

  it('a vanished project surfaces the NotFoundError as 500 via finalize (integrity bug, not swallowed)', async () => {
    // Hard-delete the project after the job exists so finalize's PROCESSING
    // write hits a broken job→project reference.
    const projectId = await makeProject();
    const jobRes = await createJobFor(projectId);
    expect(jobRes.status).toBe(201);
    const jobId = jobRes.body.job.id as string;
    await Job.updateOne({ _id: jobId }, { $set: { state: 'UPLOADING' } });
    await Project.deleteOne({ _id: projectId }); // hard delete → broken reference
    mockS3();
    vi.spyOn(console, 'error').mockImplementation(() => {});

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);
    expect(res.status).toBe(500);
    expect(String(res.body.error)).toContain('not found');
  });
});
