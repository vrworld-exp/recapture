// tests/admin-projects.test.ts
//
// P7-A staff surface: roles on User, requireRole gate, GET /auth/me, the
// /admin live-projects list/detail/export, and finalize's project-stats write.
// Hermetic: in-memory MongoDB; S3 listing scripted on the shared client
// (presigning stays real — it is LOCAL SigV4 signing, no network).
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
  await RateWindow.deleteMany({});
  vi.restoreAllMocks();
});

/** Creates a real user doc (requireRole reads the DB) + its Bearer header. */
async function makeUser(
  role: UserRole | undefined,
  extras: { phone?: string; email?: string } = {}
): Promise<{ id: string; auth: { Authorization: string } }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    ...(role ? { role } : {}),
    ...extras,
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

async function makeProject(
  ownerId: string,
  status: string,
  overrides: Record<string, unknown> = {}
) {
  return Project.create({
    userId: new Types.ObjectId(ownerId),
    name: `P-${status}-${new Types.ObjectId().toHexString().slice(-6)}`,
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status,
    ...overrides,
  });
}

/** A finalized (QUEUED) job with the canonical key prefix persisted, like
 * createJob + finalize would leave it. */
async function makeFinalizedJob(
  ownerId: string,
  projectId: string,
  { state = 'QUEUED', expectedFilesCount = 49 }: { state?: string; expectedFilesCount?: number } = {}
) {
  const jobId = new Types.ObjectId();
  const scope = { userId: ownerId, projectId, jobId: jobId.toHexString() };
  const prefix = buildJobKeyPrefix(scope);
  return Job.create({
    _id: jobId,
    projectId: new Types.ObjectId(projectId),
    userId: new Types.ObjectId(ownerId),
    state,
    objectSize: 'MEDIUM',
    queuedAt: new Date(),
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount,
      uploadedFilesCount: expectedFilesCount,
      checksumAlgo: 'md5',
      rawBucket: 'recapture-test-raw',
      rawPrefix: prefix,
      manifestKey: `${prefix}capture_manifest.json`,
    },
  });
}

/** Scripts ListObjectsV2 on the shared client: [imageCount] images + the
 * manifest under whatever prefix is asked for. Everything else is unexpected. */
function mockS3List(imageCount: number) {
  return vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
    input: { Prefix?: string };
  }) => {
    if (cmd.constructor.name !== 'ListObjectsV2Command') {
      throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }
    const prefix = cmd.input.Prefix as string;
    return {
      Contents: [
        { Key: `${prefix}capture_manifest.json`, Size: 2048 },
        ...Array.from({ length: imageCount }, (_, i) => ({
          Key: `${prefix}images/EYE/eye_${String(i + 1).padStart(4, '0')}.jpg`,
          Size: 100_000 + i,
        })),
      ],
      IsTruncated: false,
    };
  }) as never);
}

// ── Roles on User ─────────────────────────────────────────────────────────────

