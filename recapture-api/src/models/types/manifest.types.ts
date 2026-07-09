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
 * run without a readable manifest). FLOW_VARIANT_MISMATCH and
 * UNEXPECTED_LEVELS are the capture-variant rules: the manifest's declared
 * `flowVariant` disagreeing with the job's variant, and a ring level present
 * that the job's variant never captures (e.g. LOW on a without_bottom job).
 */
export type ValidationRuleId =
  | 'MANIFEST_UNREADABLE'
  | 'FILE_COUNT_MISMATCH'
  | 'FLOW_VARIANT_MISMATCH'
  | 'MISSING_REQUIRED_LEVELS'
  | 'UNEXPECTED_LEVELS'
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
  /** Ring names that must each contribute at least one photo (the job's
   * capture-variant rings, e.g. EYE/TOP/LOW or EYE/TOP). */
  requiredLevels: string[];
  /**
   * The CLOSED set of ring names allowed to appear at all — any other present
   * level is an UNEXPECTED_LEVELS finding. Optional: when omitted, no level is
   * unexpected (pre-variant behavior; finalize always passes the variant's
   * rings). Typically identical to requiredLevels.
   */
  allowedLevels?: string[];
  /** Minimum photo count per expected ring level (the variant's per-ring
   * count — server-derived, never read from the manifest). */
  minPhotosPerLevel: number;
  /**
   * The job's capture flow variant. When set, a manifest whose top-level
   * `flowVariant` field is present and different is a FLOW_VARIANT_MISMATCH;
   * an ABSENT manifest field is tolerated (pre-variant clients — same default
   * as create-job) and never an error by itself.
   */
  expectedFlowVariant?: string;
}
