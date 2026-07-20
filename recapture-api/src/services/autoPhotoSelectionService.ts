// src/services/autoPhotoSelectionService.ts
//
// PURE automatic photo selection — picks the 4 photos handed to Meshy when a
// capture finishes, with no human in the loop
// (docs/auto-model-generation-implementation-prompt.md).
//
// Pure and synchronous BY DESIGN: no DB, no S3, no async. This is the piece
// whose quality decides whether auto-generation produces good models, so it
// must be iterable against real manifests with no infrastructure in the loop.
// Everything it needs is already in the capture manifest the worker parsed.
//
// ── THE CENTRAL RULE: SPREAD FIRST, SHARPNESS SECOND ────────────────────────
// The four SHARPEST photos of a capture are very often four near-identical
// frames from one corner of the ring — sharpness correlates with the user
// standing still. Meshy would receive one viewpoint four times and hallucinate
// the other three sides. So angular spread is the CONSTRAINT (one photo per yaw
// quadrant) and sharpness is only the tiebreak WITHIN a quadrant. Inverting
// these two is the single most likely way to silently produce bad models.
//
// DECLINING IS A FEATURE: a bad capture costs exactly as much to generate as a
// good one. When the photos cannot support a model, this returns DECLINED and
// the caller spends nothing.
import { z } from 'zod';

/** Meshy Multi-Image accepts 1–4; we mirror the staff path's 3–4 window. */
export const AUTO_MIN_PHOTOS = 3;
export const AUTO_TARGET_PHOTOS = 4;

/**
 * Default sharpness floor (variance of Laplacian). Matches the client's
 * REJECT threshold from the blur-threshold policy (<40 REJECT, 40–80 WARN), so
 * a photo the capture UI would have rejected is never chosen here either.
 */
export const DEFAULT_MIN_BLUR_SCORE = 40;

/** Yaw is split into this many buckets — one chosen photo per bucket. */
const QUADRANT_COUNT = 4;
const DEGREES_PER_QUADRANT = 360 / QUADRANT_COUNT;

/** The ring shot straight-on at eye level — the views Meshy reasons best about. */
const PREFERRED_RING = 'EYE';

export type AutoSelectionDeclineReason =
  /** The document lacked the structure the rules need — never a throw. */
  | 'MANIFEST_UNREADABLE'
  /** Nothing survived the quality floor / key resolution. */
  | 'NO_USABLE_PHOTOS'
  /** Usable photos exist, but they all look at the object from one side. */
  | 'INSUFFICIENT_SPREAD';

export type AutoSelectionResult =
  | {
      outcome: 'SELECTED';
      /** Relative keys under the job's rawPrefix, e.g. `images/EYE/eye_0001.jpg`. */
      keys: string[];
      /** Human-readable trace for the worker log (never contains a URL). */
      reason: string;
    }
  | { outcome: 'DECLINED'; reason: AutoSelectionDeclineReason };

export interface AutoSelectionOptions {
  /** Sharpness floor; defaults to DEFAULT_MIN_BLUR_SCORE. */
  minBlurScore?: number;
  /** How many photos to aim for (clamped to [AUTO_MIN_PHOTOS, 4]). */
  targetCount?: number;
  /**
   * The relative keys that ACTUALLY exist under the job prefix (from
   * listObjectsUnderPrefix). When supplied, a derived key with no matching
   * object is dropped — handing Meshy a presigned URL for an object that
   * isn't there burns a paid generation on a 404.
   */
  availableKeys?: readonly string[];
}

// ── Manifest shape ───────────────────────────────────────────────────────────
// Only the fields the selection needs, all `.passthrough()` — the manifest is
// deliberately richer than this, and structure validation is
// manifestValidationService's job, not ours. Every field here is optional
// because a photo missing one is a photo we can still rank (just worse).

const photoSchema = z
  .object({
    imagePath: z.string().optional(),
    ringName: z.string().optional(),
    levelCode: z.string().optional(),
    segmentIndex: z.number().nullable().optional(),
    verdict: z.string().optional(),
    quality: z
      .object({
        blurScore: z.number().nullable().optional(),
      })
      .passthrough()
      .optional(),
    orientation: z
      .object({
        yawDegrees: z.number().nullable().optional(),
      })
      .passthrough()
      .optional(),
  })
  .passthrough();

