// tests/rep-publish.test.ts
//
// The gap this closes, and the two ways closing it could go wrong.
//
// THE GAP: activating a standee binds a code, it does not put a menu online.
// A restaurant whose dishes are all photo-only has no model that will ever
// finish, so `promoteModelToProducts` never fires its auto-publish, and before
// this route the standee stayed dead until the owner signed in on their own.
// The first test here is the whole feature: a rep signs a photo-only restaurant
// up and leaves with a WORKING standee.
//
// FAILURE MODE ONE — the rep and the owner disagree. If this route grew its own
// mapping of the publish result, a gate could render differently for the rep
// than for the owner looking at the same catalog. `gates render identically`
// asserts the two responses byte for byte rather than trusting a comment.
//
// FAILURE MODE TWO — a second, weaker door. This route must be as enumeration-
// safe as every other `/rep` route: a rep with no grant gets exactly the answer
// a nonexistent catalog gives.
import {
  describe,
  it,
  expect,
  beforeAll,
  afterAll,
  beforeEach,
  afterEach,
  vi,
} from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';
import { HeadObjectCommand } from '@aws-sdk/client-s3';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { buildProductImageKey } from '@/utils/productImageKeys';
import { User, type UserRole } from '@/models/User';
import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { Job } from '@/models/Job';
import { Project } from '@/models/Project';
import { ProjectModel } from '@/models/ProjectModel';
import { QrCode } from '@/models/QrCode';
import { QrCodeAssignment } from '@/models/QrCodeAssignment';
import { RateWindow } from '@/models/RateWindow';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import { FakeMirage } from './fixtures/mirageFake';

const app = createApp();
let mongod: MongoMemoryServer;
const mirage = new FakeMirage();

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await QrCode.syncIndexes();
  await Catalog.syncIndexes();
  await CatalogDelegation.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

/** Keys the scripted S3 believes exist. */
const s3Objects = new Map<string, number>();

beforeEach(() => {
  mirage.reset();
  setMirageClient(mirage);
  Object.assign(env, {
    PUBLIC_RESOLVER_BASE_URL: 'https://scan.test',
    MIRAGE_BASE_URL: 'https://mirage.test',
    MIRAGE_API_KEY: 'test-api-key',
    MIRAGE_ADMIN_TOKEN: 'test-admin-token',
    MIRAGE_PUBLIC_BASE_URL: 'https://menu.test',
    PUBLISH_MAX_PER_WINDOW: 10,
    PUBLISH_WINDOW_SECONDS: 3600,
  });
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'info').mockImplementation(() => {});

  s3Objects.clear();
  vi.spyOn(s3Client, 'send').mockImplementation((command: unknown) => {
    if (command instanceof HeadObjectCommand) {
      const key = command.input.Key as string;
      if (!s3Objects.has(key)) {
        const err = new Error('NotFound');
        err.name = 'NotFound';
        return Promise.reject(err);
      }
      return Promise.resolve({ ContentLength: s3Objects.get(key) }) as never;
    }
    return Promise.reject(new Error(`unscripted S3 command: ${String(command)}`));
  });
});

afterEach(async () => {
  vi.restoreAllMocks();
  resetMirageClient();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogPublishRun.deleteMany({}),
    Job.deleteMany({}),
    Project.deleteMany({}),
    ProjectModel.deleteMany({}),
    QrCode.deleteMany({}),
    QrCodeAssignment.deleteMany({}),
    RateWindow.deleteMany({}),
  ]);
});

function tokenFor(id: string, authUid: string): { Authorization: string } {
  const token = jwt.sign({ userId: id, authUid }, env.JWT_SECRET, { expiresIn: '15m' });
  return { Authorization: `Bearer ${token}` };
}

async function makeUser(role: UserRole): Promise<{ id: string; auth: { Authorization: string } }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    role,
  });
  const id = user.id as string;
  return { id, auth: tokenFor(id, user.authUid as string) };
}

/** A rep who has activated one standee, and the catalog they now hold. */
async function activated(
  code: string,
  phone = '+919876543210',
  restaurantName = 'Blue Cafe'
) {
  const rep = await makeUser('SALES_REP');
  await QrCode.create({
    code,
    batchId: new Types.ObjectId(),
    state: 'UNASSIGNED',
    deletedAt: null,
  });
  const res = await request(app)
    .post('/rep/activations')
    .set(rep.auth)
    .send({ code, restaurantName, restaurantPhone: phone });
  expect(res.status).toBe(201);

  const owner = await User.findOne({ phone }).exec();
  return {
    rep,
    catalogId: res.body.catalogId as string,
    owner: {
      id: String(owner!._id),
      auth: tokenFor(String(owner!._id), owner!.authUid as string),
    },
  };
}