describe('User.role', () => {
  it('a pre-role user document (no role field) reads as USER', async () => {
    // Raw insert bypasses mongoose defaults — exactly a pre-migration doc.
    const raw = await User.collection.insertOne({
      authProvider: 'custom',
      authUid: 'legacy|no-role',
      emailVerified: false,
      phoneVerified: false,
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    const loaded = await User.findById(raw.insertedId).exec();
    expect(loaded!.role).toBe('USER');
  });

  it('new users default to USER', async () => {
    const { id } = await makeUser(undefined);
    expect((await User.findById(id).exec())!.role).toBe('USER');
  });
});

// ── GET /auth/me ──────────────────────────────────────────────────────────────

describe('GET /auth/me', () => {
  it('returns id/role/flags/createdAt — and NO raw phone/email', async () => {
    const { id, auth } = await makeUser('MODEL_ARTIST', {
      phone: '+919876543210',
      email: 'artist@example.com',
    });

    const res = await request(app).get('/auth/me').set(auth);

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('success');
    expect(res.body.user).toEqual({
      id,
      role: 'MODEL_ARTIST',
      phoneVerified: false,
      emailVerified: false,
      createdAt: expect.any(String),
    });
    const serialized = JSON.stringify(res.body);
    expect(serialized).not.toContain('+919876543210');
    expect(serialized).not.toContain('artist@example.com');
  });

  it('401 without a token; 401 for a token whose user vanished', async () => {
    expect((await request(app).get('/auth/me')).status).toBe(401);

    const ghost = new Types.ObjectId().toHexString();
    const token = jwt.sign({ userId: ghost, authUid: `test|${ghost}` }, env.JWT_SECRET, {
      expiresIn: '15m',
    });
    const res = await request(app).get('/auth/me').set({ Authorization: `Bearer ${token}` });
    expect(res.status).toBe(401);
    expect(res.body.code).toBe('UNAUTHENTICATED');
  });
});

// ── requireRole gate on /admin ────────────────────────────────────────────────

describe('requireRole on /admin routes', () => {
  it('USER → 403 standard envelope on all three routes (+ admin_access_denied)', async () => {
    const { auth } = await makeUser('USER');
    const someId = new Types.ObjectId().toHexString();
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    for (const path of [
      '/admin/projects',
      `/admin/projects/${someId}`,
      `/admin/projects/${someId}/export`,
    ]) {
      const res = await request(app).get(path).set(auth);
      expect(res.status).toBe(403);
      expect(res.body).toEqual({
        status: 'error',
        code: 'FORBIDDEN',
        message: expect.any(String),
      });
    }

    const denied = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] admin_access_denied')
    );
    expect(denied).toHaveLength(3);
    // Route prop is the path, and nothing PII-shaped rides along.
    expect(String(denied[0]![1])).toContain('"route":"GET /admin/projects"');
  });

  it('MODEL_ARTIST → 200; ADMIN → 200 (privilege inheritance, no exact-equality)', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const admin = await makeUser('ADMIN');

    for (const staff of [artist, admin]) {
      const res = await request(app).get('/admin/projects').set(staff.auth);
      expect(res.status).toBe(200);
      expect(res.body.status).toBe('success');
    }
  });

  it('401 (not 403) without a token', async () => {
    expect((await request(app).get('/admin/projects')).status).toBe(401);
  });

  it('a role change applies on the NEXT request with the SAME token (fresh DB read)', async () => {
    const { id, auth } = await makeUser('USER');
    expect((await request(app).get('/admin/projects').set(auth)).status).toBe(403);

    await User.updateOne({ _id: id }, { $set: { role: 'MODEL_ARTIST' } });
    expect((await request(app).get('/admin/projects').set(auth)).status).toBe(200);
  });
});

// ── GET /admin/projects ───────────────────────────────────────────────────────

