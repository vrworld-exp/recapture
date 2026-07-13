// src/models/types/captureVariants.ts
//
// CANONICAL capture-flow-variant definition — the single source of truth for
// which rings a capture contains and how many images each ring carries. The
// client chooses the variant on the Pre-Capture Checklist ("Can you capture
// the bottom of the object?") and sends its wire id on POST /jobs; every
// server-side consumer (create-job count cross-check, upload-urls key
// containment, finalize manifest validation, remote-config defaults) derives
// ring sets and counts from the helpers here. Re-declaring a ring list or a
// per-ring count anywhere else is a bug — including hardcoding the 48 total.
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

/** The variant assumed when a client does not say (pre-variant clients only
 * ever produced the full three-ring capture). Same default everywhere:
 * create-job body, Job documents predating the field, and a manifest without
 * a `flowVariant` field. */
export const DEFAULT_CAPTURE_FLOW_VARIANT: CaptureFlowVariant = 'with_bottom';

/**
 * Per-variant shape. `without_bottom` drops the LOW ring and redistributes
 * the coverage over the remaining two rings — both variants total 48 images
 * today (16×3 vs 24×2), but consumers must use expectedImageCount(), never
 * assume the totals coincide.
 */
const VARIANT_DEFS: Record<
  CaptureFlowVariant,
  { rings: readonly CaptureRingName[]; perRing: number }
> = {
  with_bottom: { rings: ['EYE', 'TOP', 'LOW'], perRing: 16 },
  without_bottom: { rings: ['EYE', 'TOP'], perRing: 24 },
};

/**
 * Per-ring counts of RETIRED protocol revisions, per variant. The client's
 * counts are remote-config-tunable and captures are long-lived: a session
 * captured under an older config (or a Job document created before a deploy)
 * can reach create-job/finalize AFTER the counts changed. Count checks that
 * gate an already-captured bundle therefore accept the UNION of legacy and
 * current ranges via the compat* helpers below — otherwise every pre-change
 * capture would be rejected as COUNT_INCONSISTENT/MANIFEST_INVALID.
 * Append here when perRing changes; never remove a revision that shipped.
 */
const LEGACY_PER_RING: Record<CaptureFlowVariant, readonly number[]> = {
  with_bottom: [12],
  without_bottom: [18],
};

/** True when `value` is one of the two variant wire ids. */
export function isCaptureFlowVariant(value: unknown): value is CaptureFlowVariant {
  return (
    typeof value === 'string' &&
    (CAPTURE_FLOW_VARIANTS as readonly string[]).includes(value)
  );
}

/** The rings this variant captures, in canonical EYE→TOP→LOW order. */
export function ringsForVariant(variant: CaptureFlowVariant): readonly CaptureRingName[] {
  return VARIANT_DEFS[variant].rings;
}

/** Expected image count on EACH of the variant's rings. */
export function expectedPerRing(variant: CaptureFlowVariant): number {
  return VARIANT_DEFS[variant].perRing;
}

/** Total expected images across all of the variant's rings (excludes the
 * manifest — callers that count uploaded OBJECTS add 1 for it). */
export function expectedImageCount(variant: CaptureFlowVariant): number {
  return ringsForVariant(variant).length * expectedPerRing(variant);
}

/**
 * Minimum ring coverage (PERCENT) at which the client lets a ring count as
 * complete — mirrors the mobile client's bundled `minCoveragePct` default
 * (lib/domain/entities/capture_config.dart). A ring finished at 80% coverage
 * is a legitimate, uploadable capture, so every server-side count check
 * accepts [minimumPerRing, expectedPerRing] per ring rather than demanding
 * the exact total. MUST NOT exceed the client's value: a higher server floor
 * would make client-complete captures un-uploadable (the COUNT_INCONSISTENT
 * rejection this floor exists to prevent).
 */
export const MIN_RING_COVERAGE_PCT = 80;

/** Minimum image count on EACH of the variant's rings —
 * ceil(expectedPerRing × MIN_RING_COVERAGE_PCT / 100)
 * (→ 20 for without_bottom's 24, 13 for with_bottom's 16). */
export function minimumPerRing(variant: CaptureFlowVariant): number {
  return Math.ceil((expectedPerRing(variant) * MIN_RING_COVERAGE_PCT) / 100);
}

/** Minimum total images across all of the variant's rings (excludes the
 * manifest — same +1 convention as expectedImageCount). */
export function minimumImageCount(variant: CaptureFlowVariant): number {
  return ringsForVariant(variant).length * minimumPerRing(variant);
}

// ── Legacy-compatible bounds ─────────────────────────────────────────────────
// Every per-ring count this variant has EVER shipped with (current first).
function perRingCandidates(variant: CaptureFlowVariant): number[] {
  return [expectedPerRing(variant), ...LEGACY_PER_RING[variant]];
}

/** Lowest per-ring floor across current + retired revisions —
 * min over revisions of ceil(perRing × MIN_RING_COVERAGE_PCT / 100). Use for
 * checks that gate a bundle which may have been CAPTURED under an older
 * config (create-job range, finalize/worker manifest bounds). */
export function compatMinimumPerRing(variant: CaptureFlowVariant): number {
  return Math.min(
    ...perRingCandidates(variant).map((n) => Math.ceil((n * MIN_RING_COVERAGE_PCT) / 100))
  );
}

/** Highest per-ring ceiling across current + retired revisions. */
export function compatMaximumPerRing(variant: CaptureFlowVariant): number {
  return Math.max(...perRingCandidates(variant));
}

/** Legacy-compatible minimum total images (excludes the manifest). */
export function compatMinimumImageCount(variant: CaptureFlowVariant): number {
  return ringsForVariant(variant).length * compatMinimumPerRing(variant);
}

/** Legacy-compatible maximum total images (excludes the manifest). */
export function compatMaximumImageCount(variant: CaptureFlowVariant): number {
  return ringsForVariant(variant).length * compatMaximumPerRing(variant);
}
