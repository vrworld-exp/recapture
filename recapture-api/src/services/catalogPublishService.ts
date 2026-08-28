// src/services/catalogPublishService.ts
//
// The user-facing half of publishing: the gates, the run, the status, the
// retry, the unpublish. The worker owns what happens next; this file owns
// whether it should happen at all.
//
// TWO IDEAS RUN THROUGH EVERYTHING HERE.
//
// 1. GATES RUN BEFORE MIRAGE, AND THEY ALL RUN. Every reason a catalog cannot
//    publish is a ReCapture-side fact — no products, a product with no model, a
//    duplicate name — and every one of them is knowable without a single
//    network call. Checking them first means a doomed publish costs one database
//    round trip instead of a provisioning call, a restaurant document and a
//    half-written public page. And they are returned TOGETHER, because the
//    client shows a checklist: telling a user to fix one thing, then another,
//    then a third is three round trips and three disappointments.
//
// 2. THE MAPPING IS WRITTEN ONCE AND NEVER AGAIN. `mirageRestaurantId`,
//    `publicUrl` and `publicUrlScheme` are minted by provisionCatalog under a
//    conditional update and are then FROZEN — feature 32 says a printed QR keeps
//    working through renames, republishes and product churn, and that is only
//    true if nothing in the system can rewrite those three fields.
//    `assertMappingImmutable` below makes an attempt throw rather than corrupt.
import { Types } from 'mongoose';

import { Catalog, type ICatalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct, type ICatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun, type ICatalogPublishRun } from '@/models/CatalogPublishRun';
import { Job } from '@/models/Job';
import { Project } from '@/models/Project';
import { ProjectModel } from '@/models/ProjectModel';
import { MIRAGE_CATALOG_PUBLISH_JOB_TYPE } from '@/models/types/job.types';
import type {
  PublishMode,
  PublishRunState,
  SyncStatus,
} from '@/models/types/catalog.types';
import {
  CATALOG_NAME_TAKEN,
  provisionCatalog,
  syncCatalogBranding,
  type CatalogMappingDto,
} from '@/services/catalogProvisioningService';
import type { PublishStepExecutor } from '@/services/catalog/publishExecutors';
import { pruneRunHistory } from '@/services/catalogActivityService';
import { hasActiveRun, releaseAbandonedRun } from '@/services/catalog/publishRunState';
import { CatalogSyncErrorCode, syncFailure } from '@/services/catalog/publishSyncErrors';
import { mirageCategoryName } from '@/services/catalog/categorySync';
import { getMirageClient, isMirageConfigured, MirageError } from '@/services/mirage';
import { isValidCatalogSlug } from '@/utils/catalogNames';

// ── Gates ───────────────────────────────────────────────────────────────────

/**
 * Every reason a catalog cannot publish. The Flutter client switches on these,
 * so each value is part of the API contract.
 */
export const PublishGateCode = {
  /** Nothing to publish. Blocked BEFORE provisioning — Q7. */
  CATALOG_EMPTY: 'CATALOG_EMPTY',
  /** Mirage's restaurant requires a name; ours would be blank. */
  CATALOG_NAME_MISSING: 'CATALOG_NAME_MISSING',
  /** A 3D product with no model, or an image-only product with no image. */
  PRODUCT_ASSET_MISSING: 'PRODUCT_ASSET_MISSING',
  /** A 3D product whose generated preview is not ready — feature 51. */
  PRODUCT_THUMBNAIL_MISSING: 'PRODUCT_THUMBNAIL_MISSING',
  /** The source model is not SUCCEEDED, or is not the caller's. */
  PRODUCT_MODEL_NOT_READY: 'PRODUCT_MODEL_NOT_READY',
  /** Mirage enforces per-restaurant item-name uniqueness. */
  PRODUCT_NAME_DUPLICATE: 'PRODUCT_NAME_DUPLICATE',
  /** The product is filed under a category this catalog no longer has. */
  PRODUCT_CATEGORY_UNKNOWN: 'PRODUCT_CATEGORY_UNKNOWN',
  /** A category whose stored name would reach Mirage as nothing at all. */
  CATEGORY_NAME_INVALID: 'CATEGORY_NAME_INVALID',
  /** MIRAGE_* config is absent on this deployment. */
  PUBLISHING_UNAVAILABLE: 'PUBLISHING_UNAVAILABLE',
} as const;

