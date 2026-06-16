// src/utils/analytics.ts
import { env } from '@/config/env';
import {
  AnalyticsEvent,
  EVENT_SCHEMAS,
  type AnalyticsEventName,
  type EventPropsMap,
} from '@/validation/analyticsSchemas';

// Re-export so call sites import names + emitter from one place.
export { AnalyticsEvent };
export type { AnalyticsEventName, EventPropsMap };

function isProd(): boolean {
  return env.NODE_ENV === 'production';
}

// PII/secret guardrail. A property whose name contains any of these is treated
// as raw sensitive data that must never ship — it is dropped + flagged rather
// than emitted, even if a caller bypasses the typed signature. Values are
// already required (by schema) to be hashed; this guards the property *names*.
const FORBIDDEN_KEY_SUBSTRINGS = [
  'password',
  'passwd',
  'secret',
  'token',
  'otp',
  'code',
  'phone',
  'email',
  'msisdn',
];

function stripForbidden(props: Record<string, unknown>): {
  clean: Record<string, unknown>;
  dropped: string[];
} {
  const clean: Record<string, unknown> = {};
  const dropped: string[] = [];
  for (const [key, value] of Object.entries(props)) {
    const lower = key.toLowerCase();
    if (FORBIDDEN_KEY_SUBSTRINGS.some((bad) => lower.includes(bad))) {
      dropped.push(key);
    } else {
      clean[key] = value;
    }
  }
  return { clean, dropped };
}

/**
 * The destination sink. Swap this for the real pipeline (Segment/PostHog/
 * collector) later. It MUST remain non-blocking and MUST NOT throw out of here —
 * `track()` also guards, but keep this defensive.
 */
function dispatch(event: string, props: Record<string, unknown>): void {
  // TODO(analytics): forward to the real pipeline. Until then, echo outside prod
  // so call sites are verifiable.
  if (!isProd()) {
    console.log(`[analytics] ${event}`, JSON.stringify(props));
  }
}

/**
 * Emit a typed analytics event.
 *
 * Compile time: `event` must be a known {@link AnalyticsEvent} name and `props`
 * must match that event's schema — an unknown event name does not type-check.
 *
 * Runtime: (1) strip + flag any forbidden PII-named property, (2) validate props
 * against the event's Zod schema — invalid props are LOUD in dev/staging
 * (console.error) and silently dropped in production, never crashing, (3)
 * forward to the destination.
 *
 * Fire-and-forget: this never throws into the caller, so analytics can never
 * break or delay a request path. Auth succeeds even if analytics is down.
 */
export function track<E extends AnalyticsEventName>(event: E, props: EventPropsMap[E]): void {
  try {
    const { clean, dropped } = stripForbidden(props as Record<string, unknown>);
    if (dropped.length > 0) {
      console.warn(
        `[analytics] dropped forbidden propert${dropped.length > 1 ? 'ies' : 'y'} ` +
          `on "${event}": ${dropped.join(', ')}`
      );
    }

    const schema = EVENT_SCHEMAS[event];
    const parsed = schema.safeParse(clean);
    if (!parsed.success) {
      const detail = parsed.error.issues
        .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
        .join('; ');
      const message = `[analytics] invalid props for "${event}" — event dropped (${detail})`;
      // Loud in non-prod to catch drift early; quiet (but logged) in prod.
      if (isProd()) {
        console.warn(message);
      } else {
        console.error(message);
      }
      return;
    }

    dispatch(event, parsed.data as Record<string, unknown>);
  } catch (err) {
    // Last-resort guard: analytics must never break the request path.
    console.warn(`[analytics] track("${event}") failed and was swallowed`, err);
  }
}
