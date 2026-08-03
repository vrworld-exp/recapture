// src/modules/asset-pipeline/execute.ts
//
// STAGE 3 — the only side-effecting stage. Takes the source bytes and a plan,
// and produces the optimized bytes. Every decision was already made in plan();
// this file just carries them out, which is why it has almost no branching.
//
// RECIPE ORDER IS LOAD-BEARING:
//   dedup     — merge duplicate materials/accessors first, so everything after
//               operates on one copy instead of N.
//   prune     — drop orphans early; no point compressing what will be deleted.
//   collapse  — turn flat metalRough maps into factors BEFORE textureCompress,
//               so we never spend encoder time on an image we then delete.
//   dropTex   — remove textures no UV channel can sample (prune cannot see these).
//   weld      — merge bitwise-identical vertices; Meshy leaves a lot of splits.
//   scale     — correct auto_size only if plan() says it misfired.
//   recentre  — put the pivot on the table.
//   texture×N — per-slot budgets; base colour does the visual work, the rest
//               are low-frequency and shrink invisibly.
//   prune     — second pass: collapsing/dropping above orphaned more properties.
//   meshopt   — LAST. It quantizes and reorders geometry, so anything that
//               rewrites vertices must already have happened.
//
// Deliberately ABSENT — flatten, join, simplify:
//   simplify is a no-op at our budget (the generation preset already asks Meshy
//   for 12k triangles via its own remesher, which is better at it), and both
//   flatten and join rewrite the node hierarchy that carries auto_size's scale.
//   The size win here is entirely texture-side; spending silhouette quality for
//   nothing would be a bad trade. Add them behind a plan flag if that changes.
import type { Document, Transform } from '@gltf-transform/core';
import { dedup, meshopt, prune, textureCompress, weld } from '@gltf-transform/functions';
import { MeshoptEncoder } from 'meshoptimizer';
import sharp from 'sharp';

import { createIO, inspectDocument, readDocument } from './inspect';
import {
  collapseConstantMetalRough,
  dropTextures,
  normalizeScale,
  recentrePivot,
} from './transforms';
import type { InspectionReport, OptimizationPlan, OptimizedVariant } from './types';

/**
 * Runs the plan against the source bytes.
 *
 * The source report is passed in (not re-measured) because the constant-colour
 * analysis it contains is what tells collapseConstantMetalRough which textures
 * are flat — re-deriving it here would decode every image a second time.
 */
export async function execute(
  glb: Uint8Array,
  plan: OptimizationPlan,
  sourceReport: InspectionReport
): Promise<OptimizedVariant> {
  await MeshoptEncoder.ready;

  const doc = await readDocument(glb);
  await doc.transform(...buildTransforms(plan, sourceReport));

  const io = await createIO();
  const bytes = await io.writeBinary(doc);
  const report = await inspectDocument(doc, bytes.byteLength);

  return { id: 'web', bytes, report };
}

/** The ordered transform list for a plan — exported so tests can assert order. */
export function buildTransforms(
  plan: OptimizationPlan,
  sourceReport: InspectionReport
): Transform[] {
  const constantColors = new Map<string, [number, number, number, number]>();
  for (const texture of sourceReport.textures) {
    if (texture.isConstantColor && texture.constantColor) {
      constantColors.set(texture.name, texture.constantColor);
    }
  }

  const transforms: Transform[] = [
    dedup(),
    prune(),
    collapseConstantMetalRough(plan.collapseConstantSlots, constantColors),
    dropTextures(plan.dropTextures),
    weld(),
  ];

  if (plan.scaleFactor !== 1) transforms.push(normalizeScale(plan.scaleFactor));
  if (plan.recentrePivot) transforms.push(recentrePivot());

  for (const rule of plan.textureRules) {
    transforms.push(
      textureCompress({
        encoder: sharp,
        targetFormat: 'webp',
        slots: new RegExp(rule.slotPattern),
        resize: [rule.maxSize, rule.maxSize],
        quality: rule.quality,
      })
    );
  }

  transforms.push(prune());
  transforms.push(meshopt({ encoder: MeshoptEncoder, level: plan.meshoptLevel }));

  return transforms;
}

/** Re-serializes a Document without transforming it (used by the skip path). */
export async function writeDocument(doc: Document): Promise<Uint8Array> {
  const io = await createIO();
  return io.writeBinary(doc);
}