export type PublishGateCodeValue = (typeof PublishGateCode)[keyof typeof PublishGateCode];

/** One failing gate, in the shape the client renders as a checklist row. */
export interface PublishGate {
  code: PublishGateCodeValue;
  message: string;
  /** The product this is about, when it is about one. */
  productId?: string;
  productName?: string;
}

/**
 * Is this product publishable?
 *
 * The asset rules are asymmetric on purpose. An image-only product needs its
 * picture, obviously. A 3D product needs BOTH its model and its generated
 * thumbnail — Mirage's card shows the image while the model streams, so a 3D
 * product published without one is a blank tile on a customer's phone for
 * however many seconds the GLB takes. That is worth blocking on, and the
 * message says the fix is to wait rather than to do anything.
 */
function gateProduct(product: ICatalogProduct): PublishGate[] {
  const gates: PublishGate[] = [];
  const id = (product._id as Types.ObjectId).toHexString();
  const about = { productId: id, productName: product.name };

  if (product.type === 'THREE_D') {
    if (!product.assets?.glbUrl) {
      gates.push({
        code: PublishGateCode.PRODUCT_ASSET_MISSING,
        message: `"${product.name}" has no 3D model yet.`,
        ...about,
      });
    }
    if (!product.assets?.thumbnailUrl) {
      gates.push({
        code: PublishGateCode.PRODUCT_THUMBNAIL_MISSING,
        message: `"${product.name}" is still generating its preview image. Try again shortly.`,
        ...about,
      });
    }
    return gates;
  }

  if (!product.assets?.imageKey) {
    gates.push({
      code: PublishGateCode.PRODUCT_ASSET_MISSING,
      message: `"${product.name}" has no photo yet.`,
      ...about,
    });
  }
  return gates;
}

/**
 * Are the ProjectModels behind the 3D products real, finished, and the caller's?
 *
 * One query for all of them rather than one per product: a fifty-product
 * catalog would otherwise open fifty round trips before the publish even
 * starts. Ownership is re-derived here rather than trusted from the product row
 * because a model id is a client-supplied value at product-create time, and a
 * publish is the moment it stops being merely stored and starts being served.
 */
async function gateSourceModels(
  userId: Types.ObjectId,
  products: readonly ICatalogProduct[]
): Promise<PublishGate[]> {
  const withModels = products.filter(
    (product) => product.type === 'THREE_D' && product.sourceModelId
  );
  if (withModels.length === 0) return [];

  const models = await ProjectModel.find({
    _id: { $in: withModels.map((product) => product.sourceModelId) },
  })
    .select({ _id: 1, status: 1, projectId: 1 })
    .lean()
    .exec();

  // OWNERSHIP GOES THROUGH THE PROJECT, exactly as resolveOwnedModel does at
  // product-create time — `createdByUserId` is the ACTOR, and a staff-generated
  // model legitimately carries a staff id while belonging to the owner's
  // project. Checking the actor would refuse every staff-built model.
  const ownedProjects = await Project.find({
    _id: { $in: models.map((model) => model.projectId) },
    userId,
    deletedAt: null,
  })
    .select({ _id: 1 })
    .lean()
    .exec();
  const owned = new Set(ownedProjects.map((project) => String(project._id)));

  const byId = new Map(models.map((model) => [String(model._id), model]));

  return withModels.flatMap((product) => {
    const model = byId.get(String(product.sourceModelId));
    const usable =
      model && model.status === 'SUCCEEDED' && owned.has(String(model.projectId));
    if (usable) return [];
    return [
      {
        code: PublishGateCode.PRODUCT_MODEL_NOT_READY,
        message: `The 3D model for "${product.name}" is not ready to publish.`,
        productId: (product._id as Types.ObjectId).toHexString(),
        productName: product.name,
      },
    ];
  });
}

