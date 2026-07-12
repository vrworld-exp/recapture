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
} from '@/models/types/captureVariants';

describe('capture flow variants — canonical definition', () => {
  it('declares exactly the two wire ids, defaulting to with_bottom', () => {
    expect(CAPTURE_FLOW_VARIANTS).toEqual(['with_bottom', 'without_bottom']);
    expect(DEFAULT_CAPTURE_FLOW_VARIANT).toBe('with_bottom');
  });

  it('with_bottom: EYE/TOP/LOW at 12 per ring = 36 images', () => {
    expect(ringsForVariant('with_bottom')).toEqual(['EYE', 'TOP', 'LOW']);
    expect(expectedPerRing('with_bottom')).toBe(12);
    expect(expectedImageCount('with_bottom')).toBe(36);
  });

  it('without_bottom: EYE/TOP at 18 per ring = 36 images (no LOW)', () => {
    expect(ringsForVariant('without_bottom')).toEqual(['EYE', 'TOP']);
    expect(ringsForVariant('without_bottom')).not.toContain('LOW');
    expect(expectedPerRing('without_bottom')).toBe(18);
    expect(expectedImageCount('without_bottom')).toBe(36);
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

  it('with_bottom minimums: ceil(12 × 80%) = 10 per ring, 30 total', () => {
    expect(minimumPerRing('with_bottom')).toBe(10);
    expect(minimumImageCount('with_bottom')).toBe(30);
  });

  it('without_bottom minimums: ceil(18 × 80%) = 15 per ring, 30 total', () => {
    expect(minimumPerRing('without_bottom')).toBe(15);
    expect(minimumImageCount('without_bottom')).toBe(30);
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

  it('isCaptureFlowVariant accepts only the two ids', () => {
    expect(isCaptureFlowVariant('with_bottom')).toBe(true);
    expect(isCaptureFlowVariant('without_bottom')).toBe(true);
    expect(isCaptureFlowVariant('withBottom')).toBe(false);
    expect(isCaptureFlowVariant('')).toBe(false);
    expect(isCaptureFlowVariant(undefined)).toBe(false);
    expect(isCaptureFlowVariant(3)).toBe(false);
  });
});
