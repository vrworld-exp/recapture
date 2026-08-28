// tests/catalog-publish-planner.test.ts
//
// The publish planner, driven as a table. NO database, NO network, NO mocks —
// that is the point of the planner being pure, and this file is the proof: it
// imports `planPublish` and calls it with plain objects.
//
// The load-bearing assertions here are the two that a bug in this file's
// subject would otherwise only reveal in production:
//
//   • DETERMINISM — the same snapshot planned twice must serialise identically,
//     because the run's entries, counts and the user's "7 of 10" all assume the
//     plan is a function of the data and not of Map/query ordering.
//
//   • NO SILENT SKIP — changing ANY field in PRODUCT_DIFF_FIELDS must produce
//     an UPDATE. A field the diff forgets reads back as "unchanged", and the
//     user's edit never reaches the public page while the app reports success.
import { describe, it, expect } from 'vitest';

import type { ProductPublishedSnapshot } from '@/models/types/catalog.types';
import {
  PRODUCT_DIFF_FIELDS,
  planPublish,
  planTotals,
  type ProductDiffField,
} from '@/services/catalog/publishPlanner';
import type {
  CatalogSnapshot,
  CatalogSnapshotCategory,
  CatalogSnapshotProduct,
  CatalogSnapshotRoot,
} from '@/services/catalog/publishSnapshot';

const T0 = new Date('2026-01-01T00:00:00.000Z');
const T1 = new Date('2026-01-02T00:00:00.000Z');

function root(overrides: Partial<CatalogSnapshotRoot> = {}): CatalogSnapshotRoot {
  return {
    id: 'cat0000000000000000000001',
    userId: 'usr0000000000000000000001',
    name: 'Blue Cafe',
    status: 'PUBLISHED',
    mirageRestaurantId: 'mr1',
    draftRevision: 5,
    publishedRevision: 5,
    ...overrides,
  };
}

function category(
  overrides: Partial<CatalogSnapshotCategory> & { id: string }
): CatalogSnapshotCategory {
  return {
    name: `Category ${overrides.id}`,
    position: 0,
    mirageCategoryId: `m-${overrides.id}`,
    syncStatus: 'SYNCED',
    updatedAt: T0,
    lastSyncedAt: T1,
    ...overrides,
  };
}

/** A fully-populated, fully-synced product: every diffed field has a value. */
const PUBLISHED: ProductPublishedSnapshot = {
  name: 'Chair',
  description: 'A chair',
  price: 100,
  type: 'THREE_D',
  categoryId: 'c1',
  mirageCategoryId: 'm-c1',
  position: 0,
  glbUrl: 'https://cdn.test/model.glb',
  usdzUrl: 'https://cdn.test/model.usdz',
  thumbnailUrl: 'https://cdn.test/preview.jpg',
  imageKey: 'prod/img.jpg',
};

function product(
  overrides: Partial<CatalogSnapshotProduct> & { id: string }
): CatalogSnapshotProduct {
  return {
    type: 'THREE_D',
    name: 'Chair',
    description: 'A chair',
    price: 100,
    categoryId: 'c1',
    position: 0,
    glbUrl: 'https://cdn.test/model.glb',
    usdzUrl: 'https://cdn.test/model.usdz',
    thumbnailUrl: 'https://cdn.test/preview.jpg',
    imageKey: 'prod/img.jpg',
    mirageItemId: 'mi-1',
    mirageCategoryIdAtSync: 'm-c1',
    syncStatus: 'SYNCED',
    publishedSnapshot: { ...PUBLISHED },
    ...overrides,
  };
}

function snapshot(parts: {
  catalog?: Partial<CatalogSnapshotRoot>;
  categories?: CatalogSnapshotCategory[];
  products?: CatalogSnapshotProduct[];
}): CatalogSnapshot {
  return {
    catalog: root(parts.catalog),
    categories: parts.categories ?? [category({ id: 'c1' })],
    products: parts.products ?? [],
    takenAt: T1,
  };
}

const stepFor = (
  plan: ReturnType<typeof planPublish>,
  target: string,
  targetId?: string
): { action: string; reason: string } | undefined =>
  plan.steps.find((s) => s.target === target && s.targetId === targetId);

// ── RESTAURANT ──────────────────────────────────────────────────────────────