describe('GET /admin/projects', () => {
  it('returns other users\' PROCESSING/COMPLETED projects; excludes DRAFT/UPLOADING/FAILED/soft-deleted; ownerId present, zero PII', async () => {
    const ownerA = await makeUser('USER', { phone: '+911111111111', email: 'a@example.com' });
    const ownerB = await makeUser('USER', { phone: '+912222222222' });
    const { auth } = await makeUser('MODEL_ARTIST');

    const live1 = await makeProject(ownerA.id, 'PROCESSING', {
      stats: { totalPhotos: 48, warnings: 2, lastCaptureAt: new Date() },
    });
    const live2 = await makeProject(ownerB.id, 'COMPLETED');
    await makeProject(ownerA.id, 'DRAFT');
    await makeProject(ownerA.id, 'UPLOADING');
    await makeProject(ownerB.id, 'FAILED');
    await makeProject(ownerB.id, 'PROCESSING', { deletedAt: new Date() });

    const res = await request(app).get('/admin/projects').set(auth);

    expect(res.status).toBe(200);
    expect(res.body.items).toHaveLength(2);
    const ids = res.body.items.map((p: { id: string }) => p.id);
    expect(ids).toContain(live1.id);
    expect(ids).toContain(live2.id);

    const item = res.body.items.find((p: { id: string }) => p.id === live1.id);
    expect(item.ownerId).toBe(ownerA.id);
    expect(item.stats).toEqual({
      totalPhotos: 48,
      warnings: 2,
      lastCaptureAt: expect.any(String),
    });

    // PII assertion on the SERIALIZED body: no raw phone/email values or keys.
    const serialized = JSON.stringify(res.body);
    for (const leak of ['+911111111111', '+912222222222', 'a@example.com', '"phone"', '"email"']) {
      expect(serialized).not.toContain(leak);
    }
  });

  it('?status= override narrows to that status; a bogus status is a 400', async () => {
    const owner = await makeUser('USER');
    const { auth } = await makeUser('ADMIN');
    await makeProject(owner.id, 'FAILED');
    await makeProject(owner.id, 'PROCESSING');

    const failed = await request(app).get('/admin/projects?status=FAILED').set(auth);
    expect(failed.status).toBe(200);
    expect(failed.body.items).toHaveLength(1);
    expect(failed.body.items[0].status).toBe('FAILED');

    expect((await request(app).get('/admin/projects?status=BOGUS').set(auth)).status).toBe(400);
  });

  it('cursor pagination is deterministic — pages never overlap or skip', async () => {
    const owner = await makeUser('USER');
    const { auth } = await makeUser('MODEL_ARTIST');
    // Same-second updatedAt values force the _id tie-breaker to matter.
    for (let i = 0; i < 5; i++) await makeProject(owner.id, 'COMPLETED');

    const page1 = await request(app).get('/admin/projects?limit=2').set(auth);
    expect(page1.body.items).toHaveLength(2);
    expect(page1.body.nextCursor).toBeTruthy();

    const page2 = await request(app)
      .get(`/admin/projects?limit=2&cursor=${encodeURIComponent(page1.body.nextCursor)}`)
      .set(auth);
    expect(page2.body.items).toHaveLength(2);

    const page3 = await request(app)
      .get(`/admin/projects?limit=2&cursor=${encodeURIComponent(page2.body.nextCursor)}`)
      .set(auth);
    expect(page3.body.items).toHaveLength(1);
    expect(page3.body.nextCursor).toBeNull();

    const seen = [...page1.body.items, ...page2.body.items, ...page3.body.items].map(
      (p: { id: string }) => p.id
    );
    expect(new Set(seen).size).toBe(5);
  });

  it('emits admin_projects_listed with the actor role + applied filter', async () => {
    const { auth } = await makeUser('ADMIN');
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    await request(app).get('/admin/projects?limit=10').set(auth);

    const events = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] admin_projects_listed')
    );
    expect(events).toHaveLength(1);
    const props = JSON.parse(String(events[0]![1]));
    expect(props).toEqual({ actor_role: 'ADMIN', status_filter: 'default', page_size: 10 });
  });
});

// ── GET /admin/projects/:id ───────────────────────────────────────────────────

describe('GET /admin/projects/:id', () => {
  it('returns the project + the exportable-job summary', async () => {
    const owner = await makeUser('USER');
    const { auth } = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id, 'PROCESSING');
    const job = await makeFinalizedJob(owner.id, project.id as string);

    const res = await request(app).get(`/admin/projects/${project.id}`).set(auth);

    expect(res.status).toBe(200);
    expect(res.body.project.id).toBe(project.id);
    expect(res.body.project.ownerId).toBe(owner.id);
    expect(res.body.job).toEqual({
      id: job.id,
      state: 'QUEUED',
      expectedFilesCount: 49,
      finalizedAt: expect.any(String),
    });
  });

  it('job is null when nothing is finalized; 404 for missing/soft-deleted', async () => {
    const owner = await makeUser('USER');
    const { auth } = await makeUser('MODEL_ARTIST');
    const noJob = await makeProject(owner.id, 'PROCESSING');

    const res = await request(app).get(`/admin/projects/${noJob.id}`).set(auth);
    expect(res.status).toBe(200);
    expect(res.body.job).toBeNull();

    const deleted = await makeProject(owner.id, 'PROCESSING', { deletedAt: new Date() });
    expect((await request(app).get(`/admin/projects/${deleted.id}`).set(auth)).status).toBe(404);
    expect(
      (await request(app).get(`/admin/projects/${new Types.ObjectId().toHexString()}`).set(auth))
        .status
    ).toBe(404);
    expect((await request(app).get('/admin/projects/not-hex').set(auth)).status).toBe(400);
  });
});

