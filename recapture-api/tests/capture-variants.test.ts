// tests/capture-variants.test.ts
//
// Pure unit tests for the canonical capture-flow-variant module — the single
// source of truth every variant-aware service derives ring sets and counts
// from (create-job's count range, upload-urls containment, finalize bounds,
// remote-config defaults).
import { describe, it, expect } from 'vitest';
import {
  CAPTURE_FLOW_VARIANTS,
  DEFAULT_CAPTURE_FLOW_VARIANT,
  MIN_RING_COVERAGE_PCT,
  isCaptureFlowVariant,
  ringsForVariant,
  expectedPerRing,
  expectedImageCount,
  minimumPerRing,
  minimumImageCount,
  compatMinimumPerRing,
  compatMaximumPerRing,
  compatMinimumImageCount,
  compatMaximumImageCount,
} from '@/models/types/captureVariants';

describe('capture flow variants — canonical definition', () => {
  it('declares exactly the two wire ids, defaulting to with_bottom', () => {
    expect(CAPTURE_FLOW_VARIANTS).toEqual(['with_bottom', 'without_bottom']);
    expect(DEFAULT_CAPTURE_FLOW_VARIANT).toBe('with_bottom');
  });

  it('with_bottom: EYE/TOP/LOW at 16 per ring = 48 images', () => {
    expect(ringsForVariant('with_bottom')).toEqual(['EYE', 'TOP', 'LOW']);
    expect(expectedPerRing('with_bottom')).toBe(16);
    expect(expectedImageCount('with_bottom')).toBe(48);
  });

  it('without_bottom: EYE/TOP at 24 per ring = 48 images (no LOW)', () => {
    expect(ringsForVariant('without_bottom')).toEqual(['EYE', 'TOP']);
    expect(ringsForVariant('without_bottom')).not.toContain('LOW');
    expect(expectedPerRing('without_bottom')).toBe(24);
    expect(expectedImageCount('without_bottom')).toBe(48);
  });

  it('the total is always rings × per-ring (never an independent constant)', () => {
    for (const variant of CAPTURE_FLOW_VARIANTS) {
      expect(expectedImageCount(variant)).toBe(
        ringsForVariant(variant).length * expectedPerRing(variant)
      );
    }
  });

  it('coverage floor: 80% mirrors the client minCoveragePct default', () => {
    expect(MIN_RING_COVERAGE_PCT).toBe(80);
  });

  it('with_bottom minimums: ceil(16 × 80%) = 13 per ring, 39 total', () => {
    expect(minimumPerRing('with_bottom')).toBe(13);
    expect(minimumImageCount('with_bottom')).toBe(39);
  });

  it('without_bottom minimums: ceil(24 × 80%) = 20 per ring, 40 total', () => {
    expect(minimumPerRing('without_bottom')).toBe(20);
    expect(minimumImageCount('without_bottom')).toBe(40);
  });

  it('the minimum is always rings × per-ring floor, never above the expected total', () => {
    for (const variant of CAPTURE_FLOW_VARIANTS) {
      expect(minimumImageCount(variant)).toBe(
        ringsForVariant(variant).length * minimumPerRing(variant)
      );
      expect(minimumPerRing(variant)).toBeLessThanOrEqual(expectedPerRing(variant));
      expect(minimumImageCount(variant)).toBeLessThanOrEqual(expectedImageCount(variant));
    }
  });

  it('compat bounds span the retired 12/18-per-ring revision AND the current one', () => {
    // Legacy with_bottom rings carried 12 (floor 10); current carry 16.
    expect(compatMinimumPerRing('with_bottom')).toBe(10);
    expect(compatMaximumPerRing('with_bottom')).toBe(16);
    // Legacy without_bottom rings carried 18 (floor 15); current carry 24.
    expect(compatMinimumPerRing('without_bottom')).toBe(15);
    expect(compatMaximumPerRing('without_bottom')).toBe(24);
  });

  it('compat bounds always contain the current range (a new capture is never rejected)', () => {
    for (const variant of CAPTURE_FLOW_VARIANTS) {
      expect(compatMinimumPerRing(variant)).toBeLessThanOrEqual(minimumPerRing(variant));
      expect(compatMaximumPerRing(variant)).toBeGreaterThanOrEqual(expectedPerRing(variant));
      expect(compatMinimumImageCount(variant)).toBe(
        ringsForVariant(variant).length * compatMinimumPerRing(variant)
      );
      expect(compatMaximumImageCount(variant)).toBe(
        ringsForVariant(variant).length * compatMaximumPerRing(variant)
      );
    }
  });

  it('isCaptureFlowVariant accepts only the two ids', () => {
    expect(isCaptureFlowVariant('with_bottom')).toBe(true);
    expect(isCaptureFlowVariant('without_bottom')).toBe(true);
    expect(isCaptureFlowVariant('withBottom')).toBe(false);
    expect(isCaptureFlowVariant('')).toBe(false);
    expect(isCaptureFlowVariant(undefined)).toBe(false);
    expect(isCaptureFlowVariant(3)).toBe(false);
  });
});
