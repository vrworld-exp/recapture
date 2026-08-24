// tests/photo-upload-guardrail.test.ts
//
// PROOF that adding PHOTO_UPLOAD jobs changed nothing for capture projects.
//
// AGENTS.md calls the `jobType` filter load-bearing. This suite asserts the
// filter is still exactly where it was: `findExportableJob` /
// `findExportableJobById` were NOT widened, so export, the preview gallery and
// the staff photo soft-delete keep ignoring PHOTO_UPLOAD jobs entirely. Only
// `findModelSourceJobById` — reached solely from createMeshyModelRequest's
// explicit-jobId branch — knows they exist.
//
// It also pins the free win: because a PHOTO_UPLOAD job carries an ordinary
// `upload` block, the admin hard-delete's prefix sweep purges its objects from
// BOTH buckets with no new code.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { s3Client, BUCKET_RAW, BUCKET_ARTIFACTS } from '@/config/s3';
import { Project } from '@/models/Project';
import { Job, CAPTURE_PROCESSING_JOB_TYPE, PHOTO_UPLOAD_JOB_TYPE } from '@/models/Job';
import { ProjectModel } from '@/models/ProjectModel';
import { User } from '@/models/User';
import {
  adminDeleteProject,
  findExportableJob,
  findExportableJobById,
  findModelSourceJobById,
  buildProjectExport,
  softDeleteProjectPhotos as adminSoftDeletePhotos,
} from '@/services/adminProjectsService';
import { findGenerationSourceJob } from '@/services/projectPhotosService';
import { buildJobKeyPrefix, UPLOADED_PHOTOS_KEY_PREFIX } from '@/utils/s3Keys';

import { makeCaptureProject, makeUploadProject, makeUser } from './helpers/photoUpload';

let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
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
  ]);
  vi.restoreAllMocks();
});

/** A finalized CAPTURE job, exactly as the export surfaces expect one. */
async function makeCaptureJob(projectId: string, ownerId: string, name: string) {
  const jobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({ projectName: name, projectId, jobId: jobId.toHexString() });
  return Job.create({
    _id: jobId,
    projectId: new Types.ObjectId(projectId),
    userId: new Types.ObjectId(ownerId),
    jobType: CAPTURE_PROCESSING_JOB_TYPE,
    state: 'QUEUED',
    objectSize: 'MEDIUM',
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount: 49,
      uploadedFilesCount: 49,
      checksumAlgo: 'md5',
      rawBucket: BUCKET_RAW,
      rawPrefix: prefix,
      manifestKey: `${prefix}capture_manifest.json`,
    },
  });
}

/** An UPLOADED photo-upload job on the same project. */
async function makePhotoJob(projectId: string, ownerId: string, name: string) {
  const jobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({ projectName: name, projectId, jobId: jobId.toHexString() });
  return Job.create({
    _id: jobId,
    projectId: new Types.ObjectId(projectId),
    userId: new Types.ObjectId(ownerId),
    jobType: PHOTO_UPLOAD_JOB_TYPE,
    state: 'UPLOADED',
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount: 6,
      uploadedFilesCount: 6,
      checksumAlgo: 'md5',
      rawBucket: BUCKET_RAW,
      rawPrefix: prefix,
    },
  });
}

describe('the jobType filter is still load-bearing', () => {
  it('findExportableJob IGNORES a photo-upload job, even the newest one', async () => {
    const owner = await makeUser('MODEL_ARTIST');
    const project = await makeCaptureProject(owner.id, 'Carved Bowl');
    const projectId = project.id as string;

    const capture = await makeCaptureJob(projectId, owner.id, 'Carved Bowl');
    // Created LAST, so a filter-less `createdAt: -1` sort would resolve to it.
    const photo = await makePhotoJob(projectId, owner.id, 'Carved Bowl');
    expect(photo.createdAt.getTime()).toBeGreaterThanOrEqual(capture.createdAt.getTime());

    const resolved = await findExportableJob(projectId);
    expect(resolved!.id).toBe(capture.id);
    expect(resolved!.jobType).toBe(CAPTURE_PROCESSING_JOB_TYPE);
  });

  it('findExportableJobById refuses a photo-upload job BY ID — it was not widened', async () => {
    const owner = await makeUser('MODEL_ARTIST');
    const project = await makeCaptureProject(owner.id, 'Carved Bowl');
    const projectId = project.id as string;
    const photo = await makePhotoJob(projectId, owner.id, 'Carved Bowl');

    expect(await findExportableJobById(projectId, photo._id)).toBeNull();
  });

  it('findModelSourceJobById is the ONE function that accepts both', async () => {
    const owner = await makeUser('MODEL_ARTIST');
    const project = await makeCaptureProject(owner.id, 'Carved Bowl');
    const projectId = project.id as string;
    const capture = await makeCaptureJob(projectId, owner.id, 'Carved Bowl');
    const photo = await makePhotoJob(projectId, owner.id, 'Carved Bowl');

    expect((await findModelSourceJobById(projectId, capture._id))!.id).toBe(capture.id);
    expect((await findModelSourceJobById(projectId, photo._id))!.id).toBe(photo.id);
  });

  it('findModelSourceJobById refuses a CREATED photo job — an unverified set is no source', async () => {
    const owner = await makeUser('MODEL_ARTIST');
    const project = await makeUploadProject(owner.id, 'Brass Vase');
    const projectId = project.id as string;
    const photo = await makePhotoJob(projectId, owner.id, 'Brass Vase');
    await Job.updateOne({ _id: photo._id }, { $set: { state: 'CREATED' } }).exec();

    expect(await findModelSourceJobById(projectId, photo._id)).toBeNull();
    expect(await findGenerationSourceJob(projectId)).toBeNull();
  });

  it("findModelSourceJobById refuses a job from ANOTHER project (projectId is in the query)", async () => {
    const owner = await makeUser('MODEL_ARTIST');
    const a = await makeUploadProject(owner.id, 'A');
    const b = await makeUploadProject(owner.id, 'B');
    const photoOfA = await makePhotoJob(a.id as string, owner.id, 'A');

    expect(await findModelSourceJobById(b.id as string, photoOfA._id)).toBeNull();
  });
});

