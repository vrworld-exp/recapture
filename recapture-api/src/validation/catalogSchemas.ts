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
import { BRANDING_SLOTS, PRODUCT_IMAGE_CONTENT_TYPES } from '@/utils/productImageKeys';

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

/**
 * PATCH /catalog/profile — the business-profile screen's write.
 *
 * Deliberately the SAME schema object as {@link updateCatalogSchema}, not a
 * copy: the profile screen edits a SUBSET of the catalog document (there is no
 * separate profile row — see 03-architecture-proposal.md §6, "Changes to
 * existing collections: none"), so a second schema would be two places to keep
 * a bound in sync and one place to forget. The endpoints differ in the DTO they
 * RETURN, not in what they accept.
 */
export const updateBusinessProfileSchema = updateCatalogSchema;

export type UpdateBusinessProfileInput = UpdateCatalogInput;

/**
 * POST /catalog/logo/upload-url — mint a presigned PUT slot for a branding image
 * (feature 2).
 *
 * The same three-step shape as a product image, and the same closed content-type
 * set, because it is the same key space and the same bucket.
 */
export const brandingUploadUrlSchema = z
  .object({
    slot: z.enum(BRANDING_SLOTS),
    contentType: z.enum(PRODUCT_IMAGE_CONTENT_TYPES),
  })
  .strict();

export type BrandingUploadUrlInput = z.infer<typeof brandingUploadUrlSchema>;

/**
 * POST /catalog/logo/bytes — the QUERY of the one-call branding upload.
 *
 * There is no body schema to pair with this: the body IS the image, and its
 * type is sniffed from the bytes rather than declared. Only the slot has to be
 * named, and it rides in the query for the same reason `productId` does.
 */
export const brandingBytesQuerySchema = z
  .object({
    slot: z.enum(BRANDING_SLOTS),
  })
  .strict();

export type BrandingBytesQuery = z.infer<typeof brandingBytesQuerySchema>;

/** PUT /catalog/logo — bind an uploaded object as the logo or cover. */
export const brandingCommitSchema = z
  .object({
    slot: z.enum(BRANDING_SLOTS),
    key: z.string().trim().min(1).max(512),
  })
  .strict();

export type BrandingCommitInput = z.infer<typeof brandingCommitSchema>;

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
    /**
     * A COMMITTED product-image key (from POST /catalog/products/image/upload-url
     * followed by the PUT to S3). Required for an image-only product and
     * forbidden for a 3D one — see the superRefine below.
     *
     * Bounded rather than free-form: the key is parsed strictly by
     * productImageKeys.ts, and a 512-char ceiling stops a pathological body
     * reaching that parser at all.
     */
    imageKey: z.string().trim().min(1).max(512).optional(),
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
    // An image-only product with no image is a card with nothing on it, and it
    // can never publish (the §7.7 gate rejects it). Refuse it here, where the
    // user is still looking at the form, rather than at publish time.
    if (value.type === 'IMAGE_ONLY' && !value.imageKey) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['imageKey'],
        message: 'An image-only product needs an uploaded image',
      });
    }
    if (value.type === 'THREE_D' && value.imageKey) {
      // A 3D product's card image is the model's generated preview; accepting a
      // second source would leave two fields racing to be "the picture".
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['imageKey'],
        message: 'A 3D product uses its model preview, not an uploaded image',
      });
    }
  });

export type CreateProductInput = z.infer<typeof createProductSchema>;

/**
 * PATCH /catalog/products/:id (features 14, 15, 17).
 *
 * `type` IS patchable — but only in a request that also carries the asset the
 * new type needs. That constraint is the whole safety property: an earlier
 * revision of this schema refused `type` outright, on the grounds that a
 * one-word body should not be able to trigger a conversion. Requiring the
 * matching asset in the SAME request addresses that directly, and a conversion
 * that arrives without its asset is a 400 rather than a product left in a state
 * it has no asset for.
 *
 * The publish planner needs no extra marker to notice a conversion: the
 * `publishedSnapshot` already records the `type` that was last pushed, so a
 * conversion is just another field that differs.
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
    /** Convert the product to this type. Requires the matching asset below. */
    type: z.enum(PRODUCT_TYPES).optional(),
    /** Replace the backing 3D model (feature 15), or supply one for a conversion. */
    sourceModelId: objectId('model id').optional(),
    /** Replace the image (feature 16), or supply one for a conversion. */
    imageKey: z.string().trim().min(1).max(512).optional(),
  })
  .strict()
  .refine((v) => Object.keys(v).length > 0, {
    message: 'Provide at least one field to update',
  })
  .superRefine((value, ctx) => {
    if (value.type === 'THREE_D' && !value.sourceModelId) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['sourceModelId'],
        message: 'Converting to a 3D product needs sourceModelId in the same request',
      });
    }
    if (value.type === 'IMAGE_ONLY' && !value.imageKey) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['imageKey'],
        message: 'Converting to an image-only product needs imageKey in the same request',
      });
    }
    // Two assets in one request would leave the resulting type ambiguous.
    if (value.sourceModelId && value.imageKey) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['imageKey'],
        message: 'Send a model or an image, not both',
      });
    }
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

