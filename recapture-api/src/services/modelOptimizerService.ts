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
// THE OUTPUT NEEDS NO CLIENT DECODER. Geometry is quantized
// (KHR_mesh_quantization) and textures are WebP (EXT_texture_webp); three.js
// and <model-viewer> support both natively, and those two are the only entries
// this pipeline is allowed to put in `extensionsRequired`.
//
// meshopt() was REMOVED here deliberately. It writes EXT_meshopt_compression
// into `extensionsRequired`, and <model-viewer> ships DRACO and KTX2 decoder
// locations by default but NOT a meshopt one — so, the extension being
// *required* rather than merely used, the loader rejected the whole file
// instead of degrading, and every optimized model showed the generic "couldn't
// load this model" error. Quantization keeps most of the geometry saving with
// no such demand on the client; expect output roughly 1.5–2× the meshopt size
// on geometry-heavy models, which is the accepted price. Do not reintroduce
// meshopt unless every client registers a decoder.
//
// The meshopt DECODER is still registered on the READER: S3 already holds GLBs
// written by the previous version of this pipeline, and every retry, re-import
// or re-optimize path feeds one back in. Without it `io.readBinary()` throws
// and surfaces as a misleading OPTIMIZE_PARSE_FAILED.
import { Logger, NodeIO, type Document, type Transform } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { dedup, prune, quantize, textureCompress, weld } from '@gltf-transform/functions';
import { MeshoptDecoder } from 'meshoptimizer';

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
   * BEFORE quantize(), because quantization rewrites the position accessors and
   * the normalized min/max afterwards describe the encoding, not the source
   * geometry.
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
 * the mesh passes (dedup/weld/prune/quantize) are most of the win and need no
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
 *   dedup → weld → prune → texture… → prune → quantize
 *
 * The SECOND prune is the one that is easy to omit and expensive to omit:
 * `textureCompress` writes new texture objects and leaves the originals in the
 * document, so without a prune afterwards the output carries BOTH copies and
 * can come out larger than the input. quantize runs last for the same reason
 * meshopt used to: it rewrites the position, normal and texcoord accessors, so
 * anything that touches geometry after it would undo it.
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

  // Decoder, not encoder: nothing here WRITES meshopt any more, but the reader
  // must still accept the meshopt-compressed GLBs the old pipeline left in S3.
  await MeshoptDecoder.ready;

  const io = new NodeIO()
    .registerExtensions(ALL_EXTENSIONS)
    .registerDependencies({ 'meshopt.decoder': MeshoptDecoder })
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

  dropMeshoptExtension(doc);

  const sharp = await loadSharp();
  const degraded: OptimizeDegradation[] = [];

  const transforms: Transform[] = [
    dedup(), // merge duplicate materials/accessors
    weld(), // merge split vertices (Meshy leaves a lot)
    prune(), // drop unused nodes + orphan textures
    cullOpaqueBackfaces(), // Meshy marks everything doubleSided; closed meshes pay twice
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

  // BEFORE quantize: it rewrites the position accessors, after which
  // getMinNormalized/getMaxNormalized describe the encoding, not the geometry.
  const localBboxLongestAxis = measureLocalBboxLongestAxis(doc);

  try {
    // Defaults (quantizePosition 14). Anything coarser produces visible
    // faceting on curved surfaces at the handheld AR scale these are viewed at.
    await doc.transform(quantize());
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
 * Detaches EXT_meshopt_compression from a document that arrived carrying it.
 *
 * Reading a legacy GLB DECODES the geometry but leaves the extension attached
 * to the Document, and glTF-Transform re-encodes on write from that attachment
 * alone. That is two bugs at once: the writer reaches for an encoder we
 * deliberately no longer register (a raw TypeError out of `writeBinary`, which
 * escapes as a RETRYABLE error and retries forever), and if it succeeded it
 * would put EXT_meshopt_compression straight back into `extensionsRequired` —
 * re-creating the exact failure this change exists to remove.
 *
 * Nothing else registered by ALL_EXTENSIONS is touched: KHR_materials_*,
 * KHR_texture_transform and friends are all decoder-free and must survive.
 */
function dropMeshoptExtension(doc: Document): void {
  for (const extension of doc.getRoot().listExtensionsUsed()) {
    if (extension.extensionName === 'EXT_meshopt_compression') extension.dispose();
  }
}

/**
 * Turns backface culling back ON for OPAQUE materials.
 *
 * Meshy emits `doubleSided: true` on everything and nothing downstream clears
 * it. On a closed mesh that buys no visible geometry and roughly doubles
 * fragment cost on low-end Android, which is exactly the device this pipeline
 * exists for.
 *
 * OPAQUE ONLY, deliberately. A BLEND or MASK material is how leaves, thin
 * plastics, cellophane and glass are authored, and those legitimately need both
 * faces — culling them would delete visible surfaces, which is a far worse bug
 * than the fill cost this pass saves.
 */
function cullOpaqueBackfaces(): Transform {
  return (doc: Document): void => {
    for (const material of doc.getRoot().listMaterials()) {
      if (material.getAlphaMode() === 'OPAQUE') material.setDoubleSided(false);
    }
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
