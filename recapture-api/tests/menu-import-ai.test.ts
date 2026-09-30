// tests/menu-import-ai.test.ts
//
// more-customization Stage 13 — menu import + AI content. The AI provider is a
// FAKE in every test (setAiProvider) and S3 is mocked: no network in CI.
//
//   • messy model output is cleaned (missing prices, strings as numbers, empty
//     sections, duplicates, out-of-range prices);
//   • the worker builds one draft from every page, skips a declined page;
//   • apply creates the right rows with ONE draftRevision bump, and turns name
//     matches into price updates instead of duplicates;
//   • undo removes only rows nobody edited;
//   • the monthly budget is charged from token usage and enforced;
//   • descriptions keep only this catalog's dishes and cap the length.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

vi.mock('@/services/s3ObjectStore', async (orig) => ({
  ...(await orig<typeof import('@/services/s3ObjectStore')>()),
  getObjectBytes: vi.fn(async () => ({
    outcome: 'ok',
    body: Buffer.from('%PDF-1.4 fake'),
    contentType: 'application/pdf',
  })),
  headObject: vi.fn(async () => ({
    outcome: 'present',
    contentLength: 1000,
    contentType: 'application/pdf',
  })),
  deleteObject: vi.fn(async () => undefined),
  presignObjectPutUrl: vi.fn(async () => 'https://s3.test/put'),
}));

import { AiUsage } from '@/models/AiUsage';
import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import { Job } from '@/models/Job';
import { MenuImport } from '@/models/MenuImport';
import { AiBudgetExceededError, assertBudget, costInr, recordUsage } from '@/modules/ai/budget';
import {
  AiOutputError,
  setAiProvider,
  type AiProvider,
  type ExtractedMenuRaw,
} from '@/modules/ai/provider';
import { descriptionPrompt, suggestDescriptions } from '@/services/aiContentService';
import {
  applyImport,
  createImport,
  getImport,
  processImport,
  startImport,
  undoImport,
} from '@/services/menuImport/menuImportService';
import { cleanPrice, sanitizeMenu } from '@/services/menuImport/sanitize';

// ── sanitize (pure) ─────────────────────────────────────────────────────────

describe('sanitizeMenu', () => {
  it('cleans messy model output', () => {
    const draft = sanitizeMenu([
      {
        currency: 'INR',
        categories: [
          {
            name: ' Starters ',
            items: [
              {
                name: 'Paneer Tikka',
                price: '₹ 1,250',
                variants: [],
                foodType: 'VEG',
                confidence: 0.95,
              },
              { name: '', price: 100 },
              { name: 'Mystery', price: 250000, confidence: 0.9 },
              {
                name: 'Dal',
                price: null,
                variants: [
                  { label: 'Half', price: 120 },
                  { label: 'Full', price: 220 },
                ],
              },
            ],
          },
          { name: 'Empty', items: [] },
        ],
      },
      {
        categories: [
          {
            name: 'starters',
            items: [
              { name: 'Veg Soup', price: 90 },
              { name: 'PANEER  TIKKA', price: 1 },
            ],
          },
        ],
      },
    ]);
    expect(draft.currency).toBe('INR');
    expect(draft.categories).toHaveLength(1);
    const [starters] = draft.categories;
    expect(starters.items.map((i) => i.name)).toEqual([
      'Paneer Tikka',
      'Mystery',
      'Dal',
      'Veg Soup',
    ]);
    expect(starters.items[0].price).toBe(1250);
    // Out of range → no price, and flagged for a second look.
    expect(starters.items[1].price).toBeNull();
    expect(starters.items[1].confidence).toBeLessThan(0.7);
    // Variants: price is the first one.
    expect(starters.items[2]).toMatchObject({
      price: 120,
      variants: [{ label: 'Half' }, { label: 'Full' }],
    });
    expect(starters.items[3].sourcePage).toBe(2);
    expect(draft.duplicatesDropped).toEqual(['PANEER TIKKA']);
  });

  it('parses prices defensively', () => {
    expect(cleanPrice('250/-')).toBe(250);
    expect(cleanPrice(0)).toBeNull();
    expect(cleanPrice('free')).toBeNull();
  });
});

// ── Budget ──────────────────────────────────────────────────────────────────

describe('AI budget', () => {
  it('prices a response from its token usage', () => {
    // 10k in × $4/M + 2k out × $20/M = $0.08 → ₹6.72 at 84.
    expect(costInr('claude-opus-5-5', { input_tokens: 10_000, output_tokens: 2_000 })).toBe(6.72);
  });
});

// ── With Mongo ──────────────────────────────────────────────────────────────

