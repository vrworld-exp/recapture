// src/modules/asset-pipeline/plan.ts
//
// STAGE 2 — the decisions. A PURE function: report + profile in, plan out. No
// buffers, no I/O, no clock, no randomness.
//
// That purity is the point. Every "why did this model come out like that?"
// question is answerable by reading a plan next to the report that produced it,
// and every branch below is unit-testable without a GLB. If you are tempted to
// read a file or touch a Document here, it belongs in execute().
import { ASSET_PIPELINE_VERSION } from '@/models/types/assetManifest.types';
import type { InspectionReport, OptimizationPlan, OptimizationProfile } from './types';

/**
 * Slot names, as glTF spells them, that a constant-colour texture can be
 * collapsed into scalar/vector factors on the material.
 *
 * Restricted to metallicRoughness and occlusion ON PURPOSE. A flat baseColor
 * COULD also collapse to a factor, but a single-colour albedo is a legitimate
 * artistic result (a plain white plate), and collapsing it changes how the
 * material responds to a UV transform — not worth the risk for one small
 * texture. Occlusion and metallicRoughness carry no such ambiguity: flat means
 * "this map says nothing".
 */
const COLLAPSIBLE_SLOTS = ['metallicRoughnessTexture', 'occlusionTexture'];

/**
 * Derives what to do from what was measured.
 *
 * Reads as a sequence of independent questions rather than one branching
 * decision, so a later rule can be added without disturbing the others.
 */
export function plan(
  report: InspectionReport,
  profile: OptimizationProfile
): OptimizationPlan {
  const notes: string[] = [];

  // ── Question 1: is there anything to gain at all? ──────────────────────────
  // An already-small model is not worth a round trip through a lossy encoder:
  // the win is negligible and every re-encode is a chance to make it look
  // worse. Serving the original is the better answer, not a fallback.
  if (report.totalBytes <= profile.skipUnderBytes) {
    return {
      profileName: profile.name,
      pipelineVersion: ASSET_PIPELINE_VERSION,
      skip: true,
      skipReason: `Source is ${formatBytes(report.totalBytes)}, at or under the ${formatBytes(
        profile.skipUnderBytes
      )} floor — optimization cannot pay for its own quality loss.`,
      textureRules: [],
      dropTextures: [],
      collapseConstantSlots: [],
      scaleFactor: 1,
      scaleReason: 'skipped',
      recentrePivot: false,
      meshoptLevel: profile.meshoptLevel,
      gates: profile.gates,
      notes: ['Pipeline skipped; the original is served unchanged.'],
    };
  }

  // ── Question 2: which texture rules can actually apply? ────────────────────
  // No UVs means no texture is sampled, so every texture in the file is dead
  // weight regardless of its slot. Applying resize rules to them would spend
  // CPU shrinking images that will then be pruned anyway.
  const hasUVs = report.uvChannelCount > 0;
  if (!hasUVs && report.textureCount > 0) {
    notes.push(
      `Mesh has no UV channels, so its ${report.textureCount} texture(s) are unsampled — dropping all of them instead of resizing.`
    );
  }

  const textureRules = hasUVs ? profile.textureRules : [];

  // ── Question 3: what can be deleted outright? ──────────────────────────────
  const dropTextures = report.textures
    .filter((t) => t.slots.length === 0 || !hasUVs)
    .map((t) => t.name);
  if (dropTextures.length > 0 && hasUVs) {
    notes.push(`${dropTextures.length} texture(s) referenced by no material — dropped.`);
  }

  // ── Question 4: which flat maps become factors? ────────────────────────────
  const collapseConstantSlots = [
    ...new Set(
      report.textures
        .filter((t) => t.isConstantColor && t.slots.length > 0)
        .flatMap((t) => t.slots)
        .filter((slot) => COLLAPSIBLE_SLOTS.includes(slot))
    ),
  ];
  if (collapseConstantSlots.length > 0) {
    notes.push(
      `Constant-colour map(s) on ${collapseConstantSlots.join(', ')} collapsed to material factors — removes a whole texture and its per-draw bind.`
    );
  }

  // ── Question 5: is the real-world scale believable? ────────────────────────
  // The generation preset asks Meshy for `auto_size`, so the source SHOULD
  // already be in metres. This is the check on whether it was — not a blanket
  // renormalization. Rescaling a correctly-sized model would be the bug.
  const { scaleFactor, scaleReason } = planScale(report, profile, notes);

  // ── Question 6: is the pivot where AR needs it? ────────────────────────────
  // The preset asks for `origin_at: bottom`, so Y should already be ~0. We
  // still recentre when it drifted, because a model placed at an AR hit-test
  // point pivots about its origin: a bad pivot sinks it through the table.
  const bboxHeight = report.boundingBox.heightMeters || 1;
  const yOffsetRatio = Math.abs(report.boundingBox.min[1]) / bboxHeight;
  const xzOffset = Math.hypot(report.pivotOffset[0], report.pivotOffset[2]);
  const xzOffsetRatio =
    xzOffset / (Math.max(report.boundingBox.widthMeters, report.boundingBox.depthMeters) || 1);
  const recentrePivot = yOffsetRatio > 0.02 || xzOffsetRatio > 0.02;
  if (recentrePivot) {
    notes.push(
      `Pivot is off by ${(yOffsetRatio * 100).toFixed(1)}% of height / ${(xzOffsetRatio * 100).toFixed(1)}% of footprint — recentring to XZ centre, Y=0.`
    );
  }

  if (report.hasAnimations || report.hasSkins || report.hasMorphTargets) {
    // Not an error: joining/welding is what would break them, and this recipe
    // does neither destructively. Recorded because an animated model coming
    // out of a food capture is itself a signal worth seeing in the report.
    notes.push(
      'Source declares animation/skin/morph data — geometry merging stages stay conservative.'
    );
  }

  return {
    profileName: profile.name,
    pipelineVersion: ASSET_PIPELINE_VERSION,
    skip: false,
    textureRules,
    dropTextures,
    collapseConstantSlots,
    scaleFactor,
    scaleReason,
    recentrePivot,
    meshoptLevel: profile.meshoptLevel,
    gates: profile.gates,
    notes,
  };
}