const manifestSchema = z
  .object({
    photos: z.array(photoSchema),
    // The AUTHORITATIVE per-level ring size, keyed by level code (A/B/C) —
    // emitted by buildCaptureManifest from the capture config. See
    // segmentCountFor for why this must never be inferred from the photos.
    config: z
      .object({
        segmentCounts: z.record(z.string(), z.number()).optional(),
      })
      .passthrough()
      .optional(),
  })
  .passthrough();

/** One ranked candidate, flattened out of the manifest's nested shape. */
interface Candidate {
  relativeKey: string;
  blurScore: number;
  /** Bucket index [0, QUADRANT_COUNT), or null when orientation is unknown. */
  quadrant: number | null;
  warned: boolean;
}

/**
 * Mirrors the mobile builder's ringNameForLevelCode (A→EYE, B→TOP, C→LOW), so
 * a manifest that carries only levelCode still resolves to a ring.
 */
function ringNameOf(photo: { ringName?: string; levelCode?: string }): string {
  if (photo.ringName) return photo.ringName.toUpperCase();
  switch (photo.levelCode?.toUpperCase()) {
    case 'A':
      return 'EYE';
    case 'B':
      return 'TOP';
    case 'C':
      return 'LOW';
    default:
      return photo.levelCode?.toUpperCase() ?? 'UNKNOWN';
  }
}

/**
 * Resolves a manifest `imagePath` to a key RELATIVE to the job's rawPrefix.
 *
 * Two producers write manifests and they do NOT agree, which is why this is a
 * function and not a slice:
 *   • capture_bundle_packer.dart (the manifest that actually SHIPS in the
 *     bundle) writes the bundle-relative path already — `images/EYE/eye_0001.jpg`,
 *     exactly the shape we need;
 *   • capture_manifest_assembler.dart writes a DEVICE storage path —
 *     `recapture/{projectId}/{jobId}/images/EYE/<device-name>.jpg`.
 * Both are normalized by anchoring on the `images/` segment. Anything with no
 * such segment is unresolvable and dropped rather than guessed at.
 */
export function toRelativeImageKey(imagePath: string): string | null {
  if (typeof imagePath !== 'string' || imagePath.length === 0) return null;
  const normalized = imagePath.replace(/\\/g, '/').replace(/^\/+/, '');
  if (normalized.startsWith('images/')) return normalized;
  const anchor = normalized.indexOf('/images/');
  if (anchor >= 0) return normalized.slice(anchor + 1);
  return null;
}

/**
 * The ring's segment count, read from the manifest's capture config.
 *
 * This MUST NOT be inferred from the photos present. A segment index only means
 * something relative to the ring size it was assigned in: six photos at segments
 * 0–1 of a 16-segment ring are a narrow arc around one side of the object, but
 * inferring "the ring has 2 segments" from that same data maps them to OPPOSITE
 * sides of the circle — which is precisely the single-viewpoint capture the
 * INSUFFICIENT_SPREAD guard exists to refuse to pay for.
 *
 * Returns null when the config is absent (pre-config manifests), so callers
 * fall back to absolute yaw rather than to a fabricated ring size.
 */
function segmentCountFor(
  data: { config?: { segmentCounts?: Record<string, number> } },
  pool: readonly { levelCode?: string }[]
): number | null {
  const counts = data.config?.segmentCounts;
  if (!counts) return null;
  // The pool is one ring in the normal case; take the level code the photos
  // actually carry rather than assuming 'A'.
  const levelCode = pool.find((p) => p.levelCode)?.levelCode?.toUpperCase();
  const count = levelCode ? counts[levelCode] : undefined;
  return typeof count === 'number' && count > 0 ? count : null;
}

/** Yaw (any real number, possibly negative or >360) → bucket index. */
function quadrantOfYaw(yawDegrees: number): number {
  const wrapped = ((yawDegrees % 360) + 360) % 360;
  return Math.floor(wrapped / DEGREES_PER_QUADRANT) % QUADRANT_COUNT;
}

