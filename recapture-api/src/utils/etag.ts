// src/utils/etag.ts
import { createHash } from 'crypto';

/**
 * Canonical JSON: object keys sorted recursively so two structurally-identical
 * payloads serialize byte-for-byte identically regardless of key insertion
 * order. This makes the derived ETag deterministic for equal content.
 */
function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }
  if (value && typeof value === 'object') {
    return Object.keys(value as Record<string, unknown>)
      .sort()
      .reduce<Record<string, unknown>>((acc, key) => {
        acc[key] = canonicalize((value as Record<string, unknown>)[key]);
        return acc;
      }, {});
  }
  return value;
}

/**
 * A strong ETag derived from a payload's canonical content. Stable across equal
 * payloads, changes whenever any value (e.g. `version`) changes. Returned quoted
 * per RFC 7232 so it can be compared directly against `If-None-Match`.
 */
export function strongETag(payload: unknown): string {
  const json = JSON.stringify(canonicalize(payload));
  const hash = createHash('sha256').update(json).digest('base64url');
  return `"${hash}"`;
}

/**
 * True when an incoming `If-None-Match` header matches `etag`. Handles a missing
 * header, the `*` wildcard, and a comma-separated list of candidate tags.
 */
export function ifNoneMatchSatisfied(header: string | undefined, etag: string): boolean {
  if (!header) return false;
  if (header.trim() === '*') return true;
  return header
    .split(',')
    .map((t) => t.trim())
    .includes(etag);
}
