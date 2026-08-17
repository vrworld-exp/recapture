// src/validation/catalogSchemas.ts
//
// Zod schemas for the /catalog route group — the authoring surface behind the
// Mirage publish flow.
//
// Two rules run through every schema here:
//   • `.strict()` everywhere. Ownership comes ONLY from the access token, so a
//     `userId`/`catalogId` in a body must be REJECTED, not ignored — silently
//     dropping it makes a privilege-escalation attempt look like a success.
//   • Bounds mirror the model's `maxlength` exactly. A value that passes here
//     and then fails Mongoose validation would surface as a 500 instead of the
//     400 it is.
import { z } from 'zod';
import {
  PRODUCT_AVAILABILITIES,
  PRODUCT_TYPES,
} from '@/models/types/catalog.types';

// A Mongo ObjectId as a 24-char hex string. Validated here so a malformed id is
// a 400 that never reaches the DB, and mongoose stays out of the validation
// layer (same approach as projectSchemas.ts).
const OBJECT_ID_RE = /^[a-fA-F0-9]{24}$/;
const objectId = (label: string) => z.string().regex(OBJECT_ID_RE, `Invalid ${label}`);

// Bounds copied from the models. Keep these in lockstep with:
//   Catalog.name 120 / businessName 120 / contact.* (32,254,300,200)
//   CatalogCategory.name 80
//   CatalogProduct.name 120 / description 2000
const CATALOG_NAME_MAX = 120;
const BUSINESS_NAME_MAX = 120;
const CATEGORY_NAME_MAX = 80;
const PRODUCT_NAME_MAX = 120;
const PRODUCT_DESCRIPTION_MAX = 2000;

/** Tag bounds. ReCapture-only today; Mirage now has a tags field too (added in
 *  mirage-be), so these also bound what the publish worker can push. */
const TAG_MAX_LENGTH = 40;
const MAX_TAGS = 20;

// ── Catalog ─────────────────────────────────────────────────────────────────

const socialsSchema = z
  .object({
    instagram: z.string().trim().max(200).optional(),
    facebook: z.string().trim().max(200).optional(),
    youtube: z.string().trim().max(200).optional(),
    whatsapp: z.string().trim().max(40).optional(),
  })
  .strict();

const contactSchema = z
  .object({
    phone: z.string().trim().max(32).optional(),
    email: z.string().trim().max(254).optional(),
    address: z.string().trim().max(300).optional(),
    website: z.string().trim().max(200).optional(),
    socials: socialsSchema.optional(),
  })
  .strict();

/**
 * POST /catalog. Only `name` is required — a business can start with a name and
 * fill branding in later, and forcing the whole profile up front is what makes
 * people abandon setup.
 */
export const createCatalogSchema = z
  .object({
    name: z.string().trim().min(1).max(CATALOG_NAME_MAX),
    businessName: z.string().trim().min(1).max(BUSINESS_NAME_MAX).optional(),
    contact: contactSchema.optional(),
  })
  .strict();

export type CreateCatalogInput = z.infer<typeof createCatalogSchema>;

/**
 * PATCH /catalog. Every field optional, but at least one must be present —
 * an empty patch is a client bug, and answering 200 to it hides that bug while
 * still bumping `draftRevision` (which would light up the "unpublished changes"
 * badge for a change nobody made).
 *
 * `contact` REPLACES the whole contact block when sent. That is deliberate: a
 * deep merge gives no way to clear a single field, and "clear my website" is a
 * real thing a user does.
 */
export const updateCatalogSchema = z
  .object({
    name: z.string().trim().min(1).max(CATALOG_NAME_MAX).optional(),
    businessName: z.string().trim().max(BUSINESS_NAME_MAX).optional(),
    contact: contactSchema.optional(),
  })
  .strict()
  .refine((v) => Object.keys(v).length > 0, {
    message: 'Provide at least one field to update',
  });

export type UpdateCatalogInput = z.infer<typeof updateCatalogSchema>;

// ── Categories ──────────────────────────────────────────────────────────────

export const createCategorySchema = z
  .object({
    name: z.string().trim().min(1).max(CATEGORY_NAME_MAX),
    /** Omit to append at the end — the service resolves the next position. */
    position: z.number().int().min(0).optional(),
  })
  .strict();

export type CreateCategoryInput = z.infer<typeof createCategorySchema>;

export const updateCategorySchema = z
  .object({
    name: z.string().trim().min(1).max(CATEGORY_NAME_MAX).optional(),
    position: z.number().int().min(0).optional(),
  })
  .strict()
  .refine((v) => Object.keys(v).length > 0, {
    message: 'Provide at least one field to update',
  });

export type UpdateCategoryInput = z.infer<typeof updateCategorySchema>;

/**
 * POST /catalog/categories/reorder — the whole ordering in one call.
 *
 * A full ordered id list, not a list of (id, position) pairs: positions derived
 * from array index cannot collide or leave gaps, and the client cannot ship a
 * half-applied ordering. Duplicates are rejected because they would silently
 * make one of the two entries win.
 */
export const reorderSchema = z
  .object({
    ids: z
      .array(objectId('id'))
      .min(1, 'Provide at least one id')
      .max(500, 'Too many ids in one reorder')
      .refine((ids) => new Set(ids).size === ids.length, {
        message: 'Duplicate ids are not allowed',
      }),
  })
  .strict();

export type ReorderInput = z.infer<typeof reorderSchema>;

// ── Products ────────────────────────────────────────────────────────────────

