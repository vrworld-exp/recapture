// src/models/WeeklyReport.ts
//
// One row per (catalog, week): the owner's weekly value report as it was built
// (more-customization Stage 9). Stored rather than recomputed so the history
// screen shows what the owner was told, and so the Monday notification and the
// screen it opens can never disagree.
//
// The unique index IS the dedupe, the same pattern as ReminderLog: two worker
// instances building the same week get one row, and the loser reads the
// winner's.
import { Schema, model, Document, Types } from 'mongoose';

import type { WeeklyReportMetrics, WeeklyReportTip } from './types/weeklyReport.types';

export interface IWeeklyReport extends Document {
  catalogId: Types.ObjectId;
  /** The Monday the week starts on, `YYYY-MM-DD` in Asia/Kolkata. */
  weekStart: string;
  metrics: WeeklyReportMetrics;
  tips: WeeklyReportTip[];
  /**
   * Whether the owner was sent the "N views last week" notification. False for
   * a quiet week (below WEEKLY_REPORT_MIN_VIEWS) — the report is still kept so
   * the history has no holes.
   */
  notified: boolean;
  createdAt: Date;
  updatedAt: Date;
}

const WeeklyReportSchema = new Schema<IWeeklyReport>(
  {
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    weekStart: { type: String, required: true, match: /^\d{4}-\d{2}-\d{2}$/ },
    // Mixed on purpose: the metrics are a read model written once by the
    // builder and never queried into, and a nested schema would only add a
    // second place to keep in step with weeklyReport.types.ts.
    metrics: { type: Schema.Types.Mixed, required: true },
    tips: { type: Schema.Types.Mixed, default: [] },
    notified: { type: Boolean, default: false },
  },
  { timestamps: true, minimize: false }
);

// The dedupe key, and the history screen's newest-first read.
WeeklyReportSchema.index({ catalogId: 1, weekStart: -1 }, { unique: true });
// The sweep's "which catalogs already have this week" read.
WeeklyReportSchema.index({ weekStart: 1 });

export const WeeklyReport = model<IWeeklyReport>('WeeklyReport', WeeklyReportSchema);
