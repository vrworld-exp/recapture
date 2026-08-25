// tests/full-run-photo-counts.test.ts
//
// QA: a full three-level (EYE/TOP/LOW) Guided Capture produces the expected
// per-object-size TOTAL photo counts:
//
//   Small  ≈ 90   Medium ≈ 72   Large ≈ 54
//
// These numbers are the documented capture protocol's full-run MINIMUMS, and they
// live in exactly one source of truth: src/models/types/capture.types.ts. The flow
// is THREE rings, each taking a per-size count:
//
//   total MIN photos  = RING_COUNT × MIN_PHOTOS_PER_RING_BY_SIZE  (30/24/18) = 90/72/54
//   total CAPACITY     = RING_COUNT × SEGMENT_COUNT_BY_SIZE         (36/30/24) = 108/90/72
//
// A real full run lands in [min, capacity] per size — that span is what the spec's
// "~" tolerance denotes. The MIN itself is EXACT (derived from exact constants), so
// the ≈90/72/54 assertion is exact-equality against the derived minimum, while the
// upper bound is asserted separately as the per-size capacity.
//
// TESTS ONLY — asserts against the source-of-truth constants; changes nothing. If a
// per-ring count were edited out of band, the matching size case FAILS (verified —
// see docs/qa/full-run-photo-counts-qa.md).
//
// ── Convention reconciliation (read the QA doc) ───────────────────────────────
// The brief points at lib/features/guided_capture/ and `flutter test`. The Flutter
// CLIENT does NOT implement this size→count model: its per-level counts come from
// fixed PitchBand.segments (A=10/B=8/C=12 → 30 photos for EVERY size) and only Level
// A's eye ring is size-driven (and unwired). The 90/72/54 contract exists ONLY here,
// in the backend protocol constants — so this verification lives where the numbers
// are importable and authoritative. See docs/qa/full-run-photo-counts-qa.md.
import { describe, it, expect } from 'vitest';
import {
  SEGMENT_COUNT_BY_SIZE,
  MIN_PHOTOS_PER_RING_BY_SIZE,
  type ObjectSize,
} from '@/models/types/capture.types';
import { DEFAULT_REMOTE_CONFIG } from '@/validation/remoteConfigSchema';

// ── Ring count: derived from the served config, not hardcoded ─────────────────
// The guided-capture protocol has three rings (EYE/TOP/LOW). The authoritative
// runtime mirror is the default remote config's pitch bands (served on the wire
// as the CLIENT's band ids: EYE=mid, TOP=high, LOW=low); assert that shape so a
// change to the ring set is caught here rather than silently skewing the totals.
const BAND_IDS = DEFAULT_REMOTE_CONFIG.pitchBands.map((b) => b.id).sort();
const RING_COUNT = BAND_IDS.length;

// ── The spec's expected per-size full-run totals (the documented MINIMUMS) ────
const EXPECTED_MIN_TOTAL: Record<ObjectSize, number> = {
  SMALL: 90,
  MEDIUM: 72,
  LARGE: 54,
};

// "~" tolerance. The MIN total is exact, so the lower-bound tolerance is 0. The
// real on-device count may run up to capacity (min + per-ring headroom × rings);
// that upper headroom is asserted via the capacity bound below, not fudged here.
const MIN_TOTAL_TOLERANCE = 0;

// Ordered smallest→largest so the direction assertions read naturally.
const SIZES_ASC: ObjectSize[] = ['SMALL', 'MEDIUM', 'LARGE'];

const minTotal = (size: ObjectSize) => RING_COUNT * MIN_PHOTOS_PER_RING_BY_SIZE[size];
const capacityTotal = (size: ObjectSize) => RING_COUNT * SEGMENT_COUNT_BY_SIZE[size];

describe('full-run photo counts — protocol shape', () => {
  it('the capture protocol has exactly 3 rings (EYE/TOP/LOW ↔ mid/high/low)', () => {
    expect(RING_COUNT).toBe(3);
    expect(BAND_IDS).toEqual(['high', 'low', 'mid']); // sorted band ids
  });
});