describe('planPublish — restaurant', () => {
  it('plans CREATE when the catalog has no Mirage restaurant', () => {
    const plan = planPublish(snapshot({ catalog: { mirageRestaurantId: undefined } }), 'FULL');
    expect(plan.steps[0]).toMatchObject({
      target: 'RESTAURANT',
      action: 'CREATE',
      reason: 'NOT_PROVISIONED',
    });
  });

  it('plans UPDATE when the draft is ahead of the published revision', () => {
    const plan = planPublish(
      snapshot({ catalog: { draftRevision: 9, publishedRevision: 5 } }),
      'FULL'
    );
    expect(plan.steps[0]).toMatchObject({
      target: 'RESTAURANT',
      action: 'UPDATE',
      reason: 'DRAFT_AHEAD_OF_PUBLISHED',
    });
  });

  it('plans SKIP when nothing has changed since the last successful publish', () => {
    const plan = planPublish(snapshot({}), 'FULL');
    expect(plan.steps[0]).toMatchObject({ target: 'RESTAURANT', action: 'SKIP' });
  });

  it('omits the restaurant entirely on RETRY_FAILED once provisioned', () => {
    const plan = planPublish(snapshot({}), 'RETRY_FAILED');
    expect(plan.steps.some((s) => s.target === 'RESTAURANT')).toBe(false);
  });

  it('still plans a CREATE on RETRY_FAILED when provisioning never happened', () => {
    const plan = planPublish(
      snapshot({ catalog: { mirageRestaurantId: undefined } }),
      'RETRY_FAILED'
    );
    expect(plan.steps[0]).toMatchObject({ target: 'RESTAURANT', action: 'CREATE' });
  });
});

// ── CATEGORY ────────────────────────────────────────────────────────────────

describe('planPublish — categories', () => {
  it.each([
    ['CREATE', { mirageCategoryId: undefined }, 'NO_MIRAGE_ID'],
    ['UPDATE', { syncStatus: 'FAILED' as const }, 'PREVIOUS_ATTEMPT_FAILED'],
    ['UPDATE', { updatedAt: T1, lastSyncedAt: T0 }, 'EDITED_SINCE_SYNC'],
    ['UPDATE', { lastSyncedAt: undefined }, 'EDITED_SINCE_SYNC'],
    ['SKIP', {}, 'UP_TO_DATE'],
  ])('plans %s for %o', (action, overrides, reason) => {
    const plan = planPublish(
      snapshot({ categories: [category({ id: 'c1', ...overrides })] }),
      'FULL'
    );
    expect(stepFor(plan, 'CATEGORY', 'c1')).toMatchObject({ action, reason });
  });
});

// ── PRODUCT ─────────────────────────────────────────────────────────────────

