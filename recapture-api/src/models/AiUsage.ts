// src/models/AiUsage.ts
//
// One row per calendar month (Asia/Kolkata): what the AI features (more-
// customization Stage 13) spent, across every restaurant. The monthly budget
// check reads it before every call and the call adds to it after — a single
// `$inc` upsert, so two workers never lose each other's spend.
import { Schema, model, Document } from 'mongoose';

export interface IAiUsage extends Document {
  /** `YYYY-MM`, Asia/Kolkata. */
  month: string;
  costInr: number;
  inputTokens: number;
  outputTokens: number;
  calls: number;
  /** Per purpose (`menu_import`, `description`, …) — for "what is eating the budget". */
  byPurpose: Record<string, number>;
  createdAt: Date;
  updatedAt: Date;
}

const AiUsageSchema = new Schema<IAiUsage>(
  {
    month: { type: String, required: true, match: /^\d{4}-\d{2}$/ },
    costInr: { type: Number, default: 0 },
    inputTokens: { type: Number, default: 0 },
    outputTokens: { type: Number, default: 0 },
    calls: { type: Number, default: 0 },
    byPurpose: { type: Schema.Types.Mixed, default: {} },
  },
  { timestamps: true, minimize: false }
);

AiUsageSchema.index({ month: 1 }, { unique: true });

export const AiUsage = model<IAiUsage>('AiUsage', AiUsageSchema);
