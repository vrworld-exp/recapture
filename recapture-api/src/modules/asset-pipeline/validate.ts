// src/modules/asset-pipeline/validate.ts
//
// STAGE 4 — the gates. Collect-ALL semantics (like manifest validation
// elsewhere in this repo): every gate is evaluated and every failure reported,
// so one run tells an operator everything that is wrong rather than making them
// fix-and-rerun one gate at a time.
//
// These gates exist because an optimization that silently produces a broken
// asset is WORSE than one that fails: the failure is visible and the original
// still serves, whereas a black-textured or invisible model reaches a customer.
import type { Document } from '@gltf-transform/core';
import type { InspectionReport, OptimizationPlan, ValidationFailure } from './types';

export interface ValidationResult {
  ok: boolean;
  failures: ValidationFailure[];
}

/**
 * Checks a produced variant against the plan's gates.
 *
 * `doc` is the transformed Document, needed for the material-slot check —
 * a report cannot tell us whether a material points at a texture that no
 * longer exists, but the object graph can.
 */
export function validate(
  report: InspectionReport,
  plan: OptimizationPlan,
  doc: Document,
  sourceReport: InspectionReport
): ValidationResult {
  const failures: ValidationFailure[] = [];
  const { gates } = plan;

  if (report.totalBytes > gates.maxOutputBytes) {
    failures.push({
      gate: 'maxOutputBytes',
      message: `Optimized asset is ${mb(report.totalBytes)} MB, over the ${mb(
        gates.maxOutputBytes
      )} MB budget. Lower the baseColor texture rule for this profile.`,
    });
  }

  if (report.triangles > gates.maxTriangles) {
    failures.push({
      gate: 'maxTriangles',
      message: `Optimized asset has ${report.triangles} triangles, over the ${gates.maxTriangles} budget.`,
    });
  }

  // The floor that catches a simplifier (or a bad transform) that deleted the
  // model rather than reducing it. A 40-triangle "dish" passes every size gate
  // trivially — this is the check that says the win was not just destruction.
  if (report.triangles < gates.minTriangles) {
    failures.push({
      gate: 'minTriangles',
      message: `Optimized asset has only ${report.triangles} triangles (floor ${gates.minTriangles}) — geometry was destroyed, not reduced.`,
    });
  }

  // Physical size must survive the round trip. Compared against the SOURCE
  // measurement (times any deliberate rescale), not against the profile range,
  // so a legitimately unusual object is not failed twice for the same reason.
  const expected = sourceReport.boundingBox.longestDimMeters * plan.scaleFactor;
  const actual = report.boundingBox.longestDimMeters;
  if (expected > 0) {
    const drift = Math.abs(actual - expected) / expected;
    if (drift > gates.sizeTolerance) {
      failures.push({
        gate: 'physicalSize',
        message: `Physical size drifted ${(drift * 100).toFixed(1)}% (expected ${expected.toFixed(
          3
        )} m, got ${actual.toFixed(3)} m), over the ${(gates.sizeTolerance * 100).toFixed(
          0
        )}% tolerance.`,
      });
    }
  }

  // Every referenced texture slot must resolve to real image bytes. A material
  // pointing at a disposed or empty texture renders BLACK on some devices and
  // untextured on others — the exact failure that looks like "the AI made a bad
  // model" when it is actually our pipeline.
  const unresolved = findUnresolvedTextureSlots(doc);
  if (unresolved.length > 0) {
    failures.push({
      gate: 'textureSlotsResolve',
      message: `Material texture slot(s) resolve to missing or empty images: ${unresolved.join(', ')}.`,
    });
  }

  return { ok: failures.length === 0, failures };
}

/** Slot descriptors ("Material 0.baseColorTexture") whose image is missing. */
function findUnresolvedTextureSlots(doc: Document): string[] {
  const unresolved: string[] = [];

  doc
    .getRoot()
    .listMaterials()
    .forEach((material, index) => {
      const label = material.getName() || `Material ${index}`;
      const slots: [string, ReturnType<typeof material.getBaseColorTexture>][] = [
        ['baseColorTexture', material.getBaseColorTexture()],
        ['metallicRoughnessTexture', material.getMetallicRoughnessTexture()],
        ['normalTexture', material.getNormalTexture()],
        ['occlusionTexture', material.getOcclusionTexture()],
        ['emissiveTexture', material.getEmissiveTexture()],
      ];

      for (const [slot, texture] of slots) {
        if (!texture) continue;
        const image = texture.getImage();
        if (!image || image.byteLength === 0) unresolved.push(`${label}.${slot}`);
      }
    });

  return unresolved;
}

function mb(bytes: number): string {
  return (bytes / 1e6).toFixed(2);
}
