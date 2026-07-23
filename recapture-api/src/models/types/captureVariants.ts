// src/models/types/captureVariants.ts
//
// CANONICAL capture-shape definition — the single source of truth for which
// rings a capture contains and how many images each ring carries. The shape is
// a MATRIX of two orthogonal choices the client makes:
//
//   • captureMode  — how much we capture: 'full' (photogrammetry-grade, 48) or
//                    'meshy' (a short capture tuned for Meshy AI: ONE ring of 6).
//   • flowVariant  — whether the object's BOTTOM is capturable, which decides
//                    whether the LOW ring exists at all. IN 'full' ONLY — Meshy
//                    is a single fixed shape and ignores the variant entirely
//                    (both variant cells are identical), so a Meshy capture never
//                    asks "can you photograph the bottom?".
//
// They stay orthogonal on purpose for `full`: "can you photograph the bottom?"
// is a question about the OBJECT, so folding it into the mode enum would conflate
// two unrelated questions (and break the client's documented invariant that
// without_bottom's band list is a strict prefix of with_bottom's). Meshy keeps
// both variant cells present and equal purely to preserve that type structure.
//
// Every server-side consumer (create-job count cross-check, upload-urls key
// containment, finalize manifest validation, remote-config defaults) derives
// ring sets and counts from the helpers here. Re-declaring a ring list or a
// per-ring count anywhere else is a bug — including hardcoding the 48 total.
//
// ── PER-RING COUNTS ARE NOT UNIFORM ─────────────────────────────────────────
// `full` uses one count on every ring (16/16/16, 24/24). Meshy is a single ring
// of 6, so it is trivially uniform — but the general helpers still assume a
// non-uniform shape is possible (a past `full` revision, a future Meshy retune),
// so a total is a SUM OVER RINGS, never `rings.length × perRing`, and a per-ring
// bound is a lookup, never a scalar. The uniform-only helpers below are kept for
// `full` callers and documented as such.
//
// ── SIGNATURE CONVENTION ────────────────────────────────────────────────────
// `mode` is an OPTIONAL TRAILING parameter defaulting to 'full' on every helper.
// That is deliberate: every call site and test that predates Meshy keeps
// working and keeps asserting the same numbers, so `full` behaviour is provably
// untouched rather than merely intended to be.
//
// Ring names are the S3/manifest vocabulary (EYE/TOP/LOW — see utils/s3Keys);
// the client's band ids (mid/high/low) are a different vocabulary that stays
// in the remote-config layer. Client levels A/B/C map to EYE/TOP/LOW.

/** Ring names as they appear in S3 keys and manifest entries (uppercase).
 * Structurally identical to s3Keys' CaptureLevelSegment — declared here too so
 * this module stays pure (s3Keys binds to env config at import time). */
export type CaptureRingName = 'EYE' | 'TOP' | 'LOW';

/** Wire ids of the two capture flow variants (client + manifest + API). */
export const CAPTURE_FLOW_VARIANTS = ['with_bottom', 'without_bottom'] as const;
export type CaptureFlowVariant = (typeof CAPTURE_FLOW_VARIANTS)[number];

/** Wire ids of the two capture modes (client + manifest + API). */
export const CAPTURE_MODES = ['full', 'meshy'] as const;
export type CaptureMode = (typeof CAPTURE_MODES)[number];

/** The variant assumed when a client does not say (pre-variant clients only
 * ever produced the full three-ring capture). Same default everywhere:
 * create-job body, Job documents predating the field, and a manifest without
 * a `flowVariant` field. */
export const DEFAULT_CAPTURE_FLOW_VARIANT: CaptureFlowVariant = 'with_bottom';

/** The mode assumed when a client does not say. Every capture that existed
 * before Meshy mode was a full capture, so an absent field means 'full' —
 * applied in the same three places the variant default is: the create-job body,
 * Job documents predating the field, and a manifest without a `captureMode`. */
export const DEFAULT_CAPTURE_MODE: CaptureMode = 'full';

/** One mode × variant cell: which rings exist and how many images each holds. */
interface CaptureShape {
  rings: readonly CaptureRingName[];
  /** Per-ring counts. Only the rings in `rings` are present. */
  perRing: Partial<Record<CaptureRingName, number>>;
}

/**
 * The shape matrix. `full` is unchanged from before Meshy existed: both
 * variants total 48 (16×3 vs 24×2), but consumers must use expectedImageCount()
 * rather than assume the totals coincide.
 *
 * `meshy` captures far less — ONE ring of 6 shots. The user walks a single
 * circle taking 6 photos ~60° apart in yaw, with camera tilt anywhere in
 * [90°,180°) (eye-level → top-down) so that one ring covers both the eye view
 * and the top of the object at once. That is enough spread for the 4 photos the
 * model selector picks, and no more, because every extra shot is user time spent
 * for nothing. Meshy has no TOP or LOW ring and is variant-less: both variant
 * cells are the same single-EYE-ring shape so the matrix type still holds and
 * without_bottom stays a (trivial) prefix of with_bottom.
 *
 * The single Meshy ring keeps the canonical first-ring name EYE even though its
 * tilt spans eye→top — a mild misnomer, kept deliberately so nothing new ripples
 * into s3Keys' EYE|TOP|LOW union or any existing key path.
 */
