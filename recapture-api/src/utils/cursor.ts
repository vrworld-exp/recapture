// src/utils/cursor.ts
import { Types } from 'mongoose';

/** A decoded pagination position: the `(updatedAt, id)` of the last seen row. */
export interface ProjectCursor {
  updatedAt: Date;
  id: string;
}

/**
 * Encodes a `(updatedAt, id)` position into an opaque base64url token. The shape
 * is an implementation detail clients must not depend on — they only echo it
 * back. `updatedAt` is stored as epoch millis for a compact, lossless round-trip.
 */
export function encodeCursor(updatedAt: Date, id: string): string {
  const payload = JSON.stringify({ u: updatedAt.getTime(), i: id });
  return Buffer.from(payload, 'utf8').toString('base64url');
}

/**
 * Decodes an opaque cursor defensively. Returns `null` for anything malformed —
 * bad base64, bad JSON, wrong shape, non-finite timestamp, or an invalid
 * ObjectId — so the caller can answer a tampered cursor with 400, never 500.
 */
export function decodeCursor(raw: string): ProjectCursor | null {
  try {
    const json = Buffer.from(raw, 'base64url').toString('utf8');
    const parsed: unknown = JSON.parse(json);
    if (typeof parsed !== 'object' || parsed === null) return null;

    const { u, i } = parsed as Record<string, unknown>;
    if (typeof u !== 'number' || !Number.isFinite(u)) return null;
    if (typeof i !== 'string' || !Types.ObjectId.isValid(i)) return null;

    return { updatedAt: new Date(u), id: i };
  } catch {
    return null;
  }
}

/**
 * A decoded position-ordered position: the `(position, id)` of the last seen
 * row. Used by the catalog product list, which is ordered by an explicit
 * user-assigned `position` rather than by recency.
 */
export interface PositionCursor {
  position: number;
  id: string;
}

/**
 * Encodes a `(position, id)` position. Same opaque base64url-JSON scheme as
 * {@link encodeCursor} — one cursor format in this codebase, two orderings —
 * with `p` instead of `u` so a cursor from one list can never be silently
 * accepted by the other (it decodes to null, i.e. a clean 400).
 */
export function encodePositionCursor(position: number, id: string): string {
  const payload = JSON.stringify({ p: position, i: id });
  return Buffer.from(payload, 'utf8').toString('base64url');
}

/**
 * Decodes a position cursor with the same defensiveness as
 * {@link decodeCursor}: anything malformed returns `null` so a tampered or
 * cross-list cursor is answered with 400, never a 500 or a wrong page.
 */
export function decodePositionCursor(raw: string): PositionCursor | null {
  try {
    const json = Buffer.from(raw, 'base64url').toString('utf8');
    const parsed: unknown = JSON.parse(json);
    if (typeof parsed !== 'object' || parsed === null) return null;

    const { p, i } = parsed as Record<string, unknown>;
    if (typeof p !== 'number' || !Number.isFinite(p)) return null;
    if (typeof i !== 'string' || !Types.ObjectId.isValid(i)) return null;

    return { position: p, id: i };
  } catch {
    return null;
  }
}
