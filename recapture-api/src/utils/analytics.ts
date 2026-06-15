// src/utils/analytics.ts
import { env } from '@/config/env';

type AnalyticsValue = string | number | boolean | null | undefined;
export type AnalyticsProps = Record<string, AnalyticsValue>;

/**
 * Minimal analytics sink.
 *
 * TODO(analytics): forward events to the real pipeline (Segment / PostHog /
 * internal collector) when it lands. Until then events are echoed outside
 * production so call sites are verifiable.
 *
 * Callers MUST pass only non-PII properties — hashed identifiers, never raw
 * phone/email or the OTP itself.
 */
export function trackEvent(event: string, props: AnalyticsProps = {}): void {
  if (env.NODE_ENV !== 'production') {
    console.log(`[analytics] ${event}`, JSON.stringify(props));
  }
}
