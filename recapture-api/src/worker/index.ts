// src/worker/index.ts
//
// Background worker entry point — a SEPARATE long-lived process:
//     npm run worker        (dev watch: npm run worker:dev)
//
// NEVER import this file from the API server (src/index.ts / src/app.ts).
// The worker must run out-of-process so job processing can't block the API
// event loop and so it scales/restarts independently.
import '@/config/env'; // validates env first — import before anything else
import os from 'node:os';
import { connectDB, disconnectDB } from '@/config/db';
import { env } from '@/config/env';
import { registerProcessor } from '@/worker/processorRegistry';
import { captureProcessingProcessor } from '@/worker/processors/captureProcessingProcessor';
import { startWorker } from '@/worker/worker';
import { log, toError } from '@/worker/workerLog';
import { DEFAULT_JOB_TYPE } from '@/worker/workerTypes';

const workerId = `worker-${os.hostname()}-${process.pid}`;

async function main(): Promise<void> {
  // connectDB (src/config/db.ts) sets serverSelectionTimeoutMS and mongoose
  // auto-reconnects on drops; a job in flight during an outage is recovered
  // by the stale-claim lease, not by anything here.
  await connectDB();
  log('info', 'MongoDB connected', { workerId });

  registerProcessor(DEFAULT_JOB_TYPE, captureProcessingProcessor);
  // Register additional processors here as new job types are added.

  await startWorker({
    pollIntervalMs: env.WORKER_POLL_INTERVAL_MS,
    claimTimeoutMs: env.WORKER_CLAIM_TIMEOUT_MS,
    concurrency: env.WORKER_CONCURRENCY,
    workerId,
    heartbeatEveryNPolls: env.WORKER_HEARTBEAT_EVERY_N_POLLS,
  });

  // startWorker only resolves after a graceful drain (SIGTERM/SIGINT).
  await disconnectDB();
}

main().catch((err: unknown) => {
  log('fatal', 'Worker crashed', { workerId, error: toError(err).message });
  process.exit(1);
});
