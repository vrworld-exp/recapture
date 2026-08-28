// src/validation/analyticsSchemas.ts
//
// The canonical analytics tracking plan: event names + per-event property
// schemas. This file is the SINGLE source of truth — the typed `track()` emitter
// (utils/analytics.ts) references it so no raw event-name string literal or
// unvalidated property shape can exist anywhere else. The human-readable mirror
// lives in docs/analytics-tracking-plan.md and MUST be kept in sync with this.
import { z } from 'zod';
// Reuse the SAME enum constants POST /projects validates against — analytics
// must never declare divergent object_size/mode literals.
import { OBJECT_SIZE_VALUES, CAPTURE_MODE_VALUES } from '@/validation/projectSchemas';
// Same rule for the capture flow variant ids (POST /jobs' enum).
import { CAPTURE_FLOW_VARIANTS } from '@/models/types/captureVariants';
// And for access roles (the User model's enum) — admin events carry the
// actor's role as an enum value, never a free-form string.
import { USER_ROLES } from '@/models/User';
// Same for the project status filter values the admin list accepts.
import { PROJECT_SOURCE_VALUES, PROJECT_STATUS_VALUES } from '@/models/Project';
// And for a generated model's origin flag (meshy | manual).
import { MODEL_SOURCES } from '@/models/types/projectModel.types';
// And for the admin project-delete mode (SOFT | HARD) — the route's enum.
import { ADMIN_DELETE_MODES } from '@/validation/adminSchemas';
// And for the catalog product kind (THREE_D | IMAGE_ONLY) and the bulk-action
// verb — the same constants the /catalog routes validate against.
import {
  PRODUCT_TYPES,
  PUBLISH_ACTIONS,
  PUBLISH_MODES,
  PUBLISH_RUN_STATES,
  PUBLISH_TARGET_KINDS,
} from '@/models/types/catalog.types';
import { BULK_PRODUCT_ACTIONS } from '@/validation/catalogSchemas';

/**
 * Canonical event names. Every emit references a member of this const; passing
 * any other string is a compile error at the `track()` boundary.
 */
export const AnalyticsEvent = {
  // ── Foundational ──────────────────────────────────────────────────────────
  APP_OPENED: 'app_opened',
  AUTH_OTP_SENT: 'auth_otp_sent',
  AUTH_OTP_VERIFIED: 'auth_otp_verified',
  AUTH_FAILED: 'auth_failed',
  // ── Auth session lifecycle ────────────────────────────────────────────────
  AUTH_TOKEN_REFRESHED: 'auth_token_refreshed',
  AUTH_REFRESH_REUSE_DETECTED: 'auth_refresh_reuse_detected',
  // ── Projects Hub ──────────────────────────────────────────────────────────
  PROJECTS_LISTED: 'projects_listed',
  PROJECT_CREATED: 'project_created',
  PROJECT_RENAMED: 'project_renamed',
  PROJECT_DELETED: 'project_deleted',
  PROJECT_RESUMED: 'project_resumed',
  // ── Upload pipeline (jobs) ────────────────────────────────────────────────
  JOB_CREATED: 'job_created',
  JOB_UPLOAD_STARTED: 'job_upload_started',
  JOB_QUEUED: 'job_queued',
  // ── Config delivery ───────────────────────────────────────────────────────
  REMOTE_CONFIG_SERVED: 'remote_config_served',
  // ── Pre-Capture & Permissions (client-emitted) ────────────────────────────
  PERMISSION_CAMERA_GRANTED: 'permission_camera_granted',
  PERMISSION_MOTION_GRANTED: 'permission_motion_granted',
  PERMISSION_DENIED: 'permission_denied',
  // ── Pre-Capture checklist funnel (client-emitted) ─────────────────────────
  PRECAPTURE_CHECKLIST_STARTED: 'precapture_checklist_started',
  PRECAPTURE_TIP_OPENED: 'precapture_tip_opened',
  // ── Admin / staff live-projects access (P7-A) ─────────────────────────────
  ADMIN_PROJECTS_LISTED: 'admin_projects_listed',
  PROJECT_EXPORT_GENERATED: 'project_export_generated',
  PROJECT_PHOTOS_DELETED: 'project_photos_deleted',
  ADMIN_PROJECT_DELETED: 'admin_project_deleted',
  ADMIN_ACCESS_DENIED: 'admin_access_denied',
  // ── Meshy AI model generation (staff-triggered) ───────────────────────────
  MODEL_GENERATION_REQUESTED: 'model_generation_requested',
  MODEL_GENERATION_DECLINED: 'model_generation_declined',
  MODEL_APPROVED: 'model_approved',
  MODEL_IMAGE_UPLOADS_GENERATED: 'model_image_uploads_generated',
  // ── Artist photo-upload projects (MODEL_ARTIST) ───────────────────────────
  PHOTO_UPLOAD_SESSION_CREATED: 'photo_upload_session_created',
  PHOTO_UPLOAD_COMMITTED: 'photo_upload_committed',
  PHOTO_UPLOAD_GENERATION_REQUESTED: 'photo_upload_generation_requested',
  // ── Model optimization (the OPT variant) ──────────────────────────────────
  MODEL_OPTIMIZE_REQUESTED: 'model_optimize_requested',
  MODEL_OPTIMIZE_COMPLETED: 'model_optimize_completed',
  // ── Catalog authoring (the Mirage publish feature) ────────────────────────
  CATALOG_CREATED: 'catalog_created',
  CATALOG_UPDATED: 'catalog_updated',
  CATALOG_DELETED: 'catalog_deleted',
  CATALOG_CATEGORY_CREATED: 'catalog_category_created',
  CATALOG_CATEGORY_DELETED: 'catalog_category_deleted',
  CATALOG_PRODUCTS_LISTED: 'catalog_products_listed',
  CATALOG_PRODUCT_CREATED: 'catalog_product_created',
  CATALOG_PRODUCT_UPDATED: 'catalog_product_updated',
  CATALOG_PRODUCT_ARCHIVED: 'catalog_product_archived',
  CATALOG_PRODUCT_DELETED: 'catalog_product_deleted',
  CATALOG_PRODUCTS_BULK_ACTION: 'catalog_products_bulk_action',
  CATALOG_CLIENT_PROVISIONED: 'catalog_client_provisioned',
  // ── Publish runs (the worker's own lifecycle) ─────────────────────────────
  // Emitted by the publish PROCESSOR, not by a route: the run is a background
  // unit and the endpoint that enqueues it knows nothing about how it went.
  CATALOG_PUBLISH_STARTED: 'catalog_publish_started',
  CATALOG_PUBLISH_FINISHED: 'catalog_publish_finished',
  CATALOG_PUBLISH_TARGET_FAILED: 'catalog_publish_target_failed',
  // ── Publish REQUESTS (the endpoints) ──────────────────────────────────────
  // Separate from the run lifecycle above because they answer a different
  // question: how often does a user TRY to publish, and what stops them. A
  // blocked attempt never produces a run at all, so it is invisible to the
  // events above — and it is the number that says whether the gates are
  // helping or just in the way.
  CATALOG_PUBLISH_REQUESTED: 'catalog_publish_requested',
  CATALOG_UNPUBLISH_REQUESTED: 'catalog_unpublish_requested',
  CATALOG_QR_RENDERED: 'catalog_qr_rendered',
} as const;