/**
 * POST /catalog/products/:id/duplicate (feature 18).
 *
 * `name` is optional: the service auto-renames to avoid Mirage's
 * per-restaurant name collision when the caller does not choose one.
 */
export const duplicateProductSchema = z
  .object({
    name: z.string().trim().min(1).max(PRODUCT_NAME_MAX).optional(),
  })
  .strict();

export type DuplicateProductInput = z.infer<typeof duplicateProductSchema>;

// ── Product images (features 13, 16) ────────────────────────────────────────

/**
 * POST /catalog/products/image/upload-url — mint one presigned PUT slot.
 *
 * `productId` is OPTIONAL because the upload can legitimately come first: an
 * image-only product is created WITH its committed key (feature 13), so at
 * upload time there is no product yet. When it is absent the route mints a
 * staging slot; when it is present the slot is that product's id and the route
 * checks the caller owns it.
 */
export const productImageUploadUrlSchema = z
  .object({
    contentType: z.enum(PRODUCT_IMAGE_CONTENT_TYPES),
    productId: objectId('product id').optional(),
  })
  .strict();

export type ProductImageUploadUrlInput = z.infer<typeof productImageUploadUrlSchema>;

/**
 * POST /catalog/products/image/bytes — the QUERY of the one-call upload.
 *
 * There is no body schema to pair with this: the body IS the image, and its
 * type is sniffed from the bytes rather than declared. `productId` carries the
 * same optional meaning as on the slot schema above.
 */
export const productImageBytesQuerySchema = z
  .object({
    productId: objectId('product id').optional(),
  })
  .strict();

export type ProductImageBytesQuery = z.infer<typeof productImageBytesQuerySchema>;

/**
 * PUT /catalog/products/:id/image — bind an uploaded object to a product.
 *
 * The key is client-supplied, which is exactly why it is parsed strictly and
 * checked against the caller's own catalog before anything is written.
 */
export const productImageCommitSchema = z
  .object({
    key: z.string().trim().min(1).max(512),
  })
  .strict();

export type ProductImageCommitInput = z.infer<typeof productImageCommitSchema>;

// ── Shared param schemas ────────────────────────────────────────────────────

export const catalogEntityIdParamsSchema = z
  .object({
    id: objectId('id'),
  })
  .strict();

export type CatalogEntityIdParams = z.infer<typeof catalogEntityIdParamsSchema>;

/**
 * GET /catalog/qr query.
 *
 * `size` is CLAMPED by the renderer rather than rejected here — a client asking
 * for 4000 px wants "as big as possible", and a 400 for that is pedantry. What
 * IS rejected is a non-numeric size, because that is a bug in the caller rather
 * than a preference.
 */
export const catalogQrQuerySchema = z
  .object({
    format: z.enum(['png', 'pdf']).default('png'),
    size: z.coerce.number().int().positive().optional(),
  })
  .strict();

/** GET /catalog/activity query. The cursor is opaque; the service validates it. */
export const catalogActivityQuerySchema = z
  .object({
    cursor: z.string().min(1).optional(),
    limit: z.coerce.number().int().positive().max(50).optional(),
  })
  .strict();

/**
 * GET /catalog/analytics/* query.
 *
 * `.strict()` is doing real work here: a client-supplied `restaurant` would be
 * REJECTED rather than silently dropped, which is the loudest way to say that
 * the scope is not theirs to choose. The service ignores it regardless — this
 * is the second lock on the same door.
 */
const isoDay = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD');

export const catalogAnalyticsQuerySchema = z
  .object({
    from: isoDay.optional(),
    to: isoDay.optional(),
  })
  .strict()
  .refine((value) => !value.from || !value.to || value.from <= value.to, {
    message: 'from must not be after to',
    path: ['from'],
  });

export const catalogTopProductsQuerySchema = z
  .object({
    from: isoDay.optional(),
    to: isoDay.optional(),
    limit: z.coerce.number().int().positive().max(100).optional(),
  })
  .strict()
  .refine((value) => !value.from || !value.to || value.from <= value.to, {
    message: 'from must not be after to',
    path: ['from'],
  });
