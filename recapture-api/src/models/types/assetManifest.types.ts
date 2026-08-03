// src/models/types/assetManifest.types.ts
//
// THE ASSET MANIFEST CONTRACT — the single source of truth shared by three
// consumers: this API, the Flutter app, and the Mirage Menu web viewer.
//
// It lives here (beside the other wire vocabularies) rather than inside
// src/modules/asset-pipeline/ ON PURPOSE: the pipeline is one PRODUCER of this
// shape, but the shape outlives it. A client reads a manifest that may have
// been written by an older pipeline version, so the contract must not be
// owned by the code that happens to emit it today.
//
// The same JSON is written to S3 as `manifest.json` AND persisted on the
// ProjectModel record, so the viewer can render standalone from a CDN URL while
// the app gets it inline with the model list (no second round trip).

/**
 * Bumped whenever the optimization RECIPE changes in a way that would produce
 * different bytes for the same input — a new texture budget, a new transform,
 * a different meshopt level.
 *
 * This is the directory name under the model prefix (`v1/`, `v2/`, …), which
 * is what makes re-running an improved recipe safe: a new version writes a NEW
 * prefix and can never overwrite the variant a client already cached under the
 * old one (everything is served `immutable`). Never reuse a version number for
 * a changed recipe.
 */
export const ASSET_PIPELINE_VERSION = 1;

/**
 * Which rendition of a model a URL points at.
 *   original — Meshy's untouched GLB, exactly as re-hosted. Kept forever: it is
 *              the ONLY way to re-run an improved recipe later, and it is the
 *              admin's visual reference for judging the optimized one.
 *   web      — the optimized variant: WebP textures + EXT_meshopt_compression.
 *
 * `variants` is an ARRAY rather than named fields so a future rendition (KTX2,
 * a compat/JPEG build, USDZ) is an additive change no client has to be
 * redeployed for. Clients must ignore ids they do not recognise.
 */
export const ASSET_VARIANT_IDS = ['original', 'web'] as const;
export type AssetVariantId = (typeof ASSET_VARIANT_IDS)[number];

/** One downloadable rendition, with the numbers needed to justify choosing it. */
export interface AssetVariant {
  id: AssetVariantId;
  /** CloudFront URL — always ours, never Meshy's (theirs expire). */
  url: string;
  /** S3 key under BUCKET_ARTIFACTS, for server-side re-reads. */
  key: string;
  bytes: number;
  triangles: number;
  textureCount: number;
  /** Largest single texture, in bytes — usually the real page-weight driver. */
  largestTextureBytes: number;
  /** Whether geometry carries EXT_meshopt_compression (needs a decoder). */
  meshoptCompressed: boolean;
}

/**
 * Real-world size, in METRES, measured from the world-space bounding box.
 *
 * Measured, not declared: Meshy's `auto_size` is asked to return real scale,
 * and this is how we find out whether it actually did. A dish that reports
 * 4 m is an auto_size failure, and the client needs to know before it drops
 * the model into an AR scene at that size.
 */
export interface AssetPhysicalSize {
  widthMeters: number;
  heightMeters: number;
  depthMeters: number;
  /** Longest of the three — the single number worth alerting on. */
  longestDimMeters: number;
}

/** Before/after, so an admin can judge the trade without opening a 3D tool. */
export interface AssetReduction {
  bytesBefore: number;
  bytesAfter: number;
  /** bytesAfter / bytesBefore, 0–1. 0.18 = "18% of the original". */
  ratio: number;
  trianglesBefore: number;
  trianglesAfter: number;
}

/** What the pipeline produced for one model. Written to S3 AND to Mongo. */
export interface AssetManifest {
  modelId: string;
  pipelineVersion: number;
  /** ISO-8601. */
  generatedAt: string;
  variants: AssetVariant[];
  /**
   * Meshy's own render, re-hosted — a transparent PNG because the generation
   * preset sets `alpha_thumbnail`. We never render our own poster.
   */
  posterUrl?: string;
  physicalSize: AssetPhysicalSize;
  reduction: AssetReduction;
}

// ── The persisted record sub-document ────────────────────────────────────────

/**
 * Optimization lifecycle, deliberately SEPARATE from the model's own status.
 * A model whose optimization failed is still a SUCCEEDED model with a usable
 * original — that separation is the whole reason optimization runs as its own
 * job (a pipeline bug must never retract a generation the user already paid
 * for and can already see).
 *
 *   SKIPPED — nothing to gain; the original is already within budget.
 */
export const ASSET_OPTIMIZATION_STATUSES = [
  'QUEUED',
  'PROCESSING',
  'SUCCEEDED',
  'FAILED',
  'SKIPPED',
] as const;
export type AssetOptimizationStatus = (typeof ASSET_OPTIMIZATION_STATUSES)[number];

/** Terminal failure detail, mirroring ModelError's shape. */
export interface AssetOptimizationError {
  code: string;
  message: string;
}

/**
 * The `optimized` sub-doc on a ProjectModel.
 *
 * `activeVariant` is the ADMIN'S DECISION, not the pipeline's: the pipeline
 * only ever produces and measures: it never promotes. Optimization completing
 * successfully does not by itself change what users are served — a human looks
 * at both renditions and flips this. That keeps a bad-looking (but
 * gate-passing) optimization from silently replacing a good model.
 */
export interface OptimizedAsset {
  status: AssetOptimizationStatus;
  pipelineVersion: number;
  manifest?: AssetManifest;
  error?: AssetOptimizationError;
  /** Which variant clients should render. Defaults to 'original'. */
  activeVariant: AssetVariantId;
  /** Key of the audit report (inspection + plan + metrics) under the version prefix. */
  reportKey?: string;
}

/**
 * Resolves the URL a client should actually load, honouring the admin's choice
 * and falling back safely. Exported so the API, and any future consumer, agree
 * on the fallback rather than each re-deriving it.
 *
 * Fails SOFT to the original in every ambiguous case: an un-optimized,
 * heavier-but-correct model beats a broken one.
 */
export function resolveActiveModelUrl(
  optimized: OptimizedAsset | undefined,
  originalUrl: string
): string {
  if (!optimized || optimized.activeVariant === 'original') return originalUrl;
  const variant = optimized.manifest?.variants.find((v) => v.id === optimized.activeVariant);
  return variant?.url ?? originalUrl;
}
