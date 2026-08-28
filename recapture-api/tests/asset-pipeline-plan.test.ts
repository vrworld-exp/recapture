// tests/asset-pipeline-plan.test.ts
//
// plan() is the pipeline's only decision-making code, and it is PURE — so it
// gets the densest tests in the module. Everything here runs without a GLB, a
// buffer, or an encoder: report in, decisions out.
//
// The cases are the five shapes Meshy actually produces: an oversized model, an
// already-small one, one with no UVs, one with a flat metalRough map, and one
// carrying animation data.
import { describe, it, expect } from 'vitest';

import { plan } from '@/modules/asset-pipeline/plan';
import { getProfile } from '@/modules/asset-pipeline/profiles';
import type { InspectionReport, TextureReport } from '@/modules/asset-pipeline/types';
import { ASSET_PIPELINE_VERSION } from '@/models/types/assetManifest.types';

const food = getProfile('food');

function texture(overrides: Partial<TextureReport> = {}): TextureReport {
  return {
    name: 'baseColor',
    slots: ['baseColorTexture'],
    mimeType: 'image/png',
    width: 2048,
    height: 2048,
    bytes: 4_000_000,
    isConstantColor: false,
    ...overrides,
  };
}

/** A typical oversized Meshy dish: 30 MB, 2k textures, correct auto_size. */
function report(overrides: Partial<InspectionReport> = {}): InspectionReport {
  return {
    totalBytes: 30_000_000,
    triangles: 12_000,
    vertices: 7_000,
    meshCount: 1,
    materialCount: 1,
    nodeCount: 1,
    textureCount: 1,
    drawCallEstimate: 1,
    textures: [texture()],
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

describe('plan — oversized model (the common case)', () => {
  it('optimizes, keeps the profile texture rules, and stamps the pipeline version', () => {
    const result = plan(report(), food);

    expect(result.skip).toBe(false);
    expect(result.pipelineVersion).toBe(ASSET_PIPELINE_VERSION);
    expect(result.profileName).toBe('food');
    expect(result.textureRules).toEqual(food.textureRules);
    expect(result.meshoptLevel).toBe('high');
    // Gates are copied onto the plan so report.json is self-contained.
    expect(result.gates).toEqual(food.gates);
  });

  it('leaves scale alone when auto_size already returned a plausible size', () => {
    // The regression this guards: unconditionally renormalizing scale (correct
    // for a generator that returns unit-normalised geometry) would SHRINK every
    // correctly-sized model, because the preset asks Meshy for auto_size.
    const result = plan(report(), food);

    expect(result.scaleFactor).toBe(1);
    expect(result.scaleReason).toContain('auto_size worked');
  });
});

describe('plan — already-small model', () => {
  it('skips everything under the floor rather than re-encoding for no gain', () => {
    const result = plan(report({ totalBytes: 400_000 }), food);

    expect(result.skip).toBe(true);
    expect(result.skipReason).toMatch(/0\.40 MB/);
    expect(result.textureRules).toEqual([]);
    expect(result.collapseConstantSlots).toEqual([]);
    expect(result.scaleFactor).toBe(1);
  });

  it('treats exactly-at-the-floor as small enough (boundary is inclusive)', () => {
    expect(plan(report({ totalBytes: food.skipUnderBytes }), food).skip).toBe(true);
    expect(plan(report({ totalBytes: food.skipUnderBytes + 1 }), food).skip).toBe(false);
  });
});

describe('plan — missing UVs', () => {
  const noUVs = report({
    uvChannelCount: 0,
    textures: [texture(), texture({ name: 'normal', slots: ['normalTexture'] })],
    textureCount: 2,
  });

  it('drops every texture instead of resizing images nothing can sample', () => {
    const result = plan(noUVs, food);

    expect(result.textureRules).toEqual([]);
    expect(result.dropTextures).toEqual(['baseColor', 'normal']);
    expect(result.notes.join(' ')).toMatch(/no UV channels/);
  });
});

describe('plan — constant metallicRoughness map', () => {
  it('collapses a flat map into material factors', () => {
    const result = plan(
      report({
        textures: [
          texture(),
          texture({
            name: 'metallicRoughness',
            slots: ['metallicRoughnessTexture'],
            isConstantColor: true,
            constantColor: [0, 128, 0, 255],
          }),
        ],
        textureCount: 2,
      }),
      food
    );

    expect(result.collapseConstantSlots).toEqual(['metallicRoughnessTexture']);
    expect(result.notes.join(' ')).toMatch(/Constant-colour map/);
  });

  it('does NOT collapse a detailed metallicRoughness map', () => {
    const result = plan(
      report({
        textures: [
          texture(),
          texture({ name: 'metallicRoughness', slots: ['metallicRoughnessTexture'] }),
        ],
        textureCount: 2,
      }),
      food
    );

    expect(result.collapseConstantSlots).toEqual([]);
  });

  it('does NOT collapse a flat baseColor — a plain white plate is legitimate', () => {
    // Deliberate policy, not an oversight: collapsing albedo changes how the
    // material responds to UV transforms, for one small texture's worth of win.
    const result = plan(
      report({
        textures: [texture({ isConstantColor: true, constantColor: [255, 255, 255, 255] })],
      }),
      food
    );

    expect(result.collapseConstantSlots).toEqual([]);
  });

  it('ignores a constant texture that no material references', () => {
    const result = plan(
      report({
        textures: [texture({ name: 'orphan', slots: [], isConstantColor: true })],
      }),
      food
    );

    expect(result.collapseConstantSlots).toEqual([]);
    expect(result.dropTextures).toEqual(['orphan']);
  });
});

describe('plan — model with animations', () => {
  it('still optimizes, but records that merging stays conservative', () => {
    const result = plan(report({ hasAnimations: true, hasSkins: true }), food);

    expect(result.skip).toBe(false);
    expect(result.notes.join(' ')).toMatch(/animation\/skin\/morph/);
  });

  it('records the same for morph targets alone', () => {
    const result = plan(report({ hasMorphTargets: true }), food);
    expect(result.notes.join(' ')).toMatch(/animation\/skin\/morph/);
  });
});

describe('plan — geometry budget (the simplify decision)', () => {
  // This decision is what pays for high-fidelity generation. Meshy is asked for
  // ~200k triangles so thin features survive; without a decimation here the
  // produced variant fails gates.maxTriangles, is discarded, and owners keep
  // being served an original their WebView cannot load.

  it('decimates a high-triangle source down to the profile budget', () => {
    const result = plan(report({ triangles: 200_704 }), food);

    expect(result.simplifyRatio).toBeCloseTo(food.simplify.targetTriangles / 200_704, 6);
    expect(result.simplifyRatio).toBeLessThan(1);
    expect(result.simplifyError).toBe(food.simplify.errorTolerance);
    // Read off the profile, not pinned to a number: the budget is a tuning
    // knob that has moved once already (35k → 60k with pipeline v3), and a
    // literal here fails the retune rather than the behaviour.
    expect(result.simplifyReason).toMatch(
      new RegExp(`over the ${food.simplify.targetTriangles} budget`)
    );
    // Same reason the reason string is derived: the note quotes the ratio, so
    // pinning the percentage pins the budget.
    const expectedPercent = ((food.simplify.targetTriangles / 200_704) * 100).toFixed(1);
    expect(result.notes.join(' ')).toContain(`simplifying to ${expectedPercent}%`);
  });

  it('lands the target under the gate, so a decimated model is not then discarded', () => {
    const result = plan(report({ triangles: 200_704 }), food);

    const projected = 200_704 * result.simplifyRatio;
    expect(projected).toBeLessThan(result.gates.maxTriangles);
    expect(projected).toBeGreaterThan(result.gates.minTriangles);
  });

  it('skips simplify entirely for a source already inside the budget', () => {
    // A small model must not be degraded for a saving that does not exist —
    // the same trade the skip-under-bytes floor refuses to make.
    const result = plan(report({ triangles: 12_000 }), food);

    expect(result.simplifyRatio).toBe(1);
    expect(result.simplifyReason).toMatch(/already at or under/);
    // No note either: nothing happened, so there is nothing to explain.
    expect(result.notes.join(' ')).not.toMatch(/simplif/i);
  });

  it('treats exactly-at-the-budget as inside it (boundary is inclusive)', () => {
    const target = food.simplify.targetTriangles;
    expect(plan(report({ triangles: target }), food).simplifyRatio).toBe(1);
    expect(plan(report({ triangles: target + 1 }), food).simplifyRatio).toBeLessThan(1);
  });

  it('never divides by zero on a report with no triangles', () => {
    const result = plan(report({ triangles: 0 }), food);

    expect(result.simplifyRatio).toBe(1);
    expect(Number.isFinite(result.simplifyRatio)).toBe(true);
  });

  it('carries the error tolerance even on the skip-everything path', () => {
    // The plan lands in report.json verbatim, so "which tolerance would have
    // applied" must be answerable for a skipped model too.
    const result = plan(report({ totalBytes: 400_000, triangles: 200_000 }), food);

    expect(result.skip).toBe(true);
    expect(result.simplifyRatio).toBe(1);
    expect(result.simplifyError).toBe(food.simplify.errorTolerance);
  });
});

describe('plan — auto_size sanity correction', () => {
  it('rescales a model that came back absurdly large, snapping to the near bound', () => {
    // 3 m dish → the max plausible 0.6 m. Snapping to the BOUND (not the range
    // midpoint) is the smallest claim that makes the model usable.
    const result = plan(
      report({
        boundingBox: {
          min: [0, 0, 0],
          max: [3, 1, 1],
          widthMeters: 3,
          heightMeters: 1,
          depthMeters: 1,
          longestDimMeters: 3,
        },
      }),
      food
    );

    expect(result.scaleFactor).toBeCloseTo(0.2, 6);
    expect(result.notes.join(' ')).toMatch(/auto_size looks wrong/);
  });

  it('rescales a model that came back microscopic', () => {
    const result = plan(
      report({
        boundingBox: {
          min: [0, 0, 0],
          max: [0.001, 0.001, 0.001],
          widthMeters: 0.001,
          heightMeters: 0.001,
          depthMeters: 0.001,
          longestDimMeters: 0.001,
        },
      }),
      food
    );

    expect(result.scaleFactor).toBeCloseTo(20, 6); // 0.02 / 0.001
  });

  it('never divides by zero on a degenerate bounding box', () => {
    const result = plan(
      report({
        boundingBox: {
          min: [0, 0, 0],
          max: [0, 0, 0],
          widthMeters: 0,
          heightMeters: 0,
          depthMeters: 0,
          longestDimMeters: 0,
        },
      }),
      food
    );

    expect(result.scaleFactor).toBe(1);
    expect(Number.isFinite(result.scaleFactor)).toBe(true);
  });
});

describe('plan — pivot', () => {
  it('leaves a correct pivot alone (origin_at: bottom already did the work)', () => {
    const result = plan(report(), food);
    expect(result.recentrePivot).toBe(false);
  });

  it('recentres when the model floats above or sinks below Y=0', () => {
    const result = plan(
      report({
        boundingBox: {
          min: [-0.1, 0.05, -0.1],
          max: [0.1, 0.13, 0.1],
          widthMeters: 0.2,
          heightMeters: 0.08,
          depthMeters: 0.2,
          longestDimMeters: 0.2,
        },
        pivotOffset: [0, 0.09, 0],
      }),
      food
    );

    expect(result.recentrePivot).toBe(true);
    expect(result.notes.join(' ')).toMatch(/Pivot is off/);
  });

  it('recentres when the footprint is off-centre in XZ', () => {
    const result = plan(report({ pivotOffset: [0.15, 0.04, 0] }), food);
    expect(result.recentrePivot).toBe(true);
  });
});

describe('plan — purity', () => {
  it('is deterministic: the same report and profile always plan identically', () => {
    const input = report();
    expect(plan(input, food)).toEqual(plan(input, food));
  });

  it('does not mutate the report it was given', () => {
    const input = report();
    const snapshot = structuredClone(input);
    plan(input, food);
    expect(input).toEqual(snapshot);
  });
});