export type AnalyticsEventName = (typeof AnalyticsEvent)[keyof typeof AnalyticsEvent];

// Fixed enum vocabularies — never free-form strings.
export const ANALYTICS_CHANNELS = ['sms', 'email'] as const;
export const AUTH_STAGES = ['send_otp', 'verify_otp', 'refresh'] as const;
export const AUTH_FAIL_REASONS = [
  'wrong_code',
  'expired',
  'locked',
  'no_record',
  'rate_limited',
  'dispatch_failed',
  'invalid_token',
] as const;
export const CLIENT_PLATFORMS = ['ios', 'android', 'web'] as const;
/** Where a project_resumed open originated (optional context). */
export const RESUME_SOURCES = ['projects_list', 'deep_link', 'direct'] as const;

/**
 * Which surface asked for a 3D model. Three genuinely different risk profiles:
 * a human picked the photos, a human pressed a button and the SERVER picked
 * them, or nobody asked at all.
 */
export const MODEL_GENERATION_TRIGGERS = ['staff_selection', 'manual_button', 'auto'] as const;

/** The photo selector's typed refusals (AutoSelectionDeclineReason). */
export const MODEL_DECLINE_REASONS = [
  'MANIFEST_UNREADABLE',
  'NO_USABLE_PHOTOS',
  'INSUFFICIENT_SPREAD',
] as const;

// ── Permissions ──────────────────────────────────────────────────────────────
/** How a permission grant was obtained: the in-app OS prompt, or the user
 * enabling it in Settings (detected on resume). */
export const PERMISSION_GRANT_SOURCES = ['prompt', 'settings_return'] as const;
/**
 * Unified app-facing permission keys. NOTE: media access is `photos` (matching
 * the client's `AppPermissionType` and the existing `precapture_permission_result`
 * event) — NOT the Android native channel's internal `storage` logical key. This
 * keeps every client analytics event consistent; see the tracking-plan doc.
 */
export const PERMISSION_KEYS = ['camera', 'motion', 'photos'] as const;
/** Non-granted outcomes carried by `permission_denied` (mirror PermissionUiStatus;
 * `unavailable` is intentionally absent — it is neither a grant nor a denial). */
