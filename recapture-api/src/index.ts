// src/index.ts
import '@/config/env'; // validates env first — import before anything else
import os from 'node:os';
import { connectDB } from '@/config/db';
import { createApp } from '@/app';
import { env } from '@/config/env';
import { log, toError } from '@/worker/workerLog';
import { runWorkerRuntime } from '@/worker/workerRuntime';
import { axiosBackendMakeAlive } from './utils/axiosBackendMakeAlive';

async function main(): Promise<void> {
  await connectDB();
  await axiosBackendMakeAlive();      // // This fn keep alive our remote backend server.
  const app = createApp();
  app.listen(env.PORT, () => {
    console.log(`🚀 recapture-api running on port ${env.PORT} [${env.NODE_ENV}]`);
    startInProcessWorker();
  });
}

/**
 * Single-service deployment: run the job loop alongside the API rather than as
 * a separate `npm run worker` service (see RUN_WORKER_IN_PROCESS in
 * config/env.ts for why this is safe today, and what makes it unsafe later).
 *
 * Started AFTER listen so a worker problem can never delay the port opening,
 * and deliberately NOT awaited — runWorkerRuntime only resolves at shutdown.
 */
function startInProcessWorker(): void {
  if (!env.RUN_WORKER_IN_PROCESS) return;

  const workerId = `web-${os.hostname()}-${process.pid}`;
  // Log-only. The dedicated worker exits on a fatal error; here that would take
  // the API down with it, so the API stays up and serving while jobs stop being
  // processed — a degraded read path beats a total outage. The queue is durable,
  // so anything enqueued meanwhile is picked up on the next boot.
  runWorkerRuntime(workerId).catch((err: unknown) => {
    log('error', 'In-process worker stopped — API still serving', {
      workerId,
      error: toError(err).message,
    });
  });
}

main().catch((err) => {
  console.error('Fatal startup error:', err);
  process.exit(1);
});