// ── GET /admin/projects/:id/export ────────────────────────────────────────────

describe('GET /admin/projects/:id/export', () => {
  it('presigns every listed object with job-root-RELATIVE keys, TTL honored', async () => {
    const owner = await makeUser('USER');
    const { auth } = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id, 'COMPLETED');
    const job = await makeFinalizedJob(owner.id, project.id as string, {
      state: 'COMPLETED',
      expectedFilesCount: 49,
    });
    mockS3List(48);
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app).get(`/admin/projects/${project.id}/export`).set(auth);

    expect(res.status).toBe(200);
    const exp = res.body.export;
    expect(exp.projectId).toBe(project.id);
    expect(exp.jobId).toBe(job.id);
    expect(exp.fileCount).toBe(49);
    expect(exp.expectedFileCount).toBe(49);
    expect(exp.files).toHaveLength(49);

    // TTL: expiresAt - generatedAt == ADMIN_EXPORT_URL_TTL_SECONDS, and the
    // presigned URLs themselves carry the same expiry.
    expect(Date.parse(exp.expiresAt) - Date.parse(exp.generatedAt)).toBe(
      env.ADMIN_EXPORT_URL_TTL_SECONDS * 1000
    );

    // Keys are RELATIVE to the job root — the {env}/{userId}/… internals never
    // leak; the URL still targets the full key.
    const manifest = exp.files.find((f: { key: string }) => f.key === 'capture_manifest.json');
    expect(manifest).toBeDefined();
    expect(manifest.size).toBe(2048);
    const image = exp.files.find((f: { key: string }) => f.key === 'images/EYE/eye_0001.jpg');
    expect(image).toBeDefined();
    expect(image.url).toContain(`X-Amz-Expires=${env.ADMIN_EXPORT_URL_TTL_SECONDS}`);
    expect(image.url).toContain(encodeURIComponent('images/EYE/eye_0001.jpg').replace(/%2F/gi, '/'));
    for (const f of exp.files) {
      expect(f.key.startsWith('dev/')).toBe(false);
      expect(f.key).not.toContain(owner.id);
    }

    // Analytics: hashed ids + counts only — never a presigned URL.
    const events = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] project_export_generated')
    );
    expect(events).toHaveLength(1);
    const props = JSON.parse(String(events[0]![1]));
    expect(props.file_count).toBe(49);
    expect(props.ttl_seconds).toBe(env.ADMIN_EXPORT_URL_TTL_SECONDS);
    expect(props.project_id_hash).not.toBe(project.id);
    expect(String(events[0]![1])).not.toContain('X-Amz-');
  });

  it('fileCount and expectedFileCount are BOTH reported when they disagree', async () => {
    const owner = await makeUser('USER');
    const { auth } = await makeUser('ADMIN');
    const project = await makeProject(owner.id, 'PROCESSING');
    await makeFinalizedJob(owner.id, project.id as string, { expectedFilesCount: 49 });
    mockS3List(30); // 31 objects listed vs 49 expected

    const res = await request(app).get(`/admin/projects/${project.id}/export`).set(auth);

    expect(res.status).toBe(200);
    expect(res.body.export.fileCount).toBe(31);
    expect(res.body.export.expectedFileCount).toBe(49);
  });

  it('409 NOT_EXPORTABLE when no job passed the finalize gate', async () => {
    const owner = await makeUser('USER');
    const { auth } = await makeUser('MODEL_ARTIST');

    // No job at all.
    const bare = await makeProject(owner.id, 'PROCESSING');
    const noJob = await request(app).get(`/admin/projects/${bare.id}/export`).set(auth);
    expect(noJob.status).toBe(409);
    expect(noJob.body).toEqual({
      status: 'error',
      code: 'NOT_EXPORTABLE',
      message: expect.any(String),
    });

    // Only a mid-upload job (UPLOADING never passed verification).
    const midUpload = await makeProject(owner.id, 'PROCESSING');
    await makeFinalizedJob(owner.id, midUpload.id as string, { state: 'UPLOADING' });
    expect(
      (await request(app).get(`/admin/projects/${midUpload.id}/export`).set(auth)).status
    ).toBe(409);
  });

  it('429 with retryAfter once the per-user window is exhausted', async () => {
    const owner = await makeUser('USER');
    const { auth } = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id, 'COMPLETED');
    await makeFinalizedJob(owner.id, project.id as string);
    mockS3List(48);

    for (let i = 0; i < env.ADMIN_EXPORT_MAX_PER_WINDOW; i++) {
      const ok = await request(app).get(`/admin/projects/${project.id}/export`).set(auth);
      expect(ok.status).toBe(200);
    }

    const limited = await request(app).get(`/admin/projects/${project.id}/export`).set(auth);
    expect(limited.status).toBe(429);
    expect(limited.body.code).toBe('RATE_LIMITED');
    expect(limited.body.retryAfter).toBeGreaterThan(0);

    // The window is PER USER: another staff account is unaffected.
    const other = await makeUser('ADMIN');
    expect(
      (await request(app).get(`/admin/projects/${project.id}/export`).set(other.auth)).status
    ).toBe(200);
  });
});