export const PERMISSION_DENIED_STATUSES = ['denied', 'permanentlyDenied', 'restricted'] as const;
/** How strongly the permission gates progress (camera=required, motion=recommended,
 * photos=optional). */
export const PERMISSION_CRITICALITY = ['required', 'recommended', 'optional'] as const;

// ── Pre-Capture checklist ────────────────────────────────────────────────────
/** How a checklist item's tip surface was presented — platform-derived from
 * `Theme.platform` (Material bottom sheet on Android, Cupertino popover on iOS).
 * Optional context for platform analysis; the tip content is identical. */
export const PRECAPTURE_TIP_PRESENTATIONS = ['bottom_sheet', 'popover'] as const;

// ── Per-event property schemas ──────────────────────────────────────────────
// snake_case property names throughout. Identifiers are ALWAYS pre-hashed by the
// caller (identifier_hash / user_id_hash). `.strict()` rejects any unknown field
// so raw PII/secret keys can never ride along. Reused across all events.

/** Client cold start. Client-emitted — the backend does not currently ingest
 * this (no /events endpoint); the schema is the shared contract the client
 * validates against before sending to the destination directly. */
const appOpenedProps = z
  .object({
    platform: z.enum(CLIENT_PLATFORMS),
    app_version: z.string().min(1),
    is_cold_start: z.boolean().optional(),
  })
  .strict();

const authOtpSentProps = z
  .object({
    channel: z.enum(ANALYTICS_CHANNELS),
    identifier_hash: z.string().min(1),
    success: z.boolean(),
  })
  .strict();

const authOtpVerifiedProps = z
  .object({
    channel: z.enum(ANALYTICS_CHANNELS),
    identifier_hash: z.string().min(1),
    is_new_user: z.boolean(),
  })
  .strict();

/** Canonical failure event — supersedes the former `auth_otp_verify_failed`. */
const authFailedProps = z
  .object({
    stage: z.enum(AUTH_STAGES),
    reason: z.enum(AUTH_FAIL_REASONS),
    channel: z.enum(ANALYTICS_CHANNELS).optional(),
    identifier_hash: z.string().min(1).optional(),
  })
  .strict();

const authTokenRefreshedProps = z
  .object({
    family_id: z.string().min(1),
    user_id_hash: z.string().min(1),
  })
  .strict();

const authRefreshReuseDetectedProps = z
  .object({
    family_id: z.string().min(1),
    user_id_hash: z.string().min(1),
  })
  .strict();

const projectsListedProps = z
  .object({
    user_id_hash: z.string().min(1),
    result_count: z.number().int().nonnegative(),
    is_empty: z.boolean(),
  })
  .strict();

const projectCreatedProps = z
  .object({
    user_id_hash: z.string().min(1),
    project_id: z.string().min(1),
    // NULL on an upload project — it has neither. Nullable rather than
    // omitted so the property set stays the same shape for every project.
    object_size: z.enum(OBJECT_SIZE_VALUES).nullable(),
    mode: z.enum(CAPTURE_MODE_VALUES).nullable(),
    source: z.enum(PROJECT_SOURCE_VALUES),
    // `category` is free-form in this product (no fixed taxonomy in
    // projectSchemas), so it stays a nullable string — not an enum.
    category: z.string().nullable(),
  })
  .strict();

const projectRenamedProps = z
  .object({
    user_id_hash: z.string().min(1),
    project_id: z.string().min(1),
    was_changed: z.boolean(),
  })
  .strict();

const projectDeletedProps = z
  .object({
    user_id_hash: z.string().min(1),
    project_id: z.string().min(1),
    was_already_deleted: z.boolean(),
  })
  .strict();

/** A user re-opened an existing, owned, non-deleted project (GET /projects/:id). */
const projectResumedProps = z
  .object({
    user_id_hash: z.string().min(1),
    project_id: z.string().min(1),
    // Optional context, included only when cheaply available.
    source: z.enum(RESUME_SOURCES).optional(),
    seconds_since_last_update: z.number().int().nonnegative().optional(),
  })
  .strict();

const jobCreatedProps = z
  .object({
    user_id_hash: z.string().min(1),
    project_id: z.string().min(1),
    job_id: z.string().min(1),
    object_size: z.enum(OBJECT_SIZE_VALUES),
    // Optional so pre-variant emitters/backfills stay valid; enum-locked to
    // the capture variant wire ids. Not PII.
    flow_variant: z.enum(CAPTURE_FLOW_VARIANTS).optional(),
    expected_files_count: z.number().int().positive(),
  })
  .strict();

const jobUploadStartedProps = z
  .object({
    user_id_hash: z.string().min(1),
    job_id: z.string().min(1),
  })
  .strict();

