// tests/admin-model-variants.test.ts
//
// The staff models list shows BOTH renditions of a generation — the untouched
// Meshy original and the web-optimized build — so an artist can compare them
// and promote one.
//
// THE INVARIANT THIS SUITE EXISTS TO PROTECT: two entries, ONE record, ONE paid
// generation. `countServerSelectedGenerationsInLast24h` counts ProjectModel
// rows, so if the second entry were ever a second row it would double-count
// Meshy spend against the daily ceiling and corrupt the cost audit.
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import mongoose, { Types } from 'mongoose';
import request from 'supertest';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Project } from '@/models/Project';
import { ProjectModel } from '@/models/ProjectModel';
import { User } from '@/models/User';
import {
  ASSET_PIPELINE_VERSION,
  type AssetManifest,
  type AssetVariantId,
} from '@/models/types/assetManifest.types';

let mongod: MongoMemoryServer;
const app = createApp();

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await Project.deleteMany({});
  await ProjectModel.deleteMany({});
  await User.deleteMany({});
});

function manifest(modelId: string): AssetManifest {
  return {
    modelId,
    pipelineVersion: ASSET_PIPELINE_VERSION,
    generatedAt: new Date().toISOString(),
    variants: [
      {
        id: 'original',
        url: 'https://cdn.example/models/m/model.glb',
        key: 'models/m/model.glb',
        bytes: 7_918_404,
        triangles: 7938,
        textureCount: 3,
        largestTextureBytes: 7_196_137,
        meshoptCompressed: false,
      },
      {
        id: 'web',
        url: 'https://cdn.example/models/m/v1/web.glb',
        key: 'models/m/v1/web.glb',
        bytes: 317_924,
        triangles: 7938,
        textureCount: 1,
        largestTextureBytes: 286_080,
        meshoptCompressed: true,
      },
    ],
    posterUrl: 'https://cdn.example/models/m/preview.png',
    physicalSize: {
      widthMeters: 0.28,
      heightMeters: 0.08,
      depthMeters: 0.2,
      longestDimMeters: 0.28,
    },
    reduction: {
      bytesBefore: 7_918_404,
      bytesAfter: 317_924,
      ratio: 0.0402,
      trianglesBefore: 7938,
      trianglesAfter: 7938,
    },
  };
}

async function seed(options: {
  optimizationStatus?: 'SUCCEEDED' | 'FAILED' | 'SKIPPED';
  activeVariant?: AssetVariantId;
  withManifest?: boolean;
}) {
  const admin = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    role: 'ADMIN',
  });
  const project = await Project.create({
    userId: admin._id,
    name: 'Paneer Tikka',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status: 'COMPLETED',
  });

  const record = await ProjectModel.create({
    projectId: project._id,
    jobId: new Types.ObjectId(),
    source: 'meshy',
    status: 'SUCCEEDED',
    selectedKeys: ['a.jpg', 'b.jpg', 'c.jpg'],
    createdByUserId: admin._id,
    createdByRole: 'ADMIN',
    artifacts: {
      glbKey: 'models/m/model.glb',
      previewImageKey: 'models/m/preview.png',
      cdnUrls: {
        glb: 'https://cdn.example/models/m/model.glb',
        preview: 'https://cdn.example/models/m/preview.png',
      },
    },
  });

  if (options.optimizationStatus) {
    record.optimized = {
      status: options.optimizationStatus,
      pipelineVersion: ASSET_PIPELINE_VERSION,
      activeVariant: options.activeVariant ?? 'original',
      ...(options.withManifest === false ? {} : { manifest: manifest(record.id as string) }),
    };
    record.markModified('optimized');
    await record.save();
  }

  const token = jwt.sign(
    { userId: admin.id as string, authUid: admin.authUid },
    env.JWT_SECRET,
    { expiresIn: '15m' }
  );
  return { token, project, record };
}