/**
 * Decides whether the model's measured size is plausible for this profile, and
 * by what factor to correct it when it is not.
 *
 * Correction targets the NEAREST end of the expected range rather than its
 * midpoint: if a dish measures 3 m we know it is wrong, but we do not know it
 * is "average sized" — snapping to the boundary is the smallest claim that
 * makes it usable.
 */
function planScale(
  report: InspectionReport,
  profile: OptimizationProfile,
  notes: string[]
): { scaleFactor: number; scaleReason: string } {
  const longest = report.boundingBox.longestDimMeters;
  const { min, max } = profile.expectedLongestDimMeters;

  if (longest <= 0) {
    notes.push('Bounding box is degenerate (zero size) — leaving scale untouched.');
    return { scaleFactor: 1, scaleReason: 'degenerate bounding box; no rescale' };
  }
  if (longest >= min && longest <= max) {
    return {
      scaleFactor: 1,
      scaleReason: `measured ${longest.toFixed(3)} m is within the expected ${min}–${max} m range (auto_size worked)`,
    };
  }

  const target = longest > max ? max : min;
  const scaleFactor = target / longest;
  notes.push(
    `auto_size looks wrong: measured ${longest.toFixed(3)} m is outside ${min}–${max} m. Rescaling by ${scaleFactor.toFixed(4)} to ${target} m.`
  );
  return {
    scaleFactor,
    scaleReason: `measured ${longest.toFixed(3)} m outside expected ${min}–${max} m; corrected to ${target} m`,
  };
}

function formatBytes(bytes: number): string {
  return `${(bytes / 1e6).toFixed(2)} MB`;
}