const jobQueuedProps = z
  .object({
    user_id_hash: z.string().min(1),
    job_id: z.string().min(1),
    flow_variant: z.enum(CAPTURE_FLOW_VARIANTS).optional(),
    files_verified: z.number().int().positive(),
  })
  .strict();

const remoteConfigServedProps = z
  .object({
    config_version: z.number().int().nonnegative(),
    served_defaults: z.boolean(),
  })
  .strict();

// Permission-funnel events. CLIENT-emitted on grant/deny TRANSITIONS only (never
// on passive check()/resume re-checks). Permissions may precede auth, so
// `user_id_hash` is optional (omitted pre-login, joined later). Camera and Motion
// have named granted events; denials use a single generic event carrying the
// permission — see the tracking-plan doc for the documented naming asymmetry.
const permissionCameraGrantedProps = z
  .object({
    source: z.enum(PERMISSION_GRANT_SOURCES).optional(),
    user_id_hash: z.string().min(1).optional(),
  })
  .strict();

const permissionMotionGrantedProps = z
  .object({
    source: z.enum(PERMISSION_GRANT_SOURCES).optional(),
    user_id_hash: z.string().min(1).optional(),
  })
  .strict();

const permissionDeniedProps = z
  .object({
    permission: z.enum(PERMISSION_KEYS),
    status: z.enum(PERMISSION_DENIED_STATUSES),
    criticality: z.enum(PERMISSION_CRITICALITY),
    user_id_hash: z.string().min(1).optional(),
  })
  .strict();

// Pre-capture checklist funnel. CLIENT-emitted (Screen 4 + its tip surface).
// `precapture_checklist_started` is a REACH metric: it fires once per checklist
// screen ENTRY (not the Start-CTA conversion, and never on rebuilds). The pre-
// capture screen may precede auth, so `user_id_hash` is optional. `item_id` is
// the checklist item's stable id — not PII.
const precaptureChecklistStartedProps = z
  .object({
    // How the user arrived at the checklist (optional context).
    source: z.string().min(1).optional(),
    user_id_hash: z.string().min(1).optional(),
  })
  .strict();

const precaptureTipOpenedProps = z
  .object({
    item_id: z.string().min(1),
    presentation: z.enum(PRECAPTURE_TIP_PRESENTATIONS).optional(),
    user_id_hash: z.string().min(1).optional(),
  })
  .strict();

// Admin / staff live-projects events (P7-A). All identifiers pre-hashed via
// hashIdentifier — an admin event must never carry a raw user/project id pair
// that links an owner to their content outside the authed API surface.

/** A staff user listed the cross-user live projects (GET /admin/projects). */
const adminProjectsListedProps = z
  .object({
    actor_role: z.enum(USER_ROLES),
    // The APPLIED status filter: 'default' = the uploaded-and-finalized set
    // (PROCESSING/COMPLETED); otherwise the explicit ?status= override.
    status_filter: z.enum([...PROJECT_STATUS_VALUES, 'default'] as const),
    page_size: z.number().int().positive(),
  })
  .strict();

/** A presigned export manifest was generated (GET /admin/projects/:id/export).
 * NEVER carries a presigned URL — ids are hashed, counts are counts. */
const projectExportGeneratedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    project_id_hash: z.string().min(1),
    job_id_hash: z.string().min(1),
    file_count: z.number().int().nonnegative(),
    ttl_seconds: z.number().int().positive(),
  })
  .strict();

/** Staff soft-deleted captured photos (DELETE /admin/projects/:id/photos).
 * NEVER carries a key or presigned URL — ids are hashed, the rest are counts. */
const projectPhotosDeletedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    project_id_hash: z.string().min(1),
    job_id_hash: z.string().min(1),
    deleted_count: z.number().int().nonnegative(),
    missing_count: z.number().int().nonnegative(),
  })
  .strict();

/** ADMIN deleted a whole project (DELETE /admin/projects/:id) — the curation
 * path for bad captures. Hashed ids only; `mode` says SOFT (recoverable flag)
 * vs HARD (storage + records purged). The count fields are mode-specific. */
const adminProjectDeletedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    project_id_hash: z.string().min(1),
    owner_id_hash: z.string().min(1),
    mode: z.enum(ADMIN_DELETE_MODES),
    /** SOFT only: the flag was already set (idempotent replay). */
    was_already_deleted: z.boolean().optional(),
    /** HARD only: S3 objects removed across both buckets. */
    objects_deleted: z.number().int().nonnegative().optional(),
  })
  .strict();

// Meshy model-generation events. Same PII stance as the rest of /admin: hashed
// ids and counts only. NEVER a selected key, a presigned source URL, or the
// Meshy task id — `key_count` is all the selection detail that ships.

