// src/modules/asset-pipeline/transforms.ts
//
// The custom gltf-transform Transforms the stock library does not provide.
// Each one exists because of a specific, observed property of Meshy output —
// none of them are speculative.
import { Document, type Node, type Transform } from '@gltf-transform/core';
import { createTransform, getBounds } from '@gltf-transform/functions';

/** Root-level nodes — the ones carrying a scene's overall placement. */
function rootNodes(doc: Document): Node[] {
  const root = doc.getRoot();
  const scene = root.getDefaultScene() ?? root.listScenes()[0];
  return scene ? scene.listChildren() : [];
}

/**
 * Uniformly rescales the scene by `factor`.
 *
 * WHY THIS IS NOT ALWAYS ON: the generation preset asks Meshy for
 * `auto_size: true`, so the source is normally already in real-world metres and
 * the correct factor is 1. This transform exists for the case where auto_size
 * misfires — plan() measures the world-space bbox, compares it to the profile's
 * plausible range, and only then produces a factor ≠ 1. Rescaling
 * unconditionally (as you must when a generator returns unit-normalised
 * geometry) would corrupt every correctly-sized model.
 *
 * Applied to the node transform rather than baked into vertex positions so it
 * stays reversible and costs nothing — and so it survives meshopt quantization
 * without re-encoding every accessor.
 */
export function normalizeScale(factor: number): Transform {
  return createTransform('normalizeScale', (doc: Document): void => {
    if (factor === 1 || !Number.isFinite(factor) || factor <= 0) return;
    for (const node of rootNodes(doc)) {
      const [sx, sy, sz] = node.getScale();
      node.setScale([sx * factor, sy * factor, sz * factor]);
      const [tx, ty, tz] = node.getTranslation();
      node.setTranslation([tx * factor, ty * factor, tz * factor]);
    }
  });
}

/**
 * Moves the model so its footprint is centred on the origin and its lowest
 * point sits at Y=0 — "standing on the table", not floating above or sunk
 * through it.
 *
 * A model dropped at an AR hit-test point is positioned BY ITS ORIGIN, so a
 * pivot at the geometric centre buries the bottom half in the table surface.
 * The preset's `origin_at: 'bottom'` normally handles this; plan() only turns
 * this on when the measured bbox says it drifted (which node transforms in the
 * source scene can reintroduce).
 */
export function recentrePivot(): Transform {
  return createTransform('recentrePivot', (doc: Document): void => {
    const root = doc.getRoot();
    const scene = root.getDefaultScene() ?? root.listScenes()[0];
    if (!scene) return;

    const bounds = getBounds(scene);
    if (!bounds.min.every(Number.isFinite) || !bounds.max.every(Number.isFinite)) return;

    const dx = (bounds.min[0] + bounds.max[0]) / 2;
    const dy = bounds.min[1];
    const dz = (bounds.min[2] + bounds.max[2]) / 2;
    if (dx === 0 && dy === 0 && dz === 0) return;

    for (const node of scene.listChildren()) {
      const [tx, ty, tz] = node.getTranslation();
      node.setTranslation([tx - dx, ty - dy, tz - dz]);
    }
  });
}

/**
 * Replaces flat single-colour metallicRoughness / occlusion maps with the
 * scalar material factors they encode.
 *
 * Meshy with `enable_pbr: true` very often emits a metallicRoughness texture
 * that is one uniform colour. That is a full image — decoded into GPU memory,
 * bound on every draw — standing in for two floats. Collapsing it removes the
 * texture, its sampler, and a per-draw bind, with pixel-identical output.
 *
 * Channel mapping is the glTF spec's: G = roughness, B = metallic. Occlusion
 * lives in R; glTF has no occlusion factor, so a flat occlusion map is simply
 * dropped (a constant AO term is what the strength value already means).
 *
 * `slots` comes from plan() — this transform never decides for itself which
 * maps are constant, because that requires decoding pixels (an inspect job).
 */
export function collapseConstantMetalRough(
  slots: string[],
  constantColorByTextureName: Map<string, [number, number, number, number]>
): Transform {
  return createTransform('collapseConstantMetalRough', (doc: Document): void => {
    if (slots.length === 0) return;

    for (const material of doc.getRoot().listMaterials()) {
      if (slots.includes('metallicRoughnessTexture')) {
        const texture = material.getMetallicRoughnessTexture();
        const constant = texture && constantColorByTextureName.get(texture.getName());
        if (texture && constant) {
          // Multiply into the existing factors rather than overwrite them: the
          // sampled value is texture * factor, so the collapsed scalar must be
          // too or a material with a non-1 factor shifts appearance.
          material.setRoughnessFactor(clamp01((constant[1] / 255) * material.getRoughnessFactor()));
          material.setMetallicFactor(clamp01((constant[2] / 255) * material.getMetallicFactor()));
          material.setMetallicRoughnessTexture(null);
        }
      }

      if (slots.includes('occlusionTexture')) {
        const texture = material.getOcclusionTexture();
        const constant = texture && constantColorByTextureName.get(texture.getName());
        if (texture && constant) {
          material.setOcclusionTexture(null);
        }
      }
    }
  });
}

/**
 * Disposes textures by name — used when plan() found textures no material
 * samples (or a mesh with no UV channels at all, which makes every texture in
 * the file unsampled).
 *
 * prune() already removes textures unreferenced by any material; this handles
 * the case prune cannot see, where a material DOES reference a texture but the
 * geometry has no UVs to sample it with.
 */
export function dropTextures(names: string[]): Transform {
  return createTransform('dropTextures', (doc: Document): void => {
    if (names.length === 0) return;
    const wanted = new Set(names);
    for (const texture of doc.getRoot().listTextures()) {
      if (wanted.has(texture.getName())) texture.dispose();
    }
  });
}

function clamp01(n: number): number {
  if (!Number.isFinite(n)) return 0;
  return Math.min(1, Math.max(0, n));
}