describe('planPublish — products', () => {
  it('plans CREATE for a product with no Mirage item id', () => {
    const plan = planPublish(
      snapshot({ products: [product({ id: 'p1', mirageItemId: undefined })] }),
      'FULL'
    );
    expect(stepFor(plan, 'PRODUCT', 'p1')).toMatchObject({
      action: 'CREATE',
      reason: 'NO_MIRAGE_ID',
    });
  });

  it('plans SKIP for a product identical to its published snapshot', () => {
    const plan = planPublish(snapshot({ products: [product({ id: 'p1' })] }), 'FULL');
    expect(stepFor(plan, 'PRODUCT', 'p1')).toMatchObject({
      action: 'SKIP',
      reason: 'UP_TO_DATE',
    });
  });

  it('plans UPDATE when a mapping exists but no snapshot proves it matches', () => {
    const plan = planPublish(
      snapshot({ products: [product({ id: 'p1', publishedSnapshot: undefined })] }),
      'FULL'
    );
    expect(stepFor(plan, 'PRODUCT', 'p1')).toMatchObject({
      action: 'UPDATE',
      reason: 'NO_SNAPSHOT',
    });
  });

  it.each([
    ['archived', { archivedAt: T1 }, 'ARCHIVED'],
    ['soft-deleted', { deletedAt: T1 }, 'DELETED'],
  ])('plans DELETE for a %s product that Mirage still has', (_label, overrides, reason) => {
    const plan = planPublish(
      snapshot({ products: [product({ id: 'p1', ...overrides })] }),
      'FULL'
    );
    expect(stepFor(plan, 'PRODUCT', 'p1')).toMatchObject({ action: 'DELETE', reason });
  });

  it('emits NO step for a deleted product that was never published', () => {
    const plan = planPublish(
      snapshot({
        products: [product({ id: 'p1', deletedAt: T1, mirageItemId: undefined })],
      }),
      'FULL'
    );
    expect(stepFor(plan, 'PRODUCT', 'p1')).toBeUndefined();
  });

  it('plans UPDATE when Mirage holds the item under a different category', () => {
    const plan = planPublish(
      snapshot({
        categories: [category({ id: 'c1', mirageCategoryId: 'm-c1-recreated' })],
        products: [product({ id: 'p1', mirageCategoryIdAtSync: 'm-c1' })],
      }),
      'FULL'
    );
    expect(stepFor(plan, 'PRODUCT', 'p1')).toMatchObject({ reason: 'CATEGORY_REFILED' });
  });

  it('does NOT treat an unresolved category as a difference', () => {
    // An uncategorized product's Mirage bucket is minted by the executor, so the
    // planner cannot know its id. Reading "unknown" as "changed" would make
    // every uncategorized product publish on every run, forever.
    const plan = planPublish(
      snapshot({
        products: [
          product({
            id: 'p1',
            categoryId: null,
            mirageCategoryIdAtSync: 'm-uncategorized',
            publishedSnapshot: { ...PUBLISHED, categoryId: null },
          }),
        ],
      }),
      'FULL'
    );
    expect(stepFor(plan, 'PRODUCT', 'p1')).toMatchObject({ action: 'SKIP' });
  });
});

// ── The diff table ──────────────────────────────────────────────────────────

/**
 * One different-but-valid value per diffed field. Declared as a total Record so
 * adding a field to PRODUCT_DIFF_FIELDS without adding a case here does not
 * compile — the same guard the planner's own accessor table uses.
 */
const CHANGED_VALUES: Record<ProductDiffField, Partial<CatalogSnapshotProduct>> = {
  name: { name: 'Stool' },
  description: { description: 'A different chair' },
  price: { price: 250 },
  type: { type: 'IMAGE_ONLY' },
  categoryId: { categoryId: 'c2' },
  position: { position: 5 },
  glbUrl: { glbUrl: 'https://cdn.test/model-v2.glb' },
  usdzUrl: { usdzUrl: 'https://cdn.test/model-v2.usdz' },
  thumbnailUrl: { thumbnailUrl: 'https://cdn.test/preview-v2.jpg' },
  imageKey: { imageKey: 'prod/img-v2.jpg' },
};

describe('planPublish — the field diff misses nothing', () => {
  it.each(PRODUCT_DIFF_FIELDS.map((field) => [field] as const))(
    'detects a change to %s',
    (field) => {
      const plan = planPublish(
        snapshot({ products: [product({ id: 'p1', ...CHANGED_VALUES[field] })] }),
        'FULL'
      );
      const step = plan.steps.find((s) => s.targetId === 'p1');
      expect(step?.action).toBe('UPDATE');
      expect(step?.reason).toBe('FIELDS_CHANGED');
      expect(step?.changedFields).toContain(field);
    }
  );

  it('treats an absent value and a null value as the same, but not as zero', () => {
    const cleared = planPublish(
      snapshot({
        products: [
          product({
            id: 'p1',
            price: undefined,
            publishedSnapshot: { ...PUBLISHED, price: undefined },
          }),
        ],
      }),
      'FULL'
    );
    expect(stepFor(cleared, 'PRODUCT', 'p1')).toMatchObject({ action: 'SKIP' });

    const zeroed = planPublish(
      snapshot({
        products: [
          product({
            id: 'p1',
            price: 0,
            publishedSnapshot: { ...PUBLISHED, price: undefined },
          }),
        ],
      }),
      'FULL'
    );
    expect(stepFor(zeroed, 'PRODUCT', 'p1')).toMatchObject({ action: 'UPDATE' });
  });
});

// ── Ordering and determinism ────────────────────────────────────────────────