const tagsSchema = z
  .array(z.string().trim().min(1).max(TAG_MAX_LENGTH))
  .max(MAX_TAGS, `At most ${MAX_TAGS} tags`)
  // Normalised here rather than in the service so the stored form and the
  // uniqueness the client sees are decided in exactly one place.
  .transform((tags) => [...new Set(tags.map((t) => t.toLowerCase()))]);

/**
 * POST /catalog/products.
 *
 * `type` decides which source fields are required, enforced with superRefine
 * rather than a discriminated union so the error names the offending field:
 *   THREE_D    — needs `sourceModelId` (the SUCCEEDED ProjectModel to copy
 *                artifacts from). The service re-checks ownership of it.
 *   IMAGE_ONLY — needs no source; the image is attached by the separate
 *                presign → PUT → commit flow, exactly like an avatar.
 *
 * `categoryId` may be explicitly null — that IS the "Uncategorized" bucket
 * (feature 26), not a missing value.
 */
export const createProductSchema = z
  .object({
    type: z.enum(PRODUCT_TYPES),
    name: z.string().trim().min(1).max(PRODUCT_NAME_MAX),
    description: z.string().trim().max(PRODUCT_DESCRIPTION_MAX).optional(),
    price: z.number().min(0).optional(),
    categoryId: objectId('category id').nullable().optional(),
    tags: tagsSchema.optional(),
    availability: z.enum(PRODUCT_AVAILABILITIES).optional(),
    featured: z.boolean().optional(),
    position: z.number().int().min(0).optional(),
    sourceModelId: objectId('model id').optional(),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.type === 'THREE_D' && !value.sourceModelId) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['sourceModelId'],
        message: 'A 3D product needs sourceModelId',
      });
    }
    if (value.type === 'IMAGE_ONLY' && value.sourceModelId) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['sourceModelId'],
        message: 'An image-only product cannot have sourceModelId',
      });
    }
  });

export type CreateProductInput = z.infer<typeof createProductSchema>;

/**
 * PATCH /catalog/products/:id.
 *
 * `type` is NOT patchable here. Converting IMAGE_ONLY → THREE_D changes what
 * has to happen on the Mirage side (§12 edge case 7) and needs its own endpoint
 * that can reason about the published item — allowing it as a field patch would
 * make a one-word body silently trigger a delete-and-recreate on publish.
 */
export const updateProductSchema = z
  .object({
    name: z.string().trim().min(1).max(PRODUCT_NAME_MAX).optional(),
    description: z.string().trim().max(PRODUCT_DESCRIPTION_MAX).optional(),
    price: z.number().min(0).nullable().optional(),
    categoryId: objectId('category id').nullable().optional(),
    tags: tagsSchema.optional(),
    availability: z.enum(PRODUCT_AVAILABILITIES).optional(),
    featured: z.boolean().optional(),
    position: z.number().int().min(0).optional(),
  })
  .strict()
  .refine((v) => Object.keys(v).length > 0, {
    message: 'Provide at least one field to update',
  });

export type UpdateProductInput = z.infer<typeof updateProductSchema>;

/**
 * GET /catalog/products query. `limit` is hard-bounded so no client can trigger
 * an unbounded scan. `categoryId` accepts the literal string `none` to mean the
 * Uncategorized bucket — a null cannot be expressed in a query string.
 */
export const listProductsQuerySchema = z
  .object({
    limit: z.coerce.number().int().min(1).max(100).default(20),
    cursor: z.string().min(1).optional(),
    categoryId: z.union([objectId('category id'), z.literal('none')]).optional(),
    type: z.enum(PRODUCT_TYPES).optional(),
    availability: z.enum(PRODUCT_AVAILABILITIES).optional(),
    /** Case-insensitive substring match on name (feature 29). */
    q: z.string().trim().min(1).max(120).optional(),
    /** Include archived rows, which are hidden by default. */
    includeArchived: z
      .enum(['true', 'false'])
      .default('false')
      .transform((v) => v === 'true'),
  })
  .strict();

export type ListProductsQuery = z.infer<typeof listProductsQuerySchema>;

/**
 * POST /catalog/products/bulk — feature 30.
 *
 * Mirage has no batch endpoints, so a bulk action here is N authoring writes
 * followed by ONE publish run; this endpoint is the authoring half only.
 */
export const BULK_PRODUCT_ACTIONS = ['ARCHIVE', 'RESTORE', 'DELETE', 'SET_CATEGORY'] as const;

export const bulkProductsSchema = z
  .object({
    action: z.enum(BULK_PRODUCT_ACTIONS),
    ids: z
      .array(objectId('product id'))
      .min(1, 'Provide at least one product id')
      .max(200, 'Too many products in one bulk action')
      .refine((ids) => new Set(ids).size === ids.length, {
        message: 'Duplicate ids are not allowed',
      }),
    /** Required by SET_CATEGORY only; null means Uncategorized. */
    categoryId: objectId('category id').nullable().optional(),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.action === 'SET_CATEGORY' && value.categoryId === undefined) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['categoryId'],
        message: 'SET_CATEGORY needs categoryId (null for Uncategorized)',
      });
    }
    if (value.action !== 'SET_CATEGORY' && value.categoryId !== undefined) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['categoryId'],
        message: 'categoryId is only valid with SET_CATEGORY',
      });
    }
  });

export type BulkProductsInput = z.infer<typeof bulkProductsSchema>;

// ── Shared param schemas ────────────────────────────────────────────────────

export const catalogEntityIdParamsSchema = z
  .object({
    id: objectId('id'),
  })
  .strict();

export type CatalogEntityIdParams = z.infer<typeof catalogEntityIdParamsSchema>;