/** Staff requested a Meshy generation (POST /admin/projects/:id/model). */
const modelGenerationRequestedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    project_id_hash: z.string().min(1),
    job_id_hash: z.string().min(1),
    model_id_hash: z.string().min(1),
    source: z.enum(MODEL_SOURCES),
    key_count: z.number().int().positive(),
    /** True when an Idempotency-Key replayed an existing record (no new charge). */
    was_replay: z.boolean(),
    /**
     * WHICH surface asked. Optional so every pre-existing emit stays valid.
     * Named `trigger`, not `source`, because `source` above is already the
     * model's ORIGIN (meshy vs the in-house pipeline) and the two must not be
     * confused in the tracking plan.
     */
    trigger: z.enum(MODEL_GENERATION_TRIGGERS).optional(),
    /** The requester's role — staff and owners have different ceilings. */
    actor_role: z.enum(USER_ROLES).optional(),
    /** Staff force-regenerate: a deliberate second charge for the same capture. */
    forced: z.boolean().optional(),
  })
  .strict();

/**
 * The SERVER-side photo selector refused to spend on a capture.
 *
 * The single most valuable event in this feature: the selector has only ever
 * run against synthetic manifests, and these counters are what say whether a
 * real-world decline is a genuinely bad capture, a threshold set too tight, or
 * simply a capture packed before the manifest carried sharpness at all
 * (`dropped_no_blur` large). Counts only — never a key.
 */
const modelGenerationDeclinedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    project_id_hash: z.string().min(1),
    trigger: z.enum(MODEL_GENERATION_TRIGGERS),
    reason: z.enum(MODEL_DECLINE_REASONS),
    pool_size: z.number().int().nonnegative(),
    /** Photos with no quality.blurScore — the pre-2026-07-21 manifest tell. */
    dropped_no_blur: z.number().int().nonnegative(),
    /** How many of the four yaw quadrants had at least one usable photo. */
    quadrants_filled: z.number().int().nonnegative(),
  })
  .strict();

/** Staff requested presigned PUT slots for EDITED model-input images
 * (POST /admin/projects/:id/model-images/upload-urls). Ids hashed, counts only —
 * NEVER a key or presigned URL. */
const modelImageUploadsGeneratedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    project_id_hash: z.string().min(1),
    job_id_hash: z.string().min(1),
    file_count: z.number().int().positive(),
    ttl_seconds: z.number().int().positive(),
  })
  .strict();

/** Staff approved a generated model — the "skip manual creation" signal. */
const modelApprovedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    project_id_hash: z.string().min(1),
    model_id_hash: z.string().min(1),
    source: z.enum(MODEL_SOURCES),
  })
  .strict();

/**
 * Someone asked for a model to be optimized.
 *
 * `source_bytes` is the whole point of the event: it is the distribution that
 * says whether the 8 MiB threshold is set anywhere near the right place. Ids
 * are hashed; no keys, no URLs.
 */
const modelOptimizeRequestedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    project_id_hash: z.string().min(1),
    /** The SOURCE model — the one the button was on. */
    model_id_hash: z.string().min(1),
    /** The OPT record created (or replayed). */
    optimized_model_id_hash: z.string().min(1),
    source_bytes: z.number().int().nonnegative(),
    /** True when an OPT record already existed (no new work enqueued). */
    was_replay: z.boolean(),
    /** Which surface asked — staff history list, or the owner's viewer. */
    surface: z.enum(['staff', 'owner']),
  })
  .strict();

/** An optimization finished. The saving is what says the feature is worth its
 * CPU; `degraded` says whether the texture passes actually ran. */
const modelOptimizeCompletedProps = z
  .object({
    project_id_hash: z.string().min(1),
    model_id_hash: z.string().min(1),
    source_bytes: z.number().int().nonnegative(),
    output_bytes: z.number().int().nonnegative(),
    /** Passes skipped for a missing optional dependency (usually `sharp`). */
    degraded: z.array(z.string()).optional(),
  })
  .strict();

// ── Catalog authoring ───────────────────────────────────────────────────────
// Catalog/product/category NAMES are business content, not analytics data, and
// never appear here — only ids, enums and counts. `catalog_id` is an opaque
// ObjectId the same way `project_id` already is.

const catalogCreatedProps = z
  .object({
    user_id_hash: z.string().min(1),
    catalog_id: z.string().min(1),
    /** True when the create was a replay of an existing catalog. */
    was_existing: z.boolean(),
  })
  .strict();

/**
 * The catalog was bound to a Mirage restaurant — the moment its public URL is
 * minted and frozen, and therefore the moment the QR becomes printable. Emitted
 * ONCE per catalog for the rest of its life.
 *
 * The Mirage restaurant id is deliberately absent: it is another system's
 * identifier and the customer-facing URL is built from it, so it is closer to a
 * public address than to an opaque analytics id.
 */
