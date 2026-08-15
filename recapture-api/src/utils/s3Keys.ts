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
//   {env}/{projectSlug}_{projectId}/{jobId}/images/{LEVEL}/{filename}.jpg
// with the job manifest at:
//   {env}/{projectSlug}_{projectId}/{jobId}/capture_manifest.json
//
// The job-root segment carries a slugified PROJECT NAME so a human debugging in
// the S3 console can identify a project without cross-referencing Mongo. Rules
// of that segment:
//   • {projectSlug} is a convenience LABEL, never an identifier — nothing reads
//     it back to resolve a project. {projectId} is what makes the path unique
//     and machine-parseable.
//   • A name that slugifies to nothing (all-emoji, all-punctuation) is a real
//     input: the segment then degrades to a bare {projectId}, never a leading
//     "_". See projectNameSlug.
//   • {userId} is deliberately NOT in the path. Ownership is enforced in the DB
//     and by the token, never by key prefix. (The AVATAR key space —
//     utils/avatarKeys.ts — is separate and does keep {userId}.)
//
// GROUNDING (assumptions confirmed against the code):
//   • {env} is CONFIG-DRIVEN, never hardcoded: env.NODE_ENV maps
//     production→"prod", staging→"staging", development→"dev" — a staging
//     deploy can never emit prod/... keys. It is also the firewall that stops a
//     non-prod deploy from DELETING prod objects, since the project-delete path
//     wipes objects by this prefix.
//   • {LEVEL} is the ring name EYE | TOP | LOW — NOT the prompt's A/B/C. The
//     client bundle's layout is images/{EYE|TOP|LOW}/<name>.jpg
//     (lib/domain/upload/capture_bundle.dart) and the manifest validator's
//     REQUIRED_CAPTURE_LEVELS agree. The A→EYE / B→TOP / C→LOW level-code
//     mapping (mobile's ringNameForLevelCode) is honored as INPUT via
//     normalizeCaptureLevel, but built keys always carry the ring name.
//   • The JOB-ROOT prefix (…/{jobId}/) — not …/images/ — is what the upload
//     plan advertises and finalize lists, because expectedFilesCount is
//     manifest-INCLUSIVE and the manifest sits at the job root.
//   • BOTH buckets (raw captures and model artifacts) use the IDENTICAL prefix:
//     deleting a project runs deleteObjectsUnderPrefix against the same prefix
//     in both (adminProjectsService.deleteProject). Accepted consequence: the
//     project name is visible in public CloudFront URLs — a conscious tradeoff.
//   • Keys are built ONCE, at job creation, and persisted on the job
//     (Job.upload.rawPrefix / manifestKey). Every later read/list/move/delete
//     resolves from those persisted values, so changing this scheme leaves
//     existing objects readable in place — no migration, no backfill. Rebuilding
//     a prefix for an ALREADY-CREATED job would break that and is a bug.
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

/** Max length of the slug LABEL inside the project segment (ids excluded). */
const PROJECT_SLUG_MAX_LENGTH = 24;

/** Characters kept verbatim by the slugifier; everything else collapses to `-`.
 * `_` survives because the project segment is split on its LAST underscore, so
 * an underscore inside the label is unambiguous. `.` does NOT survive — a
 * leading dot is how ".." traversal starts. */
const SLUG_KEEP_RE = /[^a-z0-9_]+/g;

/** Trimmed off both ends: SEGMENT_RE requires an ALPHANUMERIC first char, so a
 * leading `-` or `_` would make the composed segment throw on a legitimate name. */
const SLUG_EDGE_RE = /^[-_]+|[-_]+$/g;

/**
 * Slugifies a user-authored `Project.name` into the label half of the job-root
 * segment. PURE and DETERMINISTIC — no clock, no randomness — so the same name
 * always yields the same key.
 *
 * Lowercased, NFKD-normalized with diacritics stripped (`Café` → `cafe`); any
 * run of characters outside `[a-z0-9_]` collapses to a single `-`; leading and
 * trailing `-`/`_` are stripped; truncated to 24 chars and re-stripped so
 * truncation can never leave a trailing separator.
 *
 * Returns the EMPTY STRING when nothing survives (an all-emoji name is a real
 * input and must not throw) — `buildJobKeyPrefix` then emits a bare
 * `{projectId}` segment rather than a leading `_`.
 */
export function projectNameSlug(name: string): string {
  if (typeof name !== 'string' || name.length === 0) return '';
  const folded = name
    .normalize('NFKD')
    // Strip combining marks left behind by NFKD (the accent of `é`, etc.).
    .replace(/[\u0300-\u036f]/gu, '')
    .toLowerCase();
  const collapsed = folded.replace(SLUG_KEEP_RE, '-').replace(SLUG_EDGE_RE, '');
  if (collapsed.length <= PROJECT_SLUG_MAX_LENGTH) return collapsed;
  return collapsed.slice(0, PROJECT_SLUG_MAX_LENGTH).replace(SLUG_EDGE_RE, '');
}

/**
 * The job-root's project segment: `{slug}_{projectId}`, or a bare `{projectId}`
 * when the name slugifies to nothing. Always passed through `requireSegment` —
 * a future slugifier bug must not be able to emit a traversal.
 */
function projectSegment(projectName: string, projectId: string): string {
  const id = requireSegment('projectId', projectId);
  const slug = projectNameSlug(projectName);
  return requireSegment('projectSegment', slug.length > 0 ? `${slug}_${id}` : id);
}

