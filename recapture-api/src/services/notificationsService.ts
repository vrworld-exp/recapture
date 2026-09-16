// src/services/notificationsService.ts
//
// In-app notifications: the per-user feed, read receipts, the ADMIN send /
// retract surface, and the one SYSTEM-seeded greeting.
//
// Visibility is ONE predicate (`visibleTo`), used by the feed AND by every
// per-notification write: a user can only mark read what they could have seen,
// and a notification outside their audience answers the same NOT_FOUND a
// nonexistent id does (never leak existence — AGENTS.md, enumeration-safe).
//
// Delivery is pull-only. Nothing here pushes; the client re-fetches on the
// same occasions it re-fetches projects and the profile.
import { Types, type FilterQuery } from 'mongoose';
import { env } from '@/config/env';
import {
  Notification,
  type INotification,
  type NotificationAction,
  type NotificationKind,
} from '@/models/Notification';
import { NotificationReceipt } from '@/models/NotificationReceipt';
import type { CreateNotificationInput } from '@/validation/notificationSchemas';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { hashIdentifier } from '@/utils/otp';

// ── DTOs ─────────────────────────────────────────────────────────────────────

/** What a USER sees. Built field by field — never a spread of the document. */
export interface NotificationDto {
  id: string;
  kind: NotificationKind;
  title: string;
  message: string;
  detail: string | null;
  action: NotificationAction | null;
  createdAt: string;
  isRead: boolean;
  readAt: string | null;
}

export interface NotificationFeedDto {
  notifications: NotificationDto[];
  unreadCount: number;
}

/**
 * What an ADMIN sees on the list: the user shape plus the audience and how
 * many people have opened it. Recipient ids are opaque ObjectIds — no
 * phone/email ever rides on this DTO (AGENTS.md PII stance).
 */
export interface AdminNotificationDto {
  id: string;
  kind: NotificationKind;
  title: string;
  message: string;
  detail: string | null;
  action: NotificationAction | null;
  audience: { type: 'ALL' } | { type: 'USERS'; userIds: string[] };
  createdAt: string;
  expiresAt: string | null;
  readCount: number;
}

// ── The welcome greeting ─────────────────────────────────────────────────────

/** The seed key — bump the suffix to send a NEW greeting rather than edit this one. */
export const WELCOME_NOTIFICATION_KEY = 'welcome_v1';

/**
 * The first notification every account sees. A BROADCAST rather than a
 * per-user insert at signup, on purpose: one document reaches every user who
 * already existed when it was seeded AND every user created afterwards, with
 * no signup-path code and no backfill. Unread for each of them until they open
 * it, which is what puts the badge on the bell the first time they sign in.
 */
export const WELCOME_NOTIFICATION = {
  key: WELCOME_NOTIFICATION_KEY,
  kind: 'WELCOME' as const,
  title: 'Welcome to ReCapture',
  message:
    'Welcome to the ReCapture app, developed by the MayasabhaXR team. ' +
    'Capture your products in 3D and publish them to your catalog.',
  detail:
    'ReCapture guides you through capturing photos of a product and turns them ' +
    'into a 3D model you can show customers in AR. Start with a new project from ' +
    'the Projects hub, then build your catalog and publish it when it is ready.\n\n' +
    'Updates about payments, activation and your catalog analytics will arrive ' +
    'here. Thank you for choosing MayasabhaXR.',
};

/**
 * Seeds the greeting exactly once. Idempotent on `key` (a unique partial
 * index backs it), so every boot may call this and a second API instance
 * racing the first loses on the index, not on a duplicate. Returns whether
 * this call inserted it.
 */
export async function ensureWelcomeNotification(): Promise<boolean> {
  const res = await Notification.updateOne(
    { key: WELCOME_NOTIFICATION_KEY },
    {
      $setOnInsert: {
        ...WELCOME_NOTIFICATION,
        audienceType: 'ALL',
        audienceUserIds: [],
        deletedAt: null,
      },
    },
    { upsert: true }
  ).exec();
  return res.upsertedCount > 0;
}

// ── Visibility ───────────────────────────────────────────────────────────────

/** The ONE predicate for "this user may see this notification right now". */
function visibleTo(userId: string, now: Date): FilterQuery<INotification> {
  const uid = new Types.ObjectId(userId);
  return {
    deletedAt: null,
    $and: [
      { $or: [{ audienceType: 'ALL' }, { audienceType: 'USERS', audienceUserIds: uid }] },
      // Absent (never expires) — Mongo null-equality matches the unset field.
      { $or: [{ expiresAt: null }, { expiresAt: { $gt: now } }] },
    ],
  };
}

