// tests/fixtures/glbFactory.ts
//
// Builds REAL GLB bytes shaped like Meshy output, so the asset-pipeline suite
// exercises the actual encoders (sharp, meshopt WASM, the GLB writer) instead
// of mocks. A mocked pipeline would pass while the real one produces a black
// model — which is precisely the failure the gates exist to catch.
//
// Everything here mirrors a property we actually observe in Meshy results:
// real-world scale carried on the NODE (auto_size), a flat single-colour
// metallicRoughness map (enable_pbr), and split vertices that weld can merge.
import { Document, NodeIO, type Texture } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { MeshoptDecoder, MeshoptEncoder } from 'meshoptimizer';
import sharp from 'sharp';

export interface GlbFactoryOptions {
  /** Grid resolution per side; triangles = 2*(n-1)^2. Default 32 → 1922 tris. */
  gridSize?: number;
  /** Longest world-space dimension in metres, applied as NODE SCALE. */
  sizeMeters?: number;
  /** Base-colour texture edge length. Default 2048 (a Meshy 2k map). */
  baseColorSize?: number;
  /** Emit TEXCOORD_0. Setting false models a Meshy result with no UVs. */
  withUVs?: boolean;
  /** Attach a flat single-colour metallicRoughness map (the collapsible case). */
  constantMetalRough?: boolean;
  /** Attach a NOISY metallicRoughness map, which must NOT be collapsed. */
  noisyMetalRough?: boolean;
  /** Attach a texture no material references (prune should remove it). */
  withUnusedTexture?: boolean;
  /** Add a rotation animation, to prove the recipe preserves it. */
  withAnimation?: boolean;
  /** Offset the node so the pivot is wrong (recentrePivot should fix it). */
  pivotOffset?: [number, number, number];
}

async function io(): Promise<NodeIO> {
  await MeshoptDecoder.ready;
  await MeshoptEncoder.ready;
  return new NodeIO()
    .registerExtensions(ALL_EXTENSIONS)
    .registerDependencies({
      'meshopt.decoder': MeshoptDecoder,
      'meshopt.encoder': MeshoptEncoder,
    });
}

/**
 * A detailed, PHOTO-LIKE image — must NOT be detected as constant colour, and
 * must not compress away to nothing.
 *
 * Deliberately neither a simple pattern nor pure random noise. A periodic
 * pattern deflates to a few KB, which would slip under the pipeline's
 * skip-if-already-small floor and make these tests silently assert on the skip
 * path instead of the optimization path. Pure random noise compresses far WORSE
 * than any real photograph and would make the size budgets unrealistically
 * hard. Low-frequency waves plus a small high-frequency term compresses about
 * like a real captured texture.
 *
 * Deterministic: reproducible failures beat flaky ones.
 */
async function noiseImage(size: number): Promise<Uint8Array> {
  const pixels = Buffer.alloc(size * size * 3);
  let i = 0;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const wave = Math.sin(x * 0.13) * Math.cos(y * 0.11) + Math.sin((x + y) * 0.37) * 0.5;
      const hash = ((x * 374761393 + y * 668265263) >>> 0) % 24;
      const base = 128 + wave * 80 + hash - 12;
      pixels[i++] = clampByte(base);
      pixels[i++] = clampByte(base * 0.8 + 20);
      pixels[i++] = clampByte(base * 0.6 + 40);
    }
  }
  // toColourspace is required: sharp cannot infer a colourspace for RAW input,
  // and the PNG encoder refuses without one.
  const png = await sharp(pixels, { raw: { width: size, height: size, channels: 3 } })
    .toColourspace('srgb')
    .png()
    .toBuffer();
  return new Uint8Array(png);
}

function clampByte(n: number): number {
  return Math.max(0, Math.min(255, Math.round(n)));
}

/** A perfectly flat image — the case worth collapsing into material factors. */
async function solidImage(
  size: number,
  rgb: [number, number, number]
): Promise<Uint8Array> {
  const png = await sharp({
    create: {
      width: size,
      height: size,
      channels: 3,
      background: { r: rgb[0], g: rgb[1], b: rgb[2] },
    },
  })
    .png()
    .toBuffer();
  return new Uint8Array(png);
}

/**
 * Builds a GLB. Returns the bytes plus the Document, so a test can assert on
 * the source graph without re-reading.
 */