/** Adds one photo-only dish — the shape that never auto-publishes. */
async function addPhotoDish(
  rep: { auth: { Authorization: string } },
  catalogId: string,
  name = 'Paneer Tikka'
): Promise<void> {
  const key = buildProductImageKey(
    catalogId,
    new Types.ObjectId().toHexString(),
    new Types.ObjectId().toHexString(),
    'jpg'
  );
  s3Objects.set(key, 1024);
  const res = await request(app)
    .post(`/rep/catalogs/${catalogId}/products`)
    .set(rep.auth)
    .send({ type: 'IMAGE_ONLY', name, imageKey: key });
  expect(res.status).toBe(201);
}

/**
 * A finished capture sitting in SOMEBODY's project, ready to be linked.
 *
 * `ownerOfCapture` is the whole point of the parameter: pass the rep and you
 * get the real rep flow (the dish was shot on the rep's phone, so the Project
 * is theirs); pass a stranger and you get the case the gate must still refuse.
 */
async function makeCapture(ownerOfCapture: string, name: string): Promise<string> {
  const project = await Project.create({
    userId: new Types.ObjectId(ownerOfCapture),
    name: `${name} capture`,
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
  });
  const model = await ProjectModel.create({
    projectId: project._id,
    jobId: new Types.ObjectId(),
    source: 'meshy',
    status: 'SUCCEEDED',
    createdByUserId: new Types.ObjectId(ownerOfCapture),
    createdByRole: 'USER',
    artifacts: {
      glbKey: `dev/x/y/models/${name}/model.glb`,
      cdnUrls: {
        glb: `https://cdn.example.com/${name}.glb`,
        // The preview is what clears PRODUCT_THUMBNAIL_MISSING, so its absence
        // could not be mistaken here for the model gate under test.
        preview: `https://cdn.example.com/${name}.jpg`,
      },
    },
  });
  return model.id as string;
}

describe('the gap: a photo-only restaurant can be put live by the rep', () => {
  it('publishes a catalog whose dishes would never auto-publish', async () => {
    const { rep, catalogId } = await activated('AAAA1111');
    await addPhotoDish(rep, catalogId);

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/publish`)
      .set(rep.auth);

    // 202, not 200: publishing is a background run and this is a receipt.
    expect(res.status).toBe(202);
    expect(res.body.queued).toBe(true);
    expect(res.body.runId).toBeTruthy();
  });

  it('mints the public URL on that first publish', async () => {
    const { rep, catalogId } = await activated('AAAA2222');
    await addPhotoDish(rep, catalogId);

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/publish`)
      .set(rep.auth);

    // Provisioning happens synchronously inside requestPublish so a NAME_TAKEN
    // reaches the rep at the table rather than as a failed background run.
    expect(res.body.publicUrl).toBeTruthy();
  });

  it('actually opens a run against the catalog', async () => {
    const { rep, catalogId } = await activated('AAAA3333');
    await addPhotoDish(rep, catalogId);
    await request(app).post(`/rep/catalogs/${catalogId}/publish`).set(rep.auth);

    const runs = await CatalogPublishRun.find({ catalogId }).lean().exec();
    expect(runs).toHaveLength(1);
    // A run with no job would sit QUEUED forever with the catalog locked.
    const jobs = await Job.find({}).lean().exec();
    expect(jobs.length).toBeGreaterThan(0);
  });
});

