// src/models/ReminderLog.ts
//
// One row per (catalog, milestone, period, channel): the record that a
// lifecycle reminder went out (RECAPTURE_SUBSCRIPTION_PLAN.md §10). The
// unique index IS the dedupe — the sweep reserves the row first and only then
// writes the notification, so two worker instances scanning the same minute
// send one reminder, not two.
//
// Stage 5 writes the IN_APP channel only (E14). SMS and WhatsApp are Stage 6
// and will write the same rows with a different `channel`; nothing here needs
// to change for them.
import { Schema, model, Document, Types } from 'mongoose';

/** The four moments an owner is reminded at, in period order. */
export const REMINDER_MILESTONES = [
  'T_MINUS_7D',
  'T_MINUS_1D',
  'GRACE_STARTED',
  'GRACE_MIDPOINT',
] as const;
export type ReminderMilestone = (typeof REMINDER_MILESTONES)[number];

export const REMINDER_CHANNELS = ['IN_APP', 'SMS', 'WHATSAPP'] as const;
export type ReminderChannel = (typeof REMINDER_CHANNELS)[number];

export interface IReminderLog extends Document {
  catalogId: Types.ObjectId;
  milestone: ReminderMilestone;
  /**
   * The period the milestone is about. Part of the key so a renewed
   * subscription gets its reminders again next period — the same milestone
   * for a different `periodEnd` is a different reminder.
   */
  periodEnd: Date;
  channel: ReminderChannel;
  sentAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const ReminderLogSchema = new Schema<IReminderLog>(
  {
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    milestone: { type: String, enum: REMINDER_MILESTONES, required: true },
    periodEnd: { type: Date, required: true },
    channel: { type: String, enum: REMINDER_CHANNELS, required: true },
    sentAt: { type: Date, required: true },
  },
  { timestamps: true }
);

// The dedupe key. A concurrent second sweep gets E11000 here and sends nothing.
ReminderLogSchema.index(
  { catalogId: 1, milestone: 1, periodEnd: 1, channel: 1 },
  { unique: true }
);

export const ReminderLog = model<IReminderLog>('ReminderLog', ReminderLogSchema);