/**
 * Mirage rejects a second item with the same name in one restaurant
 * (adminController.js:1084-1093), and there is no good repair at publish time —
 * the run cannot know which of two identically-named products the user meant.
 * So the collision is caught here, while the user is still looking at their own
 * catalog, and reported against every row involved rather than just the second.
 */
function gateDuplicateNames(products: readonly ICatalogProduct[]): PublishGate[] {
  const byName = new Map<string, ICatalogProduct[]>();
  for (const product of products) {
    const key = product.name.trim().toLowerCase();
    byName.set(key, [...(byName.get(key) ?? []), product]);
  }

  return [...byName.values()]
    .filter((group) => group.length > 1)
    .flatMap((group) =>
      group.map((product) => ({
        code: PublishGateCode.PRODUCT_NAME_DUPLICATE,
        message: `More than one product is called "${product.name}". Rename one of them.`,
        productId: (product._id as Types.ObjectId).toHexString(),
        productName: product.name,
      }))
    );
}

/**
 * Does every category this publish would touch actually exist in THIS catalog?
 *
 * WHY THIS RUNS BEFORE ANYTHING ELSE TOUCHES MIRAGE. A category is not a label
 * carried along with a product — it is a row Mirage creates, and a TAB the
 * customer sees on the public page. Two ways that goes wrong, and both are
 * invisible until a stranger is looking at the menu:
 *
 *   • A PRODUCT POINTS AT A CATEGORY THAT IS GONE. The authoring routes all
 *     scope their category lookup to the catalog, so this should be
 *     unreachable — but "should be" is doing a lot of work for a value that
 *     survives a soft-delete race, a restore, a hand-edited document or a
 *     seeded row. The publish path is where it stops being a dangling id and
 *     starts being a tab: `resolveCategory` finds nothing in the snapshot,
 *     falls through to the Uncategorized bucket, and the product silently
 *     changes category on the live page.
 *
 *   • A CATEGORY NAME THAT SLUGS TO NOTHING. Names are stored in Mirage's own
 *     slug form now, and the validation layer rejects one with no letters or
 *     digits in it — but a row written before that (or seeded straight into the
 *     collection) can still hold `"!!!"`, which reaches create-category as an
 *     empty name and comes back as a tab nobody can explain.
 *
 * A FULL publish pushes EVERY live category, not only the ones with products
 * under them (publishPlanner.neededCategories), so the name check covers all of
 * them rather than just the referenced set.
 *
 * One query for the whole catalog, like every other gate here — the check costs
 * a single indexed read and saves a public page nobody can un-see.
 */
async function gateCatalogCategories(
  catalogId: Types.ObjectId,
  products: readonly ICatalogProduct[]
): Promise<PublishGate[]> {
  const categories = await CatalogCategory.find({ catalogId, deletedAt: null })
    .select({ _id: 1, name: 1 })
    .lean()
    .exec();

  const known = new Map(categories.map((category) => [String(category._id), category.name]));

  const gates: PublishGate[] = categories
    .filter((category) => !isValidCatalogSlug(mirageCategoryName(category.name)))
    .map((category) => ({
      code: PublishGateCode.CATEGORY_NAME_INVALID,
      message: `The category "${category.name}" cannot be published under that name. Rename it.`,
    }));

  for (const product of products) {
    if (!product.categoryId) continue; // Uncategorized — a real bucket, not a gap.
    if (known.has(String(product.categoryId))) continue;
    gates.push({
      code: PublishGateCode.PRODUCT_CATEGORY_UNKNOWN,
      message: `"${product.name}" is filed under a category that is no longer in your catalog. Pick one for it, or move it to Uncategorized.`,
      productId: (product._id as Types.ObjectId).toHexString(),
      productName: product.name,
    });
  }

  return gates;
}

