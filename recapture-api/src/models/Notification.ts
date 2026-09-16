// src/models/Notification.ts
import { Schema, model, Document, Types } from 'mongoose';

/**
 * What a notification is ABOUT. Drives the icon on the client and nothing
 * else — there is no per-kind behaviour on the server. Add a member here and
 * the client's `NotificationKind.fromApiValue` degrades an unknown value to
 * `info`, so a new kind ships without a forced client update.
 */
export const NOTIFICATION_KINDS = [
  'WELCOME',
  'INFO',
  'PAYMENT_DUE',
  'PAYMENT_ACTIVATE',
  'ANALYTICS',
  'SYSTEM',
] as const;
export type NotificationKind = (typeof NOTIFICATION_KINDS)[number];

/** Who a notification is for: everyone, or an explicit list of user ids. */
export const NOTIFICATION_AUDIENCE_TYPES = ['ALL', 'USERS'] as const;
export type NotificationAudienceType = (typeof NOTIFICATION_AUDIENCE_TYPES)[number];

/**
 * An optional call-to-action. `url` is either an in-app route (`/catalog/…`,
 * resolved by the client's router) or an absolute https link (opened in the
 * browser). The client decides by the leading `/` — the server only validates
 * the shape (validation/notificationSchemas.ts).
 */
export interface NotificationAction {
  label: string;
  url: string;
}

/**
 * One admin-authored message. NOT per-user: a broadcast is ONE document, and
 * who has read it lives in `NotificationReceipt` (one row per user per
 * notification, written on first read). That is what keeps "send to every
 * user" a single insert rather than N, and it is why a user created AFTER a
 * broadcast still sees it — the welcome greeting relies on exactly that.
 *
 * Delivery is PULL, not push: the client re-fetches the feed on the same
 * occasions it re-fetches projects and the profile (app start, hub refresh,
 * screen open). There is no real-time channel, by design for v1.
 */
export interface INotification extends Document {
  /**
   * Optional idempotency key for SYSTEM-seeded notifications (the welcome
   * greeting is `welcome_v1`). Unique when present; absent on admin-sent
   * messages, which are never replayed by construction (a human pressed send).
   */
  key?: string;
  kind: NotificationKind;
  /** Short headline, shown bold in the list. */
  title: string;
  /** The body shown in the list row. */
  message: string;
  /** Long-form text behind the client's "Details" button. Absent = no button. */
  detail?: string;
  /** The optional CTA. Absent = no button. */
  action?: NotificationAction;
  audienceType: NotificationAudienceType;
  /** Populated only when `audienceType === 'USERS'`; empty for a broadcast. */
  audienceUserIds: Types.ObjectId[];
  /** The admin who sent it; absent for system-seeded rows. */
  createdByUserId?: Types.ObjectId;
  /** Hidden from every feed after this instant. Absent = never expires. */
  expiresAt?: Date;
  /** Soft-delete (retraction): hidden from every feed, receipts kept. */
  deletedAt: Date | null;
  createdAt: Date;
  updatedAt: Date;
}

const NotificationActionSchema = new Schema<NotificationAction>(
  {
    label: { type: String, required: true, trim: true, maxlength: 30 },
    url: { type: String, required: true, trim: true, maxlength: 2048 },
  },
  { _id: false }
);

const NotificationSchema = new Schema<INotification>(
  {
    key: { type: String, trim: true },
    kind: { type: String, enum: NOTIFICATION_KINDS, required: true, default: 'INFO' },
    title: { type: String, required: true, trim: true, maxlength: 80 },
    message: { type: String, required: true, trim: true, maxlength: 500 },
    detail: { type: String, trim: true, maxlength: 4000 },
    action: { type: NotificationActionSchema },
    audienceType: {
      type: String,
      enum: NOTIFICATION_AUDIENCE_TYPES,
      required: true,
    },
    audienceUserIds: {
      type: [{ type: Schema.Types.ObjectId, ref: 'User' }],
      required: true,
      default: [],
    },
    createdByUserId: { type: Schema.Types.ObjectId, ref: 'User' },
    expiresAt: { type: Date },
    deletedAt: { type: Date, default: null },
  },
  { timestamps: true }
);

// ── Indexes ────────────────────────────────────────────────────────────────
// The seed key: at most one row per key. PARTIAL so the many admin-sent rows
// without a key do not collide on `null`.
NotificationSchema.index(
  { key: 1 },
  { unique: true, partialFilterExpression: { key: { $type: 'string' } } }
);
// The feed's two branches, each newest-first: every live broadcast, and every
// live row that names this user.
NotificationSchema.index({ audienceType: 1, deletedAt: 1, createdAt: -1 });
NotificationSchema.index({ audienceUserIds: 1, deletedAt: 1, createdAt: -1 });

export const Notification = model<INotification>('Notification', NotificationSchema);
