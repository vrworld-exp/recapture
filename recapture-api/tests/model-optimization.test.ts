// tests/model-optimization.test.ts
//
// The "Optimize" action: the eligibility rule (`canOptimize`), the two routes
// that act on it, and the four places an extra ProjectModel record could leak
// somewhere it does not belong.
//
// The load-bearing assertions here, in order of what they protect:
//   1. a concurrent double POST creates EXACTLY ONE record — the unique partial
//      index on `optimizedFrom` is the race authority, and asserting the status
//      codes alone would pass even if two records were written;
//   2. optimization does NOT count against the server-selected 24h generation
//      ceiling — it costs CPU, never Meshy credits, and eating that cap would
//      make an optimization block a paid generation;
//   3. `pendingOwnerGenerationFor` ignores a running optimization — otherwise
//      the owner sees "creating your 3D model…" for a model they already have;
//   4. an unknown size is NOT a small one — `canOptimize` must be false when
//      `glbBytes` is absent, the same class of bug as reading a missing flag as
//      `false`.
//
// Hermetic: in-memory MongoDB, scripted S3, no worker.
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
import { Job, MODEL_OPTIMIZATION_JOB_TYPE } from '@/models/Job';
import { ProjectModel, type IProjectModel } from '@/models/ProjectModel';
import { RateWindow } from '@/models/RateWindow';
import { buildJobKeyPrefix } from '@/utils/s3Keys';
import {
  canOptimizeModel,
  countServerSelectedGenerationsInLast24h,
  listProjectModels,
  optimizedSourceIdsFor,
  pendingOwnerGenerationFor,
  requestModelOptimization,
} from '@/services/projectModelsService';

const app = createApp();
let mongod: MongoMemoryServer;

/** Comfortably over MODEL_OPTIMIZE_THRESHOLD_BYTES (5 MiB). */
const BIG = 21 * 1024 * 1024;
/** Comfortably under it. */
const SMALL = 2 * 1024 * 1024;
/**
 * The two sides of the 5 MiB gate, a tenth of a MiB out on each side.
 *
 * Written against the literal rather than `env.MODEL_OPTIMIZE_THRESHOLD_BYTES ±
 * 1` on purpose: this pair is what pins the threshold to the number the copy and
 * the docs claim, so a change to the default has to come here and be seen.
 */
const JUST_UNDER = Math.round(4.9 * 1024 * 1024);
const JUST_OVER = Math.round(5.1 * 1024 * 1024);

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  // The unique partial index IS the feature's concurrency guarantee — without
  // syncing it here the double-POST test would pass for the wrong reason.
  await ProjectModel.syncIndexes();
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

/** A project + its finalized capture job + one SUCCEEDED model on it. */
async function seedModel(
  ownerId: string,
  modelOverrides: Partial<IProjectModel> = {},
  artifactOverrides: Record<string, unknown> | null = {}
) {
  const project = await Project.create({
    userId: new Types.ObjectId(ownerId),
    name: `P-${new Types.ObjectId().toHexString().slice(-6)}`,
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status: 'PROCESSING',
  });
  const jobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({
    projectName: project.name,
    projectId: project.id as string,
    jobId: jobId.toHexString(),
  });
  await Job.create({
    _id: jobId,
    projectId: project._id,
    userId: new Types.ObjectId(ownerId),
    state: 'QUEUED',
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount: 3,
      uploadedFilesCount: 3,
      checksumAlgo: 'md5',
      rawBucket: 'recapture-test-raw',
      rawPrefix: prefix,
      manifestKey: `${prefix}capture_manifest.json`,
    },
  });

  const glbKey = `${prefix}models/m/model.glb`;
  const model = await ProjectModel.create({
    projectId: project._id,
    jobId,
    source: 'meshy',
    status: 'SUCCEEDED',
    selectedKeys: ['images/EYE/a.jpg', 'images/EYE/b.jpg', 'images/TOP/c.jpg'],
    createdByUserId: new Types.ObjectId(ownerId),
    createdByRole: 'MODEL_ARTIST',
    ...(artifactOverrides === null
      ? {}
      : {
          artifacts: {
            glbKey,
            cdnUrls: { glb: `https://cdn.example/${glbKey}` },
            glbBytes: BIG,
            ...artifactOverrides,
          },
        }),
    ...modelOverrides,
  });

  return { project, model, prefix, jobId };
}

