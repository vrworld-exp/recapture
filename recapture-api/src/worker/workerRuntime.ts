// src/worker/workerRuntime.ts
//
// The worker's boot sequence, shared by BOTH hosts:
//   • src/worker/index.ts       — the dedicated `npm run worker` process;
//   • src/index.ts              — the API process, when RUN_WORKER_IN_PROCESS.
//
// It lives here so the two can never drift: a processor registered for one host
// is registered for the other, and a job type that runs in dev cannot silently
// have no processor in the single-service deployment.
//
// This module does NOT own the process lifecycle (connectDB, exit codes,
// disconnect) — each host owns that, because the right answer differs: a fatal
// error should kill the dedicated worker, but must NOT kill the API.
import { env } from '@/config/env';
import { assertMeshyConfigured } from '@/worker/engine/meshy/meshyClient';
import { setAssetUploader } from '@/services/catalog/assetUploader';
import { assetSyncUploader } from '@/services/catalog/assetSync';
import { categoryExecutor } from '@/services/catalog/categorySync';
import { setPublishExecutors } from '@/services/catalog/publishExecutors';
import { productExecutor } from '@/services/catalog/productSync';
import { restaurantExecutor } from '@/services/catalogPublishService';
import { registerProcessor } from '@/worker/processorRegistry';
import { captureProcessingProcessor } from '@/worker/processors/captureProcessingProcessor';
import { meshyModelProcessor } from '@/worker/processors/meshyModelProcessor';
import { mirageCatalogPublishProcessor } from '@/worker/processors/mirageCatalogPublishProcessor';
import { modelOptimizationProcessor } from '@/worker/processors/modelOptimizationProcessor';
import { startWorker } from '@/worker/worker';
import {
  DEFAULT_JOB_TYPE,
  MESHY_MODEL_GENERATION_JOB_TYPE,
  MIRAGE_CATALOG_PUBLISH_JOB_TYPE,
  MODEL_OPTIMIZATION_JOB_TYPE,
} from '@/worker/workerTypes';

/**
 * Registers every job type this codebase can process.
 *
 * Add new processors HERE, not in an entry point — that is the whole reason
 * this function exists.
 */
export function registerAllProcessors(): void {
  registerProcessor(DEFAULT_JOB_TYPE, captureProcessingProcessor);
  // Staff-triggered Meshy generation — a PEER of the capture pipeline, not a
  // replacement for it (docs/meshy-integration-implementation-prompt.md).
  registerProcessor(MESHY_MODEL_GENERATION_JOB_TYPE, meshyModelProcessor);
  // Shrinking an already-generated model. Costs CPU, never Meshy credits, and
  // needs no extra credential — so unlike the Meshy processor it has nothing to
  // assert at boot (docs/prompts/model-optimization-opt-variant.md).
  registerProcessor(MODEL_OPTIMIZATION_JOB_TYPE, modelOptimizationProcessor);
  // Projecting a catalog onto Mirage. Unlike the three above its unit of work
  // is a CatalogPublishRun rather than a model, and its Mirage calls sit behind
  // injected executors (services/catalog/publishExecutors.ts) — so registering
  // it here costs the worker nothing at boot: there is no extra credential to
  // assert, and an unconfigured Mirage fails at the first call with a
  // classified error rather than at startup.
  registerProcessor(MIRAGE_CATALOG_PUBLISH_JOB_TYPE, mirageCatalogPublishProcessor);
  registerPublishExecutors();
}

/**
 * Installs the real Mirage executors over publishExecutors.ts's no-op defaults.
 *
 * It happens HERE, in the worker's boot, rather than as an import side effect of
 * the executor modules — a service that registered itself would make "which
 * implementation is active" depend on module load order, and would drag the
 * Mirage adapter into the API process's import graph for no reason. The worker
 * may import services; services may not import the worker (AGENTS.md
 * §layering), and this direction is the one that respects that.
 *
 * All three targets the planner can emit are covered here, and the record in
 * PublishExecutors is total — a new target kind is a compile error rather than
 * a silent no-op at runtime.
 */
function registerPublishExecutors(): void {
  setPublishExecutors({
    // Provisioning and branding. It lives in catalogPublishService because it
    // is the one write that can never be taken back (the public URL a printed
    // QR resolves through), and that belongs beside the immutability guard.
    RESTAURANT: restaurantExecutor,
    CATEGORY: categoryExecutor,
    PRODUCT: productExecutor,
  });
  // The asset half, behind its own seam so the product executor can be tested
  // without S3 and so the transfer strategy (bytes vs the M1 URL path) is one
  // config flag rather than a branch inside the executor.
  setAssetUploader(assetSyncUploader);
}

/**
 * Asserts the credentials the registered processors need, registers them, and
 * runs the poll loop until shutdown.
 *
 * Callers must have an open Mongo connection: the Job collection IS the queue.
 * Resolves only after a graceful drain (SIGTERM/SIGINT), which startWorker
 * wires up itself.
 */
export async function runWorkerRuntime(workerId: string): Promise<void> {
  // Whichever process runs the loop is the process that talks to Meshy, so this
  // is where the credential becomes required (config/env.ts leaves it optional
  // so an API that only enqueues is not held hostage to a secret it never
  // uses). Fail at boot, loudly, rather than at the first staff Create Model tap.
  assertMeshyConfigured();

  registerAllProcessors();

  await startWorker({
    pollIntervalMs: env.WORKER_POLL_INTERVAL_MS,
    claimTimeoutMs: env.WORKER_CLAIM_TIMEOUT_MS,
    concurrency: env.WORKER_CONCURRENCY,
    workerId,
    heartbeatEveryNPolls: env.WORKER_HEARTBEAT_EVERY_N_POLLS,
  });
}