const catalogClientProvisionedProps = z
  .object({
    user_id_hash: z.string().min(1),
    catalog_id: z.string().min(1),
    /** True when an existing Mirage restaurant was adopted instead of created. */
    adopted_existing: z.boolean(),
  })
  .strict();

const catalogUpdatedProps = z
  .object({
    user_id_hash: z.string().min(1),
    catalog_id: z.string().min(1),
    /** Which fields the patch touched — names only, never values. */
    fields: z.array(z.string()).min(1),
  })
  .strict();

/**
 * The user deleted their whole catalog to start over (feature: delete catalog).
 *
 * Worth its own event because it is the one authoring action that is not an
 * edit: it gives up the public URL, and a business doing it is telling us the
 * catalog was not recoverable by editing. The counts say how much work was
 * discarded — no names, so nothing of the owner's content travels.
 */
const catalogDeletedProps = z
  .object({
    user_id_hash: z.string().min(1),
    catalog_id: z.string().min(1),
    deleted_product_count: z.number().int().nonnegative(),
    deleted_category_count: z.number().int().nonnegative(),
    /** True when a live Mirage restaurant was torn down with it. */
    was_published: z.boolean(),
  })
  .strict();

const catalogCategoryCreatedProps = z
  .object({
    user_id_hash: z.string().min(1),
    category_id: z.string().min(1),
  })
  .strict();

const catalogCategoryDeletedProps = z
  .object({
    user_id_hash: z.string().min(1),
    category_id: z.string().min(1),
    /** Products moved to Uncategorized as a result. */
    moved_product_count: z.number().int().nonnegative(),
  })
  .strict();

const catalogProductsListedProps = z
  .object({
    user_id_hash: z.string().min(1),
    result_count: z.number().int().nonnegative(),
    is_filtered: z.boolean(),
  })
  .strict();

const catalogProductCreatedProps = z
  .object({
    user_id_hash: z.string().min(1),
    product_id: z.string().min(1),
    product_type: z.enum(PRODUCT_TYPES),
    has_category: z.boolean(),
  })
  .strict();

const catalogProductUpdatedProps = z
  .object({
    user_id_hash: z.string().min(1),
    product_id: z.string().min(1),
    fields: z.array(z.string()).min(1),
  })
  .strict();

const catalogProductArchivedProps = z
  .object({
    user_id_hash: z.string().min(1),
    product_id: z.string().min(1),
    /** false = restored. */
    archived: z.boolean(),
  })
  .strict();

const catalogProductDeletedProps = z
  .object({
    user_id_hash: z.string().min(1),
    product_id: z.string().min(1),
    was_already_deleted: z.boolean(),
  })
  .strict();

const catalogProductsBulkActionProps = z
  .object({
    user_id_hash: z.string().min(1),
    action: z.enum(BULK_PRODUCT_ACTIONS),
    requested_count: z.number().int().nonnegative(),
    affected_count: z.number().int().nonnegative(),
  })
  .strict();

/** requireRole rejected an authenticated caller (role below the minimum). */
const adminAccessDeniedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    route: z.string().min(1),
  })
  .strict();

// ── Artist photo-upload projects ─────────────────────────────────────────────
//
// NON-PII ONLY, and in particular: no S3 keys and no presigned URLs. A
// presigned URL is a bearer credential — it belongs in a response body and
// nowhere else. Identifiers are hashed with the ONE hashing util
// (utils/otp.ts -> hashIdentifier); project/job ids are opaque ObjectIds that
// the existing project events already carry in the clear, so they stay that way
// here for consistency with them.

/** An artist opened an upload session (server assigned the keys). Costs nothing. */
const photoUploadSessionCreatedProps = z
  .object({
    user_id_hash: z.string().min(1),
    project_id: z.string().min(1),
    file_count: z.number().int().nonnegative(),
  })
  .strict();

/** The photo set was verified in S3 and the job flipped to UPLOADED. */
const photoUploadCommittedProps = z
  .object({
    user_id_hash: z.string().min(1),
    project_id: z.string().min(1),
    job_id: z.string().min(1),
    photo_count: z.number().int().nonnegative(),
    total_bytes: z.number().int().nonnegative(),
  })
  .strict();

/** The artist hand-picked a selection and asked for a model. THIS is the
 * event that corresponds to spending Meshy credits. */
const photoUploadGenerationRequestedProps = z
  .object({
    user_id_hash: z.string().min(1),
    project_id: z.string().min(1),
    job_id: z.string().min(1),
    selected_count: z.number().int().nonnegative(),
  })
  .strict();

