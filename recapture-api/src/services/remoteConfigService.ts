// src/services/remoteConfigService.ts
import { ClientConfig } from '@/models/ClientConfig';
import {
  remoteConfigSchema,
  DEFAULT_REMOTE_CONFIG,
  type RemoteConfig,
} from '@/validation/remoteConfigSchema';

export interface RemoteConfigResult {
  config: RemoteConfig;
  /** True when defaults were served because the store was empty/unreachable/invalid. */
  servedDefaults: boolean;
}

/**
 * Resolves the runtime config to serve. NEVER throws for a store problem: a
 * missing document, a DB error, or a document that fails schema validation all
 * degrade to {@link DEFAULT_REMOTE_CONFIG} with a server-side warning, so the
 * client endpoint can always answer 200/304 regardless of store health.
 *
 * Reject-to-defaults policy: a partially-valid stored config is treated as
 * invalid (no field-level merge) to keep the served payload predictable.
 */
/**
 * Reads a SERVER-SIDE operational flag off the same config document.
 *
 * Deliberately NOT part of `remoteConfigSchema`: that schema is the client wire
 * payload — `.strict()`, reject-to-defaults, and documented as free of internal
 * fields. Adding an ops flag there would put a server switch on the wire and,
 * worse, a malformed value would fail validation and silently drop the WHOLE
 * config to defaults. Instead the flag rides on the store document (which is
 * `strict: false`) and is read directly here; `getRemoteConfig` picks only its
 * named fields, so the served payload is unaffected by anything added this way.
 *
 * Ops flip it with a one-line update to the `client_configs` document — no
 * deploy, no app release.
 *
 * THROWS on a store failure. Unlike the client path (which must never 5xx),
 * callers here are gating real spending and must decide their own fallback;
 * silently returning `false` or `true` would make an outage look like a
 * decision.
 */
export async function getServerFlag(key: string): Promise<boolean | undefined> {
  const doc = await ClientConfig.findOne().sort({ updatedAt: -1 }).lean().exec();
  const value = (doc as Record<string, unknown> | null)?.[key];
  return typeof value === 'boolean' ? value : undefined;
}

export async function getRemoteConfig(): Promise<RemoteConfigResult> {
  try {
    // Single global config; newest wins if more than one exists.
    const doc = await ClientConfig.findOne().sort({ updatedAt: -1 }).lean().exec();

    if (!doc) {
      console.warn('[remote-config] no config document found; serving defaults');
      return { config: DEFAULT_REMOTE_CONFIG, servedDefaults: true };
    }

    // Pick only the served fields so store-internal keys (_id, timestamps, __v)
    // never reach the strict schema or the wire.
    const candidate = {
      version: doc.version,
      pitchBands: doc.pitchBands,
      thresholds: doc.thresholds,
      segmentCounts: doc.segmentCounts,
      guided_capture_variant_segments: doc.guided_capture_variant_segments,
    };

    const parsed = remoteConfigSchema.safeParse(candidate);
    if (!parsed.success) {
      const issue = parsed.error.issues[0];
      const where = issue?.path.join('.') || 'config';
      console.warn(
        `[remote-config] stored config failed validation at "${where}": ` +
          `${issue?.message ?? 'invalid'}; serving defaults`
      );
      return { config: DEFAULT_REMOTE_CONFIG, servedDefaults: true };
    }

    return { config: parsed.data, servedDefaults: false };
  } catch (err) {
    // DB unreachable / timeout / unexpected — degrade, never 5xx.
    const message = err instanceof Error ? err.message : 'unknown error';
    console.warn(`[remote-config] store read failed (${message}); serving defaults`);
    return { config: DEFAULT_REMOTE_CONFIG, servedDefaults: true };
  }
}
