// src/validation/remoteConfigSchema.ts
import { z } from 'zod';
import {
  SEGMENT_COUNT_BY_SIZE,
  MIN_PHOTOS_PER_RING_BY_SIZE,
  type ObjectSize,
} from '@/models/types/capture.types';
import {
  expectedPerRing,
  ringsForVariant,
  type CaptureFlowVariant,
  type CaptureRingName,
} from '@/models/types/captureVariants';

/**
 * Wire schema for GET /remote-config — runtime tuning the mobile client/viewer
 * fetches so behaviour can change without an app release. Kept deliberately
 * small (low-end Android consumes this) and free of any internal/store fields.
 *
 * - `pitchBands` — camera-pitch ranges (degrees) for the guided capture rings
 *   (mirrors the EYE/TOP/LOW levels in capture.types).
 * - `thresholds` — minimum accepted photos per ring, keyed by object size.
 * - `segmentCounts` — ring segment count, keyed by object size.
 * - `guided_capture_variant_segments` — per capture-flow-variant segment
 *   counts, keyed variant-id → band-id (`mid`/`high`/`low` — the CLIENT's
 *   vocabulary for the EYE/TOP/LOW rings; the ring names stay in the
 *   S3/manifest layer and never leak here).
 *
 * `.strict()` keeps the served payload to exactly these keys. Stored configs are
 * validated against this before serving; anything that doesn't conform falls
 * back to {@link DEFAULT_REMOTE_CONFIG} (reject-to-defaults, not field merge).
 */
export const remoteConfigSchema = z
  .object({
    version: z.number().int().nonnegative(),
    pitchBands: z
      .array(
        z
          .object({
            min: z.number(),
            max: z.number(),
            label: z.string().min(1),
          })
          .strict()
      )
      .min(1),
    thresholds: z.record(z.string(), z.number()),
    segmentCounts: z.record(z.string(), z.number().int().nonnegative()),
    guided_capture_variant_segments: z
      .object({
        with_bottom: z.record(z.string(), z.number().int().positive()),
        without_bottom: z.record(z.string(), z.number().int().positive()),
      })
      .strict(),
  })
  .strict();

export type RemoteConfig = z.infer<typeof remoteConfigSchema>;

// Client-facing keys use the same lowercase apiValues as the rest of the client
// API (small/medium/large), mapped from the UPPERCASE model constants.
const SIZE_KEYS: Record<ObjectSize, string> = {
  SMALL: 'small',
  MEDIUM: 'medium',
  LARGE: 'large',
};

function bySizeApiKey(source: Record<ObjectSize, number>): Record<string, number> {
  return (Object.keys(source) as ObjectSize[]).reduce<Record<string, number>>((acc, size) => {
    acc[SIZE_KEYS[size]] = source[size];
    return acc;
  }, {});
}

// Ring names (the S3/manifest vocabulary) → the client config's band ids —
// this schema is the ONLY place the two vocabularies meet, and only in this
// direction (rings never appear on the wire here).
const BAND_ID_BY_RING: Record<CaptureRingName, string> = {
  EYE: 'mid',
  TOP: 'high',
  LOW: 'low',
};

/** One variant's band→count block, derived from the canonical variant module
 * so the served defaults can never drift from the server's own capture rules
 * (mirrors the client's bundled VariantSegments defaults by construction). */
function variantSegmentsBlock(variant: CaptureFlowVariant): Record<string, number> {
  return ringsForVariant(variant).reduce<Record<string, number>>((acc, ring) => {
    acc[BAND_ID_BY_RING[ring]] = expectedPerRing(variant);
    return acc;
  }, {});
}

/**
 * Baked-in safe config — the single source of truth used both as the runtime
 * fallback (store missing/unreachable/malformed) and as the schema fixture.
 * Numbers are derived from the capture protocol's source-of-truth constants so
 * defaults can never silently diverge from the server's own capture rules.
 */
export const DEFAULT_REMOTE_CONFIG: RemoteConfig = {
  version: 1,
  // EYE/TOP/LOW guided-capture rings, expressed as camera-pitch degree bands.
  pitchBands: [
    { min: -20, max: 20, label: 'EYE' },
    { min: 20, max: 60, label: 'TOP' },
    { min: -60, max: -20, label: 'LOW' },
  ],
  thresholds: bySizeApiKey(MIN_PHOTOS_PER_RING_BY_SIZE),
  segmentCounts: bySizeApiKey(SEGMENT_COUNT_BY_SIZE),
  guided_capture_variant_segments: {
    with_bottom: variantSegmentsBlock('with_bottom'),
    without_bottom: variantSegmentsBlock('without_bottom'),
  },
};
