// src/services/modelOptimizerService.ts
//
// The glTF-Transform optimization pipeline behind the "Optimize" action: take a
// raw Meshy GLB (routinely 15–60 MB) and produce a small one that a phone can
// download and paint quickly, with no visible quality loss on a handheld screen.
//
// PURE AND IN-MEMORY. It takes bytes and returns bytes:
//   • the worker runs on Render, whose filesystem is ephemeral and sometimes
//     read-only, so the fs-based `io.read(path)` / `io.write(path)` /
//     `fs.statSync` form of this pipeline cannot be used at all;
//   • keeping it pure is also what makes it unit-testable without S3, a Job, or
//     a Mongo record — the processor owns all of that.
//
// ⚠ THE OUTPUT REQUIRES A MESHOPT DECODER ON THE CLIENT. `meshopt()` writes
// EXT_meshopt_compression into `extensionsRequired`, and <model-viewer> ships
// DRACO and KTX2 decoder locations by default but NOT a meshopt one — so
// without client configuration GLTFLoader throws and every optimized model
// shows the generic "couldn't load this model" error. The two places that must
// be configured are `web/index.html` and `_lifecycleJs` in
// lib/presentation/screens/projects/model_render_view.dart. Do not change the
// meshopt pass without re-reading that note.
import { Logger, NodeIO, type Document, type Transform } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { dedup, meshopt, prune, textureCompress, weld } from '@gltf-transform/functions';
import { MeshoptEncoder } from 'meshoptimizer';

/** Knobs the caller (the processor) supplies. */
export interface OptimizeGlbOptions {
  /**
   * Hard ceiling on the INPUT (bytes). glTF-Transform holds the whole document
   * in memory, so an oversized GLB does not fail slowly — it OOMs the process.
   * Exceeding it raises {@link ModelOptimizeError} with OPTIMIZE_INPUT_TOO_LARGE.
   */
  maxInputBytes: number;
  /**
   * The size the OUTPUT is expected to come in under (bytes). Reported, never
   * enforced: the caller decides what an over-budget result means. A parameter
   * rather than a constant because the only meaningful number here is the same
   * one the feature gates on (MODEL_OPTIMIZE_THRESHOLD_BYTES) — a hardcoded
   * budget below the gate would flag every single run.
   */
  budgetBytes: number;
}

export interface OptimizeGlbResult {
  /** The optimized GLB. */
  bytes: Uint8Array;
  inputBytes: number;
  outputBytes: number;
  /** True when {@link OptimizeGlbOptions.budgetBytes} was exceeded. */
  overBudget: boolean;
  /**
   * Longest axis of the union of the primitives' LOCAL position bounds, in the
   * glTF's own units.
   *
   * Named for exactly what it is. The obvious version of this number — max over
   * primitives of (max − min) — ignores every node transform in the scene, so
   * calling it "metres" is wrong for any model whose nodes carry scale, and a
   * warning built on it fires on perfectly correct models. It is measured
   * BEFORE meshopt(), because meshopt quantizes the position accessors and the
   * normalized min/max afterwards no longer describe the source geometry.
   *
   * Diagnostics only: nothing branches on it.
   */
  localBboxLongestAxis: number;
  /**
   * Passes that were SKIPPED because an optional dependency was unavailable —
   * today only `texture-compress` (see {@link loadSharp}). Empty on a full run.
   * The caller should surface this: an output that skipped texture compression
   * is legitimately much larger than one that did not.
   */
  degraded: OptimizeDegradation[];
}

export type OptimizeDegradation = 'texture-compress-unavailable';

/** Stable codes for failures the caller maps to a terminal job error. */
export const ModelOptimizeErrorCode = {
  /** Input above MODEL_OPTIMIZE_MAX_INPUT_BYTES — refused before parsing. */
  INPUT_TOO_LARGE: 'OPTIMIZE_INPUT_TOO_LARGE',
  /** The bytes are not a GLB we can read, or a transform rejected them. */
  PARSE_FAILED: 'OPTIMIZE_PARSE_FAILED',
} as const;

export type ModelOptimizeErrorCodeValue =
  (typeof ModelOptimizeErrorCode)[keyof typeof ModelOptimizeErrorCode];

/**
 * A failure retrying cannot fix. Carries a stable code and a message that is
 * safe to show a user — it never interpolates a key, a URL, or upstream text.
 */
export class ModelOptimizeError extends Error {
  constructor(
    public readonly code: ModelOptimizeErrorCodeValue,
    message: string
  ) {
    super(message);
    this.name = 'ModelOptimizeError';
  }
}

/**
 * `sharp` ships a PLATFORM-NATIVE binary, and a Render image whose install
 * resolved the wrong variant (or skipped optional deps) has a `sharp` that
 * throws on import. That must not turn the whole feature into a hard failure:
 * the mesh passes (dedup/weld/prune/meshopt) are most of the win and need no
 * native code at all, so a missing encoder degrades to "textures untouched"
 * and is REPORTED, not thrown.
 *
 * Typed as `unknown` because textureCompress's `encoder` slot is structurally
 * typed against sharp's own signature and we deliberately do not want a hard
 * type dependency on a module that may not load.
 */
