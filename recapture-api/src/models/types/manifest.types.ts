// src/models/types/manifest.types.ts
//
// Shared types for capture-manifest CONTENT validation (the pure rule layer in
// services/manifestValidationService.ts). The manifest itself is the client-
// authored `capture_manifest.json` the upload engine writes to S3 (shape:
// lib/domain/upload/capture_manifest.dart on the mobile side — summary block +
// photos[] entries keyed by ring name); the backend reads it at finalize.

/**
 * Stable rule identifiers — consumed by the client, treated as a frozen string
 * enum from here on (never rename). MANIFEST_UNREADABLE covers a manifest that
 * is missing required structure / not parseable at all (the other rules cannot
 * run without a readable manifest).
 */
export type ValidationRuleId =
  | 'MANIFEST_UNREADABLE'
  | 'FILE_COUNT_MISMATCH'
  | 'MISSING_REQUIRED_LEVELS'
  | 'INSUFFICIENT_PHOTOS_PER_LEVEL';

export interface ManifestValidationError {
  rule: ValidationRuleId;
  message: string;
  /** Rule-specific structured detail — always plain JSON-serialisable data. */
  detail: Record<string, unknown>;
}

export interface ManifestValidationResult {
  valid: boolean;
  /** Every broken rule from one full pass (no short-circuiting); empty when valid. */
  errors: ManifestValidationError[];
}

/**
 * What the SERVER expects of the manifest — thresholds are server-derived (the
 * job's objectSize → per-ring minimums), never read from the manifest itself: a
 * client-authored document must not attest its own acceptance criteria.
 */
export interface ManifestExpectations {
  /** Ring names that must each contribute at least one photo (EYE/TOP/LOW). */
  requiredLevels: string[];
  /** Minimum photo count per present ring level. */
  minPhotosPerLevel: number;
}
