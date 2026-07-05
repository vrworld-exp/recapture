// src/utils/s3Keys.ts
//
// CANONICAL S3 key naming for capture uploads — the single source of truth for
// building AND parsing every object key in the upload pipeline. POST /jobs
// advertises the job prefix from here, the mobile engine writes under that
// prefix, and finalize verifies counts under the same prefix — all three derive
// from these functions so they can never disagree. Inline key templates
// anywhere else in the codebase are a bug.
//
// Key format (exact):
//   {env}/{userId}/{projectId}/{jobId}/images/{LEVEL}/{filename}.jpg
// with the job manifest at:
//   {env}/{userId}/{projectId}/{jobId}/capture_manifest.json
//
// GROUNDING vs the task prompt (its assumptions, confirmed against the code):
//   • {env} is CONFIG-DRIVEN, never hardcoded: env.NODE_ENV maps
//     production→"prod", staging→"staging", development→"dev" — a staging
//     deploy can never emit prod/... keys.
//   • {LEVEL} is the ring name EYE | TOP | LOW — NOT the prompt's A/B/C. The
//     client bundle's layout is images/{EYE|TOP|LOW}/<name>.jpg
//     (lib/domain/upload/capture_bundle.dart) and the manifest validator's
//     REQUIRED_CAPTURE_LEVELS agree. The A→EYE / B→TOP / C→LOW level-code
//     mapping (mobile's ringNameForLevelCode) is honored as INPUT via
//     normalizeCaptureLevel, but built keys always carry the ring name.
//   • The JOB-ROOT prefix (…/{jobId}/) — not …/images/ — is what the upload
//     plan advertises and finalize lists, because expectedFilesCount is
//     manifest-INCLUSIVE and the manifest sits at the job root.
//
// Every interpolated segment is validated before composition (no separators,
// no leading dot — which also kills ".." — no whitespace/control chars, never
// empty), so a hostile value can neither traverse the hierarchy nor inject
// extra key levels. Builders THROW S3KeyError on invalid input; the parser
// returns a discriminated failure instead of a partial parse.
import { env } from '@/config/env';

/** The environment prefixes keys may carry — the leading key segment. */
export const S3_ENV_PREFIXES = ['dev', 'staging', 'prod'] as const;
export type S3EnvPrefix = (typeof S3_ENV_PREFIXES)[number];

/** NODE_ENV → key prefix. Pure and exported so the mapping is unit-testable
 * without re-importing @/config/env under a different NODE_ENV. */
export function s3EnvPrefixFor(nodeEnv: typeof env.NODE_ENV): S3EnvPrefix {
  const byNodeEnv: Record<typeof env.NODE_ENV, S3EnvPrefix> = {
    development: 'dev',
    staging: 'staging',
    production: 'prod',
  };
  return byNodeEnv[nodeEnv];
}

/** The configured environment prefix — the {env} segment every builder emits. */
export function s3EnvPrefix(): S3EnvPrefix {
  return s3EnvPrefixFor(env.NODE_ENV);
}

/** The {LEVEL} segment values — the three capture ring names, uppercase. */
export const CAPTURE_LEVEL_SEGMENTS = ['EYE', 'TOP', 'LOW'] as const;
export type CaptureLevelSegment = (typeof CAPTURE_LEVEL_SEGMENTS)[number];

/** Mobile level codes → ring names (mirrors the client's ringNameForLevelCode). */
const LEVEL_BY_CODE: Readonly<Record<string, CaptureLevelSegment>> = {
  A: 'EYE',
  B: 'TOP',
  C: 'LOW',
};

/** Thrown by the builders on any invalid segment — callers never receive a
 * malformed key. */
export class S3KeyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'S3KeyError';
  }
}

/**
 * Allowed shape of ONE key segment: starts alphanumeric (a leading dot — and
 * therefore ".." — is rejected), then alphanumerics, dot, underscore, hyphen.
 * Excludes `/` and `\` (hierarchy injection), whitespace, and control chars.
 */