async function loadSharp(): Promise<unknown | null> {
  try {
    const mod = (await import('sharp')) as { default?: unknown };
    return mod.default ?? mod;
  } catch {
    return null;
  }
}

/**
 * Runs the optimization pipeline over one GLB.
 *
 * PASS ORDER IS LOAD-BEARING:
 *   dedup → weld → prune → texture… → prune → meshopt
 *
 * The SECOND prune is the one that is easy to omit and expensive to omit:
 * `textureCompress` writes new texture objects and leaves the originals in the
 * document, so without a prune afterwards the output carries BOTH copies and
 * can come out larger than the input. meshopt runs last because it re-encodes
 * every buffer view — anything that rewrites geometry after it would undo it.
 */
export async function optimizeGlb(
  input: Uint8Array,
  opts: OptimizeGlbOptions
): Promise<OptimizeGlbResult> {
  const inputBytes = input.byteLength;
  if (inputBytes > opts.maxInputBytes) {
    throw new ModelOptimizeError(
      ModelOptimizeErrorCode.INPUT_TOO_LARGE,
      'This model is too large to optimize.'
    );
  }

  await MeshoptEncoder.ready;

  const io = new NodeIO()
    .registerExtensions(ALL_EXTENSIONS)
    .registerDependencies({ 'meshopt.encoder': MeshoptEncoder })
    // glTF-Transform's default logger writes straight to `console`, and every
    // pass narrates itself ("prune: Removed types…"). Worker output is
    // one-JSON-object-per-line through workerLog (AGENTS.md), so a library
    // spraying bare strings into it is corruption, not logging. Everything a
    // caller actually needs comes back on OptimizeGlbResult instead.
    .setLogger(new Logger(Logger.Verbosity.SILENT));

  let doc: Document;
  try {
    doc = await io.readBinary(input);
  } catch {
    // The upstream parser error may quote buffer contents — never propagate it.
    throw new ModelOptimizeError(
      ModelOptimizeErrorCode.PARSE_FAILED,
      'This model could not be read for optimization.'
    );
  }

  const sharp = await loadSharp();
  const degraded: OptimizeDegradation[] = [];

  const transforms: Transform[] = [
    dedup(), // merge duplicate materials/accessors
    weld(), // merge split vertices (Meshy leaves a lot)
    prune(), // drop unused nodes + orphan textures
  ];

  if (sharp) {
    transforms.push(
      // Base colour does all the visual work → keep 1K.
      textureCompress({
        encoder: sharp,
        targetFormat: 'webp',
        slots: /baseColor/,
        resize: [1024, 1024],
        quality: 82,
      }),
      // Roughness/metallic/AO/emissive are low-frequency → 512 is invisible on
      // a phone.
      textureCompress({
        encoder: sharp,
        targetFormat: 'webp',
        slots: /(metallicRoughness|occlusion|emissive)/,
        resize: [512, 512],
        quality: 80,
      }),
      // Normals artifact badly under lossy compression → same size, higher
      // quality.
      textureCompress({
        encoder: sharp,
        targetFormat: 'webp',
        slots: /normal/,
        resize: [512, 512],
        quality: 92,
      }),
      // See the doc comment: recompression ORPHANS the originals.
      prune()
    );
  } else {
    degraded.push('texture-compress-unavailable');
  }

  try {
    await doc.transform(...transforms);
  } catch {
    throw new ModelOptimizeError(
      ModelOptimizeErrorCode.PARSE_FAILED,
      'This model could not be optimized.'
    );
  }

  // BEFORE meshopt: it quantizes the position accessors, after which
  // getMinNormalized/getMaxNormalized describe the encoding, not the geometry.
  const localBboxLongestAxis = measureLocalBboxLongestAxis(doc);

  try {
    await doc.transform(meshopt({ encoder: MeshoptEncoder, level: 'high' }));
  } catch {
    throw new ModelOptimizeError(
      ModelOptimizeErrorCode.PARSE_FAILED,
      'This model could not be optimized.'
    );
  }

  const bytes = await io.writeBinary(doc);
  const outputBytes = bytes.byteLength;

  return {
    bytes,
    inputBytes,
    outputBytes,
    overBudget: outputBytes > opts.budgetBytes,
    localBboxLongestAxis,
    degraded,
  };
}

/**
 * Longest axis of the union of every primitive's LOCAL position bounds.
 *
 * Node transforms are deliberately NOT applied — walking the scene graph to
 * produce a true world-space extent is a different (and much larger) job, and
 * the honest cheap number is worth more than a mislabelled expensive one. The
 * return value is named for what it measures so no caller mistakes it for
 * metres; see {@link OptimizeGlbResult.localBboxLongestAxis}.
 */
function measureLocalBboxLongestAxis(doc: Document): number {
  let longest = 0;
  for (const mesh of doc.getRoot().listMeshes()) {
    for (const prim of mesh.listPrimitives()) {
      const position = prim.getAttribute('POSITION');
      if (!position) continue;
      const min = position.getMinNormalized([]);
      const max = position.getMaxNormalized([]);
      for (let axis = 0; axis < 3; axis++) {
        const extent = (max[axis] ?? 0) - (min[axis] ?? 0);
        if (extent > longest) longest = extent;
      }
    }
  }
  return longest;
}
