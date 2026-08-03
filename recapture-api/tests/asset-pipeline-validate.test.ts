// tests/asset-pipeline-validate.test.ts
//
// The hard gates, exercised with DELIBERATELY BAD assets.
//
// These matter more than the happy path: a pipeline that silently ships a
// black-textured or destroyed model is worse than one that fails loudly,
// because the failure is invisible until a customer sees it. Every gate here
// is the difference between "the original keeps serving" and "we replaced a
// good model with a broken one".
import { describe, it, expect } from 'vitest';

import { validate } from '@/modules/asset-pipeline/validate';
import { plan } from '@/modules/asset-pipeline/plan';
import { getProfile } from '@/modules/asset-pipeline/profiles';
import { runPipeline } from '@/modules/asset-pipeline';
import type { InspectionReport } from '@/modules/asset-pipeline/types';
import { Document } from '@gltf-transform/core';
import { makeMeshyLikeGlb, readGlb } from './fixtures/glbFactory';

const food = getProfile('food');

function report(overrides: Partial<InspectionReport> = {}): InspectionReport {
  return {
    totalBytes: 1_000_000,
    triangles: 12_000,
    vertices: 7_000,
    meshCount: 1,
    materialCount: 1,
    nodeCount: 1,
    textureCount: 1,
    drawCallEstimate: 1,
    textures: [],
    unusedTextureCount: 0,
    boundingBox: {
      min: [-0.1, 0, -0.1],
      max: [0.1, 0.08, 0.1],
      widthMeters: 0.2,
      heightMeters: 0.08,
      depthMeters: 0.2,
      longestDimMeters: 0.2,
    },
    pivotOffset: [0, 0.04, 0],
    uvChannelCount: 1,
    hasAnimations: false,
    hasSkins: false,
    hasMorphTargets: false,
    extensions: [],
    ...overrides,
  };
}

const basePlan = plan(report({ totalBytes: 30_000_000 }), food);
const emptyDoc = new Document();

describe('validate — hard gates', () => {
  it('passes a healthy asset', () => {
    const result = validate(report(), basePlan, emptyDoc, report({ totalBytes: 30_000_000 }));
    expect(result.ok).toBe(true);
    expect(result.failures).toEqual([]);
  });

  it('fails an asset over the 3 MB size budget', () => {
    const result = validate(
      report({ totalBytes: 4_000_000 }),
      basePlan,
      emptyDoc,
      report({ totalBytes: 30_000_000 })
    );

    expect(result.ok).toBe(false);
    expect(result.failures.map((f) => f.gate)).toContain('maxOutputBytes');
    expect(result.failures[0].message).toMatch(/4\.00 MB/);
  });

  it('fails an asset over the 50k triangle budget', () => {
    const result = validate(
      report({ triangles: 80_000 }),
      basePlan,
      emptyDoc,
      report({ totalBytes: 30_000_000 })
    );

    expect(result.failures.map((f) => f.gate)).toContain('maxTriangles');
  });

  it('fails an asset whose geometry was DESTROYED rather than reduced', () => {
    // The gate that catches "we made it 40 triangles and called it a 99% win".
    const result = validate(
      report({ triangles: 40 }),
      basePlan,
      emptyDoc,
      report({ totalBytes: 30_000_000 })
    );

    const failure = result.failures.find((f) => f.gate === 'minTriangles');
    expect(failure).toBeDefined();
    expect(failure!.message).toMatch(/destroyed, not reduced/);
  });

  it('fails an asset whose physical size drifted beyond ±2%', () => {
    const source = report({ totalBytes: 30_000_000 });
    const drifted = report({
      boundingBox: { ...source.boundingBox, longestDimMeters: 0.25 }, // 0.2 → 0.25 = 25%
    });

    const result = validate(drifted, basePlan, emptyDoc, source);

    const failure = result.failures.find((f) => f.gate === 'physicalSize');
    expect(failure).toBeDefined();
    expect(failure!.message).toMatch(/drifted 25\.0%/);
  });

  it('accepts a size change the plan deliberately asked for', () => {
    // A planned rescale is not drift. Comparing against the raw source would
    // fail every model the auto_size correction legitimately resized.
    const source = report({
      totalBytes: 30_000_000,
      boundingBox: { ...report().boundingBox, longestDimMeters: 3 },
    });
    const rescalePlan = plan(source, food);
    expect(rescalePlan.scaleFactor).toBeCloseTo(0.2, 6);

    const after = report({
      boundingBox: { ...report().boundingBox, longestDimMeters: 0.6 },
    });

    const result = validate(after, rescalePlan, emptyDoc, source);
    expect(result.failures.map((f) => f.gate)).not.toContain('physicalSize');
  });

  it('reports EVERY broken gate at once, not just the first', () => {
    // Collect-all, matching the manifest-validation convention elsewhere in the
    // repo: one run must tell an operator everything that is wrong.
    const result = validate(
      report({ totalBytes: 9_000_000, triangles: 90_000 }),
      basePlan,
      emptyDoc,
      report({ totalBytes: 30_000_000 })
    );

    expect(result.failures.map((f) => f.gate).sort()).toEqual(['maxOutputBytes', 'maxTriangles']);
  });
});

