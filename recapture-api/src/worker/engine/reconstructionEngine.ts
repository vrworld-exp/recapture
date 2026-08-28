// src/worker/engine/reconstructionEngine.ts
//
// The reconstruction-engine ADAPTER seam. The pipeline task (this phase)
// deliberately delivers orchestration only — the heavy photogrammetry /
// meshing / texturing / optimization is DELEGATED behind this interface, so
// plugging in the real engine (external process, GPU service, third-party
// API) later touches exactly one file: a new ReconstructionEngine
// implementation registered in src/worker/index.ts (or via the test seam).
//
// Contract every implementation must honor:
//   • IDEMPOTENT per stage: a stage may be re-run after a crash, a lease
//     takeover, or a retry — same inputs must converge to the same outputs
//     (deterministic artifact keys; overwrite, never append).
//   • Progress via onProgress: coarse milestones, not a firehose — each call
//     is a DB write AND the claim-lease renewal. A stage that can exceed
//     WORKER_CLAIM_TIMEOUT_MS silently MUST emit progress to keep its lease.
//   • onProgress THROWS (JobCanceledError / ClaimLostError) when the job was
//     canceled or stolen — the engine must let that propagate to abort the
//     stage; it must not swallow it and keep burning compute.
//   • Failures: throw plain Error for transient trouble (→ worker retry with
//     backoff, resuming at this stage) or NonRetryableJobError for input
//     problems retrying can never fix (→ terminal FAILED).
import { BUCKET_ARTIFACTS, CLOUDFRONT_BASE } from '@/config/s3';
import { log } from '@/worker/workerLog';

/** Everything one stage run receives from the orchestrator. */
export interface EngineStageInput {
  jobId: string;
  projectId?: string;
  /** Raw-capture bundle location (validated before the pipeline starts). */
  rawBucket: string;
  rawPrefix: string;
  manifestKey: string;
  /** Parsed capture_manifest.json — structure validated upstream. */
  manifest: unknown;
  /** S3-listed object count under the job prefix (manifest included). */
  filesVerified: number;
  /**
   * Persisted outputs of the stages already completed (keyed by stage name) —
   * what makes retry-from-failed-stage possible without redoing prior work.
   */
  priorOutputs: Readonly<Record<string, Record<string, unknown>>>;
  /** Reports intra-stage progress (0–100). Throws on cancel/claim-loss. */
  onProgress: (percent: number) => Promise<void>;
}

/** Artifact refs the OPTIMIZING stage must yield (persisted on the job). */
export interface EngineArtifacts extends Record<string, unknown> {
  glbKey: string;
  usdzKey?: string;
  reportKey?: string;
  previewImageKey?: string;
  cdnUrls?: { glb?: string; usdz?: string; preview?: string };
}

export interface OptimizeOutput extends Record<string, unknown> {
  artifacts: EngineArtifacts;
}

/** One method per executable stage — the whole delegation surface. */
export interface ReconstructionEngine {
  /** PROCESSING: photogrammetry/meshing over the raw bundle. */
  reconstruct(input: EngineStageInput): Promise<Record<string, unknown>>;
  /** TEXTURING: texture the reconstructed mesh. */
  texture(input: EngineStageInput): Promise<Record<string, unknown>>;
  /** OPTIMIZING: optimize + package; returns the final artifact refs. */
  optimize(input: EngineStageInput): Promise<OptimizeOutput>;
}

// ── Stub implementation ──────────────────────────────────────────────────────
// Placeholder until the real engine lands: does no work, but exercises the
// full orchestration contract — progress milestones, prior-output threading,
// and DETERMINISTIC artifact keys (same job ⇒ same keys, so a re-run
// overwrites instead of duplicating — the idempotency contract by
// construction). Keys mirror the raw bundle's scope under the artifacts
// bucket: {env}/{projectSlug}_{projectId}/{jobId}/model.glb etc.

const STUB_PROGRESS_MILESTONES = [25, 50, 75] as const;

async function stubStage(
  input: EngineStageInput,
  stage: string,
  output: Record<string, unknown>
): Promise<Record<string, unknown>> {
  log('info', 'Reconstruction-engine stub stage running', {
    jobId: input.jobId,
    stage,
    filesVerified: input.filesVerified,
    priorStages: Object.keys(input.priorOutputs),
  });
  for (const percent of STUB_PROGRESS_MILESTONES) {
    await input.onProgress(percent);
  }
  return { engine: 'stub', stage, ...output };
}

export const stubReconstructionEngine: ReconstructionEngine = {
  reconstruct: (input) =>
    stubStage(input, 'PROCESSING', {
      meshRef: `${input.rawPrefix}intermediate/mesh.bin`,
      photosUsed: input.filesVerified - 1, // manifest is not a photo
    }),

  texture: (input) =>
    stubStage(input, 'TEXTURING', {
      texturedMeshRef: `${input.rawPrefix}intermediate/mesh_textured.bin`,
    }),

  optimize: async (input) => {
    const artifacts: EngineArtifacts = {
      glbKey: `${input.rawPrefix}model.glb`,
      reportKey: `${input.rawPrefix}quality_report.json`,
      previewImageKey: `${input.rawPrefix}preview.jpg`,
      cdnUrls: {
        glb: `${CLOUDFRONT_BASE}/${input.rawPrefix}model.glb`,
        preview: `${CLOUDFRONT_BASE}/${input.rawPrefix}preview.jpg`,
      },
    };
    const base = await stubStage(input, 'OPTIMIZING', {
      artifactBucket: BUCKET_ARTIFACTS,
    });
    return { ...base, artifacts };
  },
};

// ── Engine registration (test seam + future real engine) ────────────────────

let activeEngine: ReconstructionEngine = stubReconstructionEngine;

export function getReconstructionEngine(): ReconstructionEngine {
  return activeEngine;
}

/** Swaps the engine (tests / real-engine wiring). Pass null to restore the stub. */
export function setReconstructionEngine(engine: ReconstructionEngine | null): void {
  activeEngine = engine ?? stubReconstructionEngine;
}
