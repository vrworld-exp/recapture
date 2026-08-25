// src/utils/errors.ts
//
// Shared error classes for cases that are genuine invariant violations rather
// than expected business outcomes. Convention reminder: services model
// EXPECTED cases (missing/not-owned/conflict) as discriminated results and let
// routes map them to status codes — these classes are only for "should never
// happen" data-integrity failures that must surface loudly.

/**
 * A referenced document that must exist does not. Carries NO `statusCode`, so
 * the global errorHandler reports it as a 500: the known callers throw it for
 * broken internal references (e.g. a job pointing at a vanished project),
 * which is a data-integrity bug — not a client-visible 404.
 */
export class NotFoundError extends Error {
  code = 'NOT_FOUND';
  constructor(message: string) {
    super(message);
    this.name = 'NotFoundError';
  }
}