let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await AiUsage.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  setAiProvider(null);
  await Promise.all([
    AiUsage.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogProduct.deleteMany({}),
    MenuImport.deleteMany({}),
    Job.deleteMany({}),
  ]);
});

const page = (
  items: ExtractedMenuRaw['categories'][number]['items'],
  name = 'Starters'
): ExtractedMenuRaw => ({
  currency: 'INR',
  categories: [{ name, items }],
});
const item = (name: string, price: number | null) => ({
  name,
  description: null,
  price,
  variants: [],
  foodType: 'VEG' as const,
  confidence: 0.9,
});

function fakeProvider(pages: (ExtractedMenuRaw | Error)[]): AiProvider {
  let i = 0;
  return {
    extractMenu: vi.fn(async () => {
      const next = pages[i++];
      if (next instanceof Error) throw next;
      return { value: next, costInr: 5 };
    }),
    describeDishes: vi.fn(),
  };
}

async function seedCatalog() {
  const userId = new Types.ObjectId();
  const catalog = await Catalog.create({
    userId,
    name: 'Cafe',
    status: 'DRAFT',
    draftRevision: 0,
    publishedRevision: -1,
  });
  const main = await CatalogCategory.create({
    catalogId: catalog._id,
    userId,
    name: 'Main Course',
    position: 0,
  });
  await CatalogProduct.create({
    catalogId: catalog._id,
    userId,
    type: 'IMAGE_ONLY',
    name: 'Dal Makhani',
    price: 200,
    categoryId: main._id,
    position: 0,
  });
  return { catalog, userId };
}

async function readyImport(pages: (ExtractedMenuRaw | Error)[]) {
  const { catalog, userId } = await seedCatalog();
  setAiProvider(fakeProvider(pages));
  const created = await createImport(
    catalog,
    String(userId),
    pages.map(() => ({ contentType: 'application/pdf', size: 1000 }))
  );
  if (created.outcome !== 'OK') throw new Error(created.code);
  const started = await startImport(catalog, created.import.id);
  expect(started.outcome).toBe('OK');
  await processImport(created.import.id);
  return { catalog, importId: created.import.id };
}

