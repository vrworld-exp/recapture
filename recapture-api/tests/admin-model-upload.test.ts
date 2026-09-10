// tests/admin-model-upload.test.ts
//
// The staff "Submit model" flow: POST /admin/projects/:id/model/upload-url
// (presigned slot in the RAW bucket, the only one a browser may PUT to) and
// POST /admin/projects/:id/model/upload (validate what landed, promote it into
// the artifacts bucket, record it).
//
// The case this suite exists for is the LAST one: a model submitted by staff
// against SOMEONE ELSE'S project has to show up on that owner's own surfaces —
// their project's modelCount and their models list — because that is the whole
// point of the feature and nothing about it is owner-facing code.
//
// Hermetic: in-memory MongoDB. Presigning is local SigV4 (no network), and every
// real S3 call on the commit path is scripted through `s3Client.send`.
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

const RAW_BUCKET = 'recapture-test-raw';

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

async function makeProject(ownerId: string, status = 'PROCESSING') {
  return Project.create({
    userId: new Types.ObjectId(ownerId),
    name: `P-${new Types.ObjectId().toHexString().slice(-6)}`,
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status,
  });
}

/** A finalized (QUEUED) job with the canonical prefix persisted. */
async function makeFinalizedJob(ownerId: string, projectId: string) {
  const jobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({
    projectName: 'Model upload fixture',
    projectId,
    jobId: jobId.toHexString(),
  });
  await Job.create({
    _id: jobId,
    projectId: new Types.ObjectId(projectId),
    userId: new Types.ObjectId(ownerId),
    state: 'QUEUED',
    objectSize: 'MEDIUM',
    queuedAt: new Date(),
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount: 49,
      uploadedFilesCount: 49,
      checksumAlgo: 'md5',
      rawBucket: RAW_BUCKET,
      rawPrefix: prefix,
      manifestKey: `${prefix}capture_manifest.json`,
    },
  });
  return { prefix };
}

/**
 * A GLB header the sniffer accepts: `glTF` magic, container version 2, and a
 * total-length field that agrees with [totalBytes]. A real file's chunks follow
 * the twelve bytes; the sniffer only ever reads these, so the test never has to
 * build one.
 */
function glbHeader(totalBytes: number): Buffer {
  const header = Buffer.alloc(12);
  header.write('glTF', 0, 'ascii');
  header.writeUInt32LE(2, 4);
  header.writeUInt32LE(totalBytes, 8);
  return header;
}

/** Every S3 command the commit path issues, scripted and recorded. */
function scriptS3(options: {
  /** null → the staged object is absent (HEAD 404). */
  size: number | null;
  header?: Buffer;
  /** Make the cross-bucket copy fail, to exercise the FAILED record path. */
  copyThrows?: boolean;
}) {
  const seen: { command: string; input: Record<string, unknown> }[] = [];
  vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
    input: Record<string, unknown>;
  }) => {
    seen.push({ command: cmd.constructor.name, input: cmd.input });
    switch (cmd.constructor.name) {
      case 'HeadObjectCommand': {
        if (options.size === null) {
          const err = new Error('NotFound');
          err.name = 'NotFound';
          throw err;
        }
        return { ContentLength: options.size, ContentType: 'model/gltf-binary' };
      }
      case 'GetObjectCommand': {
        const body = options.header ?? glbHeader(options.size ?? 0);
        return { Body: { transformToByteArray: async () => new Uint8Array(body) } };
      }
      case 'CopyObjectCommand': {
        if (options.copyThrows) throw new Error('AccessDenied');
        return {};
      }
      case 'DeleteObjectCommand':
        return {};
      default:
        throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }
  }) as never);
  return seen;
}

/** Runs the upload-url call and returns the staged relative key. */
async function stagedKeyFor(projectId: string, auth: { Authorization: string }) {
  const res = await request(app)
    .post(`/admin/projects/${projectId}/model/upload-url`)
    .set(auth)
    .send({});
  expect(res.status).toBe(200);
  return res.body.upload.key as string;
}

