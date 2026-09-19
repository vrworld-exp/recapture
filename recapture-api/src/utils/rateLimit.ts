// src/utils/rateLimit.ts
import { RateWindow } from '@/models/RateWindow';

export type RateLimitResult = { limited: true; retryAfter: number } | { limited: false };

/**
 * Records one hit against a sliding window for `key` and reports whether the
 * caller has exceeded `max` within `windowSeconds`. DB-backed (no Redis):
 * a single document per key carries the window start and the running count.
 *
 * The current hit is counted as it is recorded, so the Nth call within a window
 * is the one that trips the limit. Keys must be pre-namespaced and PII-free.
 */
export async function consumeRateWindow(
  key: string,
  max: number,
  windowSeconds: number,
  now: number = Date.now()
): Promise<RateLimitResult> {
  const existing = await RateWindow.findOne({ key }).exec();

  let count = 1;
  let windowStartedAt = new Date(now);

  if (existing) {
    const windowAgeSeconds = (now - existing.windowStartedAt.getTime()) / 1000;
    if (windowAgeSeconds < windowSeconds) {
      if (existing.count >= max) {
        return { limited: true, retryAfter: Math.ceil(windowSeconds - windowAgeSeconds) };
      }
      count = existing.count + 1;
      windowStartedAt = existing.windowStartedAt;
    }
    // else: window elapsed → reset.
  }

  await RateWindow.findOneAndUpdate(
    { key },
    { key, windowStartedAt, count, purgeAt: new Date(now + windowSeconds * 1000) },
    { upsert: true, new: true, setDefaultsOnInsert: true }
  ).exec();

  return { limited: false };
}

/**
 * The same verdict {@link consumeRateWindow} would give right now, WITHOUT
 * recording a hit — for a read that wants to show a cooldown before the
 * caller taps (the rep's "Notify owner" button). `resetsAt` is the instant
 * the window lapses and the next hit would be accepted.
 */
export async function peekRateWindow(
  key: string,
  max: number,
  windowSeconds: number,
  now: number = Date.now()
): Promise<{ limited: true; retryAfter: number; resetsAt: Date } | { limited: false }> {
  const existing = await RateWindow.findOne({ key }).lean().exec();
  if (!existing) return { limited: false };
  const startedAt = existing.windowStartedAt.getTime();
  const windowAgeSeconds = (now - startedAt) / 1000;
  if (windowAgeSeconds >= windowSeconds || existing.count < max) return { limited: false };
  return {
    limited: true,
    retryAfter: Math.ceil(windowSeconds - windowAgeSeconds),
    resetsAt: new Date(startedAt + windowSeconds * 1000),
  };
}