/** An OPT child of [source] in the given status. */
async function seedOptChild(source: IProjectModel, status: string) {
  return ProjectModel.create({
    projectId: source.projectId,
    jobId: source.jobId,
    source: 'optimized',
    status,
    selectedKeys: [],
    optimizedFrom: source._id,
    createdByUserId: source.createdByUserId,
    createdByRole: 'USER',
  });
}

/** Silences the analytics echo the routes emit outside production. */
function quietAnalytics(): void {
  vi.spyOn(console, 'log').mockImplementation(() => {});
}

describe('canOptimizeModel — the truth table', () => {
  it('true for a big, SUCCEEDED, un-optimized model with a known size', async () => {
    const owner = await makeUser('USER');
    const { model, project } = await seedModel(owner.id);
    const ids = await optimizedSourceIdsFor(project.id as string);
    expect(canOptimizeModel(model, ids)).toBe(true);
  });

  it('false below the threshold', async () => {
    const owner = await makeUser('USER');
    const { model, project } = await seedModel(owner.id, {}, { glbBytes: SMALL });
    const ids = await optimizedSourceIdsFor(project.id as string);
    expect(canOptimizeModel(model, ids)).toBe(false);
  });

  it('false at 4.9 MiB — just under the 5 MiB gate, no button', async () => {
    const owner = await makeUser('USER');
    const { model, project } = await seedModel(owner.id, {}, { glbBytes: JUST_UNDER });
    const ids = await optimizedSourceIdsFor(project.id as string);
    expect(canOptimizeModel(model, ids)).toBe(false);
  });

  it('true at 5.1 MiB — just over the 5 MiB gate, button shown', async () => {
    const owner = await makeUser('USER');
    const { model, project } = await seedModel(owner.id, {}, { glbBytes: JUST_OVER });
    const ids = await optimizedSourceIdsFor(project.id as string);
    expect(canOptimizeModel(model, ids)).toBe(true);
  });

  it('false at EXACTLY the threshold — the rule is strictly greater-than', async () => {
    const owner = await makeUser('USER');
    const { model, project } = await seedModel(
      owner.id,
      {},
      { glbBytes: env.MODEL_OPTIMIZE_THRESHOLD_BYTES }
    );
    const ids = await optimizedSourceIdsFor(project.id as string);
    expect(canOptimizeModel(model, ids)).toBe(false);
  });

  it('false when the size is UNKNOWN — absent is not small', async () => {
    const owner = await makeUser('USER');
    // A record written before glbBytes existed. Treating the missing number as
    // 0 would be the same bug as reading a missing flag as false, only here it
    // HIDES the button on exactly the legacy models the feature is for.
    const { model, project } = await seedModel(owner.id, {}, { glbBytes: undefined });
    const ids = await optimizedSourceIdsFor(project.id as string);
    expect(model.artifacts?.glbBytes).toBeUndefined();
    expect(canOptimizeModel(model, ids)).toBe(false);
  });

  it('false when the record has not SUCCEEDED', async () => {
    const owner = await makeUser('USER');
    const { model, project } = await seedModel(owner.id, { status: 'PROCESSING' });
    const ids = await optimizedSourceIdsFor(project.id as string);
    expect(canOptimizeModel(model, ids)).toBe(false);
  });

  it('false when there is no GLB at all', async () => {
    const owner = await makeUser('USER');
    const { model, project } = await seedModel(owner.id, {}, null);
    const ids = await optimizedSourceIdsFor(project.id as string);
    expect(canOptimizeModel(model, ids)).toBe(false);
  });

  it('false for a record that IS an optimization — no recursion', async () => {
    const owner = await makeUser('USER');
    const { model, project } = await seedModel(owner.id, {
      source: 'optimized',
      optimizedFrom: new Types.ObjectId(),
    });
    const ids = await optimizedSourceIdsFor(project.id as string);
    expect(canOptimizeModel(model, ids)).toBe(false);
  });

  it.each(['QUEUED', 'PROCESSING', 'SUCCEEDED'])(
    'false when a %s OPT child already exists',
    async (status) => {
      const owner = await makeUser('USER');
      const { model, project } = await seedModel(owner.id);
      await seedOptChild(model, status);
      const ids = await optimizedSourceIdsFor(project.id as string);
      expect(canOptimizeModel(model, ids)).toBe(false);
    }
  );

  it('TRUE when the only OPT child FAILED — one blip must not remove the action forever', async () => {
    const owner = await makeUser('USER');
    const { model, project } = await seedModel(owner.id);
    await seedOptChild(model, 'FAILED');
    const ids = await optimizedSourceIdsFor(project.id as string);
    // Deliberate reading of "if opt is present, remove the button": PRESENT
    // means present-and-not-broken. A transient S3 failure otherwise
    // permanently consumes the single slot the unique index allows.
    expect(canOptimizeModel(model, ids)).toBe(true);
  });

  it('false when the caller did not look up the children — FAIL CLOSED', async () => {
    const owner = await makeUser('USER');
    const { model } = await seedModel(owner.id);
    // An omitted set can only ever HIDE a button, never offer one the server
    // would then refuse.
    expect(canOptimizeModel(model)).toBe(false);
  });
});

