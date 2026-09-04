// src/services/catalogDelegationService.ts
//
// The grant, the revoke, the list — and THE GATE.
//
// Every /rep route that touches a catalog resolves it through
// {@link resolveDelegatedCatalog} and through nothing else. That is the whole
// authorization model for acting-on-behalf-of, in one function, so there is
// exactly one place to audit and exactly one place a mistake could live. A
// route that resolves a catalog any other way is the bug, whatever else it
// checks afterwards.
import { Types } from 'mongoose';

import { Catalog, type ICatalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { isDuplicateKeyError } from '@/services/catalogService';
import type { CatalogStatus } from '@/models/types/catalog.types';

/**
 * A delegated catalog as the rep's picker shows it.
 *
 * DELIBERATELY SMALLER THAN CatalogDto: a rep listing twenty restaurants does
 * not need three count queries each, and the counts are the expensive part of
 * the owner DTO. A rep who opens one catalog gets the full picture from the
 * routes that act on it.
 */
export interface CatalogSummaryDto {
  id: string;
  name: string;
  businessName: string | null;
  status: CatalogStatus;
  publicUrl: string | null;
  isProvisioned: boolean;
  grantedAt: string;
}

/**
 * Grants — or re-grants — one rep access to one catalog.
 *
 * Idempotent by construction. The upsert is guarded on `revokedAt: null`, so a
 * live grant is matched and left alone while a revoked one is stepped over and
 * a fresh row opened; the partial unique index is what makes two concurrent
 * activations of the same code produce one row rather than two. Its E11000 is
 * therefore a SUCCESS here (someone else granted first, which is the state we
 * wanted), not an error to propagate.
 */
export async function grantDelegation(
  repUserId: Types.ObjectId,
  catalogId: Types.ObjectId,
  grantedByUserId?: Types.ObjectId
): Promise<void> {
  try {
    await CatalogDelegation.findOneAndUpdate(
      { repUserId, catalogId, revokedAt: null },
      {
        $setOnInsert: {
          repUserId,
          catalogId,
          grantedAt: new Date(),
          revokedAt: null,
          ...(grantedByUserId ? { grantedByUserId } : {}),
        },
      },
      { upsert: true, new: true }
    ).exec();
  } catch (err) {
    if (!isDuplicateKeyError(err)) throw err;
    // Lost the race to another activation of the same code. The row exists and
    // it is live — which is precisely what this function promises.
  }
}

/**
 * Withdraws a rep's access. Takes effect on the NEXT REQUEST — there is no
 * token carrying the grant, so nothing has to expire first.
 *
 * Silent when there is no live grant: "this rep cannot act on this catalog" is
 * the postcondition either way, and reporting the difference would tell the
 * caller whether a grant existed.
 */
export async function revokeDelegation(
  repUserId: Types.ObjectId,
  catalogId: Types.ObjectId
): Promise<void> {
  await CatalogDelegation.updateOne(
    { repUserId, catalogId, revokedAt: null },
    { $set: { revokedAt: new Date() } }
  ).exec();
}

/** The catalogs a rep may currently act on, newest grant first. */
export async function listDelegatedCatalogs(
  repUserId: Types.ObjectId
): Promise<CatalogSummaryDto[]> {
  const grants = await CatalogDelegation.find({ repUserId, revokedAt: null })
    .sort({ grantedAt: -1 })
    .lean()
    .exec();
  if (grants.length === 0) return [];

  const catalogs = await Catalog.find({
    _id: { $in: grants.map((g) => g.catalogId) },
    deletedAt: null,
  })
    .lean()
    .exec();

  const byId = new Map(catalogs.map((c) => [String(c._id), c]));

  // Driven by the GRANTS, not the catalogs, so the sort order is the grant
  // order the rep expects. A grant whose catalog was deleted underneath it
  // drops out rather than rendering as a broken row.
  return grants.flatMap((grant) => {
    const catalog = byId.get(String(grant.catalogId));
    if (!catalog) return [];
    return [
      {
        id: String(catalog._id),
        name: catalog.name,
        businessName: catalog.businessName ?? null,
        status: catalog.status,
        publicUrl: catalog.publicUrl ?? null,
        isProvisioned: Boolean(catalog.mirageRestaurantId),
        grantedAt: grant.grantedAt.toISOString(),
      },
    ];
  });
}

/**
 * THE GATE. The only way a /rep route is allowed to obtain a catalog.
 *
 * Returns null for "no live delegation", for "no such catalog", for a
 * soft-deleted catalog AND for a malformed id — the four are deliberately
 * indistinguishable, so a rep cannot probe for the existence of catalogs they
 * do not hold. Exactly the reasoning behind `resolveOwnedModel` answering
 * MODEL_NOT_FOUND for a model that exists but belongs to someone else, and
 * behind `findOwnedCatalog` collapsing missing / not-owned / soft-deleted.
 *
 * The delegation is read on EVERY request rather than carried in the token, so
 * a revoke is effective immediately — the same reasoning as requireRole's fresh
 * role read.
 */
export async function resolveDelegatedCatalog(
  repUserId: Types.ObjectId,
  catalogId: string
): Promise<ICatalog | null> {
  // A malformed id is answered with the same null as a catalog the rep does not
  // hold. Validating it here rather than at the route is what keeps that
  // promise: a 400 for "not an ObjectId" and a 404 for "not yours" would still
  // be two distinguishable answers.
  if (!Types.ObjectId.isValid(catalogId)) return null;

  const id = new Types.ObjectId(catalogId);
  const grant = await CatalogDelegation.findOne({
    repUserId,
    catalogId: id,
    revokedAt: null,
  })
    .lean()
    .exec();
  if (!grant) return null;

  return Catalog.findOne({ _id: id, deletedAt: null }).exec();
}
