// tests/manifest-validation.test.ts
//
// Pure unit tests for validateCaptureManifest — no server, no DB, no S3. The
// grounded rule set over the REAL capture_manifest.json shape: declared
// (summary.totalPhotos) vs actual (photos[]) count, required ring levels
// (EYE/TOP/LOW) present, and per-level minimums that come from the SERVER's
// expectations (never the manifest itself). Collect-all, stable rule order.
import { describe, it, expect } from 'vitest';
import {
  validateCaptureManifest,
  REQUIRED_CAPTURE_LEVELS,
} from '@/services/manifestValidationService';
import type { ManifestExpectations } from '@/models/types/manifest.types';

const expectations: ManifestExpectations = {
  requiredLevels: [...REQUIRED_CAPTURE_LEVELS],
  minPhotosPerLevel: 3,
};

/** Builds a manifest with the given photos per ring, declared consistently. */
function manifestWith(perRing: Record<string, number>, declared?: number) {
  const photos = Object.entries(perRing).flatMap(([ring, count]) =>
    Array.from({ length: count }, (_, i) => ({ photoId: `${ring}_${i}`, ringName: ring }))
  );
  return {
    summary: { totalPhotos: declared ?? photos.length, warningsCount: 0 },
    photos,
  };
}

describe('validateCaptureManifest — pass', () => {
  it('returns valid: true for a fully compliant manifest', () => {
    const result = validateCaptureManifest(
      manifestWith({ EYE: 3, TOP: 4, LOW: 3 }),
      expectations
    );
    expect(result.valid).toBe(true);
    expect(result.errors).toEqual([]);
  });

  it('empty requiredLevels → the level rule never fires', () => {
    const result = validateCaptureManifest(manifestWith({ EYE: 3 }), {
      requiredLevels: [],
      minPhotosPerLevel: 3,
    });
    expect(result.valid).toBe(true);
  });

  it('minPhotosPerLevel of 0 flags nothing', () => {
    const result = validateCaptureManifest(manifestWith({ EYE: 1, TOP: 1, LOW: 1 }), {
      requiredLevels: [...REQUIRED_CAPTURE_LEVELS],
      minPhotosPerLevel: 0,
    });
    expect(result.valid).toBe(true);
  });

  it('derives the ring from levelCode (A→EYE) when ringName is absent', () => {
    const manifest = {
      summary: { totalPhotos: 3 },
      photos: [
        { photoId: 'p1', levelCode: 'A' },
        { photoId: 'p2', levelCode: 'B' },
        { photoId: 'p3', levelCode: 'C' },
      ],
    };
    const result = validateCaptureManifest(manifest, {
      requiredLevels: [...REQUIRED_CAPTURE_LEVELS],
      minPhotosPerLevel: 1,
    });
    expect(result.valid).toBe(true);
  });
});

describe('validateCaptureManifest — single-rule failures', () => {
  it('fails FILE_COUNT_MISMATCH when entries are fewer than declared', () => {
    const result = validateCaptureManifest(
      manifestWith({ EYE: 3, TOP: 3, LOW: 3 }, 12),
      expectations
    );
    expect(result.valid).toBe(false);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]!.rule).toBe('FILE_COUNT_MISMATCH');
    expect(result.errors[0]!.detail).toEqual({ declared: 12, actual: 9 });
  });

  it('fails FILE_COUNT_MISMATCH when entries exceed the declared count', () => {
    const result = validateCaptureManifest(
      manifestWith({ EYE: 3, TOP: 3, LOW: 3 }, 7),
      expectations
    );
    expect(result.errors[0]!.detail).toEqual({ declared: 7, actual: 9 });
  });

  it('fails MISSING_REQUIRED_LEVELS with the exact missing ring names', () => {
    const result = validateCaptureManifest(manifestWith({ EYE: 3 }), expectations);
    expect(result.valid).toBe(false);
    const missing = result.errors.find((e) => e.rule === 'MISSING_REQUIRED_LEVELS');
    expect(missing!.detail).toEqual({ missingLevels: ['TOP', 'LOW'] });
  });

  it('fails INSUFFICIENT_PHOTOS_PER_LEVEL with a per-level breakdown', () => {
    const result = validateCaptureManifest(
      manifestWith({ EYE: 3, TOP: 2, LOW: 1 }),
      expectations
    );
    expect(result.valid).toBe(false);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]!.rule).toBe('INSUFFICIENT_PHOTOS_PER_LEVEL');
    expect(result.errors[0]!.detail.levels).toEqual([
      { levelId: 'TOP', count: 2, required: 3 },
      { levelId: 'LOW', count: 1, required: 3 },
    ]);
  });

  it('an unexpected extra level is still held to the minimum', () => {
    const result = validateCaptureManifest(
      manifestWith({ EYE: 3, TOP: 3, LOW: 3, XTRA: 1 }),
      expectations
    );
    expect(result.errors[0]!.rule).toBe('INSUFFICIENT_PHOTOS_PER_LEVEL');
    expect(result.errors[0]!.detail.levels).toEqual([
      { levelId: 'XTRA', count: 1, required: 3 },
    ]);
  });
});

describe('validateCaptureManifest — collect-all + order', () => {
  it('collects all three rule failures in one pass, in stable rule order', () => {
    // Declares 10 vs 5 entries; LOW missing; EYE/TOP under the minimum.
    const result = validateCaptureManifest(
      manifestWith({ EYE: 3, TOP: 2 }, 10),
      expectations
    );
    expect(result.valid).toBe(false);
    expect(result.errors.map((e) => e.rule)).toEqual([
      'FILE_COUNT_MISMATCH',
      'MISSING_REQUIRED_LEVELS',
      'INSUFFICIENT_PHOTOS_PER_LEVEL',
    ]);
  });

  it('every detail payload is plain JSON (survives a stringify round-trip)', () => {
    const result = validateCaptureManifest(
      manifestWith({ EYE: 1 }, 10),
      expectations
    );
    expect(JSON.parse(JSON.stringify(result))).toEqual(result);
  });
});

describe('validateCaptureManifest — unreadable input', () => {
  it.each([
    ['undefined (unparseable JSON upstream)', undefined],
    ['a non-object', 'garbage'],
    ['missing summary', { photos: [] }],
    ['missing photos', { summary: { totalPhotos: 0 } }],
    ['non-numeric totalPhotos', { summary: { totalPhotos: 'ten' }, photos: [] }],
  ])('%s → single MANIFEST_UNREADABLE finding, never a throw', (_name, input) => {
    const result = validateCaptureManifest(input, expectations);
    expect(result.valid).toBe(false);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]!.rule).toBe('MANIFEST_UNREADABLE');
  });

  it('empty files + declared 0: count passes, required levels all missing', () => {
    const result = validateCaptureManifest(
      { summary: { totalPhotos: 0 }, photos: [] },
      expectations
    );
    expect(result.valid).toBe(false);
    expect(result.errors.map((e) => e.rule)).toEqual(['MISSING_REQUIRED_LEVELS']);
    expect(result.errors[0]!.detail).toEqual({
      missingLevels: ['EYE', 'TOP', 'LOW'],
    });
  });
});
