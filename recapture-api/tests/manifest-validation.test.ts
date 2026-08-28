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

describe('validateCaptureManifest — capture-variant rules', () => {
  const withoutBottom: ManifestExpectations = {
    requiredLevels: ['EYE', 'TOP'],
    allowedLevels: ['EYE', 'TOP'],
    minPhotosPerLevel: 3,
    expectedFlowVariant: 'without_bottom',
  };

  it('a matching declared flowVariant passes', () => {
    const result = validateCaptureManifest(
      { flowVariant: 'without_bottom', ...manifestWith({ EYE: 3, TOP: 3 }) },
      withoutBottom
    );
    expect(result.valid).toBe(true);
  });

  it('an ABSENT flowVariant is tolerated (pre-variant client) — never an error by itself', () => {
    const result = validateCaptureManifest(manifestWith({ EYE: 3, TOP: 3 }), withoutBottom);
    expect(result.valid).toBe(true);
  });

  it('a declared flowVariant differing from the job → FLOW_VARIANT_MISMATCH', () => {
    const result = validateCaptureManifest(
      { flowVariant: 'with_bottom', ...manifestWith({ EYE: 3, TOP: 3 }) },
      withoutBottom
    );
    expect(result.valid).toBe(false);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]!.rule).toBe('FLOW_VARIANT_MISMATCH');
    expect(result.errors[0]!.detail).toEqual({
      declared: 'with_bottom',
      expected: 'without_bottom',
    });
  });

  it('a level outside allowedLevels → UNEXPECTED_LEVELS, excluded from the minimum rule', () => {
    // LOW has only 1 photo — under the minimum — but it is the UNEXPECTED
    // finding, not a second insufficient-photos finding.
    const result = validateCaptureManifest(
      manifestWith({ EYE: 3, TOP: 3, LOW: 1 }),
      withoutBottom
    );
    expect(result.valid).toBe(false);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]!.rule).toBe('UNEXPECTED_LEVELS');
    expect(result.errors[0]!.detail).toEqual({ unexpectedLevels: ['LOW'] });
  });

  it('omitted allowedLevels restricts nothing (pre-variant expectations unchanged)', () => {
    const result = validateCaptureManifest(
      manifestWith({ EYE: 3, TOP: 3, LOW: 3, XTRA: 3 }),
      { requiredLevels: ['EYE', 'TOP', 'LOW'], minPhotosPerLevel: 3 }
    );
    expect(result.valid).toBe(true); // XTRA passes — no closed set stated
  });

  it('all five rules collect in one pass, in stable order', () => {
    // Declares 10 vs 7 entries; wrong variant; TOP missing; LOW unexpected;
    // EYE under the minimum.
    const result = validateCaptureManifest(
      { flowVariant: 'with_bottom', ...manifestWith({ EYE: 2, LOW: 5 }, 10) },
      withoutBottom
    );
    expect(result.valid).toBe(false);
    expect(result.errors.map((e) => e.rule)).toEqual([
      'FILE_COUNT_MISMATCH',
      'FLOW_VARIANT_MISMATCH',
      'MISSING_REQUIRED_LEVELS',
      'UNEXPECTED_LEVELS',
      'INSUFFICIENT_PHOTOS_PER_LEVEL',
    ]);
  });
});

describe('validateCaptureManifest — per-level ceiling (maxPhotosPerLevel)', () => {
  const bounded: ManifestExpectations = {
    requiredLevels: ['EYE', 'TOP'],
    allowedLevels: ['EYE', 'TOP'],
    minPhotosPerLevel: 15,
    maxPhotosPerLevel: 18,
    expectedFlowVariant: 'without_bottom',
  };

  it('counts inside [min, max] pass — including the exact bounds', () => {
    for (const perRing of [15, 16, 18]) {
      const result = validateCaptureManifest(
        manifestWith({ EYE: perRing, TOP: perRing }),
        bounded
      );
      expect(result.valid, `perRing=${perRing}`).toBe(true);
    }
  });

  it('a level above the ceiling → EXCESS_PHOTOS_PER_LEVEL with a per-level breakdown', () => {
    const result = validateCaptureManifest(
      manifestWith({ EYE: 19, TOP: 15 }),
      bounded
    );
    expect(result.valid).toBe(false);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]!.rule).toBe('EXCESS_PHOTOS_PER_LEVEL');
    expect(result.errors[0]!.detail).toEqual({
      levels: [{ levelId: 'EYE', count: 19, allowed: 18 }],
    });
  });

  it('under-floor and over-ceiling rings report independently, in rule order', () => {
    const result = validateCaptureManifest(
      manifestWith({ EYE: 20, TOP: 14 }),
      bounded
    );
    expect(result.errors.map((e) => e.rule)).toEqual([
      'INSUFFICIENT_PHOTOS_PER_LEVEL',
      'EXCESS_PHOTOS_PER_LEVEL',
    ]);
  });

  it('an UNEXPECTED level over the ceiling stays Rule 4 only (no double report)', () => {
    const result = validateCaptureManifest(
      manifestWith({ EYE: 15, TOP: 15, LOW: 25 }),
      bounded
    );
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]!.rule).toBe('UNEXPECTED_LEVELS');
  });

  it('an omitted maxPhotosPerLevel enforces no ceiling (pre-range callers)', () => {
    const result = validateCaptureManifest(
      manifestWith({ EYE: 99, TOP: 15 }),
      { ...bounded, maxPhotosPerLevel: undefined }
    );
    expect(result.valid).toBe(true);
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