const SEGMENT_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

function requireSegment(name: string, value: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new S3KeyError(`${name} must be a non-empty string`);
  }
  if (!SEGMENT_RE.test(value)) {
    throw new S3KeyError(
      `${name} contains characters not allowed in an S3 key segment ` +
        `(allowed: alphanumeric start, then [A-Za-z0-9._-]): ${JSON.stringify(value)}`
    );
  }
  return value;
}

/**
 * Maps any accepted level spelling to the canonical {LEVEL} segment:
 * ring names in any case (eye → EYE) and mobile level codes (A/B/C → ring
 * name). Anything else throws — the level set is closed.
 */
export function normalizeCaptureLevel(value: string): CaptureLevelSegment {
  const upper = typeof value === 'string' ? value.trim().toUpperCase() : '';
  if ((CAPTURE_LEVEL_SEGMENTS as readonly string[]).includes(upper)) {
    return upper as CaptureLevelSegment;
  }
  const byCode = LEVEL_BY_CODE[upper];
  if (byCode) return byCode;
  throw new S3KeyError(
    `level must be one of ${CAPTURE_LEVEL_SEGMENTS.join('/')} (or code A/B/C): ` +
      JSON.stringify(value)
  );
}

/**
 * Normalizes a caller-supplied image file name to `<stem>.jpg` with EXACTLY
 * one lowercase extension: any trailing `.jpg` (any case, repeated) is
 * stripped, the stem is segment-validated, and a single `.jpg` is appended —
 * so "frame_0001", "frame_0001.jpg", "frame_0001.JPG", and "a.jpg.jpg" all
 * come out well-formed, and a caller-supplied extension can never double up.
 */
function jpgFilenameSegment(filename: string): string {
  if (typeof filename !== 'string' || filename.length === 0) {
    throw new S3KeyError('filename must be a non-empty string');
  }
  let stem = filename;
  while (/\.jpg$/i.test(stem)) {
    stem = stem.slice(0, -4);
  }
  if (stem.length === 0) {
    throw new S3KeyError(`filename must not be only an extension: ${JSON.stringify(filename)}`);
  }
  return `${requireSegment('filename', stem)}.jpg`;
}

/** The identifiers that scope every key of one upload job. */
export interface JobKeyScope {
  userId: string;
  projectId: string;
  jobId: string;
}

/** File name of the capture manifest at the job root. */
export const MANIFEST_FILENAME = 'capture_manifest.json';

/**
 * Job-ROOT prefix: `{env}/{userId}/{projectId}/{jobId}/`. This is the plan's
 * `keyPrefix` (containment boundary for every object of the job) AND the
 * prefix finalize lists for its manifest-inclusive count.
 */
export function buildJobKeyPrefix(scope: JobKeyScope): string {
  const userId = requireSegment('userId', scope.userId);
  const projectId = requireSegment('projectId', scope.projectId);
  const jobId = requireSegment('jobId', scope.jobId);
  return `${s3EnvPrefix()}/${userId}/${projectId}/${jobId}/`;
}

/** Image sub-prefix: `{env}/{userId}/{projectId}/{jobId}/images/`. */
export function buildJobImagePrefix(scope: JobKeyScope): string {
  return `${buildJobKeyPrefix(scope)}images/`;
}

/** Per-level image prefix: `…/images/{LEVEL}/`. Accepts ring name or A/B/C. */
export function buildLevelImagePrefix(scope: JobKeyScope, level: string): string {
  return `${buildJobImagePrefix(scope)}${normalizeCaptureLevel(level)}/`;
}

/** Where the job's capture manifest must live: `…/{jobId}/capture_manifest.json`. */
export function buildManifestKey(scope: JobKeyScope): string {
  return `${buildJobKeyPrefix(scope)}${MANIFEST_FILENAME}`;
}

