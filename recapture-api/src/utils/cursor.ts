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