// ── The feed ─────────────────────────────────────────────────────────────────

/**
 * Everything visible to the user, newest first, joined with their receipts.
 * Bounded by NOTIFICATIONS_FEED_LIMIT; older rows simply age out of the list
 * (there is no pagination in v1 — a feed is not an archive).
 *
 * `unreadCount` is counted over the SAME bounded set the list shows, so the
 * badge never promises more than the screen can present.
 */
export async function listNotificationsForUser(userId: string): Promise<NotificationFeedDto> {
  const now = new Date();
  const docs = await Notification.find(visibleTo(userId, now))
    .sort({ createdAt: -1, _id: -1 })
    .limit(env.NOTIFICATIONS_FEED_LIMIT)
    .exec();

  const readAtById = await receiptsFor(userId, docs);
  const notifications = docs.map((doc) => toNotificationDto(doc, readAtById.get(doc.id as string)));
  const unreadCount = notifications.reduce((n, item) => n + (item.isRead ? 0 : 1), 0);
  return { notifications, unreadCount };
}

async function receiptsFor(
  userId: string,
  docs: INotification[]
): Promise<Map<string, Date>> {
  if (docs.length === 0) return new Map();
  const receipts = await NotificationReceipt.find({
    userId: new Types.ObjectId(userId),
    notificationId: { $in: docs.map((d) => d._id) },
  })
    .select('notificationId readAt')
    .lean()
    .exec();
  return new Map(receipts.map((r) => [r.notificationId.toHexString(), r.readAt]));
}

function toNotificationDto(doc: INotification, readAt: Date | undefined): NotificationDto {
  return {
    id: doc.id as string,
    kind: doc.kind,
    title: doc.title,
    message: doc.message,
    detail: doc.detail ?? null,
    action: doc.action ? { label: doc.action.label, url: doc.action.url } : null,
    createdAt: doc.createdAt.toISOString(),
    isRead: readAt !== undefined,
    readAt: readAt ? readAt.toISOString() : null,
  };
}

// ── Read receipts ────────────────────────────────────────────────────────────

export type MarkReadResult =
  | { ok: true; unreadCount: number }
  | { ok: false; reason: 'NOT_FOUND' };

/**
 * Marks one notification read for the user. Idempotent: the receipt is
 * written with `$setOnInsert`, so a second tap keeps the FIRST readAt. A
 * notification the user cannot see — nonexistent, retracted, expired, or
 * someone else's — is NOT_FOUND, and the route answers all four identically.
 */
export async function markNotificationRead(
  userId: string,
  notificationId: string
): Promise<MarkReadResult> {
  const now = new Date();
  const visible = await Notification.exists({
    _id: new Types.ObjectId(notificationId),
    ...visibleTo(userId, now),
  }).exec();
  if (!visible) return { ok: false, reason: 'NOT_FOUND' };

  await NotificationReceipt.updateOne(
    { userId: new Types.ObjectId(userId), notificationId: new Types.ObjectId(notificationId) },
    { $setOnInsert: { readAt: now } },
    { upsert: true }
  ).exec();

  track(AnalyticsEvent.NOTIFICATION_READ, {
    user_id_hash: hashIdentifier(userId),
    scope: 'one',
  });

  return { ok: true, unreadCount: await countUnread(userId, now) };
}

/**
 * Marks every currently-visible notification read. Bounded by the same feed
 * limit as the list, so "mark all" clears exactly what the screen showed.
 * Returns how many receipts were newly written (0 is a fine answer).
 */
export async function markAllNotificationsRead(
  userId: string
): Promise<{ marked: number; unreadCount: number }> {
  const now = new Date();
  const uid = new Types.ObjectId(userId);
  const docs = await Notification.find(visibleTo(userId, now))
    .sort({ createdAt: -1, _id: -1 })
    .limit(env.NOTIFICATIONS_FEED_LIMIT)
    .select('_id')
    .exec();
  if (docs.length === 0) return { marked: 0, unreadCount: 0 };

  const res = await NotificationReceipt.bulkWrite(
    docs.map((doc) => ({
      updateOne: {
        filter: { userId: uid, notificationId: doc._id },
        update: { $setOnInsert: { readAt: now } },
        upsert: true,
      },
    })),
    { ordered: false }
  );

  const marked = res.upsertedCount;
  if (marked > 0) {
    track(AnalyticsEvent.NOTIFICATION_READ, {
      user_id_hash: hashIdentifier(userId),
      scope: 'all',
    });
  }
  return { marked, unreadCount: await countUnread(userId, now) };
}