const SHAPE_DEFS: Record<CaptureMode, Record<CaptureFlowVariant, CaptureShape>> = {
  full: {
    with_bottom: { rings: ['EYE', 'TOP', 'LOW'], perRing: { EYE: 16, TOP: 16, LOW: 16 } },
    without_bottom: { rings: ['EYE', 'TOP'], perRing: { EYE: 24, TOP: 24 } },
  },
  meshy: {
    // One ring, 6 shots — see block comment above. Both variants identical.
    with_bottom: { rings: ['EYE'], perRing: { EYE: 6 } },
    without_bottom: { rings: ['EYE'], perRing: { EYE: 6 } },
  },
};

/**
 * Per-ring counts of RETIRED protocol revisions. The client's counts are
 * remote-config-tunable and captures are long-lived: a session captured under
 * an older config (or a Job document created before a deploy) can reach
 * create-job/finalize AFTER the counts changed. Count checks that gate an
 * already-captured bundle therefore accept the UNION of legacy and current
 * ranges via the compat* helpers below — otherwise every pre-change capture
 * would be rejected as COUNT_INCONSISTENT/MANIFEST_INVALID.
 *
 * A revision is a UNIFORM per-ring count (that is all `full` has ever shipped),
 * applied to every ring of that variant — which reproduces the exact accepted
 * union these bounds had before the matrix existed.
 *
 * `meshy` has none: it has never shipped, so there is no older capture to
 * accept. Append here when a per-ring count changes; never remove a revision
 * that shipped.
 */
const LEGACY_PER_RING: Record<CaptureMode, Record<CaptureFlowVariant, readonly number[]>> = {
  full: {
    with_bottom: [12],
    without_bottom: [18],
  },
  meshy: {
    with_bottom: [],
    without_bottom: [],
  },
};

/**
 * Minimum ring coverage (PERCENT) at which a ring counts as complete, per mode.
 *
 * MUST NOT exceed the client's value for the same mode: a higher server floor
 * would make client-complete captures un-uploadable (the COUNT_INCONSISTENT
 * rejection this floor exists to prevent).
 *
 *   full  → 80. Mirrors the mobile client's bundled `minCoveragePct`
 *           (lib/domain/entities/capture_config.dart). A ring finished at 80%
 *           is a legitimate, uploadable capture.
 *   meshy → 100, stated EXPLICITLY rather than left to emerge from ceil().
 *           Meshy is one ring of 6 and every slot matters: the model selector
 *           picks the best 4 of the 6 and needs even yaw spread across the whole
 *           circle, so a missing slot is a real gap. "Capture all 6" is the
 *           honest product rule; pinning the floor at 100 here also means a
 *           future count retune can't silently loosen the tolerance via ceil().
 */
export const MIN_RING_COVERAGE_PCT_BY_MODE: Record<CaptureMode, number> = {
  full: 80,
  meshy: 100,
};

/**
 * @deprecated Use {@link minCoveragePctFor}. Retained as the `full` value so
 * existing imports keep compiling and keep meaning exactly what they meant.
 */
export const MIN_RING_COVERAGE_PCT = MIN_RING_COVERAGE_PCT_BY_MODE.full;

/** The coverage floor for [mode]. */
export function minCoveragePctFor(mode: CaptureMode = DEFAULT_CAPTURE_MODE): number {
  return MIN_RING_COVERAGE_PCT_BY_MODE[mode];
}

/** True when `value` is one of the two variant wire ids. */
export function isCaptureFlowVariant(value: unknown): value is CaptureFlowVariant {
  return (
    typeof value === 'string' &&
    (CAPTURE_FLOW_VARIANTS as readonly string[]).includes(value)
  );
}

/** True when `value` is one of the two capture-mode wire ids. */
export function isCaptureMode(value: unknown): value is CaptureMode {
  return typeof value === 'string' && (CAPTURE_MODES as readonly string[]).includes(value);
}

function shapeOf(variant: CaptureFlowVariant, mode: CaptureMode): CaptureShape {
  return SHAPE_DEFS[mode][variant];
}

/** The rings this shape captures, in canonical EYE→TOP→LOW order. Both modes
 * agree on the ring SET for a given variant — only the counts differ. */
export function ringsForVariant(
  variant: CaptureFlowVariant,
  mode: CaptureMode = DEFAULT_CAPTURE_MODE
): readonly CaptureRingName[] {
  return shapeOf(variant, mode).rings;
}

/**
 * Expected image count on ONE ring.
 *
 * Omitting [ring] answers for the variant's FIRST ring (EYE). That is exact for
 * any uniform mode — which is every `full` capture, and why every pre-Meshy
 * call site stays correct unchanged — and is a partial answer for a non-uniform
 * one. Non-uniform callers must pass the ring; {@link isUniformPerRing} says
 * which is which, and {@link photosByRing} is the shape to reach for when you
 * need all of them at once.
 */