/** The identifiers that scope every key of one upload job. */
export interface JobKeyScope {
  /** RAW `Project.name` — the builders slugify it, so no caller can forget to. */
  projectName: string;
  projectId: string;
  jobId: string;
}

/** File name of the capture manifest at the job root. */
export const MANIFEST_FILENAME = 'capture_manifest.json';

/**
 * Job-ROOT prefix: `{env}/{projectSlug}_{projectId}/{jobId}/`. This is the
 * plan's `keyPrefix` (containment boundary for every object of the job) AND the
 * prefix finalize lists for its manifest-inclusive count.
 */
export function buildJobKeyPrefix(scope: JobKeyScope): string {
  const project = projectSegment(scope.projectName, scope.projectId);
  const jobId = requireSegment('jobId', scope.jobId);
  return `${s3EnvPrefix()}/${project}/${jobId}/`;
}

/** Image sub-prefix: `{env}/{projectSlug}_{projectId}/{jobId}/images/`. */
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
 * Full image key:
 * `{env}/{projectSlug}_{projectId}/{jobId}/images/{LEVEL}/{filename}.jpg`.
 * Round-trip guarantee: for canonical inputs (ring-name level, filename ending
 * in one lowercase `.jpg`, an underscore-free `projectId`),
 * `parseImageKey(buildImageKey(x))` returns `x`'s ids, the configured env, and
 * the SLUG of `x.projectName` (the raw name is not recoverable from a key —
 * slugification is one-way, by design).
 */
export function buildImageKey(input: BuildImageKeyInput): string {
  return `${buildLevelImagePrefix(input, input.level)}${jpgFilenameSegment(input.filename)}`;
}

/**
 * All segments of one canonical image key, exactly as they appear in it.
 *
 * Deliberately NOT `extends JobKeyScope`: a key carries the project SLUG, and
 * the raw `projectName` a scope holds cannot be recovered from it.
 */
export interface ParsedImageKey {
  env: S3EnvPrefix;
  /** The label half of the project segment; `''` when the key carries no slug. */
  projectSlug: string;
  projectId: string;
  jobId: string;
  level: CaptureLevelSegment;
  /** Includes the `.jpg` extension (the literal final segment). */
  filename: string;
}

export type ParseImageKeyResult =
  | { ok: true; value: ParsedImageKey }
  | { ok: false; reason: string };

/** Number of `/`-separated segments in a canonical image key. */
const IMAGE_KEY_SEGMENT_COUNT = 6;

/** Human-readable shape, reused in the parser's failure reasons. */
const IMAGE_KEY_SHAPE =
  '{env}/{projectSlug}_{projectId}/{jobId}/images/{LEVEL}/{filename}.jpg';

/**
 * STRICT parser for canonical image keys. Accepts only the exact scheme —
 * six segments, a literal `images` 4th segment, a known env prefix, an
 * uppercase ring-name level, valid id segments, and a single lowercase `.jpg`
 * — and returns a discriminated failure (never a partial parse) otherwise.
 *
 * The project segment splits on its LAST underscore: project ids are ObjectId
 * hex (`[a-f0-9]{24}`, no underscore), so an underscore inside the slug label
 * cannot make the id ambiguous. A segment with no underscore at all is a
 * slug-less key (`{projectId}` alone) and yields `projectSlug: ''`.
 *
 * Keys in the OLD `{env}/{userId}/{projectId}/{jobId}/…` scheme have seven
 * segments and therefore fail cleanly here rather than mis-parsing.
 */
export function parseImageKey(key: string): ParseImageKeyResult {
  const fail = (reason: string): ParseImageKeyResult => ({ ok: false, reason });
  if (typeof key !== 'string' || key.length === 0) {
    return fail('key must be a non-empty string');
  }

  const parts = key.split('/');
  if (parts.length !== IMAGE_KEY_SEGMENT_COUNT) {
    return fail(`key must have exactly ${IMAGE_KEY_SEGMENT_COUNT} segments: ${IMAGE_KEY_SHAPE}`);
  }
  const [envSeg, projectSeg, jobId, imagesSeg, levelSeg, fileSeg] = parts as [
    string, string, string, string, string, string,
  ];

  if (!(S3_ENV_PREFIXES as readonly string[]).includes(envSeg)) {
    return fail(`unknown env prefix ${JSON.stringify(envSeg)} (expected ${S3_ENV_PREFIXES.join('/')})`);
  }
  if (!SEGMENT_RE.test(projectSeg)) {
    return fail(`invalid project segment: ${JSON.stringify(projectSeg)}`);
  }
  const splitAt = projectSeg.lastIndexOf('_');
  const projectSlug = splitAt === -1 ? '' : projectSeg.slice(0, splitAt);
  const projectId = splitAt === -1 ? projectSeg : projectSeg.slice(splitAt + 1);
  for (const [name, value] of [
    ['projectId', projectId],
    ['jobId', jobId],
  ] as const) {
    if (!SEGMENT_RE.test(value)) {
      return fail(`invalid ${name} segment: ${JSON.stringify(value)}`);
    }
  }
  if (imagesSeg !== 'images') {
    return fail(`expected literal "images" as the 4th segment, got ${JSON.stringify(imagesSeg)}`);
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
      projectSlug,
      projectId,
      jobId,
      level: levelSeg as CaptureLevelSegment,
      filename: fileSeg,
    },
  };
}