describe('POST /admin/projects/:id/models/:modelId/optimize', () => {
  it('201s, creates ONE OPT record wired to its source, and enqueues one job', async () => {
    quietAnalytics();
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const { project, model, jobId } = await seedModel(owner.id);

    const res = await request(app)
      .post(`/admin/projects/${project.id}/models/${model.id}/optimize`)
      .set(artist.auth);

    expect(res.status).toBe(201);
    expect(res.body.status).toBe('success');
    expect(res.body.model.source).toBe('optimized');
    expect(res.body.model.status).toBe('QUEUED');
    expect(res.body.model.optimizedFromId).toBe(model.id);
    // An OPT record can never itself be optimized.
    expect(res.body.model.canOptimize).toBe(false);

    const children = await ProjectModel.find({ optimizedFrom: model._id }).exec();
    expect(children).toHaveLength(1);
    // It inherits the CAPTURE job, so its artifacts land under the same prefix
    // as the generation it came from.
    expect(children[0]!.jobId.toHexString()).toBe(jobId.toHexString());

    const jobs = await Job.find({ jobType: MODEL_OPTIMIZATION_JOB_TYPE }).exec();
    expect(jobs).toHaveLength(1);
    expect(jobs[0]!.payload?.modelId).toBe(children[0]!.id);
    expect(jobs[0]!.state).toBe('QUEUED');
  });

  it('a second POST REPLAYS with 200 and creates no second record', async () => {
    quietAnalytics();
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const { project, model } = await seedModel(owner.id);

    const first = await request(app)
      .post(`/admin/projects/${project.id}/models/${model.id}/optimize`)
      .set(artist.auth);
    const second = await request(app)
      .post(`/admin/projects/${project.id}/models/${model.id}/optimize`)
      .set(artist.auth);

    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect(second.body.model.id).toBe(first.body.model.id);
    expect(await ProjectModel.countDocuments({ optimizedFrom: model._id })).toBe(1);
    // The replay must NOT enqueue a second run of the same work.
    expect(await Job.countDocuments({ jobType: MODEL_OPTIMIZATION_JOB_TYPE })).toBe(1);
  });

  it('CONCURRENT double POST creates exactly one record (the E11000 path)', async () => {
    quietAnalytics();
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const { project, model } = await seedModel(owner.id);

    const [a, b] = await Promise.all([
      request(app)
        .post(`/admin/projects/${project.id}/models/${model.id}/optimize`)
        .set(artist.auth),
      request(app)
        .post(`/admin/projects/${project.id}/models/${model.id}/optimize`)
        .set(artist.auth),
    ]);

    // Both requests pass the read checks; the unique index decides. Asserting
    // the COUNT is the point — status codes alone would pass even if two
    // records had been written.
    expect(await ProjectModel.countDocuments({ optimizedFrom: model._id })).toBe(1);
    expect([a.status, b.status].sort()).toEqual([200, 201]);
    expect(a.body.model.id).toBe(b.body.model.id);
  });

  it('409s with a stable code when the model is already small enough', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const { project, model } = await seedModel(owner.id, {}, { glbBytes: SMALL });

    const res = await request(app)
      .post(`/admin/projects/${project.id}/models/${model.id}/optimize`)
      .set(artist.auth);

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('MODEL_ALREADY_SMALL');
    expect(res.body.message).toBeTruthy();
    expect(await ProjectModel.countDocuments({ source: 'optimized' })).toBe(0);
  });

  it('409s when the source is itself an optimization', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const { project, model } = await seedModel(owner.id, {
      source: 'optimized',
      optimizedFrom: new Types.ObjectId(),
    });

    const res = await request(app)
      .post(`/admin/projects/${project.id}/models/${model.id}/optimize`)
      .set(artist.auth);

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('ALREADY_OPTIMIZED');
  });

  it('403s for a non-staff caller', async () => {
    quietAnalytics();
    const owner = await makeUser('USER');
    const { project, model } = await seedModel(owner.id);

    // Even the project's OWNER has no business on the /admin surface.
    const res = await request(app)
      .post(`/admin/projects/${project.id}/models/${model.id}/optimize`)
      .set(owner.auth);

    expect(res.status).toBe(403);
    expect(await ProjectModel.countDocuments({ source: 'optimized' })).toBe(0);
  });

  it('404s for a model that belongs to a DIFFERENT project', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const owner = await makeUser('USER');
    const { model } = await seedModel(owner.id);
    const other = await seedModel(owner.id);

    const res = await request(app)
      .post(`/admin/projects/${other.project.id}/models/${model.id}/optimize`)
      .set(artist.auth);

    expect(res.status).toBe(404);
  });
});