export function expectedPerRing(
  variant: CaptureFlowVariant,
  ring?: CaptureRingName,
  mode: CaptureMode = DEFAULT_CAPTURE_MODE
): number {
  const shape = shapeOf(variant, mode);
  const target = ring ?? shape.rings[0]!;
  return shape.perRing[target] ?? 0;
}

/** True when every ring of this shape carries the same count — i.e. when the
 * ring-less form of the helpers above is a complete answer. */
export function isUniformPerRing(
  variant: CaptureFlowVariant,
  mode: CaptureMode = DEFAULT_CAPTURE_MODE
): boolean {
  const shape = shapeOf(variant, mode);
  const counts = shape.rings.map((r) => shape.perRing[r] ?? 0);
  return counts.every((n) => n === counts[0]);
}

/** Total expected images across all of the shape's rings — a SUM over rings,
 * never `rings.length × perRing` (that identity does not hold in Meshy mode).
 * Excludes the manifest — callers that count uploaded OBJECTS add 1 for it. */
export function expectedImageCount(
  variant: CaptureFlowVariant,
  mode: CaptureMode = DEFAULT_CAPTURE_MODE
): number {
  const shape = shapeOf(variant, mode);
  return shape.rings.reduce((total, ring) => total + (shape.perRing[ring] ?? 0), 0);
}

/** Minimum image count on ONE ring — ceil(expected × coverage floor / 100).
 * Ring-less form follows {@link expectedPerRing}'s rule. */
export function minimumPerRing(
  variant: CaptureFlowVariant,
  ring?: CaptureRingName,
  mode: CaptureMode = DEFAULT_CAPTURE_MODE
): number {
  return Math.ceil((expectedPerRing(variant, ring, mode) * minCoveragePctFor(mode)) / 100);
}

/** Minimum total images across all of the shape's rings — again a sum, and
 * again excluding the manifest (same +1 convention as expectedImageCount). */
export function minimumImageCount(
  variant: CaptureFlowVariant,
  mode: CaptureMode = DEFAULT_CAPTURE_MODE
): number {
  return ringsForVariant(variant, mode).reduce(
    (total, ring) => total + minimumPerRing(variant, ring, mode),
    0
  );
}

// ── Legacy-compatible bounds ─────────────────────────────────────────────────
// Every per-ring count this ring has EVER shipped with (current first).
function perRingCandidates(
  variant: CaptureFlowVariant,
  ring: CaptureRingName | undefined,
  mode: CaptureMode
): number[] {
  return [expectedPerRing(variant, ring, mode), ...LEGACY_PER_RING[mode][variant]];
}

/** Lowest floor for ONE ring across current + retired revisions. Use for checks
 * that gate a bundle which may have been CAPTURED under an older config
 * (create-job range, finalize/worker manifest bounds). */
export function compatMinimumPerRing(
  variant: CaptureFlowVariant,
  ring?: CaptureRingName,
  mode: CaptureMode = DEFAULT_CAPTURE_MODE
): number {
  const pct = minCoveragePctFor(mode);
  return Math.min(
    ...perRingCandidates(variant, ring, mode).map((n) => Math.ceil((n * pct) / 100))
  );
}

/** Highest ceiling for ONE ring across current + retired revisions. */
export function compatMaximumPerRing(
  variant: CaptureFlowVariant,
  ring?: CaptureRingName,
  mode: CaptureMode = DEFAULT_CAPTURE_MODE
): number {
  return Math.max(...perRingCandidates(variant, ring, mode));
}

/** Legacy-compatible minimum total images (excludes the manifest). */
export function compatMinimumImageCount(
  variant: CaptureFlowVariant,
  mode: CaptureMode = DEFAULT_CAPTURE_MODE
): number {
  return ringsForVariant(variant, mode).reduce(
    (total, ring) => total + compatMinimumPerRing(variant, ring, mode),
    0
  );
}

/** Legacy-compatible maximum total images (excludes the manifest). */
export function compatMaximumImageCount(
  variant: CaptureFlowVariant,
  mode: CaptureMode = DEFAULT_CAPTURE_MODE
): number {
  return ringsForVariant(variant, mode).reduce(
    (total, ring) => total + compatMaximumPerRing(variant, ring, mode),
    0
  );
}

/**
 * The legacy-compatible [min, max] bounds for EVERY ring, keyed by ring name —
 * the shape a non-uniform capture needs, because a single scalar pair cannot
 * express "6 on EYE but 2 on TOP" without accepting 2 on EYE as well.
 *
 * Uniform modes produce the same number on every key, so a consumer can always
 * use this and never needs to branch on the mode.
 */
export function photosByRing(
  variant: CaptureFlowVariant,
  mode: CaptureMode = DEFAULT_CAPTURE_MODE
): Record<string, { min: number; max: number }> {
  return ringsForVariant(variant, mode).reduce<Record<string, { min: number; max: number }>>(
    (acc, ring) => {
      acc[ring] = {
        min: compatMinimumPerRing(variant, ring, mode),
        max: compatMaximumPerRing(variant, ring, mode),
      };
      return acc;
    },
    {}
  );
}