/**
 * Picks the bucket for a photo, preferring `segmentIndex` over raw yaw.
 *
 * segmentIndex is the ring's OWN quantization — the capture engine already
 * decided which segment this photo filled, using hysteresis and the level's
 * segment count. Raw yaw drifts over a session (IMU integration error), so
 * where the two disagree the segment index is the more trustworthy answer.
 */
function quadrantOf(
  photo: { segmentIndex?: number | null; orientation?: { yawDegrees?: number | null } },
  segmentCount: number | null
): number | null {
  const segmentIndex = photo.segmentIndex;
  if (typeof segmentIndex === 'number' && Number.isFinite(segmentIndex) && segmentCount) {
    // Map the segment onto the quadrant circle by proportion, so this works for
    // any per-ring count (12/16/18/24 have all shipped) without a table.
    const proportion = (((segmentIndex % segmentCount) + segmentCount) % segmentCount) / segmentCount;
    return Math.floor(proportion * QUADRANT_COUNT) % QUADRANT_COUNT;
  }
  const yaw = photo.orientation?.yawDegrees;
  if (typeof yaw === 'number' && Number.isFinite(yaw)) return quadrantOfYaw(yaw);
  return null;
}

/**
 * Selects the photos to hand Meshy, or declines.
 *
 * @param manifest Parsed capture_manifest.json (arrives as `unknown` — it came
 *                 from S3, not a validated request body).
 */
export function selectPhotosForAutoGeneration(
  manifest: unknown,
  opts: AutoSelectionOptions = {}
): AutoSelectionResult {
  const parsed = manifestSchema.safeParse(manifest);
  if (!parsed.success) return { outcome: 'DECLINED', reason: 'MANIFEST_UNREADABLE' };

  const minBlurScore = opts.minBlurScore ?? DEFAULT_MIN_BLUR_SCORE;
  const targetCount = Math.min(
    Math.max(opts.targetCount ?? AUTO_TARGET_PHOTOS, AUTO_MIN_PHOTOS),
    AUTO_TARGET_PHOTOS
  );
  const available = opts.availableKeys ? new Set(opts.availableKeys) : null;

  // ── Pool: prefer the EYE ring. TOP/LOW are foreshortened views of the object
  // and make weaker generative input; they are only used when EYE alone cannot
  // fill a selection (a without_bottom variant, or a partial capture).
  const allPhotos = parsed.data.photos;
  const eyePhotos = allPhotos.filter((p) => ringNameOf(p) === PREFERRED_RING);
  const pool = eyePhotos.length >= AUTO_MIN_PHOTOS ? eyePhotos : allPhotos;

  const segmentCount = segmentCountFor(parsed.data, pool);

  const candidates: Candidate[] = [];
  for (const photo of pool) {
    const relativeKey = photo.imagePath ? toRelativeImageKey(photo.imagePath) : null;
    // Unresolvable path, or an object that isn't actually in the bucket.
    if (!relativeKey) continue;
    if (available && !available.has(relativeKey)) continue;

    const blurScore = photo.quality?.blurScore;
    if (typeof blurScore !== 'number' || !Number.isFinite(blurScore)) continue;

    candidates.push({
      relativeKey,
      blurScore,
      quadrant: quadrantOf(photo, segmentCount),
      warned: photo.verdict === 'warn',
    });
  }
  if (candidates.length === 0) return { outcome: 'DECLINED', reason: 'NO_USABLE_PHOTOS' };

  // ── Quality floor. Applied only while it leaves enough photos to work with:
  // a capture where everything is slightly soft should still yield the best of
  // what it has, rather than declining on a technicality.
  const sharp = candidates.filter((c) => c.blurScore >= minBlurScore);
  const qualified = sharp.length >= AUTO_MIN_PHOTOS ? sharp : candidates;

  // Prefer clean frames over exposure-warned ones, on the same "only if enough
  // remain" basis.
  const clean = qualified.filter((c) => !c.warned);
  const usable = clean.length >= AUTO_MIN_PHOTOS ? clean : qualified;

  if (usable.length < AUTO_MIN_PHOTOS) return { outcome: 'DECLINED', reason: 'NO_USABLE_PHOTOS' };

  // ── Bucket by quadrant, sharpest first within each.
  const byQuadrant = new Map<number, Candidate[]>();
  const unplaced: Candidate[] = [];
  for (const candidate of usable) {
    if (candidate.quadrant === null) {
      unplaced.push(candidate);
      continue;
    }
    const bucket = byQuadrant.get(candidate.quadrant);
    if (bucket) bucket.push(candidate);
    else byQuadrant.set(candidate.quadrant, [candidate]);
  }
  for (const bucket of byQuadrant.values()) {
    bucket.sort((a, b) => b.blurScore - a.blurScore);
  }
  unplaced.sort((a, b) => b.blurScore - a.blurScore);

  // A capture that only ever looked at one side of the object cannot produce a
  // model worth paying for, however sharp those photos are.
  if (byQuadrant.size < 2 && unplaced.length === 0) {
    return { outcome: 'DECLINED', reason: 'INSUFFICIENT_SPREAD' };
  }

  // ── Pass 1: the sharpest photo from each filled quadrant, in quadrant order
  // (deterministic, and walks around the object rather than jumping about).
  const selected: Candidate[] = [];
  const filledQuadrants = [...byQuadrant.keys()].sort((a, b) => a - b);
  for (const quadrant of filledQuadrants) {
    if (selected.length >= targetCount) break;
    const bucket = byQuadrant.get(quadrant);
    if (bucket && bucket.length > 0) selected.push(bucket.shift()!);
  }

  // ── Pass 2: backfill from the quadrant that is ANGULARLY FARTHEST from what
  // is already chosen. Partial coverage is explicitly allowed by the upload
  // gate (80% floor), so empty quadrants are normal — and when backfilling, a
  // second view from the opposite side adds far more than a second view from
  // a side already covered.
  while (selected.length < targetCount) {
    const next = takeMostDistant(byQuadrant, selected);
    if (!next) break;
    selected.push(next);
  }
  // Last resort: photos we could not place on the circle at all.
  while (selected.length < targetCount && unplaced.length > 0) {
    selected.push(unplaced.shift()!);
  }

  if (selected.length < AUTO_MIN_PHOTOS) {
    return { outcome: 'DECLINED', reason: 'INSUFFICIENT_SPREAD' };
  }

  return {
    outcome: 'SELECTED',
    keys: selected.map((c) => c.relativeKey),
    reason:
      `${selected.length} photos from ${new Set(selected.map((c) => c.quadrant)).size} ` +
      `of ${QUADRANT_COUNT} yaw quadrants (pool=${pool.length}, usable=${usable.length})`,
  };
}