describe('the rep and the owner are told the same thing', () => {
  it('renders gates identically to POST /catalog/publish', async () => {
    // An empty catalog is blocked (CATALOG_EMPTY) — the cheapest real gate.
    const { rep, catalogId, owner } = await activated('BBBB1111');

    const repRes = await request(app)
      .post(`/rep/catalogs/${catalogId}/publish`)
      .set(rep.auth);
    const ownerRes = await request(app).post('/catalog/publish').set(owner.auth);

    expect(repRes.status).toBe(422);
    expect(ownerRes.status).toBe(422);
    // BYTE FOR BYTE. If this route ever grows its own gate mapping, this is
    // what fails — before a rep and an owner start describing the same
    // catalog to each other in different words.
    expect(repRes.body).toEqual(ownerRes.body);
  });

  it('reports every failing gate, not just the first', async () => {
    const { rep, catalogId } = await activated('BBBB2222');

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/publish`)
      .set(rep.auth);

    expect(res.body.code).toBe('PUBLISH_BLOCKED');
    expect(Array.isArray(res.body.gates)).toBe(true);
    expect(res.body.gates.length).toBeGreaterThan(0);
  });
});

describe('the delegation gate', () => {
  it('answers a rep with no grant exactly as it answers a missing catalog', async () => {
    const { catalogId } = await activated('CCCC1111');
    const stranger = await makeUser('SALES_REP');

    const notMine = await request(app)
      .post(`/rep/catalogs/${catalogId}/publish`)
      .set(stranger.auth);
    const notThere = await request(app)
      .post(`/rep/catalogs/${new Types.ObjectId().toHexString()}/publish`)
      .set(stranger.auth);

    // Indistinguishable, so /rep cannot be used to discover which catalogs
    // exist — the same promise every other route on this router makes.
    expect(notMine.status).toBe(404);
    expect(notMine.body).toEqual(notThere.body);
  });

  it('answers a malformed id the same way too', async () => {
    const stranger = await makeUser('SALES_REP');
    const res = await request(app).post('/rep/catalogs/not-an-id/publish').set(stranger.auth);

    // A 400 for "not an ObjectId" would still be a distinguishable answer.
    expect(res.status).toBe(404);
  });

  it('is closed to a plain USER', async () => {
    const { catalogId } = await activated('CCCC2222');
    const user = await makeUser('USER');

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/publish`)
      .set(user.auth);

    expect(res.status).toBe(403);
  });

  it('survives a revoked delegation', async () => {
    const { rep, catalogId } = await activated('CCCC3333');
    await addPhotoDish(rep, catalogId);
    await CatalogDelegation.updateMany(
      { catalogId: new Types.ObjectId(catalogId) },
      { $set: { revokedAt: new Date() } }
    );

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/publish`)
      .set(rep.auth);

    // The grant is read per request, so a revoke is effective at once.
    expect(res.status).toBe(404);
  });
});

describe('a dish the rep captured on their own phone', () => {
  // THE BUG THIS PINS. `POST /rep/catalogs/:id/products` widens ownership by
  // `capturedByUserId` because the rep shoots the dish on their own phone — the
  // Project, and so the ProjectModel, is the REP's while the catalog is the
  // RESTAURANT's. The publish gate re-derived ownership without that widening,
  // so it refused, on every attempt and forever, a product it had itself just
  // accepted: the dish showed a finished model and a thumbnail in the app and
  // publish answered PRODUCT_MODEL_NOT_READY with nothing on screen to explain
  // why. Linking and publishing now ask the same question.
  it('publishes rather than blocking on PRODUCT_MODEL_NOT_READY', async () => {
    const { rep, catalogId } = await activated('EEEE1111', '+919876500011', 'Green Grill');
    const modelId = await makeCapture(rep.id, 'trimmer');

    const created = await request(app)
      .post(`/rep/catalogs/${catalogId}/products`)
      .set(rep.auth)
      .send({ type: 'THREE_D', name: 'Trimmer With Box', sourceModelId: modelId });
    expect(created.status).toBe(201);

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/publish`)
      .set(rep.auth);

    expect(res.status).toBe(202);
    expect(res.body.queued).toBe(true);
  });

  it('lets the OWNER publish it too, not just the rep who shot it', async () => {
    // The rep leaves; the owner signs in later and taps Publish. Same catalog,
    // same dish, same widening — the gate keys off the delegation on the
    // catalog, not off who is holding the phone this time.
    const { rep, catalogId, owner } = await activated(
      'EEEE2222',
      '+919876500012',
      'Amber House'
    );
    const modelId = await makeCapture(rep.id, 'kettle');
    await request(app)
      .post(`/rep/catalogs/${catalogId}/products`)
      .set(rep.auth)
      .send({ type: 'THREE_D', name: 'Kettle', sourceModelId: modelId })
      .expect(201);

    const res = await request(app).post('/catalog/publish').set(owner.auth).send({});

    expect(res.status).toBe(202);
  });

  it('still refuses a model belonging to nobody who may touch this catalog', async () => {
    // The widening is exactly one step wide. A stranger's capture has no
    // delegation behind it and is refused as before — this is the test that
    // fails if the fix is ever loosened into "any SUCCEEDED model will do".
    const { rep, catalogId } = await activated('EEEE3333', '+919876500013', 'Ivory Diner');
    const stranger = await makeUser('USER');
    const modelId = await makeCapture(stranger.id, 'stolen');

    // Linking is refused at the door, so the row is planted directly: the gate,
    // not createProduct, is what this test is about.
    const catalog = await Catalog.findById(catalogId).lean().exec();
    await CatalogProduct.create({
      catalogId: new Types.ObjectId(catalogId),
      userId: catalog!.userId,
      type: 'THREE_D',
      name: 'Stolen Chair',
      position: 0,
      sourceModelId: new Types.ObjectId(modelId),
      modelStatus: 'READY',
      assets: {
        glbUrl: 'https://cdn.example.com/stolen.glb',
        thumbnailUrl: 'https://cdn.example.com/stolen.jpg',
      },
    });

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/publish`)
      .set(rep.auth);

    expect(res.status).toBe(422);
    expect(res.body.gates.map((g: { code: string }) => g.code)).toContain(
      'PRODUCT_MODEL_NOT_READY'
    );
  });

  it('re-blocks the dish once the delegation behind it is revoked', async () => {
    // The honest cost of keying off the delegation, written down rather than
    // discovered. Revoking a rep says "this rep may no longer act on this
    // catalog", and their captures stop qualifying — as a gate the owner can
    // see, not a silent change.
    const { rep, catalogId, owner } = await activated(
      'EEEE4444',
      '+919876500014',
      'Copper Pot'
    );
    const modelId = await makeCapture(rep.id, 'lamp');
    await request(app)
      .post(`/rep/catalogs/${catalogId}/products`)
      .set(rep.auth)
      .send({ type: 'THREE_D', name: 'Lamp', sourceModelId: modelId })
      .expect(201);

    await CatalogDelegation.updateMany(
      { catalogId: new Types.ObjectId(catalogId) },
      { $set: { revokedAt: new Date() } }
    );

    const res = await request(app).post('/catalog/publish').set(owner.auth).send({});

    expect(res.status).toBe(422);
    expect(res.body.gates.map((g: { code: string }) => g.code)).toContain(
      'PRODUCT_MODEL_NOT_READY'
    );
  });
});

describe('concurrency and rate', () => {
  it('reports an already-running publish with its run id', async () => {
    const { rep, catalogId } = await activated('DDDD1111');
    await addPhotoDish(rep, catalogId);

    const first = await request(app)
      .post(`/rep/catalogs/${catalogId}/publish`)
      .set(rep.auth);
    const second = await request(app)
      .post(`/rep/catalogs/${catalogId}/publish`)
      .set(rep.auth);

    expect(first.status).toBe(202);
    expect(second.status).toBe(409);
    expect(second.body.code).toBe('PUBLISH_IN_PROGRESS');
    // The client goes straight to polling this rather than guessing.
    expect(second.body.runId).toBe(first.body.runId);
  });

  it('rate-limits on the CATALOG, so a rep can work several restaurants', async () => {
    Object.assign(env, { PUBLISH_MAX_PER_WINDOW: 1 });

    const first = await activated('DDDD2222', '+919876500001', 'Blue Cafe');
    await addPhotoDish(first.rep, first.catalogId);
    // A DIFFERENT NAME, deliberately: two restaurants sharing one name collide
    // in Mirage provisioning and the second answers 409 NAME_TAKEN — which would
    // masquerade here as the rate limit this test is trying to prove is scoped.
    const second = await activated('DDDD3333', '+919876500002', 'Red Kitchen');
    await addPhotoDish(second.rep, second.catalogId);

    const a1 = await request(app)
      .post(`/rep/catalogs/${first.catalogId}/publish`)
      .set(first.rep.auth);
    const a2 = await request(app)
      .post(`/rep/catalogs/${first.catalogId}/publish`)
      .set(first.rep.auth);
    const b1 = await request(app)
      .post(`/rep/catalogs/${second.catalogId}/publish`)
      .set(second.rep.auth);

    expect(a1.status).toBe(202);
    expect(a2.status).toBe(429);
    // A DIFFERENT restaurant is unaffected — the window protects one
    // catalog's Mirage writes, not the rep's working day.
    expect(b1.status).toBe(202);
  });
});
