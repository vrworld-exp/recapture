// src/index.ts
import '@/config/env'; // validates env first — import before anything else
import os from 'node:os';
import { connectDB } from '@/config/db';
import { createApp } from '@/app';
import { env } from '@/config/env';
import { log, toError } from '@/worker/workerLog';
import { runWorkerRuntime } from '@/worker/workerRuntime';
import { axiosBackendMakeAlive } from './utils/axiosBackendMakeAlive';

/**
 * Keep the process alive when something escapes a request handler.
 *
 * Node 20 defaults to `--unhandled-rejections=throw`, so ONE floating promise
 * anywhere — a fire-and-forget refresh, an async timer callback, a `.then`
 * with no `.catch` — terminates the whole process and takes every in-flight
 * request with it. Express already contains everything thrown INSIDE a handler
 * (utils/asyncHandler.ts routes it to the error middleware); these two guards
 * cover only what escapes that path.
 *
 * `uncaughtException` is the deliberate part: the textbook advice is to exit,
 * on the grounds that the process may be in an unknown state. A single-service
 * deployment answers that differently — handlers are already isolated, durable
 * work lives in Mongo behind the job queue, and a degraded server that keeps
 * serving beats a hard outage. Anything logged here is a BUG to fix at its
 * source, not a condition to run in.
 *
 * Installed before connectDB so the very first tick is covered.
 */
function installProcessGuards(): void {
  process.on('unhandledRejection', (reason: unknown) => {
    const err = toError(reason);
    log('error', 'Unhandled promise rejection — API still serving', {
      error: err.message,
      stack: err.stack,
    });
  });

  process.on('uncaughtException', (err: Error) => {
    log('error', 'Uncaught exception — API still serving', {
      error: err.message,
      stack: err.stack,
    });
  });
}

async function main(): Promise<void> {
  installProcessGuards();

  const app = createApp();

  /**
   * Bind the port FIRST — before any network round trip.
   *
   * Render fails a deploy with "No open ports detected" when nothing is
   * listening inside its scan window, and connectDB() is exactly the kind of
   * call that can outlast it: a slow SRV lookup, a cold Atlas cluster, or an
   * IP allow-list rejection all keep the socket closed while the platform
   * gives up. Listening first makes the deploy succeed or fail on its own
   * merits, and turns a Mongo problem into a Mongo error in the logs instead
   * of a port-scan timeout that says nothing about the cause.
   *
   * Safe because mongoose BUFFERS commands until the connection is up, so a
   * request landing in the gap waits rather than failing.
   *
   * '0.0.0.0' is explicit for the same class of reason: Render routes to the
   * container's external interface, never loopback.
   */
  app.listen(env.PORT, '0.0.0.0', () => {
    console.log(`🚀 recapture-api listening on 0.0.0.0:${env.PORT} [${env.NODE_ENV}]`);
  });

  await connectDB();
  await axiosBackendMakeAlive();      // // This fn keep alive our remote backend server.
  startInProcessWorker();
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
