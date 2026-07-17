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
import { registerProcessor } from '@/worker/processorRegistry';
import { captureProcessingProcessor } from '@/worker/processors/captureProcessingProcessor';
import { meshyModelProcessor } from '@/worker/processors/meshyModelProcessor';
import { startWorker } from '@/worker/worker';
import { DEFAULT_JOB_TYPE, MESHY_MODEL_GENERATION_JOB_TYPE } from '@/worker/workerTypes';

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