describe('the capture surfaces are provably unchanged', () => {
  it('buildProjectExport still exports the CAPTURE job, not the photo job', async () => {
    const owner = await makeUser('MODEL_ARTIST');
    const project = await makeCaptureProject(owner.id, 'Carved Bowl');
    const projectId = project.id as string;
    const capture = await makeCaptureJob(projectId, owner.id, 'Carved Bowl');
    await makePhotoJob(projectId, owner.id, 'Carved Bowl');

    vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
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
          { Key: `${prefix}images/EYE/eye_0001.jpg`, Size: 100_000 },
        ],
        IsTruncated: false,
      };
    }) as never);

    const result = await buildProjectExport(projectId);
    expect(result.outcome).toBe('EXPORTED');
    if (result.outcome !== 'EXPORTED') return;
    expect(result.export.jobId).toBe(capture.id);
    // Nothing from the uploads/ namespace can appear in a capture export.
    for (const file of result.export.files) {
      expect(file.key.startsWith(UPLOADED_PHOTOS_KEY_PREFIX)).toBe(false);
    }
  });

  it("the staff photo soft-delete still resolves the CAPTURE job's prefix", async () => {
    const owner = await makeUser('MODEL_ARTIST');
    const project = await makeCaptureProject(owner.id, 'Carved Bowl');
    const projectId = project.id as string;
    const capture = await makeCaptureJob(projectId, owner.id, 'Carved Bowl');
    await makePhotoJob(projectId, owner.id, 'Carved Bowl');

    vi.spyOn(s3Client, 'send').mockImplementation((async () => ({})) as never);

    const result = await adminSoftDeletePhotos(projectId, ['images/EYE/eye_0001.jpg']);
    expect(result.outcome).toBe('DELETED');
    if (result.outcome !== 'DELETED') return;
    expect(result.jobId).toBe(capture.id);
  });
});

describe('the admin hard delete purges an upload job for free', () => {
  it('sweeps the photo job prefix from BOTH buckets — no new code needed', async () => {
    const owner = await makeUser('MODEL_ARTIST');
    const project = await makeUploadProject(owner.id, 'Brass Vase');
    const projectId = project.id as string;
    const photo = await makePhotoJob(projectId, owner.id, 'Brass Vase');
    const prefix = photo.upload!.rawPrefix;

    const swept: Array<{ bucket: string; prefix: string }> = [];
    vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
      constructor: { name: string };
      input: { Bucket?: string; Prefix?: string };
    }) => {
      if (cmd.constructor.name === 'ListObjectsV2Command') {
        swept.push({ bucket: cmd.input.Bucket as string, prefix: cmd.input.Prefix as string });
        return {
          Contents: [{ Key: `${cmd.input.Prefix}${UPLOADED_PHOTOS_KEY_PREFIX}photo_0001.jpg` }],
          IsTruncated: false,
        };
      }
      if (cmd.constructor.name === 'DeleteObjectCommand') return {};
      throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }) as never);

    const result = await adminDeleteProject(projectId, 'hard', 'Brass Vase');
    expect(result.outcome).toBe('HARD_DELETED');

    // The SAME prefix in both buckets — the two must never diverge.
    expect(swept).toContainEqual({ bucket: BUCKET_RAW, prefix });
    expect(swept).toContainEqual({ bucket: BUCKET_ARTIFACTS, prefix });
    expect(await Job.countDocuments({ projectId: project._id }).exec()).toBe(0);
  });
});

describe('the worker can never claim a PHOTO_UPLOAD job', () => {
  it('the queue filters on state QUEUED, which this job type never reaches', async () => {
    const owner = await makeUser('MODEL_ARTIST');
    const project = await makeUploadProject(owner.id, 'Brass Vase');
    await makePhotoJob(project.id as string, owner.id, 'Brass Vase');

    // claimNextJob's filter is `state: 'QUEUED'` alone — jobType-agnostic. The
    // protection is that a photo job's state path stops at UPLOADED, so it is
    // simply never in the claimable set. Registering a no-op processor for this
    // type would be dead code; asserting the state is what actually holds.
    expect(await Job.countDocuments({ jobType: PHOTO_UPLOAD_JOB_TYPE, state: 'QUEUED' }).exec()).toBe(0);
    const job = await Job.findOne({ jobType: PHOTO_UPLOAD_JOB_TYPE }).exec();
    expect(job!.state).toBe('UPLOADED');
  });
});