describe('planPublish — ordering and determinism', () => {
  const wide = (): CatalogSnapshot =>
    snapshot({
      catalog: { mirageRestaurantId: undefined },
      categories: [
        category({ id: 'cB', position: 1 }),
        category({ id: 'cA', position: 0 }),
        // Equal positions must still order deterministically — on id.
        category({ id: 'cD', position: 1 }),
      ],
      products: [
        product({ id: 'pZ', position: 2, mirageItemId: undefined }),
        product({ id: 'pA', position: 0, mirageItemId: undefined }),
        product({ id: 'pB', position: 0, mirageItemId: undefined }),
      ],
    });

  it('orders restaurant, then categories, then products', () => {
    const plan = planPublish(wide(), 'FULL');
    expect(plan.steps.map((s) => s.target)).toEqual([
      'RESTAURANT',
      'CATEGORY',
      'CATEGORY',
      'CATEGORY',
      'PRODUCT',
      'PRODUCT',
      'PRODUCT',
    ]);
    expect(plan.steps.filter((s) => s.target === 'CATEGORY').map((s) => s.targetId)).toEqual([
      'cA',
      'cB',
      'cD',
    ]);
    expect(plan.steps.filter((s) => s.target === 'PRODUCT').map((s) => s.targetId)).toEqual([
      'pA',
      'pB',
      'pZ',
    ]);
  });

  it('produces an identical plan from the same snapshot, twice', () => {
    const input = wide();
    const a = planPublish(input, 'FULL');
    const b = planPublish(input, 'FULL');
    expect(JSON.stringify(a)).toBe(JSON.stringify(b));
  });

  it('does not mutate the snapshot it was given', () => {
    const input = wide();
    const before = JSON.stringify(input);
    planPublish(input, 'FULL');
    expect(JSON.stringify(input)).toBe(before);
  });
});

// ── Modes ───────────────────────────────────────────────────────────────────

describe('planPublish — modes', () => {
  it('RETRY_FAILED plans only the failed rows', () => {
    const plan = planPublish(
      snapshot({
        products: [
          product({ id: 'pOk' }),
          product({ id: 'pBad', syncStatus: 'FAILED', mirageItemId: undefined }),
        ],
      }),
      'RETRY_FAILED'
    );
    expect(plan.steps.filter((s) => s.target === 'PRODUCT').map((s) => s.targetId)).toEqual([
      'pBad',
    ]);
  });

  it('RETRY_FAILED pulls in a category a retried product still needs', () => {
    const plan = planPublish(
      snapshot({
        categories: [category({ id: 'c1', mirageCategoryId: undefined })],
        products: [
          product({ id: 'pOk' }),
          product({ id: 'pBad', syncStatus: 'FAILED', mirageItemId: undefined }),
        ],
      }),
      'RETRY_FAILED'
    );
    expect(plan.steps.map((s) => [s.target, s.targetId])).toEqual([
      ['CATEGORY', 'c1'],
      ['PRODUCT', 'pBad'],
    ]);
  });

  it('UNPUBLISH plans DELETE for published items and touches nothing else', () => {
    const plan = planPublish(
      snapshot({
        products: [product({ id: 'p1' }), product({ id: 'p2', mirageItemId: undefined })],
      }),
      'UNPUBLISH'
    );
    expect(plan.steps).toHaveLength(1);
    expect(plan.steps[0]).toMatchObject({
      target: 'PRODUCT',
      targetId: 'p1',
      action: 'DELETE',
      reason: 'UNPUBLISH_REQUESTED',
    });
  });

  it('narrows to productIds without widening the mode selection', () => {
    const plan = planPublish(
      snapshot({
        products: [
          product({ id: 'pOk' }),
          product({ id: 'pBad', syncStatus: 'FAILED', mirageItemId: undefined }),
        ],
      }),
      'RETRY_FAILED',
      { productIds: ['pOk'] }
    );
    expect(plan.steps.filter((s) => s.target === 'PRODUCT')).toHaveLength(0);
  });

  it('reports the snapshot revision and step totals', () => {
    const plan = planPublish(
      snapshot({
        catalog: { draftRevision: 12, publishedRevision: 3, mirageRestaurantId: undefined },
        products: [product({ id: 'p1', mirageItemId: undefined }), product({ id: 'p2' })],
      }),
      'FULL'
    );
    expect(plan.snapshotRevision).toBe(12);
    expect(planTotals(plan)).toEqual({
      total: 4,
      create: 2,
      update: 0,
      delete: 0,
      skip: 2,
    });
  });
});