describe('menu import', () => {
  it('reads every page into one draft, skipping a declined page, and matches existing dishes', async () => {
    const { catalog, importId } = await readyImport([
      page([item('Paneer Tikka', 250)]),
      new AiOutputError('AI_REFUSED', 'declined'),
      page([item('Dal Makhani', 220)], 'Main Course'),
    ]);
    const dto = (await getImport(catalog, importId))!;
    expect(dto.status).toBe('READY');
    expect(dto.pagesDone).toBe(3);
    expect(dto.costInr).toBe(10);
    expect(dto.error?.code).toBe('PAGES_SKIPPED');
    const dal = dto.draft!.categories[1].items[0];
    expect(dto.matches[dal.key]).toMatchObject({ name: 'Dal Makhani', price: 200 });
  });

  it('fails clearly when no page produced a dish', async () => {
    const { catalog, importId } = await readyImport([new AiOutputError('AI_UNPARSEABLE', 'x')]);
    expect((await getImport(catalog, importId))!.error?.code).toBe('NO_DISHES');
  });

  it('applies with one draft bump, updates matched prices, never duplicates', async () => {
    const { catalog, importId } = await readyImport([page([item('Paneer Tikka', 250)])]);
    const dal = await CatalogProduct.findOne({ name: 'Dal Makhani' }).lean();
    const result = await applyImport(catalog, importId, {
      categories: [
        {
          name: 'Starters',
          items: [
            { name: 'Paneer Tikka', price: 250, foodType: 'VEG' },
            {
              name: 'Chilli Paneer',
              price: 230,
              variants: [
                { label: 'Half', price: 130 },
                { label: 'Full', price: 230 },
              ],
            },
          ],
        },
        {
          name: 'main course',
          items: [
            { name: 'Dal Makhani', price: 220, updateProductId: String(dal!._id) },
            { name: 'dal makhani', price: 999 },
          ],
        },
      ],
    });
    if (result.outcome !== 'OK') throw new Error(result.code);
    expect(result.result).toEqual({ created: 2, updated: 1, skipped: 1, categoriesCreated: 1 });
    expect((await Catalog.findById(catalog._id).lean())!.draftRevision).toBe(1);
    expect((await CatalogProduct.findById(dal!._id).lean())!.price).toBe(220);
    const chilli = await CatalogProduct.findOne({ name: 'Chilli Paneer' }).lean();
    expect(chilli).toMatchObject({ type: 'IMAGE_ONLY', description: 'Half ₹130 · Full ₹230' });
    expect(chilli!.assets?.imageKey).toBeUndefined();
    // The existing "Main Course" section was reused, not duplicated.
    expect(await CatalogCategory.countDocuments({ catalogId: catalog._id, deletedAt: null })).toBe(
      2
    );
  });

  it('undo removes only what nobody edited, and restores untouched prices', async () => {
    const { catalog, importId } = await readyImport([page([item('Paneer Tikka', 250)])]);
    const dal = await CatalogProduct.findOne({ name: 'Dal Makhani' }).lean();
    await applyImport(catalog, importId, {
      categories: [
        {
          name: 'Starters',
          items: [
            { name: 'Paneer Tikka', price: 250 },
            { name: 'Veg Soup', price: 90 },
          ],
        },
        {
          name: 'Main Course',
          items: [{ name: 'Dal Makhani', price: 220, updateProductId: String(dal!._id) }],
        },
      ],
    });
    await CatalogProduct.updateOne({ name: 'Veg Soup' }, { $set: { price: 95 } });
    // A publish touching sync fields must not count as an edit.
    await CatalogProduct.updateOne({ name: 'Paneer Tikka' }, { $set: { syncStatus: 'SYNCED' } });

    const undo = await undoImport(catalog, importId);
    expect(undo).toEqual({ outcome: 'OK', removed: 1, kept: 1, pricesRestored: 1 });
    expect((await CatalogProduct.findOne({ name: 'Paneer Tikka' }).lean())!.deletedAt).toBeTruthy();
    expect((await CatalogProduct.findOne({ name: 'Veg Soup' }).lean())!.deletedAt).toBeFalsy();
    expect((await CatalogProduct.findById(dal!._id).lean())!.price).toBe(200);
    // Its section still holds the edited dish, so it stays.
    expect(await CatalogCategory.countDocuments({ name: 'Starters', deletedAt: null })).toBe(1);
  });

  it('caps imports at 5 per catalog per day', async () => {
    const { catalog, userId } = await seedCatalog();
    setAiProvider(fakeProvider([]));
    for (let i = 0; i < 5; i += 1) {
      expect(
        (await createImport(catalog, String(userId), [{ contentType: 'image/jpeg', size: 10 }]))
          .outcome
      ).toBe('OK');
    }
    expect(
      await createImport(catalog, String(userId), [{ contentType: 'image/jpeg', size: 10 }])
    ).toEqual({
      outcome: 'REJECTED',
      code: 'DAILY_LIMIT',
    });
  });

  it('is off when no AI provider is configured', async () => {
    const { catalog, userId } = await seedCatalog();
    expect(
      await createImport(catalog, String(userId), [{ contentType: 'image/jpeg', size: 10 }])
    ).toEqual({
      outcome: 'REJECTED',
      code: 'AI_NOT_CONFIGURED',
    });
  });
});

describe('monthly budget', () => {
  it('stops AI calls once the month has reached the cap', async () => {
    await recordUsage('menu_import', 'claude-opus-5-5', {
      input_tokens: 10_000_000,
      output_tokens: 1_000_000,
    });
    await expect(assertBudget()).rejects.toBeInstanceOf(AiBudgetExceededError);
  });
});

describe('AI descriptions', () => {
  it('keeps only this catalog’s dishes and caps the length', async () => {
    const { catalog } = await seedCatalog();
    const dal = await CatalogProduct.findOne({ name: 'Dal Makhani' }).lean();
    const long = 'Slow-cooked black lentils finished with butter and cream. '.repeat(5);
    setAiProvider({
      extractMenu: vi.fn(),
      describeDishes: vi.fn(async () => ({
        value: {
          dishes: [
            {
              id: String(dal!._id),
              options: [long, 'Creamy black lentils, slow-cooked overnight.', 'ok'],
            },
            {
              id: new Types.ObjectId().toHexString(),
              options: ['Not ours at all, should vanish.'],
            },
          ],
        },
        costInr: 1,
      })),
    });
    const result = await suggestDescriptions(catalog, [String(dal!._id)], { perDish: 3 });
    if (result.outcome !== 'OK') throw new Error(result.code);
    expect(result.suggestions).toHaveLength(1);
    expect(result.suggestions[0].options).toHaveLength(2);
    expect(result.suggestions[0].options[0].length).toBeLessThanOrEqual(160);
  });

  it('puts the guardrails in the prompt', () => {
    const prompt = descriptionPrompt('Cafe', 'premium', 'en', 3, [
      { id: 'a', name: 'Chicken_Tikka', foodType: 'NON_VEG' },
    ]);
    expect(prompt).toContain('No health or nutrition claims');
    expect(prompt).toContain('never write "may include"');
    expect(prompt).toContain('"name":"Chicken Tikka"');
    expect(prompt).toContain('"veg":false');
  });
});