/** The products a FULL publish would actually push. */
function publishableProducts(products: readonly ICatalogProduct[]): ICatalogProduct[] {
  return products.filter((product) => !product.deletedAt && !product.archivedAt);
}

/**
 * Runs every gate and returns ALL failures.
 *
 * Exported because the client asks for it directly (so the Publish button can be
 * disabled with a reason before it is pressed) and because the publish endpoint
 * runs the identical set — one implementation, so a preview can never disagree
 * with what actually happens.
 */
export async function evaluatePublishGates(
  catalog: ICatalog,
  products: readonly ICatalogProduct[]
): Promise<PublishGate[]> {
  const gates: PublishGate[] = [];

  if (!isMirageConfigured()) {
    // An operator problem, not the user's. Returned as a gate so the client
    // renders one honest sentence instead of a 500.
    return [
      {
        code: PublishGateCode.PUBLISHING_UNAVAILABLE,
        message: 'Publishing is not available right now. Please try again later.',
      },
    ];
  }

  const live = publishableProducts(products);

  if (live.length === 0) {
    gates.push({
      code: PublishGateCode.CATALOG_EMPTY,
      message: 'Add at least one product before publishing.',
    });
  }

  if (!catalog.name.trim()) {
    gates.push({
      code: PublishGateCode.CATALOG_NAME_MISSING,
      message: 'Give your catalog a name before publishing.',
    });
  }

  for (const product of live) gates.push(...gateProduct(product));
  gates.push(...gateDuplicateNames(live));

  // The two database-backed gates go together rather than one after the other:
  // they read different collections and neither depends on the other's answer.
  const [modelGates, categoryGates] = await Promise.all([
    gateSourceModels(catalog.userId, live),
    gateCatalogCategories(catalog._id as Types.ObjectId, live),
  ]);
  gates.push(...modelGates, ...categoryGates);

  return gates;
}

// ── The immutable mapping ───────────────────────────────────────────────────

/**
 * Refuses to let anything rewrite a catalog's Mirage mapping or its public URL.
 *
 * A guard rather than a convention. Those three fields are what a printed QR
 * resolves through; repointing them silently turns every sticker a business has
 * put on a table into a dead link, and there is no way to notice from inside the
 * app. So an attempt THROWS, loudly, and any code path that wants to must first
 * explain itself to a reviewer.
 */
export class CatalogMappingImmutableError extends Error {
  constructor(field: string) {
    super(
      `${field} is frozen once written — a printed QR resolves through it (feature 32).`
    );
    this.name = 'CatalogMappingImmutableError';
  }
}

export function assertMappingImmutable(
  catalog: Pick<ICatalog, 'mirageRestaurantId' | 'publicUrl'>,
  next: { mirageRestaurantId?: string; publicUrl?: string }
): void {
  if (
    next.mirageRestaurantId !== undefined &&
    catalog.mirageRestaurantId &&
    next.mirageRestaurantId !== catalog.mirageRestaurantId
  ) {
    throw new CatalogMappingImmutableError('mirageRestaurantId');
  }
  if (next.publicUrl !== undefined && catalog.publicUrl && next.publicUrl !== catalog.publicUrl) {
    throw new CatalogMappingImmutableError('publicUrl');
  }
}

// ── The RESTAURANT executor ─────────────────────────────────────────────────

/**
 * The publish run's first step: make sure a Mirage restaurant exists, and push
 * branding onto it.
 *
 * It lives HERE, not in the worker, because provisioning is the one write that
 * can never be taken back and it belongs beside the immutability guard. The
 * worker registers it the same way it registers the other two.
 *
 * A CREATE that comes back NAME_TAKEN is a ROW failure, not a run crash: the
 * business can rename the catalog and publish again, and the processor's own
 * rule (a failed RESTAURANT aborts the remaining steps) already stops fifty
 * products from failing individually behind it.
 */