/**
 * A publish run began.
 *
 * NOTE what is absent and must stay absent: no product names, no category
 * names, no business name, no phone or email. `targetName` is catalog content
 * and the run entries are where it belongs — an analytics pipeline is a
 * different blast radius (catalog.types.ts, PublishRunEntry).
 */
const catalogPublishStartedProps = z
  .object({
    user_id_hash: z.string().min(1),
    catalog_id: z.string().min(1),
    run_id: z.string().min(1),
    mode: z.enum(PUBLISH_MODES),
    /** Steps the planner emitted — the denominator of "7 of 10 published". */
    planned_total: z.number().int().nonnegative(),
  })
  .strict();

const catalogPublishFinishedProps = z
  .object({
    user_id_hash: z.string().min(1),
    catalog_id: z.string().min(1),
    run_id: z.string().min(1),
    mode: z.enum(PUBLISH_MODES),
    state: z.enum(PUBLISH_RUN_STATES),
    total: z.number().int().nonnegative(),
    synced: z.number().int().nonnegative(),
    failed: z.number().int().nonnegative(),
    skipped: z.number().int().nonnegative(),
  })
  .strict();

/**
 * One target failed inside an otherwise-continuing run.
 *
 * ⚠ The ReCapture failure code travels as `failure_reason`, NOT as `code`:
 * utils/analytics.ts strips any property whose NAME contains "code" as a
 * suspected OTP/secret leak, so a prop called `code` (or `error_code`, or
 * `failure_code`) would be silently dropped and this event would carry no
 * diagnosis at all.
 */
const catalogPublishTargetFailedProps = z
  .object({
    user_id_hash: z.string().min(1),
    catalog_id: z.string().min(1),
    run_id: z.string().min(1),
    target: z.enum(PUBLISH_TARGET_KINDS),
    action: z.enum(PUBLISH_ACTIONS),
    /** The UPPER_SNAKE ReCapture code. Never Mirage prose. */
    failure_reason: z.string().min(1),
  })
  .strict();

/**
 * A publish attempt, whatever came of it.
 *
 * `blocked_by` carries the gate codes, never their messages — the messages name
 * products ("\"Chair\" has no photo yet"), and a product name is catalog content
 * that must not leave the owner's own responses.
 */
const catalogPublishRequestedProps = z
  .object({
    user_id_hash: z.string().min(1),
    catalog_id: z.string().min(1),
    mode: z.enum(PUBLISH_MODES),
    outcome: z.enum(['QUEUED', 'BLOCKED', 'IN_PROGRESS', 'NAME_TAKEN', 'NOTHING_TO_RETRY']),
    /** How many gates failed. Zero on a successful request. */
    gate_count: z.number().int().nonnegative(),
    /** The distinct UPPER_SNAKE gate codes, deduplicated. Never messages. */
    blocked_by: z.array(z.string().min(1)).optional(),
  })
  .strict();

const catalogUnpublishRequestedProps = z
  .object({
    user_id_hash: z.string().min(1),
    catalog_id: z.string().min(1),
    outcome: z.enum(['QUEUED', 'NOT_PUBLISHED', 'IN_PROGRESS']),
  })
  .strict();

/** A QR render. No URL, no business name — the format and the size, nothing else. */
const catalogQrRenderedProps = z
  .object({
    user_id_hash: z.string().min(1),
    catalog_id: z.string().min(1),
    format: z.enum(['png', 'pdf']),
    size: z.number().int().positive(),
  })
  .strict();

/**
 * Registry mapping every event name to its property schema. The `satisfies`
 * clause makes this EXHAUSTIVE: forgetting a schema for any AnalyticsEventName
 * is a compile error.
 */
