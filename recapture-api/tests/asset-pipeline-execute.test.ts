// tests/asset-pipeline-execute.test.ts
//
// End-to-end over REAL bytes: real sharp encodes, real meshopt WASM, real GLB
// round trips. Nothing here is mocked, because the failures worth catching
// (a black texture, a destroyed mesh, a model that renders 4 m wide) only exist
// at the byte level — a mocked pipeline passes while the real one ships a
// broken asset.
//
// Prints a before/after table per case, which is also how a real Meshy sample
// is checked by hand (`npm run pipeline`).
import { describe, it, expect } from 'vitest';

import { runPipeline, largestTexture } from '@/modules/asset-pipeline';
import { inspect } from '@/modules/asset-pipeline/inspect';
import { readGlb, makeMeshyLikeGlb } from './fixtures/glbFactory';
import type { InspectionReport } from '@/modules/asset-pipeline/types';

/** The before/after table the pipeline is judged by. */
function table(label: string, before: InspectionReport, after: InspectionReport): void {
  const row = (r: InspectionReport) => ({
    'size (MB)': (r.totalBytes / 1e6).toFixed(2),
    triangles: r.triangles,
    textures: r.textureCount,
    'largest texture (KB)': (largestTexture(r) / 1e3).toFixed(0),
    'longest dim (m)': r.boundingBox.longestDimMeters.toFixed(3),
  });
  // eslint-disable-next-line no-console
  console.table({ [`${label} — before`]: row(before), [`${label} — after`]: row(after) });
}

describe('asset pipeline — a typical oversized Meshy dish', () => {
  it('cuts a heavy GLB well under budget while keeping the mesh intact', async () => {
    const { glb } = await makeMeshyLikeGlb({
      baseColorSize: 2048,
      constantMetalRough: true,
      sizeMeters: 0.25,
    });

    const run = await runPipeline(glb, { profileName: 'food' });

    expect(run.plan.skip).toBe(false);
    expect(run.validation.ok).toBe(true);
    expect(run.variant).toBeDefined();

    const after = run.variant!.report;
    table('typical dish', run.sourceReport, after);

    // The headline requirement: materially smaller.
    expect(after.totalBytes).toBeLessThan(run.sourceReport.totalBytes);
    expect(after.totalBytes).toBeLessThan(2_000_000);

    // Silhouette survives — this is what "recognisable" means numerically.
    // Welding may merge duplicate vertices, so triangles must not COLLAPSE.
    expect(after.triangles).toBeGreaterThan(run.sourceReport.triangles * 0.9);

    // Geometry is meshopt-encoded for a small decoder on low-end Android.
    expect(after.extensions).toContain('EXT_meshopt_compression');
  }, 120_000);

  it('converts textures to WebP and honours the per-slot budgets', async () => {
    const { glb } = await makeMeshyLikeGlb({ baseColorSize: 2048 });

    const run = await runPipeline(glb, { profileName: 'food' });
    const after = run.variant!.report;

    for (const texture of after.textures) {
      expect(texture.mimeType).toBe('image/webp');
    }
    const baseColor = after.textures.find((t) => t.slots.includes('baseColorTexture'));
    expect(baseColor).toBeDefined();
    // 2048 → the profile's 1024 baseColor budget.
    expect(baseColor!.width).toBeLessThanOrEqual(1024);
    expect(baseColor!.height).toBeLessThanOrEqual(1024);
  }, 120_000);

  it('preserves real-world scale through the whole recipe', async () => {
    // The single most breakable property: meshopt quantizes positions and the
    // custom transforms touch node TRS. If any of them is wrong the dish
    // renders at the wrong size in AR, which is the demo-breaking failure.
    const { glb } = await makeMeshyLikeGlb({ sizeMeters: 0.3 });

    const run = await runPipeline(glb, { profileName: 'food' });
    const after = run.variant!.report;

    expect(run.sourceReport.boundingBox.longestDimMeters).toBeCloseTo(0.3, 2);
    expect(after.boundingBox.longestDimMeters).toBeCloseTo(0.3, 2);
  }, 120_000);
});

describe('asset pipeline — constant metallicRoughness collapse', () => {
  it('removes the flat map entirely and folds it into material factors', async () => {
    const { glb } = await makeMeshyLikeGlb({ constantMetalRough: true });

    const source = await inspect(glb);
    const metalRough = source.textures.find((t) =>
      t.slots.includes('metallicRoughnessTexture')
    );
    expect(metalRough?.isConstantColor).toBe(true);

    const run = await runPipeline(glb, { profileName: 'food' });
    const after = run.variant!.report;

    // The whole texture is gone — not merely resized.
    expect(after.textures.some((t) => t.slots.includes('metallicRoughnessTexture'))).toBe(false);
    expect(after.textureCount).toBeLessThan(source.textureCount);

    // ...and its values survive as scalar factors. Source image was G=128,
    // B=0 → roughness ≈ 0.502, metallic 0.
    const doc = await readGlb(run.variant!.bytes);
    const material = doc.getRoot().listMaterials()[0];
    expect(material.getRoughnessFactor()).toBeCloseTo(128 / 255, 2);
    expect(material.getMetallicFactor()).toBeCloseTo(0, 5);
    expect(material.getMetallicRoughnessTexture()).toBeNull();
  }, 120_000);

  it('leaves a DETAILED metallicRoughness map in place', async () => {
    // The inverse guard: collapsing a real roughness map would flatten glossy
    // gravy and dry naan into the same surface — the exact thing enable_pbr
    // was turned on to distinguish.
    const { glb } = await makeMeshyLikeGlb({ noisyMetalRough: true });

    const run = await runPipeline(glb, { profileName: 'food' });
    const doc = await readGlb(run.variant!.bytes);

    expect(doc.getRoot().listMaterials()[0].getMetallicRoughnessTexture()).not.toBeNull();
  }, 120_000);
});