export interface BuildImageKeyInput extends JobKeyScope {
  /** Ring name (EYE/TOP/LOW, any case) or mobile level code (A/B/C). */
  level: string;
  /** File name with or without a `.jpg` extension; emitted with exactly one. */
  filename: string;
}

/**
 * Full image key: `{env}/{userId}/{projectId}/{jobId}/images/{LEVEL}/{filename}.jpg`.
 * Round-trip guarantee: for canonical inputs (ring-name level, filename ending
 * in one lowercase `.jpg`), `parseImageKey(buildImageKey(x))` returns exactly
 * `x` plus the configured env.
 */
export function buildImageKey(input: BuildImageKeyInput): string {
  return `${buildLevelImagePrefix(input, input.level)}${jpgFilenameSegment(input.filename)}`;
}

/** All segments of one canonical image key, exactly as they appear in it. */
export interface ParsedImageKey extends JobKeyScope {
  env: S3EnvPrefix;
  level: CaptureLevelSegment;
  /** Includes the `.jpg` extension (the literal final segment). */
  filename: string;
}

export type ParseImageKeyResult =
  | { ok: true; value: ParsedImageKey }
  | { ok: false; reason: string };

/**
 * STRICT parser for canonical image keys. Accepts only the exact scheme —
 * seven segments, a literal `images` level-4 segment, a known env prefix, an
 * uppercase ring-name level, valid id segments, and a single lowercase `.jpg`
 * — and returns a discriminated failure (never a partial parse) otherwise.
 */
export function parseImageKey(key: string): ParseImageKeyResult {
  const fail = (reason: string): ParseImageKeyResult => ({ ok: false, reason });
  if (typeof key !== 'string' || key.length === 0) {
    return fail('key must be a non-empty string');
  }

  const parts = key.split('/');
  if (parts.length !== 7) {
    return fail(
      'key must have exactly 7 segments: {env}/{userId}/{projectId}/{jobId}/images/{LEVEL}/{filename}.jpg'
    );
  }
  const [envSeg, userId, projectId, jobId, imagesSeg, levelSeg, fileSeg] = parts as [
    string, string, string, string, string, string, string,
  ];

  if (!(S3_ENV_PREFIXES as readonly string[]).includes(envSeg)) {
    return fail(`unknown env prefix ${JSON.stringify(envSeg)} (expected ${S3_ENV_PREFIXES.join('/')})`);
  }
  for (const [name, value] of [
    ['userId', userId],
    ['projectId', projectId],
    ['jobId', jobId],
  ] as const) {
    if (!SEGMENT_RE.test(value)) {
      return fail(`invalid ${name} segment: ${JSON.stringify(value)}`);
    }
  }
  if (imagesSeg !== 'images') {
    return fail(`expected literal "images" as the 5th segment, got ${JSON.stringify(imagesSeg)}`);
  }
  if (!(CAPTURE_LEVEL_SEGMENTS as readonly string[]).includes(levelSeg)) {
    return fail(
      `level segment must be exactly one of ${CAPTURE_LEVEL_SEGMENTS.join('/')}, got ${JSON.stringify(levelSeg)}`
    );
  }
  if (!fileSeg.endsWith('.jpg')) {
    return fail(`filename must end in lowercase ".jpg": ${JSON.stringify(fileSeg)}`);
  }
  const stem = fileSeg.slice(0, -'.jpg'.length);
  if (/\.jpg$/i.test(stem)) {
    return fail(`filename must end in exactly one ".jpg": ${JSON.stringify(fileSeg)}`);
  }
  if (!SEGMENT_RE.test(stem)) {
    return fail(`invalid filename segment: ${JSON.stringify(fileSeg)}`);
  }

  return {
    ok: true,
    value: {
      env: envSeg as S3EnvPrefix,
      userId,
      projectId,
      jobId,
      level: levelSeg as CaptureLevelSegment,
      filename: fileSeg,
    },
  };
}
