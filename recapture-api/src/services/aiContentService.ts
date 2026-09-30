// src/services/aiContentService.ts
//
// AI dish descriptions and photo enhancement (more-customization Stage 13.2, 13.3).
//
// DESCRIPTIONS ARE SUGGESTIONS, NEVER SAVED HERE. The owner (or rep) picks one,
// edits it, and saves through the ordinary product update — so an AI sentence
// reaches the menu only after a human chose it, and it goes live on Publish.
//
// PHOTO ENHANCEMENT IS DETERMINISTIC (sharp, no AI): upright, auto-levels, a
// little warmth and saturation, a 4:3 smart crop. The ORIGINAL is untouched;
// the enhanced copy is a new staged key in the same slot, and the editor shows
// both and commits whichever the owner picks.
import { randomUUID } from 'node:crypto';

import sharp from 'sharp';
import { Types } from 'mongoose';

import { BUCKET_ARTIFACTS, CLOUDFRONT_BASE } from '@/config/s3';
import type { ICatalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import { AiBudgetExceededError } from '@/modules/ai/budget';
import { AiOutputError, getAiProvider } from '@/modules/ai/provider';
import { getObjectBytes, putObjectBytes } from '@/services/s3ObjectStore';
import { buildProductImageKey, parseProductImageKey } from '@/utils/productImageKeys';
import { s3EnvPrefix } from '@/utils/s3Keys';

export const AI_TONES = ['casual', 'premium', 'fun'] as const;
export type AiTone = (typeof AI_TONES)[number];

export const DESCRIPTION_MAX = 160;
export const MAX_DISHES_PER_REQUEST = 40;

type CatalogRef = Pick<ICatalog, 'name'> & { _id: Types.ObjectId; aiTone?: AiTone };

const TONE_TEXT: Record<AiTone, string> = {
  casual: 'warm and friendly, like a neighbourhood favourite',
  premium: 'refined and elegant, like a fine-dining menu',
  fun: 'playful and energetic, with a light touch of humour',
};

const LANGUAGE_NAMES: Record<string, string> = {
  en: 'Indian English',
  hi: 'Hindi (Devanagari script)',
  mr: 'Marathi',
  ta: 'Tamil',
  te: 'Telugu',
  kn: 'Kannada',
  ml: 'Malayalam',
  bn: 'Bengali',
  gu: 'Gujarati',
  pa: 'Punjabi',
};

export type AiContentRejection = 'AI_NOT_CONFIGURED' | 'AI_BUDGET' | 'AI_FAILED' | 'NOT_FOUND';

/** Builds the prompt: the guardrails are the product rules, so they live here. */
export function descriptionPrompt(
  restaurant: string,
  tone: AiTone,
  language: string,
  perDish: number,
  dishes: { id: string; name: string; category?: string; foodType?: string; tags?: string[] }[]
): string {
  const list = dishes
    .map((d) =>
      JSON.stringify({
        id: d.id,
        name: d.name.replace(/_/g, ' '),
        section: d.category ?? null,
        veg: d.foodType === 'VEG' ? true : d.foodType === 'NON_VEG' ? false : null,
        tags: d.tags ?? [],
      })
    )
    .join('\n');
  return `Write menu descriptions for dishes at "${restaurant}", an Indian restaurant.

For each dish below write ${perDish} different option(s). Each option: one or two short, appetising sentences, at most ${DESCRIPTION_MAX} characters, in ${LANGUAGE_NAMES[language] ?? 'Indian English'}. Tone: ${TONE_TEXT[tone]}.

Rules:
- Only describe what the dish name, section and tags make clear. Do not invent ingredients, sides or portion sizes; never write "may include".
- No health or nutrition claims (healthy, low-fat, good for digestion, etc.).
- No prices, discounts, or superlatives about the restaurant ("best in town").
- If veg is false, never call the dish vegetarian; if veg is true, never mention meat, fish or egg.

Return every dish by its id.

Dishes (one JSON object per line):
${list}`;
}

const cleanOption = (s: string): string =>
  s
    .replace(/\s+/g, ' ')
    .replace(/^["“]|["”]$/g, '')
    .trim()
    .slice(0, DESCRIPTION_MAX);

/** Description options for up to 40 of the catalog's dishes. Nothing is saved. */
export async function suggestDescriptions(
  catalog: CatalogRef,
  productIds: string[],
  opts: { perDish: number; language?: string }
): Promise<
  | { outcome: 'REJECTED'; code: AiContentRejection }
  | { outcome: 'OK'; suggestions: { productId: string; options: string[] }[]; costInr: number }
> {
  const provider = getAiProvider();
  if (!provider) return { outcome: 'REJECTED', code: 'AI_NOT_CONFIGURED' };
  const ids = productIds
    .filter((id) => Types.ObjectId.isValid(id))
    .slice(0, MAX_DISHES_PER_REQUEST);
  const products = await CatalogProduct.find({
    _id: { $in: ids.map((id) => new Types.ObjectId(id)) },
    catalogId: catalog._id,
    deletedAt: null,
  })
    .select({ _id: 1, name: 1, categoryId: 1, foodType: 1, tags: 1 })
    .lean<
      {
        _id: Types.ObjectId;
        name: string;
        categoryId?: Types.ObjectId;
        foodType?: string;
        tags?: string[];
      }[]
    >()
    .exec();
  if (products.length === 0) return { outcome: 'REJECTED', code: 'NOT_FOUND' };
  const categories = await CatalogCategory.find({
    _id: { $in: products.map((p) => p.categoryId).filter(Boolean) },
  })
    .select({ _id: 1, name: 1 })
    .lean<{ _id: Types.ObjectId; name: string }[]>()
    .exec();
  const categoryName = new Map(categories.map((c) => [String(c._id), c.name]));

  const perDish = Math.min(3, Math.max(1, opts.perDish));
  const prompt = descriptionPrompt(
    catalog.name.replace(/_/g, ' '),
    catalog.aiTone ?? 'casual',
    opts.language ?? 'en',
    perDish,
    products.map((p) => ({
      id: String(p._id),
      name: p.name,
      category: p.categoryId ? categoryName.get(String(p.categoryId)) : undefined,
      foodType: p.foodType,
      tags: p.tags,
    }))
  );

  try {
    const { value, costInr } = await provider.describeDishes(prompt);
    const known = new Set(products.map((p) => String(p._id)));
    const suggestions = value.dishes
      .filter((d) => known.has(d.id))
      .map((d) => ({
        productId: d.id,
        options: [...new Set(d.options.map(cleanOption).filter((o) => o.length >= 10))].slice(
          0,
          perDish
        ),
      }))
      .filter((s) => s.options.length > 0);
    return { outcome: 'OK', suggestions, costInr };
  } catch (err) {
    if (err instanceof AiBudgetExceededError) return { outcome: 'REJECTED', code: 'AI_BUDGET' };
    if (err instanceof AiOutputError) return { outcome: 'REJECTED', code: 'AI_FAILED' };
    throw err;
  }
}

// ── Photo enhancement (13.3) ───────────────────────────────────────────────

export type EnhanceRejection = 'INVALID_KEY' | 'FORBIDDEN' | 'NOT_FOUND' | 'UNREADABLE';

/**
 * A 4:3, auto-levelled copy of a product photo, as a NEW staged key in the same
 * slot. The owner commits it (or the original) through the ordinary product
 * update, which runs the usual key checks.
 */
export async function enhanceProductImage(
  catalogId: Types.ObjectId,
  productId: string
): Promise<
  { outcome: 'REJECTED'; code: EnhanceRejection } | { outcome: 'OK'; key: string; url: string }
> {
  if (!Types.ObjectId.isValid(productId)) return { outcome: 'REJECTED', code: 'NOT_FOUND' };
  const product = await CatalogProduct.findOne({
    _id: new Types.ObjectId(productId),
    catalogId,
    deletedAt: null,
  })
    .select({ assets: 1 })
    .lean<{ assets?: { imageKey?: string } }>()
    .exec();
  const imageKey = product?.assets?.imageKey;
  if (!imageKey) return { outcome: 'REJECTED', code: 'NOT_FOUND' };

  const parsed = parseProductImageKey(imageKey);
  if (!parsed.ok || parsed.value.env !== s3EnvPrefix()) {
    return { outcome: 'REJECTED', code: 'INVALID_KEY' };
  }
  if (parsed.value.catalogId !== catalogId.toHexString()) {
    return { outcome: 'REJECTED', code: 'FORBIDDEN' };
  }
  const got = await getObjectBytes(BUCKET_ARTIFACTS, imageKey);
  if (got.outcome === 'absent') return { outcome: 'REJECTED', code: 'NOT_FOUND' };

  let out: Buffer;
  try {
    out = await sharp(got.body)
      .rotate()
      .resize({ width: 1600, height: 1200, fit: 'cover', position: sharp.strategy.attention })
      .normalise()
      .modulate({ brightness: 1.03, saturation: 1.1 })
      .sharpen({ sigma: 0.8 })
      .jpeg({ quality: 88, mozjpeg: true })
      .toBuffer();
  } catch {
    return { outcome: 'REJECTED', code: 'UNREADABLE' };
  }
  const key = buildProductImageKey(
    parsed.value.catalogId,
    parsed.value.slotId,
    randomUUID(),
    'jpg'
  );
  await putObjectBytes(BUCKET_ARTIFACTS, key, out, 'image/jpeg');
  return { outcome: 'OK', key, url: `${CLOUDFRONT_BASE}/${key}` };
}
