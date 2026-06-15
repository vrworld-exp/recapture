// src/middleware/validate.ts
import { Request, Response, NextFunction, RequestHandler } from 'express';
import { ZodTypeAny } from 'zod';

/**
 * Validates and normalizes `req.body` against a Zod schema. On success the
 * parsed (normalized) value replaces `req.body`. On failure it responds 400 in
 * the documented contract shape, without touching the global error middleware.
 */
export function validateBody(schema: ZodTypeAny): RequestHandler {
  return (req: Request, res: Response, next: NextFunction): void => {
    const result = schema.safeParse(req.body);
    if (!result.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: result.error.issues[0]?.message ?? 'Invalid request',
      });
      return;
    }
    req.body = result.data;
    next();
  };
}
