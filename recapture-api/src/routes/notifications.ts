// src/routes/notifications.ts
//
// The signed-in user's in-app notification feed (mounted at /notifications).
// Three routes, all requireAuth, all the standard envelope:
//   GET  /               → the feed + unreadCount
//   POST /read-all       → mark everything visible read
//   POST /:id/read       → mark one read (idempotent)
//
// Read-only from the user's side beyond receipts: sending lives on
// /admin/notifications (ADMIN). Delivery is pull — the client calls GET on
// the same occasions it re-fetches projects and the profile.
import { Router } from 'express';
import { asyncHandler } from '@/utils/asyncHandler';
import { requireAuth } from '@/middleware/auth';
import { notificationIdParamsSchema } from '@/validation/notificationSchemas';
import {
  listNotificationsForUser,
  markAllNotificationsRead,
  markNotificationRead,
} from '@/services/notificationsService';

const router = Router();

router.use(requireAuth);

/** GET /notifications — everything visible to the caller, newest first. */
router.get(
  '/',
  asyncHandler(async (req, res) => {
    const feed = await listNotificationsForUser(req.user!.userId);
    res.status(200).json({ status: 'success', ...feed });
  })
);

/**
 * POST /notifications/read-all — declared BEFORE `/:id/read` so the literal
 * segment can never be swallowed as an id.
 */
router.post(
  '/read-all',
  asyncHandler(async (req, res) => {
    const result = await markAllNotificationsRead(req.user!.userId);
    res.status(200).json({ status: 'success', ...result });
  })
);

/**
 * POST /notifications/:id/read — one receipt. Nonexistent, retracted, expired
 * and not-for-you all answer the SAME 404 (enumeration-safe).
 */
router.post(
  '/:id/read',
  asyncHandler(async (req, res) => {
    const params = notificationIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid request',
      });
      return;
    }

    const result = await markNotificationRead(req.user!.userId, params.data.id);
    if (!result.ok) {
      res.status(404).json({
        status: 'error',
        code: 'NOTIFICATION_NOT_FOUND',
        message: 'Notification not found.',
      });
      return;
    }

    res.status(200).json({ status: 'success', unreadCount: result.unreadCount });
  })
);

export default router;