export const restaurantExecutor: PublishStepExecutor = async (step, context) => {
  const catalogId = new Types.ObjectId(context.catalogId);

  if (step.action === 'CREATE') {
    const result = await provisionCatalog(catalogId);
    switch (result.outcome) {
      case 'ALREADY_PROVISIONED':
      case 'ADOPTED':
      case 'CREATED':
        context.mirageRestaurantId = result.mapping.mirageRestaurantId;
        return { outcome: 'SUCCEEDED' };
      case 'NAME_TAKEN':
        return {
          outcome: 'FAILED',
          code: CATALOG_NAME_TAKEN,
          message: `That catalog name is already taken online. Try "${result.suggestedName}".`,
        };
      case 'CATALOG_GONE':
        return {
          outcome: 'FAILED',
          code: CatalogSyncErrorCode.RESTAURANT_MISSING,
          message: syncFailure(CatalogSyncErrorCode.RESTAURANT_MISSING).message,
        };
    }
  }

  const branding = await syncCatalogBranding(catalogId);
  switch (branding.outcome) {
    case 'SYNCED':
      return { outcome: 'SUCCEEDED' };
    case 'NAME_TAKEN':
      // The rename is refused; the page, the URL and every published product
      // keep working under the old label. Worth reporting, not worth aborting.
      return {
        outcome: 'FAILED',
        code: CATALOG_NAME_TAKEN,
        message: `Your catalog could not be renamed online. Try "${branding.suggestedName}".`,
      };
    case 'NOT_PROVISIONED':
    case 'CATALOG_GONE':
      return {
        outcome: 'FAILED',
        code: CatalogSyncErrorCode.RESTAURANT_MISSING,
        message: syncFailure(CatalogSyncErrorCode.RESTAURANT_MISSING).message,
      };
  }
};

// ── Requesting a publish ────────────────────────────────────────────────────

export interface PublishRunDto {
  runId: string;
  state: PublishRunState;
  mode: PublishMode;
  snapshotRevision: number;
}

export type RequestPublishResult =
  | { outcome: 'QUEUED'; run: PublishRunDto; mapping?: CatalogMappingDto }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'BLOCKED'; gates: PublishGate[] }
  | { outcome: 'IN_PROGRESS'; runId: string }
  | { outcome: 'NAME_TAKEN'; code: typeof CATALOG_NAME_TAKEN; suggestedName: string }
  | { outcome: 'NOTHING_TO_RETRY'; run: PublishRunDto };

interface RequestPublishOptions {
  mode: PublishMode;
  idempotencyKey?: string;
}

/**
 * Creates the run, enqueues the job, and takes the catalog's publish lock — in
 * that order, and the order is the whole safety argument.
 *
 * The LOCK IS LAST and it is a conditional update guarded on
 * `activePublishRunId: null`. Two concurrent publishes both create a run; only
 * one wins the guard. The loser deletes its own run and job and reports 409, so
 * what the user sees is "a publish is already running", not two runs racing
 * Mirage's non-idempotent writes.
 *
 * The JOB IS CREATED BEFORE THE LOCK for the same reason a Meshy job is: a run
 * with no job would sit QUEUED forever with the catalog locked behind it, and
 * nothing in the system would ever notice.
 */
