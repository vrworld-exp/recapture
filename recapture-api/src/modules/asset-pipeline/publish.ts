// src/modules/asset-pipeline/publish.ts
//
// STAGE 5 — upload, and build the manifest clients read.
//
// The ONLY file in this module that touches AWS, which is what lets the CLI run
// the whole pipeline on a local file with no credentials.
//
// IMMUTABILITY IS THE CONTRACT HERE. Variants are written under a
// version-scoped prefix (`…/models/{modelId}/v{n}/`) and served
// `max-age=31536000, immutable`, so:
//   • a client that cached v1 can never be handed different bytes at that URL;
//   • re-running an improved recipe means a NEW pipelineVersion and a NEW
//     prefix, never an overwrite;
//   • the untouched Meshy original at `…/models/{modelId}/model.glb` is left
//     exactly where the generation processor put it — it is the only way to
//     re-run a better recipe later, so nothing in this file may write to it.
import { BUCKET_ARTIFACTS, CLOUDFRONT_BASE } from '@/config/s3';
import {
  ASSET_PIPELINE_VERSION,
  type AssetManifest,
  type AssetVariant,
} from '@/models/types/assetManifest.types';
import { putObjectBytes } from '@/services/s3ObjectStore';

import { largestTexture, type PipelineRun } from './index';
import type { InspectionReport } from './types';

/** One year, the maximum any CDN should be asked to hold an immutable object. */
const IMMUTABLE_CACHE_CONTROL = 'public, max-age=31536000, immutable';

export const GLB_CONTENT_TYPE = 'model/gltf-binary';

/** Where this pipeline version's outputs live for one model. */
export function variantPrefix(modelPrefix: string, pipelineVersion: number): string {
  return `${modelPrefix}v${pipelineVersion}/`;
}

export interface PublishInput {
  modelId: string;
  /** `…/models/{modelId}/` — the prefix the generation processor already used. */
  modelPrefix: string;
  run: PipelineRun;
  /** Key of the untouched Meshy GLB, already re-hosted. Never rewritten. */
  originalKey: string;
  originalReport: InspectionReport;
  /** Meshy's own re-hosted poster, when the generation produced one. */
  posterKey?: string;
}

export interface PublishResult {
  manifest: AssetManifest;
  reportKey: string;
}

/**
 * Uploads the optimized variant, the audit report, and manifest.json, then
 * returns the manifest to persist on the record.
 *
 * The manifest ALWAYS describes the original, even when optimization was
 * skipped or produced nothing: a client must be able to render from the
 * manifest alone, and "there is no optimized variant" is a legitimate answer
 * that still needs an original to point at.
 */
export async function publish(input: PublishInput): Promise<PublishResult> {
  const { modelId, modelPrefix, run, originalKey, originalReport, posterKey } = input;
  const prefix = variantPrefix(modelPrefix, ASSET_PIPELINE_VERSION);

  const variants: AssetVariant[] = [
    toVariant('original', originalKey, originalReport, false),
  ];

  if (run.variant) {
    const webKey = `${prefix}web.glb`;
    await putObjectBytes(BUCKET_ARTIFACTS, webKey, run.variant.bytes, GLB_CONTENT_TYPE, {
      cacheControl: IMMUTABLE_CACHE_CONTROL,
    });
    variants.push(toVariant('web', webKey, run.variant.report, true));
  }

  // The audit trail: inspection + plan + durations + gate results. Written even
  // on a skip, because "why did nothing happen to this model?" is exactly the
  // question an admin asks, and the answer is in the plan.
  const reportKey = `${prefix}report.json`;
  const auditReport = {
    modelId,
    pipelineVersion: ASSET_PIPELINE_VERSION,
    generatedAt: new Date().toISOString(),
    source: run.sourceReport,
    plan: run.plan,
    optimized: run.variant?.report ?? null,
    validation: run.validation,
    durationsMs: run.durationsMs,
  };
  await putObjectBytes(
    BUCKET_ARTIFACTS,
    reportKey,
    Buffer.from(JSON.stringify(auditReport, null, 2)),
    'application/json',
    { cacheControl: IMMUTABLE_CACHE_CONTROL }
  );

  const after = run.variant?.report ?? originalReport;
  const manifest: AssetManifest = {
    modelId,
    pipelineVersion: ASSET_PIPELINE_VERSION,
    generatedAt: auditReport.generatedAt,
    variants,
    ...(posterKey ? { posterUrl: cdnUrl(posterKey) } : {}),
    physicalSize: {
      widthMeters: after.boundingBox.widthMeters,
      heightMeters: after.boundingBox.heightMeters,
      depthMeters: after.boundingBox.depthMeters,
      longestDimMeters: after.boundingBox.longestDimMeters,
    },
    reduction: {
      bytesBefore: originalReport.totalBytes,
      bytesAfter: after.totalBytes,
      ratio: after.totalBytes / Math.max(1, originalReport.totalBytes),
      trianglesBefore: originalReport.triangles,
      trianglesAfter: after.triangles,
    },
  };

  await putObjectBytes(
    BUCKET_ARTIFACTS,
    `${prefix}manifest.json`,
    Buffer.from(JSON.stringify(manifest, null, 2)),
    'application/json',
    { cacheControl: IMMUTABLE_CACHE_CONTROL }
  );

  return { manifest, reportKey };
}

function toVariant(
  id: AssetVariant['id'],
  key: string,
  report: InspectionReport,
  meshoptCompressed: boolean
): AssetVariant {
  return {
    id,
    url: cdnUrl(key),
    key,
    bytes: report.totalBytes,
    triangles: report.triangles,
    textureCount: report.textureCount,
    largestTextureBytes: largestTexture(report),
    meshoptCompressed,
  };
}

function cdnUrl(key: string): string {
  return `${CLOUDFRONT_BASE}/${key}`;
}