describe('GET /admin/projects/:id/models — both renditions', () => {
  it('returns TWO entries for one optimized generation, sharing one id', async () => {
    const { token, project, record } = await seed({ optimizationStatus: 'SUCCEEDED' });

    const res = await request(app)
      .get(`/admin/projects/${project.id}/models`)
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.models).toHaveLength(2);
    expect(res.body.models.map((m: { variant: string }) => m.variant)).toEqual([
      'original',
      'web',
    ]);
    // ONE generation, one record — the ids are deliberately identical so that
    // approve/promote keep working and the spend audit stays truthful.
    for (const model of res.body.models) {
      expect(model.id).toBe(record.id);
    }
  });

  it('points each entry at its own GLB, and carries comparable metrics', async () => {
    const { token, project } = await seed({ optimizationStatus: 'SUCCEEDED' });

    const res = await request(app)
      .get(`/admin/projects/${project.id}/models`)
      .set('Authorization', `Bearer ${token}`);

    const [original, web] = res.body.models;

    expect(original.artifacts.glb).toBe('https://cdn.example/models/m/model.glb');
    expect(web.artifacts.glb).toBe('https://cdn.example/models/m/v1/web.glb');

    expect(original.metrics).toEqual({
      bytes: 7_918_404,
      triangles: 7938,
      textureCount: 3,
      largestTextureBytes: 7_196_137,
    });
    expect(web.metrics).toEqual({
      bytes: 317_924,
      triangles: 7938,
      textureCount: 1,
      largestTextureBytes: 286_080,
    });
  });

  it('the poster is shared — the pipeline never re-renders one', async () => {
    const { token, project } = await seed({ optimizationStatus: 'SUCCEEDED' });

    const res = await request(app)
      .get(`/admin/projects/${project.id}/models`)
      .set('Authorization', `Bearer ${token}`);

    for (const model of res.body.models) {
      expect(model.artifacts.preview).toBe('https://cdn.example/models/m/preview.png');
    }
  });

  it('marks which rendition is actually being served', async () => {
    const { token, project } = await seed({ optimizationStatus: 'SUCCEEDED' });

    const before = await request(app)
      .get(`/admin/projects/${project.id}/models`)
      .set('Authorization', `Bearer ${token}`);
    expect(before.body.models.map((m: { isActiveVariant: boolean }) => m.isActiveVariant)).toEqual([
      true,
      false,
    ]);

    await request(app)
      .patch(`/admin/projects/${project.id}/models/${before.body.models[1].id}/variant`)
      .set('Authorization', `Bearer ${token}`)
      .send({ variant: 'web' });

    const after = await request(app)
      .get(`/admin/projects/${project.id}/models`)
      .set('Authorization', `Bearer ${token}`);
    expect(after.body.models.map((m: { isActiveVariant: boolean }) => m.isActiveVariant)).toEqual([
      false,
      true,
    ]);
  });
});

describe('GET /admin/projects/:id/models — when there is nothing to compare', () => {
  it('returns ONE entry when optimization has not run', async () => {
    const { token, project } = await seed({});

    const res = await request(app)
      .get(`/admin/projects/${project.id}/models`)
      .set('Authorization', `Bearer ${token}`);

    expect(res.body.models).toHaveLength(1);
    expect(res.body.models[0].variant).toBe('original');
    expect(res.body.models[0].isActiveVariant).toBe(true);
    // Unknown, not zero — a 0-byte metric would render as a fake 100% saving.
    expect(res.body.models[0].metrics).toBeUndefined();
  });

  it('returns ONE entry when the model was already small enough to SKIP', async () => {
    const { token, project } = await seed({ optimizationStatus: 'SKIPPED' });

    const res = await request(app)
      .get(`/admin/projects/${project.id}/models`)
      .set('Authorization', `Bearer ${token}`);

    expect(res.body.models).toHaveLength(1);
    expect(res.body.models[0].variant).toBe('original');
  });

  it('returns ONE entry when optimization FAILED — the original still serves', async () => {
    const { token, project } = await seed({
      optimizationStatus: 'FAILED',
      withManifest: false,
    });

    const res = await request(app)
      .get(`/admin/projects/${project.id}/models`)
      .set('Authorization', `Bearer ${token}`);

    expect(res.body.models).toHaveLength(1);
    expect(res.body.models[0].variant).toBe('original');
    expect(res.body.models[0].optimized.status).toBe('FAILED');
  });
});

describe('two entries never mean two generations', () => {
  it('the database still holds exactly ONE record — the spend audit is untouched', async () => {
    const { token, project } = await seed({ optimizationStatus: 'SUCCEEDED' });

    const res = await request(app)
      .get(`/admin/projects/${project.id}/models`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.body.models).toHaveLength(2);

    // The 24h Meshy ceiling counts ROWS. Two list entries must never become two.
    expect(await ProjectModel.countDocuments({ projectId: project._id })).toBe(1);
  });
});
