// src/modules/asset-pipeline/index.ts
//
// THE ASSET PIPELINE — the public surface of this module.
//
// Takes the GLB Meshy produced and returns a smaller one that renders on a
// low-end Android over café Wi-Fi, plus the measurements that justify serving
// it.
//
// ── NO QUEUE CONSUMER TODAY ──────────────────────────────────────────────────
// The ASSET_OPTIMIZATION job that used to drive this module is gone: shrinking
// a generated model now runs through services/modelOptimizerService.ts and the
// MODEL_OPTIMIZATION job, which writes its output as a SEPARATE OPT record
// (`ProjectModel.optimizedFrom`) rather than an `optimized.activeVariant` field
// on the source record. This module survives as a library and a CLI — the
// tuning ground for texture budgets and simplify ratios against real Meshy
// samples — with no worker seam and no S3 publisher.
//
// The gates remain the load-bearing part of it: a variant that fails validation
// is discarded rather than served, and on a high-poly source serving the
// original means a viewer that cannot load the model. `plan.simplifyRatio` is
// what keeps that from happening.
//
// This module is a PURE LIBRARY: no Express, no Mongoose, no AWS, no direct
// filesystem access. It takes bytes and returns bytes. That is what lets the
// CLI run it on a local file with no credentials, and what keeps it testable
// without standing up a queue.
import { inspect } from './inspect';
import { plan as planStage } from './plan';
import { execute } from './execute';
import { validate, type ValidationResult } from './validate';
import { DEFAULT_PROFILE_NAME, getProfile } from './profiles';
import { readDocument } from './inspect';
import type {
  InspectionReport,
  OptimizationPlan,
  OptimizedVariant,
} from './types';

export { inspect, planStage as plan, execute, validate };
export { getProfile, listProfileNames, DEFAULT_PROFILE_NAME } from './profiles';
export * from './types';

/** Structured stage logging, injected so the library stays worker-agnostic. */
export type PipelineLogger = (message: string, meta: Record<string, unknown>) => void;

const NOOP_LOGGER: PipelineLogger = () => undefined;

export interface PipelineRun {
  sourceReport: InspectionReport;
  plan: OptimizationPlan;
  /** Absent when the plan skipped, or when the gates rejected the output. */
  variant?: OptimizedVariant;
  validation: ValidationResult;
  durationsMs: {
    inspect: number;
    plan: number;
    execute: number;
    validate: number;
    total: number;
  };
}

export interface RunOptions {
  profileName?: string;
  logger?: PipelineLogger;
  /** Correlation ids for the log lines. Never PII. */
  context?: Record<string, unknown>;
}

/**
 * Runs inspect → plan → execute → validate over one GLB.
 *
 * Returns rather than throws on a gate failure: the caller decides what a
 * failure means. For the worker that is a terminal job (leaving the original
 * serving); for the CLI it is a non-zero exit with a printed table.
 */
export async function runPipeline(glb: Uint8Array, options: RunOptions = {}): Promise<PipelineRun> {
  const log = options.logger ?? NOOP_LOGGER;
  const context = options.context ?? {};
  const profile = getProfile(options.profileName ?? DEFAULT_PROFILE_NAME);
  const startedAt = Date.now();

  // ── inspect ────────────────────────────────────────────────────────────────
  const inspectStart = Date.now();
  const sourceReport = await inspect(glb);
  const inspectMs = Date.now() - inspectStart;
  log('Asset pipeline: inspected source', {
    ...context,
    durationMs: inspectMs,
    bytes: sourceReport.totalBytes,
    triangles: sourceReport.triangles,
    textureCount: sourceReport.textureCount,
    largestTextureBytes: largestTexture(sourceReport),
    longestDimMeters: round(sourceReport.boundingBox.longestDimMeters, 4),
    uvChannelCount: sourceReport.uvChannelCount,
  });

  // ── plan ───────────────────────────────────────────────────────────────────
  const planStart = Date.now();
  const decided = planStage(sourceReport, profile);
  const planMs = Date.now() - planStart;
  log('Asset pipeline: planned', {
    ...context,
    durationMs: planMs,
    profile: decided.profileName,
    skip: decided.skip,
    ...(decided.skipReason ? { skipReason: decided.skipReason } : {}),
    scaleFactor: round(decided.scaleFactor, 4),
    recentrePivot: decided.recentrePivot,
    dropTextureCount: decided.dropTextures.length,
    collapseConstantSlots: decided.collapseConstantSlots,
  });

  if (decided.skip) {
    return {
      sourceReport,
      plan: decided,
      validation: { ok: true, failures: [] },
      durationsMs: {
        inspect: inspectMs,
        plan: planMs,
        execute: 0,
        validate: 0,
        total: Date.now() - startedAt,
      },
    };
  }

  // ── execute ────────────────────────────────────────────────────────────────
  const executeStart = Date.now();
  const variant = await execute(glb, decided, sourceReport);
  const executeMs = Date.now() - executeStart;
  log('Asset pipeline: executed', {
    ...context,
    durationMs: executeMs,
    bytesBefore: sourceReport.totalBytes,
    bytesAfter: variant.report.totalBytes,
    ratio: round(variant.report.totalBytes / Math.max(1, sourceReport.totalBytes), 4),
    trianglesBefore: sourceReport.triangles,
    trianglesAfter: variant.report.triangles,
    textureCountBefore: sourceReport.textureCount,
    textureCountAfter: variant.report.textureCount,
    largestTextureBefore: largestTexture(sourceReport),
    largestTextureAfter: largestTexture(variant.report),
  });

  // ── validate ───────────────────────────────────────────────────────────────
  const validateStart = Date.now();
  // Re-read the produced bytes rather than reusing the in-memory Document: the
  // gates must judge the FILE we would actually publish, including anything the
  // meshopt encoder changed on the way out.
  const producedDoc = await readDocument(variant.bytes);
  const validation = validate(variant.report, decided, producedDoc, sourceReport);
  const validateMs = Date.now() - validateStart;
  log('Asset pipeline: validated', {
    ...context,
    durationMs: validateMs,
    ok: validation.ok,
    ...(validation.ok ? {} : { failures: validation.failures.map((f) => f.gate) }),
  });

  return {
    sourceReport,
    plan: decided,
    variant: validation.ok ? variant : undefined,
    validation,
    durationsMs: {
      inspect: inspectMs,
      plan: planMs,
      execute: executeMs,
      validate: validateMs,
      total: Date.now() - startedAt,
    },
  };
}

/** Largest single texture in bytes — usually the real page-weight driver. */
export function largestTexture(report: InspectionReport): number {
  return report.textures.reduce((max, t) => Math.max(max, t.bytes), 0);
}

function round(value: number, places: number): number {
  const factor = 10 ** places;
  return Math.round(value * factor) / factor;
}

export type { OptimizationPlan, InspectionReport, OptimizedVariant, ValidationResult };
