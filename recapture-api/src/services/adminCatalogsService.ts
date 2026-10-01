// src/services/adminCatalogsService.ts
//
// The ADMIN's "All catalogs" grid: every LIVE catalog, in name order.
//
// A BROWSER, NOT A DASHBOARD. A card carries what an admin needs to recognise a
// restaurant — its name, its logo, whether it is a branch, whether it has edits
// nobody has published — and nothing that costs a query per row. Opening one
// goes through the /rep surface, whose gate (`resolveCatalogAccess`) admits an
// ADMIN for any live catalog; this list grants nothing by itself.
//
// NO CONTACT, NOT EVEN A MASK. Same stance as every other admin list
// (AGENTS.md §Roles): the one raw-contact door is GET /admin/users/:id.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { cdnUrlForKey } from '@/services/catalogService';
import { customerUrl } from '@/services/customerUrl';
import { flexibleSlugRegex } from '@/utils/catalogNames';

export interface AdminCatalogCardDto {
  id: string;
  /** The stored slug; the client shows it de-slugged, like every catalog name. */
  name: string;
  businessName: string | null;
  /** CDN URL of the logo, or null when the restaurant has none. */
  logoUrl: string | null;
  /** The customer page (Mirage), never the resolver — see services/customerUrl.ts. */
  publicUrl: string | null;
  /** A Stage 16 branch outlet rather than a main / standalone catalog. */
  isBranch: boolean;
  /** PUBLISHED (live) or UNPUBLISHED (taken offline). Drafts are never listed. */
  status: 'PUBLISHED' | 'UNPUBLISHED';
  /** A publish or unpublish run holds the catalog right now. */
  isPublishing: boolean;
  /** Edits saved since the last successful publish. */
  hasDraftChanges: boolean;
  lastPublishedAt: string | null;
}

export type ListAdminCatalogsResult =
  | { outcome: 'INVALID_CURSOR' }
  | { outcome: 'OK'; items: AdminCatalogCardDto[]; nextCursor: string | null };

/** A `(name, id)` keyset position. `n`, not `u`/`p`: no other list's cursor decodes here. */
interface NameCursor {
  name: string;
  id: string;
}

function encodeNameCursor(name: string, id: string): string {
  return Buffer.from(JSON.stringify({ n: name, i: id }), 'utf8').toString('base64url');
}

function decodeNameCursor(raw: string): NameCursor | null {
  try {
    const parsed: unknown = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
    if (typeof parsed !== 'object' || parsed === null) return null;
    const { n, i } = parsed as Record<string, unknown>;
    if (typeof n !== 'string' || typeof i !== 'string' || !Types.ObjectId.isValid(i)) return null;
    return { name: n, id: i };
  } catch {
    return null;
  }
}

function escapeRegex(input: string): string {
  return input.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * One page of live catalogs, `(name ASC, _id ASC)`.
 *
 * Name order rather than "recently touched": an admin EDITS from this list, and
 * under updatedAt ordering the catalog they just saved would jump to the top
 * and shift every page behind it — the keyset would skip or repeat rows. A
 * name changes only on a rename.
 *
 * PUBLISHED and UNPUBLISHED — every catalog that has ever had a page — each
 * card saying which, so a menu an admin takes offline stays on the grid to be
 * published again. A DRAFT has never had a page and is not listed.
 */
export async function listPublishedCatalogs(params: {
  limit: number;
  cursor?: string;
  q?: string;
}): Promise<ListAdminCatalogsResult> {
  const and: Record<string, unknown>[] = [
    { status: { $in: ['PUBLISHED', 'UNPUBLISHED'] } },
    { deletedAt: null },
  ];

  if (params.cursor !== undefined) {
    const cursor = decodeNameCursor(params.cursor);
    if (!cursor) return { outcome: 'INVALID_CURSOR' };
    and.push({
      $or: [
        { name: { $gt: cursor.name } },
        { name: cursor.name, _id: { $gt: new Types.ObjectId(cursor.id) } },
      ],
    });
  }

  if (params.q !== undefined) {
    // Names are stored as slugs ("blue_cafe") and nobody types one; the
    // flexible pattern finds "blue cafe", "blue-cafe" and "bluecafe" alike. An
    // all-separator query falls back to the escaped literal, which matches
    // nothing rather than everything. The business name is free text.
    const literal = escapeRegex(params.q);
    and.push({
      $or: [
        { name: { $regex: flexibleSlugRegex(params.q) || literal, $options: 'i' } },
        { businessName: { $regex: literal, $options: 'i' } },
      ],
    });
  }

  const rows = await Catalog.find({ $and: and })
    .select({
      name: 1,
      businessName: 1,
      logoKey: 1,
      mirageRestaurantId: 1,
      branchKey: 1,
      draftRevision: 1,
      publishedRevision: 1,
      lastPublishedAt: 1,
      status: 1,
      activePublishRunId: 1,
    })
    .sort({ name: 1, _id: 1 })
    .limit(params.limit + 1)
    .lean()
    .exec();

  const hasMore = rows.length > params.limit;
  const page = hasMore ? rows.slice(0, params.limit) : rows;
  const last = page[page.length - 1];

  return {
    outcome: 'OK',
    items: page.map((c) => ({
      id: String(c._id),
      name: c.name,
      businessName: c.businessName ?? null,
      logoUrl: cdnUrlForKey(c.logoKey),
      publicUrl: customerUrl(c),
      isBranch: Boolean(c.branchKey),
      status: c.status === 'UNPUBLISHED' ? 'UNPUBLISHED' : 'PUBLISHED',
      isPublishing: Boolean(c.activePublishRunId),
      hasDraftChanges: (c.draftRevision ?? 0) > (c.publishedRevision ?? 0),
      lastPublishedAt: c.lastPublishedAt ? c.lastPublishedAt.toISOString() : null,
    })),
    nextCursor: hasMore && last ? encodeNameCursor(last.name, String(last._id)) : null,
  };
}
