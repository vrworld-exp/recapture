// src/modules/ai/provider.ts
//
// The AI provider behind menu import and dish descriptions (more-customization
// Stage 13; Q7 answered 2026-09-30: Claude, ₹2,000/month).
//
// ONE INTERFACE, ONE REAL IMPLEMENTATION, AND A SEAM. Services call
// `getAiProvider()`; tests install a fake with `setAiProvider()` so CI never
// makes a network call. The real provider is Claude through the official SDK
// with STRUCTURED OUTPUTS (`betaZodOutputFormat`): the API constrains the reply
// to the schema, and the caller still re-validates and sanitises it — model
// output is never trusted as-is.
//
// REFUSAL FALLBACK: requests carry `fallbacks: 'default'` (beta
// `server-side-fallback-2026-07-01`), so a safety-classifier false positive on
// an ordinary menu is re-run server-side instead of failing the import.
import Anthropic from '@anthropic-ai/sdk';
import { betaZodOutputFormat } from '@anthropic-ai/sdk/helpers/beta/zod';
import * as z from 'zod/v4';

import { env } from '@/config/env';
import { assertBudget, recordUsage, type AiTokenUsage } from '@/modules/ai/budget';

// ── Schemas the model must answer in ───────────────────────────────────────
// Kept simple on purpose (nullable, no numeric bounds): the API enforces the
// shape, and menuImportSanitize.ts enforces the sense.

export const ExtractedMenuSchema = z.object({
  currency: z.string(),
  categories: z.array(
    z.object({
      name: z.string(),
      items: z.array(
        z.object({
          name: z.string(),
          description: z.string().nullable(),
          price: z.number().nullable(),
          variants: z.array(z.object({ label: z.string(), price: z.number() })),
          foodType: z.enum(['VEG', 'NON_VEG', 'NONE']),
          confidence: z.number(),
        })
      ),
    })
  ),
});
export type ExtractedMenuRaw = z.infer<typeof ExtractedMenuSchema>;

export const DescriptionOptionsSchema = z.object({
  dishes: z.array(z.object({ id: z.string(), options: z.array(z.string()) })),
});
export type DescriptionOptionsRaw = z.infer<typeof DescriptionOptionsSchema>;

// ── Interface ──────────────────────────────────────────────────────────────

export interface MenuPage {
  /** `image/jpeg` | `image/png` | `image/webp` | `application/pdf`. */
  mediaType: string;
  base64: string;
}

export interface AiResult<T> {
  value: T;
  costInr: number;
}

export interface AiProvider {
  /** One photo or PDF of a printed menu → its categories and dishes. */
  extractMenu(page: MenuPage): Promise<AiResult<ExtractedMenuRaw>>;
  /** Short dish descriptions: up to `perDish` options for each dish. */
  describeDishes(prompt: string): Promise<AiResult<DescriptionOptionsRaw>>;
}

/** Thrown when the model declined or its answer did not fit the schema. */
export class AiOutputError extends Error {
  constructor(
    public readonly code: 'AI_REFUSED' | 'AI_TRUNCATED' | 'AI_UNPARSEABLE',
    message: string
  ) {
    super(message);
    this.name = 'AiOutputError';
  }
}

export const isAiConfigured = (): boolean => Boolean(env.AI_API_KEY);

// ── Claude ─────────────────────────────────────────────────────────────────

const EXTRACT_SYSTEM = `You read photos of printed Indian restaurant menus and return every dish as structured data.

Rules:
- Copy dish and section names exactly as printed (keep the restaurant's spelling). Do not invent dishes, sections, prices or descriptions.
- price: the single price in rupees as a number (no ₹, no commas). If a dish has two or more prices (Half/Full, Regular/Large, 6 pcs/12 pcs), put them in variants with their labels and set price to the first one.
- description: only if one is printed under the dish; otherwise null.
- foodType: VEG or NON_VEG only when the menu marks it (green/red dot, a Veg/Non-veg section) or the dish name makes it unambiguous (e.g. chicken, mutton, fish, egg = NON_VEG; paneer, dal = VEG). Otherwise NONE.
- confidence: 0 to 1 — how sure you are of that dish's name and price as read. Use below 0.7 for blurry, cut-off or handwritten entries.
- Dishes printed without a section heading go in a section named "Menu".
- Ignore taxes/service-charge notes, phone numbers, addresses and offers text.
- currency: "INR" unless the menu clearly uses another currency.`;

class ClaudeProvider implements AiProvider {
  private readonly client: Anthropic;

  constructor(apiKey: string) {
    this.client = new Anthropic({ apiKey });
  }

  async extractMenu(page: MenuPage): Promise<AiResult<ExtractedMenuRaw>> {
    await assertBudget();
    const source =
      page.mediaType === 'application/pdf'
        ? ({
            type: 'document',
            source: { type: 'base64', media_type: 'application/pdf', data: page.base64 },
          } as const)
        : ({
            type: 'image',
            source: {
              type: 'base64',
              media_type: page.mediaType as 'image/jpeg' | 'image/png' | 'image/webp',
              data: page.base64,
            },
          } as const);

    const response = await this.client.beta.messages.parse({
      model: env.AI_MODEL,
      max_tokens: 16000,
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      // Reading a menu is mostly careful transcription: medium effort is the
      // quality/cost balance for a ₹2,000/month budget.
      output_config: { effort: 'medium', format: betaZodOutputFormat(ExtractedMenuSchema) },
      system: EXTRACT_SYSTEM,
      messages: [
        {
          role: 'user',
          content: [source, { type: 'text', text: 'Extract every dish on this menu page.' }],
        },
      ],
    });
    const cost = await recordUsage('menu_import', response.model, response.usage as AiTokenUsage);
    return { value: this.parsed(response, ExtractedMenuSchema), costInr: cost };
  }

  async describeDishes(prompt: string): Promise<AiResult<DescriptionOptionsRaw>> {
    await assertBudget();
    const response = await this.client.beta.messages.parse({
      model: env.AI_MODEL,
      max_tokens: 16000,
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      // Two appetising sentences do not need deep reasoning.
      output_config: { effort: 'low', format: betaZodOutputFormat(DescriptionOptionsSchema) },
      messages: [{ role: 'user', content: prompt }],
    });
    const cost = await recordUsage('description', response.model, response.usage as AiTokenUsage);
    return { value: this.parsed(response, DescriptionOptionsSchema), costInr: cost };
  }

  private parsed<T>(
    response: { stop_reason: string | null; parsed_output?: unknown },
    schema: z.ZodType<T>
  ): T {
    if (response.stop_reason === 'refusal') {
      throw new AiOutputError('AI_REFUSED', 'The AI declined this request.');
    }
    if (response.stop_reason === 'max_tokens') {
      throw new AiOutputError('AI_TRUNCATED', 'The page had more than the AI could read at once.');
    }
    const check = schema.safeParse(response.parsed_output);
    if (!check.success) throw new AiOutputError('AI_UNPARSEABLE', 'The AI answer was not usable.');
    return check.data;
  }
}

// ── Seam ───────────────────────────────────────────────────────────────────

let override: AiProvider | null = null;
let real: AiProvider | null = null;

/** Test seam — install a fake; `null` restores the real one. */
export function setAiProvider(provider: AiProvider | null): void {
  override = provider;
}

/** The provider, or null when AI is not configured (every AI feature is then off). */
export function getAiProvider(): AiProvider | null {
  if (override) return override;
  if (!env.AI_API_KEY) return null;
  real ??= new ClaudeProvider(env.AI_API_KEY);
  return real;
}
