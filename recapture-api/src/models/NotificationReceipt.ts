// src/models/NotificationReceipt.ts
import { Schema, model, Document, Types } from 'mongoose';

/**
 * "This user has read this notification." One row per (user, notification),
 * written on the FIRST read and never updated — `readAt` is the first time the
 * user opened it, which is the only instant that means anything.
 *
 * Absence is the unread state. There is deliberately no `unread` row and no
 * per-user copy of the notification: a broadcast to ten thousand users costs
 * ONE Notification document plus one receipt per user who actually reads it.
 * The unread count is therefore "visible notifications minus receipts", which
 * `notificationsService` computes per request.
 *
 * Receipts survive a retraction (soft-delete of the notification) — they are
 * a fact about the past, and the join simply stops finding the parent.
 */
export interface INotificationReceipt extends Document {
  userId: Types.ObjectId;
  notificationId: Types.ObjectId;
  readAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const NotificationReceiptSchema = new Schema<INotificationReceipt>(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    notificationId: { type: Schema.Types.ObjectId, ref: 'Notification', required: true },
    readAt: { type: Date, required: true },
  },
  { timestamps: true }
);

// One receipt per user per notification — the upsert in markNotificationRead
// races on this, so a double-tap produces one row rather than two.
NotificationReceiptSchema.index({ userId: 1, notificationId: 1 }, { unique: true });

export const NotificationReceipt = model<INotificationReceipt>(
  'NotificationReceipt',
  NotificationReceiptSchema
);
