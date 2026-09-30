// src/services/brand/branchService.ts
//
// Stage 16b/c — an owner's outlets: the MAIN catalog plus up to
// MAX_BRANCHES BRANCH catalogs. A branch is an ordinary Catalog (own public URL,
// QR standees, subscription, staff, offers, stock) whose menu and look follow
// the main outlet through copy-down (./copyDown.ts).
import { Types } from 'mongoose';
import { Catalog, type ICatalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { isDuplicateKeyError } from '@/services/catalogService';
import { requestPublish, type RequestPublishResult } from '@/services/catalogPublishService';
import { mainCatalogFilter, withOutlet } from '@/services/catalog/outletScope';
import type { Actor } from '@/models/types/subscription.types';
import { overriddenFields, reconcileBranches, resetBranchProduct } from './copyDown';

export const MAX_BRANCHES = 10;

export interface OutletDto {
  id: string;
  role: 'MAIN' | 'BRANCH';
  name: string;
  outletName: string | null;
  status: string;
  draftRevision: number;
  publishedRevision: number;
  hasUnpublishedChanges: boolean;
  publicUrl: string | null;
}

function toOutletDto(c: ICatalog): OutletDto {
  return {
    id: String(c._id),
    role: c.brandRole === 'BRANCH' ? 'BRANCH' : 'MAIN',
    name: c.name,
    outletName: c.outletName ?? null,
    status: c.status,
    draftRevision: c.draftRevision,
    publishedRevision: c.publishedRevision,
    hasUnpublishedChanges: c.draftRevision > c.publishedRevision,
    publicUrl: c.publicUrl ?? null,
  };
}

async function mainOf(ownerUserId: string): Promise<ICatalog | null> {
  return Catalog.findOne(mainCatalogFilter(ownerUserId)).exec();
}

async function branchesOf(mainId: Types.ObjectId): Promise<ICatalog[]> {
  return Catalog.find({ masterCatalogId: mainId, brandRole: 'BRANCH', deletedAt: null })
    .sort({ createdAt: 1 })
    .exec();
}

/** Main outlet first, then branches in the order they were added. */
export async function listOutlets(ownerUserId: string): Promise<OutletDto[] | null> {
  const main = await mainOf(ownerUserId);
  if (!main) return null;
  const branches = await branchesOf(main._id as Types.ObjectId);
  return [main, ...branches].map(toOutletDto);
}

export interface AddBranchInput {
  outletName: string;
  phone?: string;
  address?: string;
}

export type AddBranchResult =
  | { outcome: 'CREATED'; outlet: OutletDto }
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'LIMIT'; max: number }
  | { outcome: 'DUPLICATE_NAME' };

/**
 * Adds a branch: marks the main catalog MASTER (first time), creates the
 * BRANCH, and copies the whole menu and look down to it. Contact and hours
 * start as the main outlet's and are the branch's own from then on.
 */
export async function addBranch(ownerUserId: string, input: AddBranchInput): Promise<AddBranchResult> {
  const main = await mainOf(ownerUserId);
  if (!main) return { outcome: 'NO_CATALOG' };
  const mainId = main._id as Types.ObjectId;

  const count = await Catalog.countDocuments({ masterCatalogId: mainId, brandRole: 'BRANCH', deletedAt: null });
  if (count >= MAX_BRANCHES) return { outcome: 'LIMIT', max: MAX_BRANCHES };

  const outletName = input.outletName.trim();
  const contact = {
    ...((main.contact ? JSON.parse(JSON.stringify(main.contact)) : {}) as Record<string, unknown>),
    ...(input.phone ? { phone: input.phone } : {}),
    ...(input.address ? { address: input.address } : {}),
  };

  let branch: ICatalog;
  try {
    branch = await Catalog.create({
      userId: main.userId,
      // Mirage adopts a restaurant by NAME, so each outlet needs its own.
      name: `${main.name} · ${outletName}`.slice(0, 120),
      ...(main.businessName ? { businessName: main.businessName } : {}),
      ...(Object.keys(contact).length > 0 ? { contact } : {}),
      ...(main.hours ? { hours: JSON.parse(JSON.stringify(main.hours)) } : {}),
      brandRole: 'BRANCH',
      masterCatalogId: mainId,
      outletName,
      branchKey: outletName.toLowerCase(),
    });
  } catch (err) {
    if (isDuplicateKeyError(err)) return { outcome: 'DUPLICATE_NAME' };
    throw err;
  }

  if (main.brandRole !== 'MASTER') {
    await Catalog.updateOne({ _id: mainId }, { $set: { brandRole: 'MASTER' } }).exec();
  }
  await reconcileBranches(mainId);

  const fresh = await Catalog.findById(branch._id).exec();
  return { outcome: 'CREATED', outlet: toOutletDto(fresh ?? branch) };
}

export type ResetProductResult = 'OK' | 'NOT_FOUND' | 'NOT_LINKED';

/** "Reset to main outlet" for one dish on one of the owner's branches. */
export async function resetProductToMain(
  ownerUserId: string,
  outletId: string,
  productId: string
): Promise<ResetProductResult> {
  if (!Types.ObjectId.isValid(outletId) || !Types.ObjectId.isValid(productId)) return 'NOT_FOUND';
  const branch = await Catalog.findOne({
    _id: new Types.ObjectId(outletId),
    userId: new Types.ObjectId(ownerUserId),
    brandRole: 'BRANCH',
    deletedAt: null,
  }).exec();
  if (!branch) return 'NOT_FOUND';
  return resetBranchProduct(branch._id as Types.ObjectId, new Types.ObjectId(productId));
}

/** The fields a branch dish changed itself — the app's "From main outlet" labels. */
export async function productOverrides(
  catalogId: Types.ObjectId,
  productId: string
): Promise<{ linked: boolean; overridden: string[] } | null> {
  if (!Types.ObjectId.isValid(productId)) return null;
  const row = await CatalogProduct.findOne({ _id: new Types.ObjectId(productId), catalogId, deletedAt: null })
    .lean()
    .exec();
  if (!row) return null;
  return {
    linked: !!row.masterProductId,
    overridden: overriddenFields(row as unknown as Parameters<typeof overriddenFields>[0]),
  };
}

export interface PublishAllOutcome {
  outletId: string;
  outletName: string | null;
  outcome: RequestPublishResult['outcome'];
}

/**
 * "Publish all outlets": one ordinary publish per outlet (each keeps its own
 * single-flight guard and plan gates). Copy-down runs first so every branch
 * publishes the main outlet's latest menu.
 */
export async function publishAllOutlets(
  ownerUserId: string,
  publishedBy?: Actor
): Promise<PublishAllOutcome[] | null> {
  const main = await mainOf(ownerUserId);
  if (!main) return null;
  const mainId = main._id as Types.ObjectId;
  if (main.brandRole === 'MASTER') await reconcileBranches(mainId);

  const outlets = [main, ...(await branchesOf(mainId))];
  const results: PublishAllOutcome[] = [];
  for (const outlet of outlets) {
    const result = await withOutlet(outlet._id as Types.ObjectId, () =>
      requestPublish(ownerUserId, publishedBy ? { publishedBy } : {})
    );
    results.push({ outletId: String(outlet._id), outletName: outlet.outletName ?? null, outcome: result.outcome });
  }
  return results;
}