export const EVENT_SCHEMAS = {
  [AnalyticsEvent.APP_OPENED]: appOpenedProps,
  [AnalyticsEvent.AUTH_OTP_SENT]: authOtpSentProps,
  [AnalyticsEvent.AUTH_OTP_VERIFIED]: authOtpVerifiedProps,
  [AnalyticsEvent.AUTH_FAILED]: authFailedProps,
  [AnalyticsEvent.AUTH_TOKEN_REFRESHED]: authTokenRefreshedProps,
  [AnalyticsEvent.AUTH_REFRESH_REUSE_DETECTED]: authRefreshReuseDetectedProps,
  [AnalyticsEvent.PROJECTS_LISTED]: projectsListedProps,
  [AnalyticsEvent.PROJECT_CREATED]: projectCreatedProps,
  [AnalyticsEvent.PROJECT_RENAMED]: projectRenamedProps,
  [AnalyticsEvent.PROJECT_DELETED]: projectDeletedProps,
  [AnalyticsEvent.PROJECT_RESUMED]: projectResumedProps,
  [AnalyticsEvent.JOB_CREATED]: jobCreatedProps,
  [AnalyticsEvent.JOB_UPLOAD_STARTED]: jobUploadStartedProps,
  [AnalyticsEvent.JOB_QUEUED]: jobQueuedProps,
  [AnalyticsEvent.REMOTE_CONFIG_SERVED]: remoteConfigServedProps,
  [AnalyticsEvent.PERMISSION_CAMERA_GRANTED]: permissionCameraGrantedProps,
  [AnalyticsEvent.PERMISSION_MOTION_GRANTED]: permissionMotionGrantedProps,
  [AnalyticsEvent.PERMISSION_DENIED]: permissionDeniedProps,
  [AnalyticsEvent.PRECAPTURE_CHECKLIST_STARTED]: precaptureChecklistStartedProps,
  [AnalyticsEvent.PRECAPTURE_TIP_OPENED]: precaptureTipOpenedProps,
  [AnalyticsEvent.ADMIN_PROJECTS_LISTED]: adminProjectsListedProps,
  [AnalyticsEvent.PROJECT_EXPORT_GENERATED]: projectExportGeneratedProps,
  [AnalyticsEvent.PROJECT_PHOTOS_DELETED]: projectPhotosDeletedProps,
  [AnalyticsEvent.ADMIN_PROJECT_DELETED]: adminProjectDeletedProps,
  [AnalyticsEvent.ADMIN_ACCESS_DENIED]: adminAccessDeniedProps,
  [AnalyticsEvent.MODEL_GENERATION_REQUESTED]: modelGenerationRequestedProps,
  [AnalyticsEvent.MODEL_GENERATION_DECLINED]: modelGenerationDeclinedProps,
  [AnalyticsEvent.MODEL_APPROVED]: modelApprovedProps,
  [AnalyticsEvent.MODEL_IMAGE_UPLOADS_GENERATED]: modelImageUploadsGeneratedProps,
  [AnalyticsEvent.PHOTO_UPLOAD_SESSION_CREATED]: photoUploadSessionCreatedProps,
  [AnalyticsEvent.PHOTO_UPLOAD_COMMITTED]: photoUploadCommittedProps,
  [AnalyticsEvent.PHOTO_UPLOAD_GENERATION_REQUESTED]: photoUploadGenerationRequestedProps,
  [AnalyticsEvent.MODEL_OPTIMIZE_REQUESTED]: modelOptimizeRequestedProps,
  [AnalyticsEvent.MODEL_OPTIMIZE_COMPLETED]: modelOptimizeCompletedProps,
  [AnalyticsEvent.CATALOG_CREATED]: catalogCreatedProps,
  [AnalyticsEvent.CATALOG_UPDATED]: catalogUpdatedProps,
  [AnalyticsEvent.CATALOG_DELETED]: catalogDeletedProps,
  [AnalyticsEvent.CATALOG_CATEGORY_CREATED]: catalogCategoryCreatedProps,
  [AnalyticsEvent.CATALOG_CATEGORY_DELETED]: catalogCategoryDeletedProps,
  [AnalyticsEvent.CATALOG_PRODUCTS_LISTED]: catalogProductsListedProps,
  [AnalyticsEvent.CATALOG_PRODUCT_CREATED]: catalogProductCreatedProps,
  [AnalyticsEvent.CATALOG_PRODUCT_UPDATED]: catalogProductUpdatedProps,
  [AnalyticsEvent.CATALOG_PRODUCT_ARCHIVED]: catalogProductArchivedProps,
  [AnalyticsEvent.CATALOG_PRODUCT_DELETED]: catalogProductDeletedProps,
  [AnalyticsEvent.CATALOG_PRODUCTS_BULK_ACTION]: catalogProductsBulkActionProps,
  [AnalyticsEvent.CATALOG_CLIENT_PROVISIONED]: catalogClientProvisionedProps,
  [AnalyticsEvent.CATALOG_PUBLISH_STARTED]: catalogPublishStartedProps,
  [AnalyticsEvent.CATALOG_PUBLISH_FINISHED]: catalogPublishFinishedProps,
  [AnalyticsEvent.CATALOG_PUBLISH_TARGET_FAILED]: catalogPublishTargetFailedProps,
  [AnalyticsEvent.CATALOG_PUBLISH_REQUESTED]: catalogPublishRequestedProps,
  [AnalyticsEvent.CATALOG_UNPUBLISH_REQUESTED]: catalogUnpublishRequestedProps,
  [AnalyticsEvent.CATALOG_QR_RENDERED]: catalogQrRenderedProps,
} satisfies Record<AnalyticsEventName, z.ZodTypeAny>;

/** Compile-time map: event name → its validated property type. */
export type EventPropsMap = {
  [K in AnalyticsEventName]: z.infer<(typeof EVENT_SCHEMAS)[K]>;
};
