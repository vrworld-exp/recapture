// src/services/manifestValidationService.ts
//
// PURE capture-manifest content validation — no DB, no S3, no async. Receives
// the parsed `capture_manifest.json` (as `unknown` — it arrives from S3, not a
// Zod-validated request body) plus the SERVER-derived expectations, and returns
// a structured pass/fail result listing EVERY broken rule in one pass (no
// short-circuiting).
//
// Rule order (stable, preserved in the errors array):
//   FILE_COUNT_MISMATCH → FLOW_VARIANT_MISMATCH → MISSING_REQUIRED_LEVELS
//   → UNEXPECTED_LEVELS → INSUFFICIENT_PHOTOS_PER_LEVEL
//   → EXCESS_PHOTOS_PER_LEVEL
// with MANIFEST_UNREADABLE standing alone when the document lacks the required
// structure (the rules cannot run against garbage — that is its own finding,
// not a thrown error: an unreadable client-authored file is a verification
// failure, never a 500).
//
// GROUNDING vs the task prompt: the real manifest (mobile
// lib/domain/upload/capture_manifest.dart) has no declaredFileCount /
// requiredLevels / minPhotosPerLevel / fileType fields —
//   • the declared count is `summary.totalPhotos` vs the actual `photos[]`
//     entries (every entry IS an accepted photo; rejected shots never enter
//     the manifest);
//   • levels are ring names (EYE/TOP/LOW) carried on each photo entry;
//   • the expected ring set + per-level minimum come from the JOB's
//     captureVariant (@/models/types/captureVariants) — server-authoritative,
//     deliberately NOT read from the manifest (see ManifestExpectations);
//   • the manifest's top-level `flowVariant` (camelCase — the manifest's key
//     convention) is cross-checked against the job's variant when present.
//
// Future rules noted, out of scope here: duplicate photoId detection, manifest
// projectId/jobId ↔ job cross-check, per-photo MD5 verification (worker's job).
import { z } from 'zod';
import { ringsForVariant, DEFAULT_CAPTURE_FLOW_VARIANT } from '@/models/types/captureVariants';
import type {
  ManifestExpectations,
  ManifestValidationError,
  ManifestValidationResult,
} from '@/models/types/manifest.types';

/** The full three-ring level set (the default variant's rings) — kept for
 * callers that need the complete taxonomy; per-job expectations use the job's
 * own variant via ringsForVariant. */
export const REQUIRED_CAPTURE_LEVELS: readonly string[] = ringsForVariant(
  DEFAULT_CAPTURE_FLOW_VARIANT
);

// Minimal STRUCTURAL contract the rules need — everything else in the manifest
// passes through untouched (the document is intentionally richer than this).
const manifestShapeSchema = z
  .object({
    // The client's declared capture variant (top-level, camelCase). Optional:
    // pre-variant manifests never carry it, and its absence is tolerated.
    flowVariant: z.string().optional(),
    summary: z
      .object({
        totalPhotos: z.number().int().nonnegative(),
      })
      .passthrough(),
    photos: z.array(
      z
        .object({
          ringName: z.string().optional(),
          levelCode: z.string().optional(),
        })
        .passthrough()
    ),
  })
  .passthrough();

/** Mirrors the mobile builder's ringNameForLevelCode (A→EYE, B→TOP, C→LOW). */
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

/** Canonical level ordering for deterministic per-level detail (EYE→TOP→LOW,
 * then anything unexpected alphabetically). */
function levelSortKey(level: string): string {
  const idx = REQUIRED_CAPTURE_LEVELS.indexOf(level);
  return idx >= 0 ? `0${idx}` : `1${level}`;
}

/**
 * Validates one parsed manifest against the server's expectations. Pure and
 * synchronous; collects every failed rule before returning.
 */