// ── Finalize writes the project's Hub-card stats ──────────────────────────────

describe('finalize → project stats', () => {
  it('sets stats.totalPhotos (manifest-exclusive) and lastCaptureAt on the project', async () => {
    const owner = await makeUser('USER');
    const project = await makeProject(owner.id, 'UPLOADING');
    const jobRes = await request(app)
      .post('/jobs')
      .set(owner.auth)
      .send({ projectId: project.id, objectSize: 'medium', expectedFilesCount: 49 });
    expect(jobRes.status).toBe(201);
    const jobId = jobRes.body.job.id as string;
    await Job.updateOne({ _id: jobId }, { $set: { state: 'UPLOADING' } });

    // Script GET (manifest) + LIST (49 objects) like the finalize suite does.
    const manifestBody = JSON.stringify({
      summary: { totalPhotos: 48, warningsCount: 0, overallComplete: true },
      photos: ['EYE', 'TOP', 'LOW'].flatMap((ring) =>
        Array.from({ length: 16 }, (_, i) => ({ photoId: `${ring}_${i}`, ringName: ring }))
      ),
    });
    vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
      constructor: { name: string };
      input: { Prefix?: string };
    }) => {
      if (cmd.constructor.name === 'GetObjectCommand') {
        return { Body: { transformToString: async () => manifestBody } };
      }
      if (cmd.constructor.name === 'ListObjectsV2Command') {
        return {
          Contents: Array.from({ length: 49 }, (_, i) => ({
            Key: `${cmd.input.Prefix}f_${i}.jpg`,
          })),
          IsTruncated: false,
        };
      }
      throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }) as never);

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(owner.auth);
    expect(res.status).toBe(200);

    const saved = await Project.findById(project.id).exec();
    expect(saved!.status).toBe('PROCESSING');
    expect(saved!.stats!.totalPhotos).toBe(48); // 49 verified − the manifest
    expect(saved!.stats!.lastCaptureAt).toBeInstanceOf(Date);

    // Owner list DTO surfaces the stats (the All Projects card contract).
    const list = await request(app).get('/projects').set(owner.auth);
    const dto = list.body.items.find((p: { id: string }) => p.id === project.id);
    expect(dto.status).toBe('PROCESSING');
    expect(dto.stats.totalPhotos).toBe(48);
    expect(dto.stats.lastCaptureAt).toEqual(expect.any(String));

    // Idempotent replay: stats identical, lastCaptureAt does not drift.
    const replay = await request(app).post(`/jobs/${jobId}/finalize`).set(owner.auth);
    expect(replay.status).toBe(200);
    const after = await Project.findById(project.id).exec();
    expect(after!.stats!.totalPhotos).toBe(48);
    expect(after!.stats!.lastCaptureAt!.toISOString()).toBe(
      saved!.stats!.lastCaptureAt!.toISOString()
    );
  });
});