export async function makeMeshyLikeGlb(
  options: GlbFactoryOptions = {}
): Promise<{ glb: Uint8Array; doc: Document }> {
  const {
    gridSize = 32,
    sizeMeters = 0.25,
    baseColorSize = 2048,
    withUVs = true,
    constantMetalRough = false,
    noisyMetalRough = false,
    withUnusedTexture = false,
    withAnimation = false,
    pivotOffset,
  } = options;

  const doc = new Document();
  const buffer = doc.createBuffer();

  // ── Geometry: a gridSize × gridSize displaced plane, spanning 0..1 ─────────
  const positions: number[] = [];
  const normals: number[] = [];
  const uvs: number[] = [];
  for (let y = 0; y < gridSize; y++) {
    for (let x = 0; x < gridSize; x++) {
      const u = x / (gridSize - 1);
      const v = y / (gridSize - 1);
      // A gentle dome, so the silhouette is recognisable and welding has
      // something real to do.
      const h = Math.sin(u * Math.PI) * Math.sin(v * Math.PI) * 0.3;
      positions.push(u, h, v);
      normals.push(0, 1, 0);
      uvs.push(u, v);
    }
  }

  const indices: number[] = [];
  for (let y = 0; y < gridSize - 1; y++) {
    for (let x = 0; x < gridSize - 1; x++) {
      const a = y * gridSize + x;
      const b = a + 1;
      const c = a + gridSize;
      const d = c + 1;
      indices.push(a, c, b, b, c, d);
    }
  }

  const positionAccessor = doc
    .createAccessor('POSITION')
    .setType('VEC3')
    .setArray(new Float32Array(positions))
    .setBuffer(buffer);
  const normalAccessor = doc
    .createAccessor('NORMAL')
    .setType('VEC3')
    .setArray(new Float32Array(normals))
    .setBuffer(buffer);
  const indexAccessor = doc
    .createAccessor('indices')
    .setType('SCALAR')
    .setArray(new Uint32Array(indices))
    .setBuffer(buffer);

  const material = doc.createMaterial('dish_material').setRoughnessFactor(1).setMetallicFactor(1);

  const primitive = doc
    .createPrimitive()
    .setAttribute('POSITION', positionAccessor)
    .setAttribute('NORMAL', normalAccessor)
    .setIndices(indexAccessor)
    .setMaterial(material);

  if (withUVs) {
    primitive.setAttribute(
      'TEXCOORD_0',
      doc
        .createAccessor('TEXCOORD_0')
        .setType('VEC2')
        .setArray(new Float32Array(uvs))
        .setBuffer(buffer)
    );
  }

  // ── Textures ──────────────────────────────────────────────────────────────
  const baseColor: Texture = doc
    .createTexture('baseColor')
    .setImage(await noiseImage(baseColorSize))
    .setMimeType('image/png');
  material.setBaseColorTexture(baseColor);

  if (constantMetalRough) {
    // Flat: G=roughness 128, B=metallic 0 — exactly the Meshy pattern.
    material.setMetallicRoughnessTexture(
      doc
        .createTexture('metallicRoughness')
        .setImage(await solidImage(1024, [0, 128, 0]))
        .setMimeType('image/png')
    );
  } else if (noisyMetalRough) {
    material.setMetallicRoughnessTexture(
      doc
        .createTexture('metallicRoughness')
        .setImage(await noiseImage(1024))
        .setMimeType('image/png')
    );
  }

  if (withUnusedTexture) {
    doc
      .createTexture('orphan')
      .setImage(await noiseImage(512))
      .setMimeType('image/png');
  }

  // ── Scene: real-world scale lives on the NODE, as auto_size produces it ────
  const mesh = doc.createMesh('dish').addPrimitive(primitive);
  const node = doc.createNode('dish_node').setMesh(mesh).setScale([sizeMeters, sizeMeters, sizeMeters]);
  if (pivotOffset) node.setTranslation(pivotOffset);

  const scene = doc.createScene('Scene').addChild(node);
  doc.getRoot().setDefaultScene(scene);

  if (withAnimation) {
    const input = doc
      .createAccessor('time')
      .setType('SCALAR')
      .setArray(new Float32Array([0, 1]))
      .setBuffer(buffer);
    const output = doc
      .createAccessor('rotation')
      .setType('VEC4')
      .setArray(new Float32Array([0, 0, 0, 1, 0, 1, 0, 0]))
      .setBuffer(buffer);
    const sampler = doc.createAnimationSampler().setInput(input).setOutput(output).setInterpolation('LINEAR');
    const channel = doc
      .createAnimationChannel()
      .setTargetNode(node)
      .setTargetPath('rotation')
      .setSampler(sampler);
    doc.createAnimation('spin').addSampler(sampler).addChannel(channel);
  }

  const glb = await (await io()).writeBinary(doc);
  return { glb, doc };
}

/** Reads GLB bytes back into a Document (for asserting on produced output). */
export async function readGlb(glb: Uint8Array): Promise<Document> {
  return (await io()).readBinary(glb);
}
