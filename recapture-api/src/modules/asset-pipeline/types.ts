// src/modules/asset-pipeline/types.ts
//
// The pipeline's INTERNAL vocabulary: what inspect measured, and what plan
// decided to do about it. Neither shape is a wire contract — they are an audit
// trail (both land in report.json) and may change freely between pipeline
// versions. The client-facing shape is AssetManifest, in
// models/types/assetManifest.types.ts.

/** One texture, as found in the source GLB. */
export interface TextureReport {
  /** Texture name, or a synthesized `texture_{i}` when the GLB leaves it blank. */
  name: string;
  /** Material slots referencing it — e.g. ['baseColorTexture']. Empty = unused. */
  slots: string[];
  mimeType: string;
  width: number;
  height: number;
  bytes: number;
  /**
   * True when every pixel is identical — the case worth acting on. Meshy
   * frequently emits a flat single-colour metallicRoughness map, which is a
   * whole texture (plus a sampler, plus a draw-time bind) standing in for two
   * float factors.
   */
  isConstantColor: boolean;
  /** The constant RGBA (0–255) when isConstantColor; used to derive factors. */
  constantColor?: [number, number, number, number];
}

/** Everything measured from a GLB without changing a single byte of it. */
export interface InspectionReport {
  totalBytes: number;
  triangles: number;
  vertices: number;
  meshCount: number;
  materialCount: number;
  nodeCount: number;
  textureCount: number;
  /** Distinct (material, mode) pairs — a proxy for draw calls on the device. */
  drawCallEstimate: number;
  textures: TextureReport[];
  /** Textures present in the file that no material references. Pure waste. */
  unusedTextureCount: number;
  /** World-space bounding box, in metres, WITH node transforms applied. */
  boundingBox: {
    min: [number, number, number];
    max: [number, number, number];
    widthMeters: number;
    heightMeters: number;
    depthMeters: number;
    longestDimMeters: number;
  };
  /** World-space centre of the bbox — how far the pivot sits from the model. */
  pivotOffset: [number, number, number];
  /** Highest TEXCOORD_n index in use, + 1. 0 means the mesh has NO UVs. */
  uvChannelCount: number;
  hasAnimations: boolean;
  hasSkins: boolean;
  hasMorphTargets: boolean;
  /** Extensions declared by the source file (Meshy sometimes ships KHR_*). */
  extensions: string[];
}

/** A per-slot texture budget: which slots, resized to what, at what quality. */
export interface TextureRule {
  /** Human-readable slot group, for the log/report — e.g. 'baseColor'. */
  label: string;
  /** Regex matched against material slot names (baseColorTexture, …). */
  slotPattern: string;
  maxSize: number;
  quality: number;
}

/** A profile is the POLICY half of planning — see profiles/food.json. */
export interface OptimizationProfile {
  name: string;
  /** Skip the whole pipeline when the source is already this small (bytes). */
  skipUnderBytes: number;
  textureRules: TextureRule[];
  /** Plausible real-world size range, in metres, for this class of object. */
  expectedLongestDimMeters: { min: number; max: number };
  /** Hard gates — a produced asset outside these fails the job. */
  gates: {
    maxOutputBytes: number;
    maxTriangles: number;
    minTriangles: number;
    /** Allowed drift between measured and expected physical size, 0–1. */
    sizeTolerance: number;
  };
  meshoptLevel: 'medium' | 'high';
}

/**
 * The decisions, derived from a report + a profile. PURE DATA — no buffers, no
 * side effects — which is what makes plan() unit-testable and what makes an
 * operator able to read (or override) exactly what the pipeline is about to do
 * to a specific model before it does it.
 */
export interface OptimizationPlan {
  profileName: string;
  pipelineVersion: number;
  /** When true, every stage below is a no-op and the original is served as-is. */
  skip: boolean;
  skipReason?: string;
  textureRules: TextureRule[];
  /** Texture names to delete outright (unused by any material). */
  dropTextures: string[];
  /**
   * Slots whose flat single-colour map should become scalar factors. Each entry
   * removes one texture AND one texture bind from every draw using it.
   */
  collapseConstantSlots: string[];
  /** Rescale factor to apply, or 1 when the source scale is already sane. */
  scaleFactor: number;
  scaleReason: string;
  /** Recentre XZ / drop to Y=0. Usually already true (preset origin_at bottom). */
  recentrePivot: boolean;
  meshoptLevel: 'medium' | 'high';
  /** Gates copied from the profile so the report is self-contained. */
  gates: OptimizationProfile['gates'];
  /** Human-readable "why" lines, surfaced in the report and the worker log. */
  notes: string[];
}

/** What execute() produced, before anything is uploaded. */
export interface OptimizedVariant {
  id: 'web';
  bytes: Uint8Array;
  report: InspectionReport;
}

/** A validation failure — one hard gate, and the numbers that broke it. */
export interface ValidationFailure {
  gate: string;
  message: string;
}
