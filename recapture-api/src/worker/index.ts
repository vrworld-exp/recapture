// src/worker/index.ts
//
// Background worker entry point — the DEDICATED long-lived process:
//     npm run worker        (dev watch: npm run worker:dev)
//
// This file owns a worker's PROCESS LIFECYCLE (connect, run, disconnect, exit
// on fatal) and must not be imported by the API server — its `process.exit(1)`
// would take the API down with it. The loop itself lives in workerRuntime.ts,
// which the API may run in-process under RUN_WORKER_IN_PROCESS (see the flag's
// note in config/env.ts for when that stops being safe). Deploying this as its
// own service is still the preferred shape once job processing does real
// CPU-bound work; today it is I/O-bound, so a single service is a legitimate
// choice.
import '@/config/env'; // validates env first — import before anything else
import os from 'node:os';
import { connectDB, disconnectDB } from '@/config/db';
import { log, toError } from '@/worker/workerLog';
import { runWorkerRuntime } from '@/worker/workerRuntime';

const workerId = `worker-${os.hostname()}-${process.pid}`;

async function main(): Promise<void> {
  // connectDB (src/config/db.ts) sets serverSelectionTimeoutMS and mongoose
  // auto-reconnects on drops; a job in flight during an outage is recovered
  // by the stale-claim lease, not by anything here.
  await connectDB();
  log('info', 'MongoDB connected', { workerId });

  // Resolves only after a graceful drain (SIGTERM/SIGINT).
  await runWorkerRuntime(workerId);

  await disconnectDB();
}

main().catch((err: unknown) => {
  log('fatal', 'Worker crashed', { workerId, error: toError(err).message });
  process.exit(1);
});
