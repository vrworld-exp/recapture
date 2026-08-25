// tests/model-generation-dedupe.test.ts
//
// One capture → at most ONE server-selected generation, no matter which trigger
// fires. The automatic capture-processor path and the owner "Generate 3D model"
// button share the capture idempotency key (capture:{jobId}), so whichever runs
// first wins and the other REPLAYS instead of paying for a second Meshy task.
//
// This is the regression guard for the "two models per capture" bug: two
// generations meant two charges and two DIFFERENT meshes (Meshy is
// non-deterministic), so the model the owner watched right after capture and the
// one the project showed later were different, and one of the pair would not open.
//
// Hermetic: in-memory MongoDB, scripted S3 (for the button's manifest/list), no
// Meshy. Both feature gates are ON here — that is the whole point of the file.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { env } from '@/config/env';
import { ClientConfig } from '@/models/ClientConfig';
import { Job, MESHY_MODEL_GENERATION_JOB_TYPE } from '@/models/Job';
import { Project } from '@/models/Project';
import { ProjectModel } from '@/models/ProjectModel';
import { RateWindow } from '@/models/RateWindow';
import { User, type UserRole } from '@/models/User';
import { buildJobKeyPrefix } from '@/utils/s3Keys';
import { s3Client } from '@/config/s3';
import { maybeAutoGenerateModel } from '@/services/autoModelGenerationService';
import { generateModelOnDemand } from '@/services/onDemandModelGenerationService';

let mongod: MongoMemoryServer;

/** The manifest the bundle packer actually produces (shared fixture). */
const PACKER_MANIFEST = readFileSync(
  join(__dirname, 'fixtures', 'packer-capture-manifest.json'),
  'utf-8'
);
const PACKER_MANIFEST_JSON = JSON.parse(PACKER_MANIFEST) as {
  photos: { imagePath: string }[];
};
const PACKER_IMAGE_KEYS: string[] = PACKER_MANIFEST_JSON.photos.map((p) => p.imagePath);

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await ProjectModel.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  // BOTH triggers enabled — the duplicate could only ever happen with both on.
  vi.spyOn(env, 'AUTO_MODEL_GENERATION_ENABLED', 'get').mockReturnValue(true);
  vi.spyOn(env, 'MANUAL_MODEL_GENERATION_ENABLED', 'get').mockReturnValue(true);
});

afterEach(async () => {
  await User.deleteMany({});
  await Project.deleteMany({});
  await Job.deleteMany({});
  await ProjectModel.deleteMany({});
  await RateWindow.deleteMany({});
  await ClientConfig.deleteMany({});
  vi.restoreAllMocks();
});

async function makeUser(role?: UserRole) {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    ...(role ? { role } : {}),
  });
  return { id: user.id as string };
}

/** A project with one finalized capture job under a real key prefix. */
async function makeCapturedProject(ownerId: string) {
  const project = await Project.create({
    userId: new Types.ObjectId(ownerId),
    name: 'Dedupe test',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status: 'COMPLETED',
  });
  const jobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({
    projectName: project.name,
    projectId: project.id as string,
    jobId: jobId.toHexString(),
  });
  const job = await Job.create({
    _id: jobId,
    projectId: project._id,
    userId: new Types.ObjectId(ownerId),
    state: 'QUEUED',
    objectSize: 'MEDIUM',
    queuedAt: new Date(),
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount: 37,
      uploadedFilesCount: 37,
      checksumAlgo: 'md5',
      rawBucket: 'recapture-test-raw',
      rawPrefix: prefix,
      manifestKey: `${prefix}capture_manifest.json`,
    },
  });
  return { project, job, prefix };
}

/** Scripts S3 for the button path (manifest read + object list, absolute keys). */
function mockS3(prefix: string) {
  vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
  }) => {
    switch (cmd.constructor.name) {
      case 'GetObjectCommand':
        return { Body: { transformToString: async () => PACKER_MANIFEST } };
      case 'ListObjectsV2Command':
        return {
          Contents: [
            `${prefix}capture_manifest.json`,
            ...PACKER_IMAGE_KEYS.map((k) => `${prefix}${k}`),
          ].map((Key) => ({ Key })),
          IsTruncated: false,
        };
      default:
        throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }
  }) as never);
}

const queuedModelJobs = () =>
  Job.countDocuments({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE }).exec();

describe('one server-selected generation per capture', () => {
  it('button first, then auto → the auto path REPLAYS (one model, one charge)', async () => {
    const owner = await makeUser();
    const { project, job, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    const button = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: owner.id, role: 'USER' },
    });
    const auto = await maybeAutoGenerateModel({
      job: job as never,
      manifest: PACKER_MANIFEST_JSON,
      availableKeys: PACKER_IMAGE_KEYS,
    });

    expect(button.outcome).toBe('ENQUEUED');
    // The capture already has a generation — the automatic path must not add one.
    expect(auto).toEqual({ outcome: 'SKIPPED', reason: 'ALREADY_EXISTS' });
    expect(await ProjectModel.countDocuments({})).toBe(1);
    expect(await queuedModelJobs()).toBe(1);
  });

  it('auto first, then button → the button REPLAYS the same model', async () => {
    const owner = await makeUser();
    const { project, job, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    const auto = await maybeAutoGenerateModel({
      job: job as never,
      manifest: PACKER_MANIFEST_JSON,
      availableKeys: PACKER_IMAGE_KEYS,
    });
    const button = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: owner.id, role: 'USER' },
    });

    expect(auto.outcome).toBe('ENQUEUED');
    expect(button.outcome).toBe('REPLAYED');
    if (auto.outcome !== 'ENQUEUED' || button.outcome !== 'REPLAYED') return;
    // Same record → the owner watches, and later re-opens, the SAME model.
    expect(button.modelId).toBe(auto.modelId);
    expect(await ProjectModel.countDocuments({})).toBe(1);
    expect(await queuedModelJobs()).toBe(1);
  });

  it('a concurrent auto + button race still settles to one model', async () => {
    const owner = await makeUser();
    const { project, job, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    // Both pass their pre-check before either inserts — the unique index is the
    // authority, exactly as it is for two concurrent presses.
    const [button, auto] = await Promise.all([
      generateModelOnDemand({
        projectId: project.id as string,
        actor: { userId: owner.id, role: 'USER' },
      }),
      maybeAutoGenerateModel({
        job: job as never,
        manifest: PACKER_MANIFEST_JSON,
        availableKeys: PACKER_IMAGE_KEYS,
      }),
    ]);

    // Whichever won, exactly one record and one queued generation exist.
    expect([button.outcome === 'ENQUEUED', auto.outcome === 'ENQUEUED']).toContain(true);
    expect(await ProjectModel.countDocuments({})).toBe(1);
    expect(await queuedModelJobs()).toBe(1);
  });

  it('a forced staff regenerate still creates a NEW model (dedupe is not a lock)', async () => {
    const owner = await makeUser();
    const staff = await makeUser('ADMIN');
    const { project, job, prefix } = await makeCapturedProject(owner.id);
    mockS3(prefix);

    await maybeAutoGenerateModel({
      job: job as never,
      manifest: PACKER_MANIFEST_JSON,
      availableKeys: PACKER_IMAGE_KEYS,
    });
    const forced = await generateModelOnDemand({
      projectId: project.id as string,
      actor: { userId: staff.id, role: 'ADMIN' },
      force: true,
    });

    expect(forced.outcome).toBe('ENQUEUED');
    expect(await ProjectModel.countDocuments({})).toBe(2);
    expect(await queuedModelJobs()).toBe(2);
  });
});
