// tests/admin-delete-photos.test.ts
//
// DELETE /admin/projects/:id/photos — the staff soft-delete curation surface.
// Verifies the ADMIN-only gate (stricter than browse/export), key containment,
// the move-to-deleted/ semantics, idempotent missing keys, hashed-only
// analytics, and that a soft-deleted object disappears from a later export.
//
// Hermetic: in-memory MongoDB; S3 is scripted on the shared client. The scripted
// store is a mutable Set of absolute keys so Head/Copy/Delete behave like S3
// (Copy adds the dest, Delete removes the source) and assertions can read the
// resulting key set.
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

async function makeProject(ownerId: string, status: string, overrides: Record<string, unknown> = {}) {
  return Project.create({
    userId: new Types.ObjectId(ownerId),
    name: `P-${status}-${new Types.ObjectId().toHexString().slice(-6)}`,
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status,
    ...overrides,
  });
}

/** A finalized (QUEUED) job with the canonical prefix persisted; returns the prefix. */
async function makeFinalizedJob(ownerId: string, projectId: string, state = 'QUEUED') {
  const jobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({ projectName: 'Delete photos fixture', projectId, jobId: jobId.toHexString() });
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

/**
 * Scripts Head/Copy/Delete/List against a mutable Set of absolute keys, so the
 * store behaves like S3. Returns the live Set for post-request assertions.
 */
function mockS3Store(initialKeys: string[]): Set<string> {
  const store = new Set(initialKeys);
  vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
    input: { Key?: string; CopySource?: string; Prefix?: string };
  }) => {
    const name = cmd.constructor.name;
    if (name === 'HeadObjectCommand') {
      if (store.has(cmd.input.Key as string)) return {};
      throw Object.assign(new Error('NotFound'), {
        name: 'NotFound',
        $metadata: { httpStatusCode: 404 },
      });
    }
    if (name === 'CopyObjectCommand') {
      store.add(cmd.input.Key as string);
      return {};
    }
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

describe('DELETE /admin/projects/:id/photos', () => {
  it('ADMIN soft-deletes only the targeted keys (moved to deleted/), reports missing, hashed-only analytics', async () => {
    const owner = await makeUser('USER');
    const admin = await makeUser('ADMIN');
    const project = await makeProject(owner.id, 'PROCESSING');
    const { job, prefix } = await makeFinalizedJob(owner.id, project.id as string);

    const store = mockS3Store([
      `${prefix}images/EYE/eye_0001.jpg`,
      `${prefix}images/EYE/eye_0002.jpg`,
      `${prefix}images/TOP/top_0001.jpg`,
    ]);
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app)
      .delete(`/admin/projects/${project.id}/photos`)
      .set(admin.auth)
      .send({ keys: ['images/EYE/eye_0001.jpg', 'images/EYE/does_not_exist.jpg'] });

    expect(res.status).toBe(200);
    expect(res.body.deleted).toEqual(['images/EYE/eye_0001.jpg']);
    expect(res.body.missing).toEqual(['images/EYE/does_not_exist.jpg']);

    // Targeted key moved under deleted/; the OTHER keys are untouched.
    expect(store.has(`${prefix}images/EYE/eye_0001.jpg`)).toBe(false);
    expect(store.has(`${prefix}deleted/images/EYE/eye_0001.jpg`)).toBe(true);
    expect(store.has(`${prefix}images/EYE/eye_0002.jpg`)).toBe(true);
    expect(store.has(`${prefix}images/TOP/top_0001.jpg`)).toBe(true);

    // Analytics: hashed ids + counts only — no key or presigned URL.
    const events = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] project_photos_deleted')
    );
    expect(events).toHaveLength(1);
    const props = JSON.parse(String(events[0]![1]));
    expect(props.deleted_count).toBe(1);
    expect(props.missing_count).toBe(1);
    expect(props.project_id_hash).not.toBe(project.id);
    expect(props.job_id_hash).not.toBe(job.id);
    const serialized = String(events[0]![1]);
    expect(serialized).not.toContain('eye_0001');
    expect(serialized).not.toContain(prefix);
  });

  it('rejects a key that escapes the job prefix (containment) — nothing moved', async () => {
    const owner = await makeUser('USER');
    const admin = await makeUser('ADMIN');
    const project = await makeProject(owner.id, 'PROCESSING');
    const { prefix } = await makeFinalizedJob(owner.id, project.id as string);

    const store = mockS3Store([`${prefix}images/EYE/eye_0001.jpg`]);

    for (const badKey of [
      '../../other-job/images/EYE/x.jpg',
      '/etc/passwd',
      'images/../../escape.jpg',
      'deleted/images/EYE/eye_0001.jpg', // the reserved namespace is off-limits
    ]) {
      const res = await request(app)
        .delete(`/admin/projects/${project.id}/photos`)
        .set(admin.auth)
        .send({ keys: ['images/EYE/eye_0001.jpg', badKey] });
      expect(res.status).toBe(400);
      expect(res.body.code).toBe('INVALID_REQUEST');
    }

    // Fail-closed: the valid key alongside the bad one was NOT moved.
    expect(store.has(`${prefix}images/EYE/eye_0001.jpg`)).toBe(true);
    expect([...store].some((k) => k.includes('deleted/'))).toBe(false);
  });

  it('MODEL_ARTIST → 403 (delete is ADMIN-only, stricter than browse/export)', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id, 'PROCESSING');
    await makeFinalizedJob(owner.id, project.id as string);

    const res = await request(app)
      .delete(`/admin/projects/${project.id}/photos`)
      .set(artist.auth)
      .send({ keys: ['images/EYE/eye_0001.jpg'] });
    expect(res.status).toBe(403);
    expect(res.body.code).toBe('FORBIDDEN');
  });

  it('USER → 403; no token → 401', async () => {
    const owner = await makeUser('USER');
    const project = await makeProject(owner.id, 'PROCESSING');
    await makeFinalizedJob(owner.id, project.id as string);

    const user = await makeUser('USER');
    const forbidden = await request(app)
      .delete(`/admin/projects/${project.id}/photos`)
      .set(user.auth)
      .send({ keys: ['images/EYE/eye_0001.jpg'] });
    expect(forbidden.status).toBe(403);

    const noAuth = await request(app)
      .delete(`/admin/projects/${project.id}/photos`)
      .send({ keys: ['images/EYE/eye_0001.jpg'] });
    expect(noAuth.status).toBe(401);
  });

  it('unknown project → 404; not-exportable → 409; empty keys → 400', async () => {
    const owner = await makeUser('USER');
    const admin = await makeUser('ADMIN');

    const missing = await request(app)
      .delete(`/admin/projects/${new Types.ObjectId().toHexString()}/photos`)
      .set(admin.auth)
      .send({ keys: ['images/EYE/eye_0001.jpg'] });
    expect(missing.status).toBe(404);

    const noJob = await makeProject(owner.id, 'PROCESSING');
    const notExportable = await request(app)
      .delete(`/admin/projects/${noJob.id}/photos`)
      .set(admin.auth)
      .send({ keys: ['images/EYE/eye_0001.jpg'] });
    expect(notExportable.status).toBe(409);
    expect(notExportable.body.code).toBe('NOT_EXPORTABLE');

    const project = await makeProject(owner.id, 'PROCESSING');
    await makeFinalizedJob(owner.id, project.id as string);
    const emptyBody = await request(app)
      .delete(`/admin/projects/${project.id}/photos`)
      .set(admin.auth)
      .send({ keys: [] });
    expect(emptyBody.status).toBe(400);
  });

  it('a soft-deleted object no longer appears in the export', async () => {
    const owner = await makeUser('USER');
    const admin = await makeUser('ADMIN');
    const project = await makeProject(owner.id, 'COMPLETED');
    const { prefix } = await makeFinalizedJob(owner.id, project.id as string, 'COMPLETED');

    mockS3Store([
      `${prefix}capture_manifest.json`,
      `${prefix}images/EYE/eye_0001.jpg`,
      `${prefix}images/EYE/eye_0002.jpg`,
    ]);

    // Delete one image, then export and confirm it is filtered out.
    const del = await request(app)
      .delete(`/admin/projects/${project.id}/photos`)
      .set(admin.auth)
      .send({ keys: ['images/EYE/eye_0001.jpg'] });
    expect(del.status).toBe(200);

    const exp = await request(app).get(`/admin/projects/${project.id}/export`).set(admin.auth);
    expect(exp.status).toBe(200);
    const keys = exp.body.export.files.map((f: { key: string }) => f.key);
    expect(keys).toContain('images/EYE/eye_0002.jpg');
    expect(keys).toContain('capture_manifest.json');
    expect(keys).not.toContain('images/EYE/eye_0001.jpg');
    // Nothing from the deleted/ namespace leaks into the manifest either.
    expect(keys.some((k: string) => k.startsWith('deleted/'))).toBe(false);
    expect(exp.body.export.fileCount).toBe(2);
  });
});
