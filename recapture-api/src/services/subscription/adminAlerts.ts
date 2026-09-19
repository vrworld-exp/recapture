// src/services/subscription/adminAlerts.ts
//
// "Something about money needs a human": one in-app notification to every
// ADMIN user, plus a console line so it also lands in the logs. Used by the
// webhook (amount mismatch, unknown order, orphan payment, external refund,
// chargeback), the reconciler (webhooks silent) and, later, the entitlement
// job (Stage 5).
//
// NEVER THROWS. Every caller is on a path that must still answer 200 to
// Razorpay or finish a sweep — an alert that failed to send is logged, not
// raised. Addressed as a `USERS` list, never `audienceType: 'ALL'`: a revenue
// anomaly is not a broadcast.
import { Types } from 'mongoose';

import { Notification } from '@/models/Notification';
import { User } from '@/models/User';
import { track, AnalyticsEvent } from '@/utils/analytics';

export type AdminAlertKind =
  | 'UNKNOWN_ORDER'
  | 'AMOUNT_MISMATCH'
  | 'ORPHAN_PAYMENT'
  | 'DUPLICATE_SUSPECTED'
  | 'REFUND_FAILED'
  | 'EXTERNAL_REFUND'
  | 'WEBHOOKS_SILENT'
  | 'DISPUTE'
  | 'ENTITLEMENT_FAILED';

export interface AdminAlertInput {
  kind: AdminAlertKind;
  title: string;
  message: string;
  /** Opaque catalog id, when the alert is about one catalog. */
  catalogId?: Types.ObjectId | string;
  /** Long-form context behind the client's "Details" button. Ids and amounts only. */
  detail?: string;
}

/** Notification.title is capped at 80 chars and message at 500 — clip, never reject. */
function clip(value: string, max: number): string {
  return value.length <= max ? value : `${value.slice(0, max - 1)}…`;
}

/**
 * Fans the alert out. Resolves to the number of admins addressed (0 when
 * there are none, or when the write failed).
 */
export async function alertAdmins(input: AdminAlertInput): Promise<number> {
  const catalogRef = input.catalogId ? ` catalog=${String(input.catalogId)}` : '';
  console.error(`[subscription-alert] ${input.kind}${catalogRef}: ${input.message}`);

  try {
    const admins = await User.find({ role: 'ADMIN' }).select({ _id: 1 }).lean().exec();
    if (admins.length === 0) {
      console.error('[subscription-alert] no ADMIN users to notify');
      return 0;
    }
    await Notification.create({
      kind: 'SYSTEM',
      title: clip(input.title, 80),
      message: clip(input.message, 500),
      ...(input.detail ? { detail: clip(input.detail, 4000) } : {}),
      ...(input.catalogId
        ? {
            action: {
              label: 'Open subscription',
              url: `/admin/subscriptions/${String(input.catalogId)}`,
            },
          }
        : {}),
      audienceType: 'USERS',
      audienceUserIds: admins.map((a) => a._id),
      deletedAt: null,
    });
    track(AnalyticsEvent.ADMIN_ALERT_SENT, { kind: input.kind, recipients: admins.length });
    return admins.length;
  } catch (err) {
    const message = err instanceof Error ? err.message : 'unknown error';
    console.error(`[subscription-alert] failed to notify admins (${message})`);
    return 0;
  }
}