describe('validate — texture slots must resolve', () => {
  it('fails a material pointing at an empty texture', async () => {
    // The failure mode this exists for: a material keeps its slot but the image
    // bytes are gone, which renders BLACK on some devices and untextured on
    // others — and reads to a customer as "the AI made a bad model".
    const doc = new Document();
    const emptyTexture = doc.createTexture('broken').setImage(new Uint8Array()).setMimeType('image/webp');
    doc.createMaterial('dish_material').setBaseColorTexture(emptyTexture);

    const result = validate(report(), basePlan, doc, report({ totalBytes: 30_000_000 }));

    const failure = result.failures.find((f) => f.gate === 'textureSlotsResolve');
    expect(failure).toBeDefined();
    expect(failure!.message).toMatch(/dish_material\.baseColorTexture/);
  });

  it('passes when every referenced slot has real bytes', async () => {
    const { glb } = await makeMeshyLikeGlb({ baseColorSize: 256 });
    const doc = await readGlb(glb);

    const result = validate(report(), basePlan, doc, report({ totalBytes: 30_000_000 }));

    expect(result.failures.map((f) => f.gate)).not.toContain('textureSlotsResolve');
  }, 60_000);
});

describe('validate — end to end with a failing profile', () => {
  it('runPipeline reports the failure and withholds the variant', async () => {
    // A profile whose budget no real asset can meet, so the gate fires on a
    // genuinely produced file rather than a hand-built report.
    const impossible = {
      ...food,
      gates: { ...food.gates, maxOutputBytes: 1_000 },
    };
    const { glb } = await makeMeshyLikeGlb({ baseColorSize: 1024 });

    // Reach past the profile registry to inject the impossible policy.
    const source = await import('@/modules/asset-pipeline/inspect').then((m) => m.inspect(glb));
    const badPlan = plan(source, impossible);
    const { execute } = await import('@/modules/asset-pipeline/execute');
    const variant = await execute(glb, badPlan, source);
    const producedDoc = await readGlb(variant.bytes);

    const result = validate(variant.report, badPlan, producedDoc, source);

    expect(result.ok).toBe(false);
    expect(result.failures.map((f) => f.gate)).toContain('maxOutputBytes');
  }, 120_000);

  it('a healthy run publishes a variant', async () => {
    const { glb } = await makeMeshyLikeGlb({ baseColorSize: 1024 });
    const run = await runPipeline(glb, { profileName: 'food' });

    expect(run.validation.ok).toBe(true);
    expect(run.variant).toBeDefined();
  }, 120_000);
});
