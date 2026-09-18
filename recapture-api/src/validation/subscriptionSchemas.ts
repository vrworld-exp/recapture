// src/validation/subscriptionSchemas.ts
//
// Request shapes for the subscription routes.
import { z } from 'zod';

/**
 * The trial route takes NO body: the plan and the length are config, and a
 * client that thinks it can pass either is one deploy away from a free year.
 * `.strict()` makes any key a 400; `.optional()` accepts a request with no
 * body at all (the body parser hands those through as `undefined` or `{}`).
 */
export const startTrialSchema = z.object({}).strict().optional();
