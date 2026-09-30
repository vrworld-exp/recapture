// src/modules/ai/budget.ts
//
// The monthly AI budget (decided 2026-09-30: ₹2,000 across every restaurant).
// Checked BEFORE every call and charged AFTER it from the response's own token
// counts. The check can let the last call of a month run a little over the cap —
// it cannot know a call's cost in advance — but never a second one.
import { env } from '@/config/env';
import { AiUsage } from '@/models/AiUsage';

/** USD per million tokens, from Anthropic's price list. Unknown models bill as Opus. */
const PRICES: Record<string, { input: number; output: number }> = {
  'claude-opus-5-5': { input: 4, output: 20 },
  'claude-sonnet-5-5': { input: 2, output: 10 },
  'claude-haiku-4-5': { input: 1, output: 5 },
};
const FALLBACK_PRICE = { input: 5, output: 25 };

export interface AiTokenUsage {
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens?: number | null;
  cache_read_input_tokens?: number | null;
}

/** INR cost of one response. Cache writes bill at 1.25×, cache reads at 0.1× input. */
export function costInr(modelId: string, usage: AiTokenUsage): number {
  const p = PRICES[modelId] ?? FALLBACK_PRICE;
  const input =
    usage.input_tokens +
    1.25 * (usage.cache_creation_input_tokens ?? 0) +
    0.1 * (usage.cache_read_input_tokens ?? 0);
  const usd = (input * p.input + usage.output_tokens * p.output) / 1_000_000;
  return Math.round(usd * env.AI_USD_TO_INR * 100) / 100;
}

/** `YYYY-MM` in Asia/Kolkata. */
export function currentMonth(now = new Date()): string {
  const ist = new Date(now.getTime() + 5.5 * 60 * 60 * 1000);
  return ist.toISOString().slice(0, 7);
}

export class AiBudgetExceededError extends Error {
  constructor() {
    super('The monthly AI budget is used up');
    this.name = 'AiBudgetExceededError';
  }
}

export async function spentThisMonth(now = new Date()): Promise<number> {
  const row = await AiUsage.findOne({ month: currentMonth(now) })
    .lean()
    .exec();
  return row?.costInr ?? 0;
}

/** Throws AiBudgetExceededError when this month's spend has reached the cap. */
export async function assertBudget(now = new Date()): Promise<void> {
  if ((await spentThisMonth(now)) >= env.AI_MONTHLY_BUDGET_INR) throw new AiBudgetExceededError();
}

/** Adds one response's cost to the month. Returns that cost in INR. */
export async function recordUsage(
  purpose: string,
  modelId: string,
  usage: AiTokenUsage,
  now = new Date()
): Promise<number> {
  const cost = costInr(modelId, usage);
  await AiUsage.updateOne(
    { month: currentMonth(now) },
    {
      $inc: {
        costInr: cost,
        inputTokens: usage.input_tokens,
        outputTokens: usage.output_tokens,
        calls: 1,
        [`byPurpose.${purpose}`]: cost,
      },
    },
    { upsert: true }
  ).exec();
  return cost;
}
