// tests/capture-modes.test.ts
//
// Pure unit tests for the MODE dimension of the capture shape matrix. The
// existing capture-variants suite covers `full` and is deliberately left
// untouched — this file exists so that "did Meshy change anything about full?"
// is answered by that file passing unmodified, not by assertions here.
import { describe, it, expect } from 'vitest';
import {
  CAPTURE_MODES,
  DEFAULT_CAPTURE_MODE,
  MIN_RING_COVERAGE_PCT_BY_MODE,
  compatMaximumImageCount,
  compatMinimumImageCount,
  expectedImageCount,
  expectedPerRing,
  isCaptureMode,
  isUniformPerRing,
  minCoveragePctFor,
  minimumImageCount,
  minimumPerRing,
  photosByRing,
  ringsForVariant,
} from '@/models/types/captureVariants';

describe('capture modes — the wire concept', () => {
  it('declares exactly the two wire ids, defaulting to full', () => {
    expect(CAPTURE_MODES).toEqual(['full', 'meshy']);
    expect(DEFAULT_CAPTURE_MODE).toBe('full');
  });

  it('guards the wire ids and rejects everything else', () => {
    expect(isCaptureMode('full')).toBe(true);
    expect(isCaptureMode('meshy')).toBe(true);
    for (const bad of ['FULL', 'Meshy', '', 'with_bottom', null, undefined, 3, {}]) {
      expect(isCaptureMode(bad)).toBe(false);
    }
  });

  it('every helper defaults to full, so a mode-less call is a full call', () => {
    // This is the property that lets every pre-Meshy call site keep working:
    // omitting the mode must be indistinguishable from passing 'full'.
    for (const variant of ['with_bottom', 'without_bottom'] as const) {
      expect(expectedImageCount(variant)).toBe(expectedImageCount(variant, 'full'));
      expect(expectedPerRing(variant)).toBe(expectedPerRing(variant, undefined, 'full'));
      expect(minimumImageCount(variant)).toBe(minimumImageCount(variant, 'full'));
      expect(ringsForVariant(variant)).toEqual(ringsForVariant(variant, 'full'));
    }
    expect(minCoveragePctFor()).toBe(MIN_RING_COVERAGE_PCT_BY_MODE.full);
  });
});

describe('meshy shape — 6 / 2 / 2', () => {
  it('with_bottom: EYE 6 + TOP 2 + LOW 2 = 10 images', () => {
    expect(ringsForVariant('with_bottom', 'meshy')).toEqual(['EYE', 'TOP', 'LOW']);
    expect(expectedPerRing('with_bottom', 'EYE', 'meshy')).toBe(6);
    expect(expectedPerRing('with_bottom', 'TOP', 'meshy')).toBe(2);
    expect(expectedPerRing('with_bottom', 'LOW', 'meshy')).toBe(2);
    expect(expectedImageCount('with_bottom', 'meshy')).toBe(10);
  });

  it('without_bottom: EYE 6 + TOP 2 = 8 images (no LOW)', () => {
    expect(ringsForVariant('without_bottom', 'meshy')).toEqual(['EYE', 'TOP']);
    expect(expectedImageCount('without_bottom', 'meshy')).toBe(8);
  });

  it('the total is a SUM over rings, not rings × per-ring', () => {
    // The identity the full-mode suite asserts does NOT hold here, which is the
    // whole reason expectedImageCount had to stop multiplying.
    const rings = ringsForVariant('with_bottom', 'meshy');
    expect(expectedImageCount('with_bottom', 'meshy')).not.toBe(
      rings.length * expectedPerRing('with_bottom', 'EYE', 'meshy')
    );
    expect(expectedImageCount('with_bottom', 'meshy')).toBe(
      rings.reduce((sum, ring) => sum + expectedPerRing('with_bottom', ring, 'meshy'), 0)
    );
  });

  it('reports itself as non-uniform, while full stays uniform', () => {
    expect(isUniformPerRing('with_bottom', 'meshy')).toBe(false);
    expect(isUniformPerRing('with_bottom', 'full')).toBe(true);
    expect(isUniformPerRing('without_bottom', 'full')).toBe(true);
  });
});

describe('meshy coverage floor — all-or-nothing, stated not emergent', () => {
  it('is 100%, so every ring must be complete', () => {
    expect(MIN_RING_COVERAGE_PCT_BY_MODE.meshy).toBe(100);
    expect(minimumPerRing('with_bottom', 'EYE', 'meshy')).toBe(6);
    expect(minimumPerRing('with_bottom', 'TOP', 'meshy')).toBe(2);
    expect(minimumImageCount('with_bottom', 'meshy')).toBe(10);
  });

  it('never exceeds the expected count on any ring (the un-uploadable trap)', () => {
    // The invariant the whole floor exists to protect: a server floor above the
    // client's completion rule makes a client-complete capture un-uploadable.
    for (const mode of CAPTURE_MODES) {
      for (const variant of ['with_bottom', 'without_bottom'] as const) {
        for (const ring of ringsForVariant(variant, mode)) {
          expect(minimumPerRing(variant, ring, mode)).toBeLessThanOrEqual(
            expectedPerRing(variant, ring, mode)
          );
        }
      }
    }
  });

  it('has no legacy revisions, so compat bounds equal the current ones', () => {
    // Meshy has never shipped: there is no older capture to stay compatible
    // with, and inventing tolerance would just widen the accepted range.
    expect(compatMinimumImageCount('with_bottom', 'meshy')).toBe(10);
    expect(compatMaximumImageCount('with_bottom', 'meshy')).toBe(10);
    expect(compatMinimumImageCount('without_bottom', 'meshy')).toBe(8);
    expect(compatMaximumImageCount('without_bottom', 'meshy')).toBe(8);
  });
});

describe('photosByRing — the per-ring bound shape', () => {
  it('meshy gives each ring its OWN pair', () => {
    expect(photosByRing('with_bottom', 'meshy')).toEqual({
      EYE: { min: 6, max: 6 },
      TOP: { min: 2, max: 2 },
      LOW: { min: 2, max: 2 },
    });
  });

  it('full gives every ring the same pair — its legacy-widened bounds', () => {
    // Identical numbers on every key means a consumer can always use this map
    // and never has to branch on the mode.
    expect(photosByRing('with_bottom', 'full')).toEqual({
      EYE: { min: 10, max: 16 },
      TOP: { min: 10, max: 16 },
      LOW: { min: 10, max: 16 },
    });
    expect(photosByRing('without_bottom')).toEqual({
      EYE: { min: 15, max: 24 },
      TOP: { min: 15, max: 24 },
    });
  });

  it('a scalar pair could NOT express the meshy bounds', () => {
    // The reason ManifestExpectations grew photosByLevel: collapsing 6/2/2 to
    // one [min, max] pair yields [2, 6], which accepts a 2-photo EYE ring.
    const bounds = photosByRing('with_bottom', 'meshy');
    const collapsedMin = Math.min(...Object.values(bounds).map((b) => b.min));
    expect(collapsedMin).toBe(2);
    expect(bounds.EYE!.min).toBe(6);
  });
});