describe('POST /projects/:id/models/:modelId/optimize (owner)', () => {
  it('201s for the project owner', async () => {
    quietAnalytics();
    const owner = await makeUser('USER');
    const { project, model } = await seedModel(owner.id);

    const res = await request(app)
      .post(`/projects/${project.id}/models/${model.id}/optimize`)
      .set(owner.auth);

    expect(res.status).toBe(201);
    expect(res.body.optimization.status).toBe('QUEUED');
    // The owner payload is deliberately minimal — no S3 keys, no optimizedFrom
    // ObjectId, no staff actor ids, no `model` DTO.
    expect(Object.keys(res.body.optimization).sort()).toEqual(['id', 'status']);
    expect(JSON.stringify(res.body)).not.toContain('models/');
  });

  it('404s for a caller who does not own the project — never 403', async () => {
    const owner = await makeUser('USER');
    const stranger = await makeUser('USER');
    const { project, model } = await seedModel(owner.id);

    const res = await request(app)
      .post(`/projects/${project.id}/models/${model.id}/optimize`)
      .set(stranger.auth);

    // Enumeration-safe: "not yours" and "does not exist" are indistinguishable.
    expect(res.status).toBe(404);
    expect(res.body.code).toBe('NOT_FOUND');
    expect(await ProjectModel.countDocuments({ source: 'optimized' })).toBe(0);
  });

  it('a model id from another project is the SAME 404, not a leak', async () => {
    const owner = await makeUser('USER');
    const { project } = await seedModel(owner.id);
    const other = await seedModel(owner.id);

    const res = await request(app)
      .post(`/projects/${project.id}/models/${other.model.id}/optimize`)
      .set(owner.auth);

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('NOT_FOUND');
  });

  it('is rate-limited', async () => {
    quietAnalytics();
    const owner = await makeUser('USER');
    const { project, model } = await seedModel(owner.id);
    const original = env.MODEL_OPTIMIZE_MAX_PER_WINDOW;
    // @ts-expect-error — env is a plain parsed object.
    env.MODEL_OPTIMIZE_MAX_PER_WINDOW = 1;
    try {
      await request(app)
        .post(`/projects/${project.id}/models/${model.id}/optimize`)
        .set(owner.auth);
      const second = await request(app)
        .post(`/projects/${project.id}/models/${model.id}/optimize`)
        .set(owner.auth);
      expect(second.status).toBe(429);
      expect(second.body.code).toBe('RATE_LIMITED');
    } finally {
      // @ts-expect-error — env is a plain parsed object.
      env.MODEL_OPTIMIZE_MAX_PER_WINDOW = original;
    }
  });
});