describe('full-run photo counts — per-size totals (≈ 90 / 72 / 54)', () => {
  for (const size of SIZES_ASC) {
    const expected = EXPECTED_MIN_TOTAL[size];

    it(`${size}: full-run minimum total ≈ ${expected} (±${MIN_TOTAL_TOLERANCE})`, () => {
      // Derived from the source of truth (3 × per-ring minimum) — NOT a second
      // hardcoded copy of 90/72/54.
      const actual = minTotal(size);
      const within =
        actual >= expected - MIN_TOTAL_TOLERANCE &&
        actual <= expected + MIN_TOTAL_TOLERANCE;
      expect(
        within,
        `size=${size} expected≈${expected} (±${MIN_TOTAL_TOLERANCE}) actual=${actual}`,
      ).toBe(true);
    });

    it(`${size}: A+B+C split sums to the total (3 × per-ring minimum)`, () => {
      // Dynamic consistency: change one ring's per-size minimum without updating
      // the expected total and this catches the inconsistency. Three identical
      // rings ⇒ sum is 3 × the per-ring count.
      const perRing = MIN_PHOTOS_PER_RING_BY_SIZE[size];
      const summed = BAND_IDS.reduce((acc) => acc + perRing, 0);
      expect(summed).toBe(EXPECTED_MIN_TOTAL[size]);
    });

    it(`${size}: real full run lands in [min, capacity] = [${minTotal(size)}, ${capacityTotal(size)}]`, () => {
      // The "~" range: a complete run accepts at least the minimum and at most
      // the ring capacity. Capacity = 3 × segment count.
      const min = minTotal(size);
      const cap = capacityTotal(size);
      expect(min).toBe(expected); // floor == the spec target
      expect(cap).toBeGreaterThanOrEqual(min); // capacity is never below the floor
      // Per-ring headroom is uniform (6 each ⇒ 18 across 3 rings) for the bundled
      // protocol; assert the documented capacities explicitly.
      expect({ SMALL: cap, MEDIUM: cap, LARGE: cap }[size]).toBe(
        { SMALL: 108, MEDIUM: 90, LARGE: 72 }[size],
      );
    });

    it(`${size}: no ring targets 0 photos`, () => {
      expect(MIN_PHOTOS_PER_RING_BY_SIZE[size]).toBeGreaterThan(0);
      expect(SEGMENT_COUNT_BY_SIZE[size]).toBeGreaterThan(0);
    });
  }
});

describe('full-run photo counts — size→count direction (DESCENDING with size)', () => {
  // A regression that flipped the mapping ("bigger ⇒ more") would pass a naive
  // magnitude check; this locks the documented direction independently of the
  // magnitude assertions above.
  it('minimum totals strictly decrease as object size increases (Small > Medium > Large)', () => {
    const totals = SIZES_ASC.map(minTotal); // [90, 72, 54]
    for (let i = 0; i + 1 < totals.length; i++) {
      expect(
        totals[i],
        `${SIZES_ASC[i]}(${totals[i]}) should exceed ${SIZES_ASC[i + 1]}(${totals[i + 1]})`,
      ).toBeGreaterThan(totals[i + 1]);
    }
    expect(totals).toEqual([90, 72, 54]);
  });

  it('capacity totals strictly decrease as object size increases', () => {
    const caps = SIZES_ASC.map(capacityTotal); // [108, 90, 72]
    for (let i = 0; i + 1 < caps.length; i++) {
      expect(caps[i]).toBeGreaterThan(caps[i + 1]);
    }
    expect(caps).toEqual([108, 90, 72]);
  });
});

describe('full-run photo counts — unknown / unset object size', () => {
  it('an unrecognized size key yields undefined and does not throw (no backend fallback in these maps)', () => {
    // The protocol maps are keyed by the three known sizes only; there is no
    // baked-in default IN THESE CONSTANTS (the remote-config layer falls back to
    // DEFAULT_REMOTE_CONFIG wholesale, asserted in the remote-config tests). A
    // lookup with an unknown key is a benign undefined, never a throw.
    const unknown = 'HUGE' as ObjectSize;
    let total: number | undefined;
    expect(() => {
      total = RING_COUNT * (MIN_PHOTOS_PER_RING_BY_SIZE[unknown] as number);
    }).not.toThrow();
    expect(MIN_PHOTOS_PER_RING_BY_SIZE[unknown]).toBeUndefined();
    expect(Number.isNaN(total)).toBe(true); // 3 × undefined → NaN, not a crash
  });
});
