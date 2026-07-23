// src/validation/remoteConfigSchema.ts
import { z } from 'zod';
import {
  SEGMENT_COUNT_BY_SIZE,
  MIN_PHOTOS_PER_RING_BY_SIZE,
  type ObjectSize,
} from '@/models/types/capture.types';
import {
  DEFAULT_CAPTURE_MODE,
  expectedPerRing,
  ringsForVariant,
  type CaptureFlowVariant,
  type CaptureRingName,
  type CaptureMode,
} from '@/models/types/captureVariants';

/**
 * Wire schema for GET /remote-config — runtime tuning the mobile client/viewer
 * fetches so behaviour can change without an app release. Kept deliberately
 * small (low-end Android consumes this) and free of any internal/store fields.
 *
 * - `pitchBands` — camera-TILT ranges for the guided capture rings on the
 *   0–180° scale (0 = camera at the sky, 90 = horizon, 180 = at the ground),
 *   keyed by the client's band ids (`low`/`mid`/`high` ↔ the LOW/EYE/TOP rings
 *   in capture.types). The wire shape (`id`/`minDegrees`/`maxDegrees`/
 *   `segments`, min inclusive, max exclusive) is EXACTLY what the client's
 *   `CaptureConfig.fromMap` parses — one shape on both sides, no mapping layer.
 * - `thresholds` — minimum accepted photos per ring, keyed by object size.
 * - `segmentCounts` — ring segment count, keyed by object size.
 * - `guided_capture_variant_segments` — per capture-flow-variant segment
 *   counts, keyed variant-id → band-id (`mid`/`high`/`low` — the CLIENT's
 *   vocabulary for the EYE/TOP/LOW rings; the ring names stay in the
 *   S3/manifest layer and never leak here).
 * - `meshy_capture_variant_segments` — the same shape for MESHY capture mode,
 *   in its own key so an older client parsing the block above is unaffected.
 *   Optional: absent means the client uses its bundled Meshy defaults.
 *
 * NOTE: `thresholds` and `segmentCounts` are OBJECT-SIZE knobs and apply to
 * FULL captures only. Meshy mode captures ONE ring of 6 regardless of object
 * size — far below those floors — so it is exempt from both by design.
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
            id: z.string().min(1),
            minDegrees: z.number().min(0).max(180),
            maxDegrees: z.number().min(0).max(180),
            segments: z.number().int().positive(),
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
    // Meshy mode's counts ride in their OWN key rather than nesting the block
    // above by mode. Re-keying it would hand every already-shipped client a map
    // where it expects ints: VariantSegments.fromMap drops ill-typed entries,
    // so those clients would silently fall back to bundled defaults and lose
    // remote tunability for FULL captures — with no error anywhere. Optional so
    // a stored config written before Meshy still validates.
    meshy_capture_variant_segments: z
      .object({
        with_bottom: z.record(z.string(), z.number().int().positive()),
        without_bottom: z.record(z.string(), z.number().int().positive()),
      })
      .strict()
      .optional(),
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
function variantSegmentsBlock(
  variant: CaptureFlowVariant,
  mode: CaptureMode = DEFAULT_CAPTURE_MODE
): Record<string, number> {
  return ringsForVariant(variant, mode).reduce<Record<string, number>>((acc, ring) => {
    // Per RING, not one number for the variant: full's rings can differ across
    // revisions and this stays correct if a future mode is non-uniform. (Meshy
    // is a single EYE ring of 6, so its block is just { mid: 6 }.)
    acc[BAND_ID_BY_RING[ring]] = expectedPerRing(variant, ring, mode);
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
  // Version 5: adds meshy_capture_variant_segments (Meshy capture mode). The
  // bump is what rolls client ETag/304 caches over to the new payload — a
  // client still serving a cached v4 simply never sees the Meshy block and
  // falls back to its bundled defaults, which is the correct degradation.
  // Version 4 retuned the tilt bands to 0–40 / 40–110 / 110–180; version 3 was
  // the 16×3 / 24×2 per-ring counts; version 2 was the 0–180° band scale.
  version: 5,
  // LOW/EYE/TOP guided-capture rings as camera-tilt bands tiling [0, 180]:
  // BOTTOM ring `low` (tilt up) [0,40) / EYE ring `mid` (hold straight)
  // [40,110) / TOP ring `high` (tilt down) [110,180). Deliberately UNEQUAL
  // (40/70/70) — the eye band is not centred on the horizon. Mirrors the
  // client's bundled defaults; legacy per-band `segments` retained (real counts
  // come from guided_capture_variant_segments).
  pitchBands: [
    { id: 'low', minDegrees: 0, maxDegrees: 40, segments: 12 },
    { id: 'mid', minDegrees: 40, maxDegrees: 110, segments: 10 },
    { id: 'high', minDegrees: 110, maxDegrees: 180, segments: 8 },
  ],
  thresholds: bySizeApiKey(MIN_PHOTOS_PER_RING_BY_SIZE),
  segmentCounts: bySizeApiKey(SEGMENT_COUNT_BY_SIZE),
  guided_capture_variant_segments: {
    with_bottom: variantSegmentsBlock('with_bottom'),
    without_bottom: variantSegmentsBlock('without_bottom'),
  },
  // ONE ring of 6 (EYE only) — see the shape matrix. Both variant blocks are
  // identical ({ mid: 6 }) because Meshy is variant-less. `thresholds` and
  // `segmentCounts` above are NOT consulted in Meshy mode: they are the
  // object-size knobs (30/24/18 photos, 36/30/24 segments), all far above
  // Meshy's counts, and object size does not modulate this mode at all.
  meshy_capture_variant_segments: {
    with_bottom: variantSegmentsBlock('with_bottom', 'meshy'),
    without_bottom: variantSegmentsBlock('without_bottom', 'meshy'),
  },
};