async function countUnread(userId: string, now: Date): Promise<number> {
  const docs = await Notification.find(visibleTo(userId, now))
    .sort({ createdAt: -1, _id: -1 })
    .limit(env.NOTIFICATIONS_FEED_LIMIT)
    .select('_id')
    .exec();
  if (docs.length === 0) return 0;
  const read = await NotificationReceipt.countDocuments({
    userId: new Types.ObjectId(userId),
    notificationId: { $in: docs.map((d) => d._id) },
  }).exec();
  return docs.length - read;
}

// ── Admin: send / list / retract ─────────────────────────────────────────────

/** Creates one notification. Validation happened at the Zod boundary. */
export async function createNotification(
  input: CreateNotificationInput,
  createdByUserId: string
): Promise<AdminNotificationDto> {
  const doc = await Notification.create({
    kind: input.kind,
    title: input.title,
    message: input.message,
    ...(input.detail ? { detail: input.detail } : {}),
    ...(input.action ? { action: input.action } : {}),
    audienceType: input.audience.type,
    audienceUserIds:
      input.audience.type === 'USERS'
        ? input.audience.userIds.map((id) => new Types.ObjectId(id))
        : [],
    createdByUserId: new Types.ObjectId(createdByUserId),
    ...(input.expiresAt ? { expiresAt: new Date(input.expiresAt) } : {}),
    deletedAt: null,
  });

  track(AnalyticsEvent.NOTIFICATION_SENT, {
    actor_id_hash: hashIdentifier(createdByUserId),
    kind: doc.kind,
    audience: doc.audienceType,
    recipient_count: doc.audienceType === 'USERS' ? doc.audienceUserIds.length : null,
    has_action: Boolean(doc.action),
    has_detail: Boolean(doc.detail),
  });

  return toAdminDto(doc, 0);
}

/** Every non-retracted notification, newest first, with its read count. */
export async function listNotificationsForAdmin(): Promise<AdminNotificationDto[]> {
  const docs = await Notification.find({ deletedAt: null })
    .sort({ createdAt: -1, _id: -1 })
    .limit(env.NOTIFICATIONS_FEED_LIMIT)
    .exec();
  if (docs.length === 0) return [];

  const counts = await NotificationReceipt.aggregate<{ _id: Types.ObjectId; n: number }>([
    { $match: { notificationId: { $in: docs.map((d) => d._id) } } },
    { $group: { _id: '$notificationId', n: { $sum: 1 } } },
  ]).exec();
  const readCountById = new Map(counts.map((c) => [c._id.toHexString(), c.n]));

  return docs.map((doc) => toAdminDto(doc, readCountById.get(doc.id as string) ?? 0));
}

export type RetractResult = { ok: true } | { ok: false; reason: 'NOT_FOUND' };

/**
 * Soft-deletes a notification so it leaves every feed. Receipts are kept —
 * they are history. Idempotent on an already-retracted row is NOT offered:
 * retracting twice is NOT_FOUND the second time, exactly like an id that
 * never existed, so the admin client cannot tell the two apart (nor needs to).
 */
export async function retractNotification(
  notificationId: string,
  actorUserId: string
): Promise<RetractResult> {
  const doc = await Notification.findOneAndUpdate(
    { _id: new Types.ObjectId(notificationId), deletedAt: null },
    { $set: { deletedAt: new Date() } },
    { new: true }
  ).exec();
  if (!doc) return { ok: false, reason: 'NOT_FOUND' };

  track(AnalyticsEvent.NOTIFICATION_RETRACTED, {
    actor_id_hash: hashIdentifier(actorUserId),
    kind: doc.kind,
    audience: doc.audienceType,
  });
  return { ok: true };
}

function toAdminDto(doc: INotification, readCount: number): AdminNotificationDto {
  return {
    id: doc.id as string,
    kind: doc.kind,
    title: doc.title,
    message: doc.message,
    detail: doc.detail ?? null,
    action: doc.action ? { label: doc.action.label, url: doc.action.url } : null,
    audience:
      doc.audienceType === 'USERS'
        ? { type: 'USERS', userIds: doc.audienceUserIds.map((id) => id.toHexString()) }
        : { type: 'ALL' },
    createdAt: doc.createdAt.toISOString(),
    expiresAt: doc.expiresAt ? doc.expiresAt.toISOString() : null,
    readCount,
  };
}
