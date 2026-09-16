// src/validation/notificationSchemas.ts
//
// Zod schemas for the user-facing /notifications group and the ADMIN-only
// send/retract routes under /admin/notifications. The create body is `.strict()`
// so a field this API does not understand is a 400 rather than a silent drop —
// the same posture as updateProfileSchema.
import { z } from 'zod';
import { NOTIFICATION_KINDS } from '@/models/Notification';

const OBJECT_ID_RE = /^[a-fA-F0-9]{24}$/;

/** Bounds shared with the Mongoose schema; the client mirrors them as copy. */
export const NOTIFICATION_RULES = {
  titleMax: 80,
  messageMax: 500,
  detailMax: 4000,
  actionLabelMax: 30,
  actionUrlMax: 2048,
  /** Cap on an explicit recipient list — a bigger send is a broadcast. */
  maxTargetedUsers: 500,
} as const;

/**
 * An action URL is either an IN-APP ROUTE (a path the client's router owns —
 * `/catalog/analytics`) or an ABSOLUTE https link. `http://` is refused: a
 * notification is an admin telling a user to go somewhere, and that somewhere
 * must not be a plaintext page. `javascript:` and friends are refused by the
 * same rule.
 */
const actionUrlSchema = z
  .string()
  .trim()
  .min(1)
  .max(NOTIFICATION_RULES.actionUrlMax)
  .refine((url) => url.startsWith('/') || /^https:\/\/\S+$/.test(url), {
    message: 'Action url must be an in-app path (starting with /) or an https:// link',
  });

const actionSchema = z
  .object({
    label: z.string().trim().min(1).max(NOTIFICATION_RULES.actionLabelMax),
    url: actionUrlSchema,
  })
  .strict();

const audienceSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('ALL') }).strict(),
  z
    .object({
      type: z.literal('USERS'),
      userIds: z
        .array(z.string().regex(OBJECT_ID_RE, 'Invalid user id'))
        .min(1, 'At least one recipient is required')
        .max(NOTIFICATION_RULES.maxTargetedUsers),
    })
    .strict(),
]);

/** POST /admin/notifications body. */
export const createNotificationSchema = z
  .object({
    kind: z.enum(NOTIFICATION_KINDS).default('INFO'),
    title: z.string().trim().min(1, 'Title is required').max(NOTIFICATION_RULES.titleMax),
    message: z
      .string()
      .trim()
      .min(1, 'Message is required')
      .max(NOTIFICATION_RULES.messageMax),
    detail: z.string().trim().min(1).max(NOTIFICATION_RULES.detailMax).optional(),
    action: actionSchema.optional(),
    audience: audienceSchema,
    // ISO instant. Must be in the future — an already-expired notification is
    // a send nobody can ever see, which is a mistake, not a request.
    expiresAt: z
      .string()
      .datetime({ offset: true })
      .refine((iso) => new Date(iso).getTime() > Date.now(), {
        message: 'expiresAt must be in the future',
      })
      .optional(),
  })
  .strict();

export type CreateNotificationInput = z.infer<typeof createNotificationSchema>;

/** `:id` param for /notifications/:id/read and /admin/notifications/:id. */
export const notificationIdParamsSchema = z
  .object({
    id: z.string().regex(OBJECT_ID_RE, 'Invalid notification id'),
  })
  .strict();