describe('asset pipeline — awkward Meshy output', () => {
  it('drops textures a mesh with no UVs could never sample', async () => {
    const { glb } = await makeMeshyLikeGlb({ withUVs: false, baseColorSize: 1024 });

    const run = await runPipeline(glb, { profileName: 'food' });
    const after = run.variant!.report;

    expect(run.sourceReport.uvChannelCount).toBe(0);
    expect(after.textureCount).toBe(0);
    expect(run.validation.ok).toBe(true);
  }, 120_000);

  it('prunes a texture no material references', async () => {
    const { glb } = await makeMeshyLikeGlb({ withUnusedTexture: true, baseColorSize: 1024 });

    const run = await runPipeline(glb, { profileName: 'food' });

    expect(run.sourceReport.unusedTextureCount).toBe(1);
    expect(run.variant!.report.unusedTextureCount).toBe(0);
  }, 120_000);

  it('corrects a model whose auto_size came back absurdly large', async () => {
    const { glb } = await makeMeshyLikeGlb({ sizeMeters: 4, baseColorSize: 1024 });

    const run = await runPipeline(glb, { profileName: 'food' });
    const after = run.variant!.report;

    expect(run.sourceReport.boundingBox.longestDimMeters).toBeCloseTo(4, 1);
    expect(run.plan.scaleFactor).toBeLessThan(1);
    // Snapped to the profile's 0.6 m ceiling, and it survives validation.
    expect(after.boundingBox.longestDimMeters).toBeCloseTo(0.6, 2);
    expect(run.validation.ok).toBe(true);
  }, 120_000);

  it('recentres a model whose pivot drifted off the table', async () => {
    const { glb } = await makeMeshyLikeGlb({
      sizeMeters: 0.25,
      pivotOffset: [0.5, 0.4, 0.5],
      baseColorSize: 1024,
    });

    const run = await runPipeline(glb, { profileName: 'food' });
    const after = run.variant!.report;

    expect(run.plan.recentrePivot).toBe(true);
    // Sits ON the table (Y=0) and centred in XZ.
    expect(after.boundingBox.min[1]).toBeCloseTo(0, 3);
    expect(after.pivotOffset[0]).toBeCloseTo(0, 3);
    expect(after.pivotOffset[2]).toBeCloseTo(0, 3);
  }, 120_000);

  it('keeps animation data through the recipe', async () => {
    const { glb } = await makeMeshyLikeGlb({ withAnimation: true, baseColorSize: 1024 });

    const run = await runPipeline(glb, { profileName: 'food' });
    const doc = await readGlb(run.variant!.bytes);

    expect(run.sourceReport.hasAnimations).toBe(true);
    expect(doc.getRoot().listAnimations().length).toBe(1);
  }, 120_000);
});

describe('asset pipeline — skip path', () => {
  it('returns no variant for a model already under the floor', async () => {
    const { glb } = await makeMeshyLikeGlb({ gridSize: 6, baseColorSize: 32 });

    const run = await runPipeline(glb, { profileName: 'food' });

    expect(run.sourceReport.totalBytes).toBeLessThan(512_000);
    expect(run.plan.skip).toBe(true);
    expect(run.variant).toBeUndefined();
    expect(run.validation.ok).toBe(true);
    expect(run.durationsMs.execute).toBe(0);
  }, 120_000);
});

describe('asset pipeline — stage instrumentation', () => {
  it('logs before/after metrics and a duration for every stage', async () => {
    const lines: { message: string; meta: Record<string, unknown> }[] = [];
    const { glb } = await makeMeshyLikeGlb({ baseColorSize: 1024 });

    await runPipeline(glb, {
      profileName: 'food',
      logger: (message, meta) => lines.push({ message, meta }),
      context: { modelId: 'model-1' },
    });

    expect(lines.map((l) => l.message)).toEqual([
      'Asset pipeline: inspected source',
      'Asset pipeline: planned',
      'Asset pipeline: executed',
      'Asset pipeline: validated',
    ]);
    for (const line of lines) {
      expect(typeof line.meta.durationMs).toBe('number');
      // Correlation id present on every line, so a slow model is traceable.
      expect(line.meta.modelId).toBe('model-1');
    }

    const executed = lines.find((l) => l.message.endsWith('executed'))!.meta;
    expect(executed.bytesBefore).toBeGreaterThan(executed.bytesAfter as number);
  }, 120_000);
});