async function openRun(
  catalog: ICatalog,
  options: RequestPublishOptions
): Promise<RequestPublishResult> {
  const catalogId = catalog._id as Types.ObjectId;

  const run = await CatalogPublishRun.create({
    catalogId,
    userId: catalog.userId,
    // Replaced immediately below. The field is required and the job does not
    // exist yet — a chicken-and-egg the model resolves by being written twice.
    jobId: new Types.ObjectId(),
    // READ NOW, NOT AT ENQUEUE TIME. This is the revision the run publishes and
    // the one `publishedRevision` becomes on success, so an edit made while the
    // job waits in the queue correctly reads as "not yet live".
    snapshotRevision: catalog.draftRevision,
    mode: options.mode,
    state: 'QUEUED',
    ...(options.idempotencyKey ? { idempotencyKey: options.idempotencyKey } : {}),
  });
  const runId = run._id as Types.ObjectId;

  const job = await Job.create({
    userId: catalog.userId,
    jobType: MIRAGE_CATALOG_PUBLISH_JOB_TYPE,
    state: 'QUEUED',
    payload: {
      catalogId: catalogId.toHexString(),
      publishRunId: runId.toHexString(),
      mode: options.mode,
    },
  });
  await CatalogPublishRun.updateOne({ _id: runId }, { $set: { jobId: job._id } }).exec();

  const locked = await Catalog.findOneAndUpdate(
    { _id: catalogId, deletedAt: null, activePublishRunId: null },
    { $set: { activePublishRunId: runId } },
    { new: true }
  )
    .lean()
    .exec();

  if (!locked) {
    // Lost the race. Roll our own artefacts back, so the run the winner owns is
    // the only one anybody can see.
    await Promise.all([
      CatalogPublishRun.deleteOne({ _id: runId }).exec(),
      Job.deleteOne({ _id: job._id }).exec(),
    ]);
    const active = await hasActiveRun(catalogId);
    return active.runId
      ? { outcome: 'IN_PROGRESS', runId: active.runId }
      : { outcome: 'NOT_FOUND' };
  }

  // Bound the history here rather than in a sweep: one query per publish keeps
  // "the last N runs" continuously true, and a failure is swallowed because a
  // full history must never turn a successful publish into an error.
  await pruneRunHistory(catalogId).catch(() => undefined);

  return {
    outcome: 'QUEUED',
    run: {
      runId: runId.toHexString(),
      state: 'QUEUED',
      mode: options.mode,
      snapshotRevision: run.snapshotRevision,
    },
  };
}

/** Loads the caller's catalog. An absent one is indistinguishable from another user's. */
async function ownCatalog(userId: string): Promise<ICatalog | null> {
  return Catalog.findOne({ userId: new Types.ObjectId(userId), deletedAt: null }).exec();
}

/**
 * POST /catalog/publish.
 *
 * Gates, then provisioning, then the run. Nothing touches Mirage until every
 * gate has passed — an empty catalog never provisions, which is what keeps a
 * user who tapped Publish too early from permanently owning a Mirage restaurant
 * (and a public URL) for a catalog with nothing in it.
 */
export async function requestPublish(
  userId: string,
  options: { idempotencyKey?: string } = {}
): Promise<RequestPublishResult> {
  const catalog = await ownCatalog(userId);
  if (!catalog) return { outcome: 'NOT_FOUND' };

  const catalogId = catalog._id as Types.ObjectId;

  const active = await hasActiveRun(catalogId);
  if (active.active && active.runId) {
    return { outcome: 'IN_PROGRESS', runId: active.runId };
  }

  const products = await CatalogProduct.find({ catalogId, deletedAt: null }).exec();
  const gates = await evaluatePublishGates(catalog, products);
  if (gates.length > 0) return { outcome: 'BLOCKED', gates };

  // Provisioning is idempotent and returns the stored mapping without a Mirage
  // call once it exists, so calling it here (rather than only inside the run)
  // costs nothing on a republish and lets a NAME_TAKEN reach the user
  // synchronously, with a suggestion, instead of as a failed background run.
  let mapping: CatalogMappingDto | undefined;
  if (!catalog.mirageRestaurantId) {
    const provisioned = await provisionCatalog(catalogId);
    switch (provisioned.outcome) {
      case 'NAME_TAKEN':
        return {
          outcome: 'NAME_TAKEN',
          code: CATALOG_NAME_TAKEN,
          suggestedName: provisioned.suggestedName,
        };
      case 'CATALOG_GONE':
        return { outcome: 'NOT_FOUND' };
      default:
        mapping = provisioned.mapping;
    }
  }

  const fresh = await ownCatalog(userId);
  if (!fresh) return { outcome: 'NOT_FOUND' };

  const result = await openRun(fresh, { mode: 'FULL', ...options });
  return result.outcome === 'QUEUED' && mapping ? { ...result, mapping } : result;
}