/**
 * Pops the sharpest remaining photo from the quadrant that adds the most to the
 * current selection. Returns null once every bucket is empty.
 *
 * Ranked by, in order:
 *   1. FEWEST photos already taken from that quadrant — keeps backfill balanced.
 *      Without this, a half-covered capture (two filled quadrants) ties on
 *      distance forever and drains one side 3–1 instead of taking 2–2.
 *   2. GREATEST angular distance from the quadrants already represented — the
 *      least redundant viewpoint.
 *   3. Quadrant index, so the result is deterministic.
 */
function takeMostDistant(
  byQuadrant: Map<number, Candidate[]>,
  selected: readonly Candidate[]
): Candidate | null {
  const taken = selected.map((c) => c.quadrant).filter((q): q is number => q !== null);
  const takenSet = new Set(taken);
  const countIn = (quadrant: number): number => taken.filter((q) => q === quadrant).length;

  /** Distance to the NEAREST already-selected quadrant, around the circle. */
  const distanceFromSelected = (quadrant: number): number => {
    let nearest = QUADRANT_COUNT;
    for (const t of takenSet) {
      const raw = Math.abs(quadrant - t);
      nearest = Math.min(nearest, Math.min(raw, QUADRANT_COUNT - raw));
    }
    return nearest;
  };

  let best: { quadrant: number; count: number; distance: number } | null = null;
  for (const [quadrant, bucket] of byQuadrant) {
    if (bucket.length === 0) continue;
    const candidate = {
      quadrant,
      count: countIn(quadrant),
      distance: distanceFromSelected(quadrant),
    };
    if (
      best === null ||
      candidate.count < best.count ||
      (candidate.count === best.count && candidate.distance > best.distance)
    ) {
      best = candidate;
    }
  }
  if (best === null) return null;
  return byQuadrant.get(best.quadrant)!.shift() ?? null;
}
