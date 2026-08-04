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
//               MUST precede simplify: split vertices are seams the simplifier
//               cannot collapse across, so an unwelded mesh decimates badly.
//   simplify  — the geometry budget. Runs only when plan() says the source is
//               over it (plan.simplifyRatio < 1). Sits AFTER weld for the reason
//               above and BEFORE meshopt, which quantizes and reorders geometry:
//               anything that rewrites vertices has to happen first.
//   scale     — correct auto_size only if plan() says it misfired.
//   recentre  — put the pivot on the table.
//   texture×N — per-slot budgets; base colour does the visual work, the rest
//               are low-frequency and shrink invisibly.
//   prune     — second pass: collapsing/dropping above orphaned more properties.
//   meshopt   — LAST. It quantizes and reorders geometry, so anything that
//               rewrites vertices must already have happened.
//
// SIMPLIFY IS NOW LOAD-BEARING, and it used to be deliberately absent. The old
// reasoning was that Meshy's own remesher already hit a 12k budget, so there was
// nothing left to reduce and the whole win was texture-side. That premise is
// gone: generation now asks for ~200k triangles because a low budget was
// breaking thin geometry at the source (see MESHY_TARGET_POLYCOUNT in
// config/env.ts), and this stage is what turns that into something a low-end
// Android can load. Without it a high-poly source produces a variant that fails
// `gates.maxTriangles` and is discarded — i.e. nothing optimized ever ships.
//
// Deliberately ABSENT — flatten, join:
//   both rewrite the node hierarchy that carries auto_size's scale, and the
//   pipeline's own physicalSize gate is what would catch that as a failure.
//   Add them behind a plan flag if that ever changes.
import type { Document, Transform } from '@gltf-transform/core';
import { dedup, meshopt, prune, simplify, textureCompress, weld } from '@gltf-transform/functions';
import { MeshoptEncoder, MeshoptSimplifier } from 'meshoptimizer';
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
  // Both WASM modules, always: the simplifier is only USED when the plan says
  // so, but awaiting it unconditionally keeps this the one place readiness is
  // handled — a lazily-awaited encoder is exactly the kind of race that shows up
  // once in production and never in a test.
  await Promise.all([MeshoptEncoder.ready, MeshoptSimplifier.ready]);

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

  // Ratio 1 means plan() found the source already within the profile's triangle
  // budget. Skipping the transform entirely (rather than passing ratio: 1) keeps
  // a small model out of a lossy encoder altogether.
  if (plan.simplifyRatio < 1) {
    transforms.push(
      simplify({
        simplifier: MeshoptSimplifier,
        ratio: plan.simplifyRatio,
        error: plan.simplifyError,
      })
    );
  }

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