/**
 * POST /catalog/publish/retry — feature 53.
 *
 * Re-enqueues exactly the rows whose `syncStatus` is FAILED. A retry with
 * nothing failed is a SUCCESS with a zero-count run, not an error: the user
 * asked for "make the failures go away" and there are none, which is the state
 * they wanted.
 */
export async function requestRetry(userId: string): Promise<RequestPublishResult> {
  const catalog = await ownCatalog(userId);
  if (!catalog) return { outcome: 'NOT_FOUND' };

  const catalogId = catalog._id as Types.ObjectId;

  const active = await hasActiveRun(catalogId);
  if (active.active && active.runId) {
    return { outcome: 'IN_PROGRESS', runId: active.runId };
  }

  const failedCount = await CatalogProduct.countDocuments({
    catalogId,
    deletedAt: null,
    syncStatus: 'FAILED' satisfies SyncStatus,
  }).exec();

  if (failedCount === 0) {
    return {
      outcome: 'NOTHING_TO_RETRY',
      run: {
        runId: '',
        state: 'SUCCEEDED',
        mode: 'RETRY_FAILED',
        snapshotRevision: catalog.publishedRevision,
      },
    };
  }

  return openRun(catalog, { mode: 'RETRY_FAILED' });
}

// ── Unpublish (feature 39) ──────────────────────────────────────────────────

export type UnpublishResult =
  | { outcome: 'QUEUED'; run: PublishRunDto }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'IN_PROGRESS'; runId: string }
  /** A DRAFT catalog was never live; taking it down is a no-op success. */
  | { outcome: 'NOT_PUBLISHED' };

/**
 * POST /catalog/unpublish.
 *
 * ⚠ THE RESTAURANT SURVIVES. Mirage's only removal primitive for a business is
 * `delete-restaurant`, and it destroys the ObjectId that the public URL — and
 * therefore every printed QR, sticker and menu card — is built from. So
 * unpublish deletes the ITEMS (an UNPUBLISH run) and flips the restaurant's
 * `isPublished` to false, which Mirage's read paths honour. Republishing later
 * restores the same page at the same URL.
 *
 * That is a product decision, not a limitation: permanently destroying a
 * business's public link is a separate, explicitly-confirmed action, and it is
 * deliberately not reachable from this endpoint.
 */
export async function requestUnpublish(userId: string): Promise<UnpublishResult> {
  const catalog = await ownCatalog(userId);
  if (!catalog) return { outcome: 'NOT_FOUND' };

  const catalogId = catalog._id as Types.ObjectId;

  if (catalog.status === 'DRAFT' || !catalog.mirageRestaurantId) {
    // Never live. No Mirage call, no run — there is nothing to take down.
    return { outcome: 'NOT_PUBLISHED' };
  }

  const active = await hasActiveRun(catalogId);
  if (active.active && active.runId) {
    return { outcome: 'IN_PROGRESS', runId: active.runId };
  }

  // The soft switch first, so the page goes dark immediately rather than after
  // however long the item deletes take. A Mirage that refuses it is not fatal:
  // the run still removes the items, which is the substantive half.
  try {
    await getMirageClient().updateRestaurant(catalog.mirageRestaurantId, { isPublished: false });
  } catch (err) {
    if (!(err instanceof MirageError)) throw err;
    console.warn(
      `[catalog] unpublish could not clear isPublished (${err.code}); continuing with item removal`
    );
  }

  await Catalog.updateOne(
    { _id: catalogId },
    { $set: { status: 'UNPUBLISHED' } },
    { timestamps: false }
  ).exec();

  const queued = await openRun(catalog, { mode: 'UNPUBLISH' });
  if (queued.outcome === 'QUEUED') return { outcome: 'QUEUED', run: queued.run };
  if (queued.outcome === 'IN_PROGRESS') return queued;
  return { outcome: 'NOT_FOUND' };
}

