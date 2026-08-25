// src/modules/asset-pipeline/inspect.ts
//
// STAGE 1 — pure read. Measures a GLB and changes nothing about it.
//
// Everything downstream is derived from this report, which is why it is a
// separate stage rather than a few numbers gathered inline during execute:
// Meshy output varies enormously per object (a flat naan and a garnished thali
// are not the same optimization problem), so the decisions must be traceable to
// a measurement, and both must land in report.json for an admin to read back.
import { Document, NodeIO, type Texture } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { getBounds, getGLPrimitiveCount, listTextureSlots } from '@gltf-transform/functions';
import { MeshoptDecoder, MeshoptEncoder } from 'meshoptimizer';
import sharp from 'sharp';

import type { InspectionReport, TextureReport } from './types';

/**
 * A NodeIO wired for BOTH directions of our own pipeline: the decoder is what
 * lets us re-read (and therefore verify) a web.glb we just meshopt-encoded, and
 * ALL_EXTENSIONS is what stops an unrecognised KHR_* extension in Meshy's
 * output from being silently dropped on the round trip.
 *
 * Built per call rather than memoized at module scope: the WASM encoders must
 * be awaited before use, and a shared instance would make that ordering a
 * cross-call assumption.
 */
export async function createIO(): Promise<NodeIO> {
  await MeshoptDecoder.ready;
  await MeshoptEncoder.ready;
  return new NodeIO()
    .registerExtensions(ALL_EXTENSIONS)
    .registerDependencies({
      'meshopt.decoder': MeshoptDecoder,
      'meshopt.encoder': MeshoptEncoder,
    });
}

/** Reads GLB bytes into a Document. Throws on a corrupt/truncated file. */
export async function readDocument(glb: Uint8Array): Promise<Document> {
  const io = await createIO();
  return io.readBinary(glb);
}

/**
 * Whether every pixel of an image is the same colour, and what colour.
 *
 * This is the check that pays for itself: Meshy's `enable_pbr` output very
 * often contains a metallicRoughness map that is one flat colour, which is a
 * whole texture (plus a sampler and a per-draw bind) encoding two floats.
 *
 * Uses sharp's per-channel min/max rather than scanning pixels ourselves —
 * one pass in native code. Fails CLOSED (reports "not constant") on anything
 * it cannot decode: wrongly collapsing a real texture would visibly break a
 * model, while missing one only costs bytes.
 */
async function analyzeConstantColor(
  bytes: Uint8Array
): Promise<{ isConstantColor: boolean; constantColor?: [number, number, number, number] }> {
  try {
    const image = sharp(Buffer.from(bytes));
    const stats = await image.stats();
    const flat = stats.channels.every((c) => c.min === c.max);
    if (!flat) return { isConstantColor: false };

    const [r, g, b, a] = stats.channels.map((c) => c.min);
    return {
      isConstantColor: true,
      constantColor: [r ?? 0, g ?? 0, b ?? 0, a ?? 255],
    };
  } catch {
    return { isConstantColor: false };
  }
}

/** Measures one texture, including the constant-colour test. */
async function inspectTexture(texture: Texture, index: number): Promise<TextureReport> {
  const image = texture.getImage() ?? new Uint8Array();
  const size = texture.getSize() ?? [0, 0];
  const constant = await analyzeConstantColor(image);

  return {
    name: texture.getName() || `texture_${index}`,
    slots: listTextureSlots(texture),
    mimeType: texture.getMimeType() || 'application/octet-stream',
    width: size[0],
    height: size[1],
    bytes: image.byteLength,
    ...constant,
  };
}

/**
 * Measures a GLB. `totalBytes` is passed in rather than re-serialized, so the
 * report always describes the exact file that was read (a re-serialize would
 * report OUR encoder's size, not the source's).
 */
export async function inspect(glb: Uint8Array): Promise<InspectionReport> {
  const doc = await readDocument(glb);
  return inspectDocument(doc, glb.byteLength);
}

/** The measurement itself, split out so execute() can re-measure in memory. */
export async function inspectDocument(
  doc: Document,
  totalBytes: number
): Promise<InspectionReport> {
  const root = doc.getRoot();
  const meshes = root.listMeshes();

  let triangles = 0;
  let vertices = 0;
  let primitiveCount = 0;
  let uvChannelCount = 0;
  let hasMorphTargets = false;

  for (const mesh of meshes) {
    for (const prim of mesh.listPrimitives()) {
      primitiveCount++;
      triangles += getGLPrimitiveCount(prim);
      vertices += prim.getAttribute('POSITION')?.getCount() ?? 0;
      if (prim.listTargets().length > 0) hasMorphTargets = true;

      // TEXCOORD_n is contiguous from 0 by spec, so the highest present index
      // + 1 is the channel count. Zero means the mesh has no UVs at all —
      // which makes every texture rule below moot, and is worth knowing.
      for (const semantic of prim.listSemantics()) {
        const match = /^TEXCOORD_(\d+)$/.exec(semantic);
        if (match) uvChannelCount = Math.max(uvChannelCount, Number(match[1]) + 1);
      }
    }
  }

  const textures = await Promise.all(root.listTextures().map(inspectTexture));

  // World-space bounds: getBounds applies node transforms, which is the whole
  // point. Reading POSITION accessor min/max directly (the obvious shortcut)
  // silently ignores a scale on the node — and Meshy's `auto_size` puts the
  // real-world scale exactly there, so the shortcut reports unit-cube numbers
  // for a correctly-sized model.
  const scene = root.getDefaultScene() ?? root.listScenes()[0];
  const bounds = scene ? getBounds(scene) : { min: [0, 0, 0], max: [0, 0, 0] };
  const finite = (n: number): number => (Number.isFinite(n) ? n : 0);
  const min: [number, number, number] = [
    finite(bounds.min[0]),
    finite(bounds.min[1]),
    finite(bounds.min[2]),
  ];
  const max: [number, number, number] = [
    finite(bounds.max[0]),
    finite(bounds.max[1]),
    finite(bounds.max[2]),
  ];

  const widthMeters = Math.abs(max[0] - min[0]);
  const heightMeters = Math.abs(max[1] - min[1]);
  const depthMeters = Math.abs(max[2] - min[2]);

  return {
    totalBytes,
    triangles,
    vertices,
    meshCount: meshes.length,
    materialCount: root.listMaterials().length,
    nodeCount: root.listNodes().length,
    textureCount: textures.length,
    // One primitive is one draw call — the number the phone actually pays.
    drawCallEstimate: primitiveCount,
    textures,
    unusedTextureCount: textures.filter((t) => t.slots.length === 0).length,
    boundingBox: {
      min,
      max,
      widthMeters,
      heightMeters,
      depthMeters,
      longestDimMeters: Math.max(widthMeters, heightMeters, depthMeters),
    },
    pivotOffset: [(min[0] + max[0]) / 2, (min[1] + max[1]) / 2, (min[2] + max[2]) / 2],
    uvChannelCount,
    hasAnimations: root.listAnimations().length > 0,
    hasSkins: root.listSkins().length > 0,
    hasMorphTargets,
    extensions: root.listExtensionsUsed().map((e) => e.extensionName),
  };
}