export function validateCaptureManifest(
  manifest: unknown,
  expectations: ManifestExpectations
): ManifestValidationResult {
  const parsed = manifestShapeSchema.safeParse(manifest);
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    return {
      valid: false,
      errors: [
        {
          rule: 'MANIFEST_UNREADABLE',
          message: 'The manifest is missing required structure and cannot be validated.',
          detail: {
            path: issue?.path.join('.') || '(root)',
            issue: issue?.message ?? 'unparseable',
          },
        },
      ],
    };
  }

  const { summary, photos } = parsed.data;
  const errors: ManifestValidationError[] = [];

  // Rule 1: declared photo count vs actual entries.
  if (photos.length !== summary.totalPhotos) {
    errors.push({
      rule: 'FILE_COUNT_MISMATCH',
      message:
        `Manifest declares ${summary.totalPhotos} photos but contains ` +
        `${photos.length} entries.`,
      detail: { declared: summary.totalPhotos, actual: photos.length },
    });
  }

  // Rule 2: a manifest-declared flowVariant must agree with the job's variant.
  // Fires only when BOTH sides are stated: an absent manifest field is the
  // pre-variant client (tolerated — same default as create-job), and an unset
  // expectation means the caller doesn't cross-check.
  const declaredVariant = parsed.data.flowVariant;
  if (
    expectations.expectedFlowVariant !== undefined &&
    declaredVariant !== undefined &&
    declaredVariant !== expectations.expectedFlowVariant
  ) {
    errors.push({
      rule: 'FLOW_VARIANT_MISMATCH',
      message:
        `Manifest declares flowVariant '${declaredVariant}' but the job was ` +
        `created as '${expectations.expectedFlowVariant}'.`,
      detail: {
        declared: declaredVariant,
        expected: expectations.expectedFlowVariant,
      },
    });
  }

  // One grouping pass feeds Rules 3–5.
  const photosByLevel = new Map<string, number>();
  for (const photo of photos) {
    const ring = ringNameOf(photo);
    photosByLevel.set(ring, (photosByLevel.get(ring) ?? 0) + 1);
  }

  // Rule 3: every required level contributes at least one photo. An empty
  // requiredLevels list means nothing is required (never an error).
  const missingLevels = expectations.requiredLevels.filter((l) => !photosByLevel.has(l));
  if (missingLevels.length > 0) {
    errors.push({
      rule: 'MISSING_REQUIRED_LEVELS',
      message: `Required levels missing from manifest: ${missingLevels.join(', ')}.`,
      detail: { missingLevels },
    });
  }

  // Rule 4: no level outside the allowed (variant) set may appear at all —
  // e.g. LOW photos on a without_bottom job. Only when the caller states a
  // closed set; an omitted allowedLevels restricts nothing.
  const unexpectedLevels =
    expectations.allowedLevels === undefined
      ? []
      : [...photosByLevel.keys()]
          .filter((l) => !expectations.allowedLevels!.includes(l))
          .sort((a, b) => levelSortKey(a).localeCompare(levelSortKey(b)));
  if (unexpectedLevels.length > 0) {
    errors.push({
      rule: 'UNEXPECTED_LEVELS',
      message:
        `Levels not part of this capture variant are present in the manifest: ` +
        `${unexpectedLevels.join(', ')}.`,
      detail: { unexpectedLevels },
    });
  }

  // Rule 5: every EXPECTED level present in the manifest meets the per-level
  // photo minimum (absent levels are Rule 3's finding, unexpected levels are
  // Rule 4's — neither is double-reported here). minPhotosPerLevel === 0
  // flags nothing by construction.
  const underMinLevels = [...photosByLevel.entries()]
    .filter(([levelId]) => !unexpectedLevels.includes(levelId))
    .filter(([, count]) => count < expectations.minPhotosPerLevel)
    .sort(([a], [b]) => levelSortKey(a).localeCompare(levelSortKey(b)))
    .map(([levelId, count]) => ({
      levelId,
      count,
      required: expectations.minPhotosPerLevel,
    }));
  if (underMinLevels.length > 0) {
    errors.push({
      rule: 'INSUFFICIENT_PHOTOS_PER_LEVEL',
      message:
        `${underMinLevels.length} level(s) have fewer than ` +
        `${expectations.minPhotosPerLevel} photo(s).`,
      detail: { levels: underMinLevels },
    });
  }

  // Rule 6: no EXPECTED level may exceed the per-level ceiling (the variant's
  // full per-ring count). The floor relaxed to the coverage minimum, so the
  // ceiling is enforced explicitly — extra entries on a ring are no longer
  // caught by an exact-total check. Unexpected levels stay Rule 4's finding;
  // an omitted maxPhotosPerLevel enforces nothing.
  const maxPerLevel = expectations.maxPhotosPerLevel;
  const overMaxLevels =
    maxPerLevel === undefined
      ? []
      : [...photosByLevel.entries()]
          .filter(([levelId]) => !unexpectedLevels.includes(levelId))
          .filter(([, count]) => count > maxPerLevel)
          .sort(([a], [b]) => levelSortKey(a).localeCompare(levelSortKey(b)))
          .map(([levelId, count]) => ({ levelId, count, allowed: maxPerLevel }));
  if (overMaxLevels.length > 0) {
    errors.push({
      rule: 'EXCESS_PHOTOS_PER_LEVEL',
      message:
        `${overMaxLevels.length} level(s) have more than ` +
        `${maxPerLevel} photo(s).`,
      detail: { levels: overMaxLevels },
    });
  }

  return { valid: errors.length === 0, errors };
}