// ── Status (features 37, 38, 52) ────────────────────────────────────────────

export interface PublishProductStatusDto {
  id: string;
  name: string;
  type: ICatalogProduct['type'];
  syncStatus: SyncStatus;
  code?: string;
  message?: string;
}

export interface PublishStatusDto {
  /** DRAFT | PUBLISHED | UNPUBLISHED. */
  status: ICatalog['status'];
  /**
   * DERIVED, never a stored flag (feature 38). `draftRevision` moves on every
   * authoring write and `publishedRevision` only on a fully successful run, so
   * this is true exactly when it should be — including after a PARTIAL run,
   * where some products genuinely are not live.
   */
  hasDraftChanges: boolean;
  publicUrl: string | null;
  lastPublishedAt: string | null;
  activeRunId: string | null;
  run: {
    id: string;
    state: PublishRunState;
    mode: PublishMode;
    counts: ICatalogPublishRun['counts'];
    startedAt: string | null;
    finishedAt: string | null;
    error?: { code: string; message: string };
  } | null;
  products: PublishProductStatusDto[];
  /** What would block a publish right now — the same set POST /publish uses. */
  gates: PublishGate[];
}

/**
 * GET /catalog/publish/status.
 *
 * SERVER TRUTH, entirely. Nothing here is derived from anything the client
 * holds, so a second device polling the same endpoint mid-run sees the identical
 * payload — which is the only way "publishing… 7 of 10" can be honest on a phone
 * and a tablet at once.
 */
export async function getPublishStatus(
  userId: string
): Promise<{ outcome: 'OK'; status: PublishStatusDto } | { outcome: 'NOT_FOUND' }> {
  const loaded = await ownCatalog(userId);
  if (!loaded) return { outcome: 'NOT_FOUND' };

  const catalogId = loaded._id as Types.ObjectId;

  // LAZY REPAIR ON READ — the polling clients way out of a lock whose run can
  // never finish (releaseAbandonedRun leaves anything merely slow alone). It
  // must happen BEFORE the run is read below: reading first would pair a
  // cleared lock with a run still reported as QUEUED, and the screen would go
  // on spinning against a run that had just been failed underneath it.
  const catalog =
    loaded.activePublishRunId && (await releaseAbandonedRun(catalogId, loaded.activePublishRunId))
      ? ((await ownCatalog(userId)) ?? loaded)
      : loaded;

  const [run, products] = await Promise.all([
    CatalogPublishRun.findOne({ catalogId }).sort({ createdAt: -1 }).lean().exec(),
    CatalogProduct.find({ catalogId, deletedAt: null })
      .sort({ position: 1, _id: 1 })
      .exec(),
  ]);

  const gates = await evaluatePublishGates(catalog, products);

  return {
    outcome: 'OK',
    status: {
      status: catalog.status,
      hasDraftChanges: catalog.draftRevision > catalog.publishedRevision,
      publicUrl: catalog.publicUrl ?? null,
      lastPublishedAt: catalog.lastPublishedAt?.toISOString() ?? null,
      activeRunId: catalog.activePublishRunId?.toHexString() ?? null,
      run: run
        ? {
            id: String(run._id),
            state: run.state,
            mode: run.mode,
            counts: run.counts,
            startedAt: run.startedAt?.toISOString() ?? null,
            finishedAt: run.finishedAt?.toISOString() ?? null,
            ...(run.error ? { error: { code: run.error.code, message: run.error.message } } : {}),
          }
        : null,
      // Field by field, never a spread — `syncError.at` and every mapping field
      // stay server-side, and a schema that grows cannot leak into a response.
      products: products.map((product) => ({
        id: (product._id as Types.ObjectId).toHexString(),
        name: product.name,
        type: product.type,
        syncStatus: product.syncStatus,
        ...(product.syncError
          ? { code: product.syncError.code, message: product.syncError.message }
          : {}),
      })),
      gates,
    },
  };
}

export { CATALOG_NAME_TAKEN };
