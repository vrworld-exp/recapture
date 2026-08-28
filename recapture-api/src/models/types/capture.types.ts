// src/models/types/capture.types.ts
//
// Shared TypeScript interfaces for capture-related data structures.
// Used by Job.captureSummary and referenced by Project.stats aggregation logic.

/**
 * Summary of a single capture ring level (EYE, TOP, or LOW).
 * Mirrors the per-level data in the mobile app's capture_manifest.json.
 */
export interface LevelSummary {
  /** Number of accepted photos for this level */
  photos: number;

  /** Coverage percentage (0-100) — percentage of ring segments filled */
  coverage: number;

  /** Total segment count for this level (36 | 30 | 24, depends on objectSize) */
  segmentCount: number;

  /** Number of photos flagged with quality warnings (blur/exposure) */
  warnings: number;
}

/**
 * The three capture ring levels in ReCapture's guided capture protocol.
 */
export interface CaptureLevels {
  EYE: LevelSummary;
  TOP: LevelSummary;
  LOW: LevelSummary;
}

/**
 * Top-level capture summary stored on a Job document.
 * Populated when the manifest is processed during job finalization.
 */
export interface CaptureSummary {
  levels: CaptureLevels;
  totalPhotos: number;
  warningsCount: number;
}

/**
 * Object size presets — determines segment counts and minimum photo thresholds.
 * SMALL: 36 segments/ring, 30 min photos/ring (~90 total)
 * MEDIUM: 30 segments/ring, 24 min photos/ring (~72 total)
 * LARGE: 24 segments/ring, 18 min photos/ring (~54 total)
 */
export type ObjectSize = 'SMALL' | 'MEDIUM' | 'LARGE';

/**
 * Segment count lookup by object size — single source of truth.
 * Mirrors remote config values served to the mobile app.
 */
export const SEGMENT_COUNT_BY_SIZE: Record<ObjectSize, number> = {
  SMALL: 36,
  MEDIUM: 30,
  LARGE: 24,
};

/**
 * Minimum accepted photos per ring level by object size.
 */
export const MIN_PHOTOS_PER_RING_BY_SIZE: Record<ObjectSize, number> = {
  SMALL: 30,
  MEDIUM: 24,
  LARGE: 18,
};
