// src/worker/workerLog.ts
//
// The worker process's single log seam: one JSON object per line, always with
// timestamp/level/message. Every log statement in src/worker/ goes through
// this helper — no bare console.log strings — so worker output is machine-
// parseable for ops alerting (e.g. growing QUEUED depth in heartbeats).
//
// PII rule (AGENTS.md): meta must carry only non-PII values — ObjectIds,
// worker ids, counts, enum values, error messages. Never phone/email/tokens.

export type WorkerLogLevel = 'info' | 'warn' | 'error' | 'fatal';

export function log(
  level: WorkerLogLevel,
  message: string,
  meta: Record<string, unknown> = {}
): void {
  const line = JSON.stringify({
    timestamp: new Date().toISOString(),
    level,
    message,
    ...meta,
  });
  if (level === 'error' || level === 'fatal') {
    console.error(line);
  } else if (level === 'warn') {
    console.warn(line);
  } else {
    console.log(line);
  }
}

/** Normalizes an unknown thrown value into an Error (strict mode: no `any`). */
export function toError(err: unknown): Error {
  return err instanceof Error ? err : new Error(String(err));
}