describe('POST /admin/projects/:id/model/upload-url', () => {
  it('MODEL_ARTIST gets a presigned PUT under model-upload/ — hashed-only analytics, no URL/key leak', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    const { prefix } = await makeFinalizedJob(owner.id, project.id as string);

    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model/upload-url`)
      .set(artist.auth)
      .send({});

    expect(res.status).toBe(200);
    expect(res.body.upload.key).toMatch(/^model-upload\/[0-9a-f-]+\/model\.glb$/);
    expect(res.body.upload.maxBytes).toBe(env.MODEL_UPLOAD_MAX_BYTES);
    expect(Date.parse(res.body.upload.expiresAt)).toBeGreaterThan(Date.now());

    // The PUT targets the RAW bucket — the only one with a browser CORS policy
    // — at the job's absolute key, content type locked into the signature.
    expect(res.body.upload.url).toContain(RAW_BUCKET);
    expect(res.body.upload.url).toContain(
      encodeURIComponent(`${prefix}${res.body.upload.key}`).replace(/%2F/gi, '/')
    );
    expect(res.body.upload.url).toContain('X-Amz-Signature=');

    // Presigning writes nothing: an abandoned slot must not put a model in the
    // owner's list.
    expect(await ProjectModel.countDocuments({})).toBe(0);

    const events = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] model_upload_url_generated')
    );
    expect(events).toHaveLength(1);
    const serialized = String(events[0]![1]);
    expect(serialized).not.toContain('model-upload/');
    expect(serialized).not.toContain('X-Amz-Signature');
    expect(JSON.parse(serialized).project_id_hash).not.toBe(project.id);
  });

  it('USER → 403; no token → 401', async () => {
    const owner = await makeUser('USER');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);

    const user = await makeUser('USER');
    const forbidden = await request(app)
      .post(`/admin/projects/${project.id}/model/upload-url`)
      .set(user.auth)
      .send({});
    expect(forbidden.status).toBe(403);

    const noAuth = await request(app)
      .post(`/admin/projects/${project.id}/model/upload-url`)
      .send({});
    expect(noAuth.status).toBe(401);
  });

  it('unknown project → 404; no finalized upload → 409 NOT_EXPORTABLE', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');

    const missing = await request(app)
      .post(`/admin/projects/${new Types.ObjectId().toHexString()}/model/upload-url`)
      .set(artist.auth)
      .send({});
    expect(missing.status).toBe(404);

    const draft = await makeProject(owner.id, 'DRAFT');
    const notExportable = await request(app)
      .post(`/admin/projects/${draft.id}/model/upload-url`)
      .set(artist.auth)
      .send({});
    expect(notExportable.status).toBe(409);
    expect(notExportable.body.code).toBe('NOT_EXPORTABLE');
  });
});

describe('POST /admin/projects/:id/model/upload', () => {
  it('promotes the staged GLB into a SUCCEEDED manual model on the artifacts bucket', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    const { prefix } = await makeFinalizedJob(owner.id, project.id as string);
    const key = await stagedKeyFor(project.id as string, artist.auth);

    const size = 3_500_000;
    const seen = scriptS3({ size });
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model/upload`)
      .set(artist.auth)
      .send({ key });

    expect(res.status).toBe(201);
    expect(res.body.model.source).toBe('manual');
    expect(res.body.model.status).toBe('SUCCEEDED');
    expect(res.body.model.selectedKeys).toEqual([]);

    const record = await ProjectModel.findById(res.body.model.id).exec();
    expect(record!.status).toBe('SUCCEEDED');
    expect(record!.createdByUserId.toHexString()).toBe(artist.id);
    expect(record!.createdByRole).toBe('MODEL_ARTIST');
    // Never flagged as a system generation: a person made this model, so the
    // owner must not see the "AI generated" badge on it.
    expect(record!.createdBySystem).toBeUndefined();
    expect(record!.artifacts!.glbBytes).toBe(size);
    expect(record!.artifacts!.glbKey).toBe(`${prefix}models/${res.body.model.id}/model.glb`);
    expect(record!.artifacts!.cdnUrls.glb).toContain(record!.artifacts!.glbKey);

    // The header was read through a RANGED get — a 100 MiB model is never
    // pulled into the API just to be identified.
    const ranged = seen.find((c) => c.command === 'GetObjectCommand');
    expect(ranged!.input.Range).toBe('bytes=0-11');

    // Promoted server-side into the artifacts bucket, then the staging object
    // is dropped so a replay cannot duplicate the model.
    const copy = seen.find((c) => c.command === 'CopyObjectCommand');
    expect(copy!.input.Bucket).toBe(env.S3_BUCKET_ARTIFACTS);
    expect(String(copy!.input.CopySource)).toContain(RAW_BUCKET);
    expect(copy!.input.ContentType).toBe('model/gltf-binary');
    expect(seen.some((c) => c.command === 'DeleteObjectCommand')).toBe(true);

    const events = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] model_upload_submitted')
    );
    expect(events).toHaveLength(1);
    const props = JSON.parse(String(events[0]![1]));
    expect(props.size_bytes).toBe(size);
    expect(props.model_id_hash).not.toBe(res.body.model.id);
  });

  it("the submitted model reaches the OWNER's project and models list", async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);
    const key = await stagedKeyFor(project.id as string, artist.auth);

    scriptS3({ size: 2_048_000 });
    await request(app)
      .post(`/admin/projects/${project.id}/model/upload`)
      .set(artist.auth)
      .send({ key })
      .expect(201);

    // The project card's gate — this is what makes the Models button appear and
    // the stale "Processing" pill disappear on the owner's own list.
    const list = await request(app).get('/projects').set(owner.auth);
    expect(list.status).toBe(200);
    const row = list.body.items.find((p: { id: string }) => p.id === project.id);
    expect(row.modelCount).toBe(1);

    // The owner's model history, and the viewer behind the project detail.
    const models = await request(app).get(`/projects/${project.id}/models`).set(owner.auth);
    expect(models.status).toBe(200);
    expect(models.body.models).toHaveLength(1);
    expect(models.body.models[0].status).toBe('SUCCEEDED');
    expect(models.body.models[0].source).toBe('manual');
    expect(models.body.models[0].glbUrl).toContain('/model.glb');
    // A submitted model is NOT an AI preview — the badge must stay off.
    expect(models.body.models[0].isAutoGenerated).toBe(false);

    const detail = await request(app).get(`/projects/${project.id}`).set(owner.auth);
    expect(detail.body.model.glbUrl).toContain('/model.glb');
    // Nothing is pending: submission is not a generation the owner waits on.
    expect(detail.body.generation).toBeNull();
  });

  it('a key outside the reserved namespace or escaping the job root → 422', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);

    const send = vi.spyOn(s3Client, 'send');

    for (const key of [
      'images/EYE/eye_0001.jpg',
      '../other-project/model.glb',
      'model-upload/../../escape/model.glb',
      '/model-upload/abc/model.glb',
    ]) {
      const res = await request(app)
        .post(`/admin/projects/${project.id}/model/upload`)
        .set(artist.auth)
        .send({ key });
      expect(res.status).toBe(422);
      expect(res.body.code).toBe('INVALID_KEY');
    }

    // Refused before S3 is touched at all, and nothing recorded.
    expect(send).not.toHaveBeenCalled();
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it('nothing at the staged key → 409 UPLOAD_MISSING (also the double-submit guard)', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);
    const key = await stagedKeyFor(project.id as string, artist.auth);

    scriptS3({ size: null });

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model/upload`)
      .set(artist.auth)
      .send({ key });

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('UPLOAD_MISSING');
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it('over the byte ceiling → 413, and no record is left behind', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);
    const key = await stagedKeyFor(project.id as string, artist.auth);

    scriptS3({ size: env.MODEL_UPLOAD_MAX_BYTES + 1 });

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model/upload`)
      .set(artist.auth)
      .send({ key });

    expect(res.status).toBe(413);
    expect(res.body.code).toBe('PAYLOAD_TOO_LARGE');
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it('bytes that are not a glTF 2.0 binary → 415, whatever the file was called', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);

    // A JPEG renamed .glb; a truncated GLB whose header lies about its length;
    // and a glTF 1.0 binary, which no client in this app can load.
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0]);
    const lying = glbHeader(999);
    const v1 = glbHeader(1000);
    v1.writeUInt32LE(1, 4);

    for (const header of [jpeg, lying, v1]) {
      const key = await stagedKeyFor(project.id as string, artist.auth);
      scriptS3({ size: 1000, header });
      const res = await request(app)
        .post(`/admin/projects/${project.id}/model/upload`)
        .set(artist.auth)
        .send({ key });
      expect(res.status).toBe(415);
      expect(res.body.code).toBe('UNSUPPORTED_MEDIA_TYPE');
      vi.restoreAllMocks();
    }

    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it('a failed promotion leaves a FAILED record, never a SUCCEEDED one with a dead URL', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);
    const key = await stagedKeyFor(project.id as string, artist.auth);

    scriptS3({ size: 1000, copyThrows: true });

    const res = await request(app)
      .post(`/admin/projects/${project.id}/model/upload`)
      .set(artist.auth)
      .send({ key });

    expect(res.status).toBe(502);
    const record = await ProjectModel.findOne({}).exec();
    expect(record!.status).toBe('FAILED');
    expect(record!.artifacts).toBeUndefined();
    expect(record!.error!.code).toBe('MODEL_UPLOAD_STORE_FAILED');

    // A FAILED record is not a viewable model, so the owner's gate stays shut.
    const list = await request(app).get('/projects').set(owner.auth);
    const row = list.body.items.find((p: { id: string }) => p.id === project.id);
    expect(row.modelCount).toBe(0);
  });

  it('USER → 403; no token → 401; missing key → 400', async () => {
    const owner = await makeUser('USER');
    const artist = await makeUser('MODEL_ARTIST');
    const project = await makeProject(owner.id);
    await makeFinalizedJob(owner.id, project.id as string);

    const user = await makeUser('USER');
    const forbidden = await request(app)
      .post(`/admin/projects/${project.id}/model/upload`)
      .set(user.auth)
      .send({ key: 'model-upload/a/model.glb' });
    expect(forbidden.status).toBe(403);

    const noAuth = await request(app)
      .post(`/admin/projects/${project.id}/model/upload`)
      .send({ key: 'model-upload/a/model.glb' });
    expect(noAuth.status).toBe(401);

    const empty = await request(app)
      .post(`/admin/projects/${project.id}/model/upload`)
      .set(artist.auth)
      .send({});
    expect(empty.status).toBe(400);
  });
});
