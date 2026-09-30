// src/services/catalog/offersBlock.ts
//
// Stage 10: the offers block the publish sends with the restaurant's branding.
// Its own module (not in catalogOffersService) so the provisioning service can
// import it without pulling catalogService into its import graph.
import { Types } from 'mongoose';

import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogOffer, type ICatalogOffer } from '@/models/CatalogOffer';
import { CatalogProduct } from '@/models/CatalogProduct';
import { publishedDishName } from '@/services/catalog/menuExtras';
import { publishableProducts } from '@/services/catalog/publishableProducts';
import { offerStatus } from '@/services/offers/offerPricing';

interface ProductRow {
  _id: Types.ObjectId;
  name: string;
  categoryId?: Types.ObjectId | null;
  assets?: { glbUrl?: string };
}

const oid = (id: string): Types.ObjectId => new Types.ObjectId(id);

// ── Publish ────────────────────────────────────────────────────────────────

/**
 * `restaurant.offers` as JSON, or `''` for none — always sent, like every block.
 *
 * Only switched-on offers that have not already ended. Targets become the
 * dishes' CURRENT published names; a category target is expanded to its
 * dishes and remembered as `targetLabel` ("Drinks") for the top strip. An
 * offer left with no dishes, or a combo missing one of its dishes, drops out.
 */
export async function mirageOffersField(
  catalog: { _id: unknown },
  now: Date = new Date()
): Promise<string> {
  const catalogId = catalog._id as Types.ObjectId;
  const rows = await CatalogOffer.find({ catalogId, deletedAt: null, active: true })
    .sort({ priority: 1, createdAt: 1 })
    .lean<ICatalogOffer[]>()
    .exec();
  const live = rows.filter((r) => offerStatus({ ...r, active: true }, now) !== 'ENDED');
  if (live.length === 0) return '';

  const products = publishableProducts(
    await CatalogProduct.find({ catalogId, deletedAt: null, archivedAt: null })
      .select({
        _id: 1,
        name: 1,
        categoryId: 1,
        modelStatus: 1,
        assets: 1,
        deletedAt: 1,
        archivedAt: 1,
      })
      .lean<ProductRow[]>()
      .exec()
  );
  const nameById = new Map(products.map((p) => [String(p._id), publishedDishName(p.name)]));

  const categoryIds = [
    ...new Set(
      live.flatMap((r) => (r.target?.type === 'CATEGORIES' ? r.target.ids.map(String) : []))
    ),
  ];
  const categories = categoryIds.length
    ? await CatalogCategory.find({ _id: { $in: categoryIds.map(oid) }, catalogId, deletedAt: null })
        .select({ _id: 1, name: 1 })
        .lean<{ _id: Types.ObjectId; name: string }[]>()
        .exec()
    : [];
  const categoryName = new Map(categories.map((c) => [String(c._id), c.name]));

  const out: Record<string, unknown>[] = [];
  for (const r of live) {
    const s = r.schedule ?? {};
    const base = {
      id: String(r._id),
      name: r.name,
      kind: r.kind,
      priority: r.priority ?? 0,
      schedule: {
        ...(s.startsAt ? { startsAt: new Date(s.startsAt).toISOString() } : {}),
        ...(s.endsAt ? { endsAt: new Date(s.endsAt).toISOString() } : {}),
        ...(s.days && s.days.length ? { days: s.days } : {}),
        ...(s.from && s.to ? { from: s.from, to: s.to } : {}),
      },
    };

    if (r.kind === 'COMBO') {
      const names = (r.combo?.productIds ?? []).map((id) => nameById.get(String(id)));
      if (names.length < 2 || names.some((n) => !n)) continue;
      out.push({
        ...base,
        combo: { title: r.combo?.title || r.name, items: names, price: r.combo?.price },
      });
      continue;
    }

    const type = r.target?.type ?? 'ALL';
    if (type === 'ALL') {
      out.push({ ...base, value: r.value, all: true });
      continue;
    }
    const ids = new Set((r.target?.ids ?? []).map(String));
    const items =
      type === 'PRODUCTS'
        ? [...ids].map((id) => nameById.get(id)).filter((n): n is string => Boolean(n))
        : products
            .filter((p) => p.categoryId && ids.has(String(p.categoryId)))
            .map((p) => nameById.get(String(p._id)) as string);
    if (items.length === 0) continue;
    const label =
      type === 'CATEGORIES'
        ? [...ids]
            .map((id) => categoryName.get(id))
            .filter(Boolean)
            .join(' & ')
            .slice(0, 40)
        : '';
    out.push({ ...base, value: r.value, items, ...(label ? { targetLabel: label } : {}) });
  }
  return out.length ? JSON.stringify(out) : '';
}