describe('the four places an extra record must not leak', () => {
  it('optimization does NOT count toward the server-selected 24h ceiling', async () => {
    const owner = await makeUser('USER');
    const { model } = await seedModel(owner.id);

    const before = await countServerSelectedGenerationsInLast24h(owner.id);
    const result = await requestModelOptimization({
      projectId: model.projectId.toHexString(),
      modelId: model.id as string,
      actor: { userId: owner.id, role: 'USER' },
    });
    expect(result.outcome).toBe('CREATED');

    // The OPT record sets neither createdBySystem nor createdByManualButton, so
    // it is invisible to the cap. Optimization costs no Meshy money and must
    // never be able to block a paid generation.
    expect(await countServerSelectedGenerationsInLast24h(owner.id)).toBe(before);
  });

  it('pendingOwnerGenerationFor ignores a running optimization', async () => {
    const owner = await makeUser('USER');
    const { project, model } = await seedModel(owner.id);
    await seedOptChild(model, 'PROCESSING');

    // Without the source filter the owner would be shown "creating your 3D
    // model…" for a model they already have.
    expect(await pendingOwnerGenerationFor(project.id as string)).toBeNull();
  });

  it('pendingOwnerGenerationFor still reports a real pending GENERATION', async () => {
    const owner = await makeUser('USER');
    const { project, model } = await seedModel(owner.id);
    await seedOptChild(model, 'PROCESSING');
    const running = await ProjectModel.create({
      projectId: model.projectId,
      jobId: model.jobId,
      source: 'meshy',
      status: 'PROCESSING',
      selectedKeys: ['images/EYE/a.jpg'],
      createdByUserId: new Types.ObjectId(owner.id),
      createdByRole: 'USER',
    });

    const pending = await pendingOwnerGenerationFor(project.id as string);
    expect(pending?.id).toBe(running.id);
  });

  it('the OPT record appears in the project model LIST (the whole point)', async () => {
    quietAnalytics();
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const { project, model } = await seedModel(owner.id);

    await request(app)
      .post(`/admin/projects/${project.id}/models/${model.id}/optimize`)
      .set(artist.auth);

    const res = await request(app)
      .get(`/admin/projects/${project.id}/models`)
      .set(artist.auth);

    expect(res.status).toBe(200);
    expect(res.body.models).toHaveLength(2);
    const opt = res.body.models.find(
      (m: { source: string }) => m.source === 'optimized'
    );
    expect(opt.optimizedFromId).toBe(model.id);
    // The source row no longer offers the action — it now has a live child.
    const src = res.body.models.find((m: { id: string }) => m.id === model.id);
    expect(src.canOptimize).toBe(false);
  });
});

describe('glbBytes backfill on the list path', () => {
  it('HEADs a legacy record once and writes the size back', async () => {
    const owner = await makeUser('USER');
    const { project, model } = await seedModel(owner.id, {}, { glbBytes: undefined });

    const heads: string[] = [];
    vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
      constructor: { name: string };
      input: { Key?: string };
    }) => {
      if (cmd.constructor.name === 'HeadObjectCommand') {
        heads.push(cmd.input.Key as string);
        return { ContentLength: BIG, ContentType: 'model/gltf-binary' };
      }
      return {};
    }) as never);

    const listed = await listProjectModels(project.id as string);
    expect(heads).toEqual([model.artifacts!.glbKey]);
    // The size is on the records THIS call returns — no refresh needed for the
    // button to appear.
    expect(listed[0]!.artifacts?.glbBytes).toBe(BIG);

    const reread = await ProjectModel.findById(model._id).exec();
    expect(reread!.artifacts?.glbBytes).toBe(BIG);
  });

  it('a HEAD failure degrades to "size unknown", never a failed list', async () => {
    const owner = await makeUser('USER');
    const { project } = await seedModel(owner.id, {}, { glbBytes: undefined });

    vi.spyOn(s3Client, 'send').mockRejectedValue(new Error('S3 is having a day'));

    // A staff user losing the entire model list over one S3 hiccup is far worse
    // than a button that shows up on the next refresh.
    const listed = await listProjectModels(project.id as string);
    expect(listed).toHaveLength(1);
    expect(listed[0]!.artifacts?.glbBytes).toBeUndefined();
  });
});
