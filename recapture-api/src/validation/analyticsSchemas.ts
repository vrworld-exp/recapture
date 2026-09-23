// src/validation/analyticsSchemas.ts
//
// The canonical analytics tracking plan: event names + per-event property
// schemas. This file is the SINGLE source of truth — the typed `track()` emitter
// (utils/analytics.ts) references it so no raw event-name string literal or
// unvalidated property shape can exist anywhere else. The human-readable mirror
// lives in docs/analytics-tracking-plan.md and MUST be kept in sync with this.
import { z } from 'zod';
import { NOTIFICATION_AUDIENCE_TYPES, NOTIFICATION_KINDS } from '@/models/Notification';
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
// And for the subscription layer's status vocabulary (the gate's "why").
import {
  BILLING_INTERVALS,
  MANUAL_METHODS,
  PLAN_IDS,
  SUBSCRIPTION_STATUSES,
} from '@/models/types/subscription.types';

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
  ADMIN_PROJECT_OWNER_VIEWED: 'admin_project_owner_viewed',
  // ── Rep field surface (acting on a restaurant's behalf) ───────────────
  REP_RESTAURANT_ACCOUNT_VIEWED: 'rep_restaurant_account_viewed',
  // ── Meshy AI model generation (staff-triggered) ───────────────────────────
  MODEL_GENERATION_REQUESTED: 'model_generation_requested',
  MODEL_GENERATION_DECLINED: 'model_generation_declined',
  MODEL_APPROVED: 'model_approved',
  MODEL_IMAGE_UPLOADS_GENERATED: 'model_image_uploads_generated',
  // ── Staff GLB submission ("Submit model" on a live project) ───────────────
  MODEL_UPLOAD_URL_GENERATED: 'model_upload_url_generated',
  MODEL_UPLOAD_SUBMITTED: 'model_upload_submitted',
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
  // A publish ATTEMPT refused by one of the two subscription gates. Off until
  // Stage 5 flips `subscriptionGatesEnabled`; emitted by the gate wiring in
  // catalogPublishService, once per subscription gate, only on an attempt
  // (never on the status poll, which runs the same gates).
  PUBLISH_BLOCKED_BY_SUBSCRIPTION: 'publish_blocked_by_subscription',
  // ── Subscription trial (Door 1) ───────────────────────────────────────────
  // Emitted by subscriptionService.startTrial, whichever route called it; the
  // `door` says which. Hashed actor only, never the owner's contact.
  SUBSCRIPTION_TRIAL_STARTED: 'subscription_trial_started',
  SUBSCRIPTION_TRIAL_REFUSED: 'subscription_trial_refused',
  // ── Rep "Notify owner to pay" nudge (Door 2, stage-04) ────────────────────
  // Emitted by services/subscription/nudgeService.ts. Hashed actor and owner
  // ids, the status the sentence was chosen from, and which channels landed —
  // never the phone, never the rendered text.
  SUBSCRIPTION_NUDGE_SENT: 'subscription_nudge_sent',
  SUBSCRIPTION_NUDGE_REFUSED: 'subscription_nudge_refused',
  // ── Subscription payments (Doors 2–4, Stage 3) ────────────────────────────
  // Money events carry the opaque catalog id, plan/interval enums, integer
  // paise and hashed actor ids — never a Razorpay contact field, never a card
  // or UPI detail, never the raw webhook body.
  SUBSCRIPTION_ORDER_CREATED: 'subscription_order_created',
  SUBSCRIPTION_PAYMENT_RECORDED: 'subscription_payment_recorded',
  SUBSCRIPTION_PAYMENT_FAILED: 'subscription_payment_failed',
  SUBSCRIPTION_DUPLICATE_PAYMENT_FLAGGED: 'subscription_duplicate_payment_flagged',
  SUBSCRIPTION_MANUAL_PAYMENT_SUBMITTED: 'subscription_manual_payment_submitted',
  SUBSCRIPTION_MANUAL_PAYMENT_DECIDED: 'subscription_manual_payment_decided',
  SUBSCRIPTION_REFUND_ISSUED: 'subscription_refund_issued',
  SUBSCRIPTION_GRACE_EXTENDED: 'subscription_grace_extended',
  // A paid period applied onto a menu that already carries more 3D dishes
  // than the plan covers (E11). Activation is never blocked; this is the
  // admin-side record of the nudge the owner received.
  SUBSCRIPTION_OVER_CAP_ON_ACTIVATE: 'subscription_over_cap_on_activate',
  // The webhook refused or could not place a delivery. `reason` is the whole
  // diagnosis — the body is never logged.
  RAZORPAY_WEBHOOK_REJECTED: 'razorpay_webhook_rejected',
  // An in-app alert fanned out to every ADMIN user (services/subscription/adminAlerts.ts).
  ADMIN_ALERT_SENT: 'admin_alert_sent',
  // ── Subscription gaps (docs/subscription/gaps-addendum.md, Prompt A) ──────
  // A chargeback (B9): the row went ACTIVE → GRACE, never PAUSED, and no
  // refund was issued. `previous_status` says whether a state change happened.
  SUBSCRIPTION_DISPUTE_RECEIVED: 'subscription_dispute_received',
  SUBSCRIPTION_DISPUTE_CLOSED: 'subscription_dispute_closed',
  // Any status transition not made by a payment: today a dispute, in Stage 5
  // the sweeps and the admin. `by` names the author.
  SUBSCRIPTION_STATE_CHANGED: 'subscription_state_changed',
  // ── Subscription enforcement (Stage 5) ────────────────────────────────────
  // The worker told Mirage (or decided not to) whether one restaurant's 3D
  // is on. `skipped` is the D4 last-write check: the owner paid between the
  // enqueue and the run, so the payload no longer matched the row.
  SUBSCRIPTION_AR_ENTITLEMENT_SYNCED: 'subscription_ar_entitlement_synced',
  // The worker told Mirage (or decided not to) whether one restaurant's
  // CUSTOMER PAGE is live — the pending-payment window opening, expiring, or
  // being cleared. `skipped` is the same D4 last-write check, and here it is
  // the guard that stops a stale expiry taking a paid restaurant offline.
  SUBSCRIPTION_PAGE_STATE_SYNCED: 'subscription_page_state_synced',
  // A rep or staff publish opened a pending-payment window: the menu went live
  // before anybody paid, with a deadline. `days` is the window length in force.
  SUBSCRIPTION_PENDING_PAYMENT_STARTED: 'subscription_pending_payment_started',
  // The window ran out unpaid and the customer page was switched off. The one
  // event that means a live link died for non-payment.
  SUBSCRIPTION_PENDING_PAYMENT_EXPIRED: 'subscription_pending_payment_expired',
  // One per lifecycle sweep, zeros included — the heartbeat the runbook
  // watches for. A worker that stops emitting this has stopped sweeping.
  SUBSCRIPTION_SWEEP_RAN: 'subscription_sweep_ran',
  // An admin set how many complimentary standees have been handed over — a
  // human counter, never derived from QR assignments (README C8).
  SUBSCRIPTION_STANDEES_ISSUED: 'subscription_standees_issued',
  // The owner downloaded a receipt PDF. The kind of row, never its amount.
  SUBSCRIPTION_RECEIPT_DOWNLOADED: 'subscription_receipt_downloaded',
  CATALOG_QR_RENDERED: 'catalog_qr_rendered',
  // ── Pre-printed standee inventory ─────────────────────────────────────────
  // The MINT, not the code. A code value is a public identifier for a specific
  // restaurant's menu, so it never becomes an analytics property — only the
  // size of the run and a hashed actor.
  QR_BATCH_MINTED: 'qr_batch_minted',
  // ── Handing a standee to a rep (POST/DELETE /admin/qr-codes/:code/assignment)
  // Two hashed actors — the admin who did it and the rep who now holds it — and
  // the outcome. NEVER the code: it is a public identifier for one restaurant's
  // menu, barred here by the same rule that keeps it out of the mint event.
  // What this answers is whether stock is actually being handed out, or whether
  // reps are still working from codes read off a PDF.
  QR_CODE_ASSIGNED: 'qr_code_assigned',
  // ── The public resolver (GET /r/:code) ────────────────────────────────────
  // THE OUTCOME, AND NOTHING ELSE. A code value is a public identifier for one
  // restaurant's menu, and a scan is one diner's presence in that restaurant —
  // so no code, no catalog id, no restaurant name, no IP and no user agent
  // appears here. What the event is for is the shape of the funnel: how many
  // scans land on a live menu versus a holding page, and whether the error
  // outcome is ever non-zero.
  QR_CODE_SCANNED: 'qr_code_scanned',
  // ── Rep activation (POST /rep/activations) ────────────────────────────────
  // The hashed REP and the outcome. Never the code, never the restaurant's
  // phone: the first is a public identifier for one restaurant's menu, the
  // second is a person.
  QR_CODE_ACTIVATED: 'qr_code_activated',
  // ── In-app notifications (/notifications, /admin/notifications) ───────────
  // The hashed actor/reader, the kind and the audience shape. Never the title
  // or body: an admin may name a specific customer's overdue invoice in one,
  // and a message addressed to a person is that person's business.
  NOTIFICATION_SENT: 'notification_sent',
  NOTIFICATION_RETRACTED: 'notification_retracted',
  NOTIFICATION_READ: 'notification_read',
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

/** A staff user asked for a presigned slot to submit a hand-made GLB into. */
const modelUploadUrlGeneratedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    project_id_hash: z.string().min(1),
    job_id_hash: z.string().min(1),
    ttl_seconds: z.number().int().positive(),
  })
  .strict();

/**
 * A staff GLB submission was committed. `size_bytes` is the point of the event:
 * it is the only signal for how big hand-made models actually are, which is
 * what the MODEL_UPLOAD_MAX_BYTES ceiling has to be tuned against.
 */
const modelUploadSubmittedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    project_id_hash: z.string().min(1),
    model_id_hash: z.string().min(1),
    size_bytes: z.number().int().positive(),
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

/**
 * An ADMIN opened the identity behind a live project (GET /admin/users/:id) —
 * the ONE route that answers with a raw phone/email, so the read is audited.
 *
 * That makes the PROPS a place a leak would be easy and catastrophic: both ids
 * are HASHED with the one hashing util, and neither the identifier nor the
 * display name appears here in any form. `contact_channels` says only WHICH
 * KINDS of identifier the account had — enough to know what an admin could see,
 * worth nothing to anyone who reads the event.
 *
 * ⚠ Its NAME is deliberate. The emit layer strips any prop whose name contains
 * 'phone' or 'email' (utils/analytics.ts), so the obvious `has_phone`/`has_email`
 * pair would be dropped and this event would arrive as a strict-schema failure
 * — an audit trail that silently stops existing. One enum, one safe name.
 */
const adminProjectOwnerViewedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    subject_id_hash: z.string().min(1),
    subject_role: z.enum(USER_ROLES),
    contact_channels: z.enum(['none', 'sms', 'mail', 'both']),
  })
  .strict();

/**
 * A rep opened a restaurant's details, which carries that restaurant's RAW
 * account number (GET/PATCH /rep/catalogs/:id/profile) — the SECOND route in
 * this API that answers with an unmasked identifier, so the read is audited
 * exactly as the first one is.
 *
 * The bound that makes it defensible is `catalog_id` + the delegation behind it:
 * a rep only ever holds a restaurant they activated themselves, which means they
 * TYPED this number. The event exists to make that claim auditable rather than
 * assumed — if a rep is reading restaurants they did not sign up, this is where
 * it shows.
 *
 * ⚠ The same naming trap as [adminProjectOwnerViewedProps]: the emit layer
 * strips any prop whose name contains 'phone' or 'email', so a `has_phone` here
 * would be dropped and take the whole audit event down as a strict-schema
 * failure. `account_contact` says only WHETHER there was a number to show.
 */
const repRestaurantAccountViewedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    catalog_id: z.string().min(1),
    owner_id_hash: z.string().min(1),
    account_contact: z.enum(['none', 'sms']),
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
    // REPLAYED is an Idempotency-Key that had already made a run: nothing was
    // queued by that request, and the answer was the run the key already owns.
    // It rides the existing event rather than growing a new one — the question
    // ("how often is a publish attempted for this catalog, and what stops it")
    // is the same question.
    outcome: z.enum([
      'QUEUED',
      'BLOCKED',
      'IN_PROGRESS',
      'NAME_TAKEN',
      'NOTHING_TO_RETRY',
      'REPLAYED',
    ]),
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

const subscriptionTrialStartedProps = z
  .object({
    catalog_id: z.string().min(1),
    actor_role: z.enum(USER_ROLES),
    actor_id_hash: z.string().min(1),
    /** Which route: the rep's delegated one or the admin's. */
    door: z.enum(['REP', 'ADMIN']),
  })
  .strict();

const subscriptionTrialRefusedProps = z
  .object({
    catalog_id: z.string().min(1),
    actor_role: z.enum(USER_ROLES),
    /** ALREADY_USED (one trial ever), ACTIVE (a live row), NOT_ELIGIBLE (has paid before). */
    reason: z.enum(['ALREADY_USED', 'ACTIVE', 'NOT_ELIGIBLE']),
  })
  .strict();

const subscriptionNudgeSentProps = z
  .object({
    catalog_id: z.string().min(1),
    actor_id_hash: z.string().min(1),
    owner_id_hash: z.string().min(1),
    /** The row's status the clause was chosen from, or NONE when there is no row. */
    subscription_status: z.enum([...SUBSCRIPTION_STATUSES, 'NONE']),
    /** Which channels actually landed: both, or IN_APP alone when the SMS stub threw. */
    channels: z.array(z.enum(['SMS', 'IN_APP'])).min(1),
  })
  .strict();

const subscriptionNudgeRefusedProps = z
  .object({
    catalog_id: z.string().min(1),
    /**
     * RATE_LIMITED (the per-catalog window), NO_PHONE (a legacy owner with no
     * number), NOT_NEEDED (paid up), FAILED (both channels threw).
     */
    reason: z.enum(['RATE_LIMITED', 'NO_PHONE', 'NOT_NEEDED', 'FAILED']),
  })
  .strict();

const subscriptionOrderCreatedProps = z
  .object({
    catalog_id: z.string().min(1),
    plan_id: z.enum(PLAN_IDS),
    interval: z.enum(BILLING_INTERVALS),
    amount_paise: z.number().int().nonnegative(),
    /** True when the open order was handed back instead of a new one minted. */
    reused: z.boolean(),
  })
  .strict();

const subscriptionPaymentRecordedProps = z
  .object({
    catalog_id: z.string().min(1),
    source: z.enum(['ONLINE', 'MANUAL', 'COMP']),
    /** Null for a comp, which is not a plan. */
    plan_id: z.enum(PLAN_IDS).nullable(),
    amount_paise: z.number().int().nonnegative(),
    previous_status: z.enum([...SUBSCRIPTION_STATUSES, 'NONE']),
    /** Which path applied it: the webhook, the reconciler, or an admin route. */
    via: z.enum(['WEBHOOK', 'RECONCILE', 'ADMIN']),
  })
  .strict();

const subscriptionPaymentFailedProps = z
  .object({
    catalog_id: z.string().min(1),
    /**
     * Razorpay's error code, under a name the emitter will not strip — any
     * property whose NAME contains "code" is dropped (utils/analytics.ts).
     */
    failure_reason: z.string().min(1).max(64),
  })
  .strict();

const subscriptionDuplicatePaymentFlaggedProps = z
  .object({
    catalog_id: z.string().min(1),
    payment_id_hash: z.string().min(1),
  })
  .strict();

const subscriptionManualPaymentSubmittedProps = z
  .object({
    catalog_id: z.string().min(1),
    actor_id_hash: z.string().min(1),
    method: z.enum(MANUAL_METHODS),
    amount_paise: z.number().int().nonnegative(),
  })
  .strict();

const subscriptionManualPaymentDecidedProps = z
  .object({
    catalog_id: z.string().min(1),
    decision: z.enum(['VERIFIED', 'REJECTED']),
    admin_id_hash: z.string().min(1),
    /** Whether the verifier is the same person who submitted it (AC-6.4). */
    same_actor: z.boolean(),
  })
  .strict();

const subscriptionRefundIssuedProps = z
  .object({
    catalog_id: z.string().min(1),
    admin_id_hash: z.string().min(1),
    amount_paise: z.number().int().nonnegative(),
    /** True when the row was not flagged DUPLICATE_SUSPECTED and the admin overrode. */
    override: z.boolean(),
    /** True for a cash refund recorded by hand (E13) — no provider call was made. */
    manual: z.boolean(),
  })
  .strict();

const subscriptionGraceExtendedProps = z
  .object({
    catalog_id: z.string().min(1),
    admin_id_hash: z.string().min(1),
    days: z.number().int().positive(),
  })
  .strict();

const subscriptionOverCapOnActivateProps = z
  .object({
    catalog_id: z.string().min(1),
    plan_id: z.enum(PLAN_IDS),
    three_d_dish_count: z.number().int().nonnegative(),
    three_d_dish_cap: z.number().int().nonnegative(),
  })
  .strict();

const razorpayWebhookRejectedProps = z
  .object({
    reason: z.enum(['SIGNATURE', 'UNKNOWN_ORDER', 'AMOUNT_MISMATCH', 'MALFORMED']),
  })
  .strict();

const adminAlertSentProps = z
  .object({
    kind: z.string().min(1).max(40),
    recipients: z.number().int().nonnegative(),
  })
  .strict();

const subscriptionDisputeReceivedProps = z
  .object({
    catalog_id: z.string().min(1),
    amount_paise: z.number().int().nonnegative(),
    previous_status: z.enum([...SUBSCRIPTION_STATUSES, 'NONE']),
  })
  .strict();

const subscriptionDisputeClosedProps = z
  .object({
    catalog_id: z.string().min(1),
    result: z.enum(['won', 'lost']),
  })
  .strict();

const subscriptionStateChangedProps = z
  .object({
    catalog_id: z.string().min(1),
    from: z.enum(SUBSCRIPTION_STATUSES),
    to: z.enum(SUBSCRIPTION_STATUSES),
    by: z.enum(['SWEEP', 'PAYMENT', 'ADMIN', 'DISPUTE']),
  })
  .strict();

const subscriptionArEntitlementSyncedProps = z
  .object({
    catalog_id: z.string().min(1),
    enabled: z.boolean(),
    reason: z.enum(['GRACE_EXPIRED', 'PAYMENT', 'COMP', 'ADMIN']),
    skipped: z.boolean(),
  })
  .strict();

const subscriptionPageStateSyncedProps = z
  .object({
    catalog_id: z.string().min(1),
    is_published: z.boolean(),
    reason: z.enum([
      'PENDING_PAYMENT_STARTED',
      'PENDING_PAYMENT_EXPIRED',
      'PAYMENT',
      'COMP',
      'TRIAL',
      'ADMIN',
    ]),
    skipped: z.boolean(),
  })
  .strict();

const subscriptionPendingPaymentStartedProps = z
  .object({
    catalog_id: z.string().min(1),
    actor_role: z.enum(USER_ROLES),
    days: z.number().int().positive(),
  })
  .strict();

const subscriptionPendingPaymentExpiredProps = z
  .object({
    catalog_id: z.string().min(1),
  })
  .strict();

const subscriptionSweepRanProps = z
  .object({
    to_grace: z.number().int().nonnegative(),
    to_paused: z.number().int().nonnegative(),
    // Pending-payment windows this pass expired. Its own number rather than
    // folded into `to_paused`: one means "a plan lapsed", the other means "a
    // live link died", and a dashboard must never average the two.
    to_page_off: z.number().int().nonnegative().optional(),
    duration_ms: z.number().int().nonnegative(),
  })
  .strict();

const subscriptionStandeesIssuedProps = z
  .object({
    catalog_id: z.string().min(1),
    admin_id_hash: z.string().min(1),
    issued: z.number().int().nonnegative(),
    included: z.number().int().nonnegative(),
  })
  .strict();

const subscriptionReceiptDownloadedProps = z
  .object({
    catalog_id: z.string().min(1),
    kind: z.enum(['PAID', 'MANUAL', 'COMP']),
  })
  .strict();

const publishBlockedBySubscriptionProps = z
  .object({
    catalog_id: z.string().min(1),
    /**
     * Which gate. Named `gate`, not `gate_code`: the emitter strips any
     * property whose NAME contains "code" (utils/analytics.ts), so the
     * obvious name would arrive as nothing at all.
     */
    gate: z.enum(['SUBSCRIPTION_REQUIRED', 'SUBSCRIPTION_CAPACITY_EXCEEDED']),
    /** The row's status, or NONE when the catalog has no row yet. */
    subscription_status: z.enum([...SUBSCRIPTION_STATUSES, 'NONE']),
    three_d_dish_count: z.number().int().nonnegative(),
    /** The cap in force; -1 is "uncapped" and also what a missing row reports. */
    three_d_dish_cap: z.number().int().min(-1),
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
 * The MINT, never the code. `batch_size` is the whole point of the event — it
 * answers "how much inventory did we just commit to printing" — and a code
 * value would be a public identifier for one restaurant's menu, so none appears
 * here. Actor is hashed per the house rule.
 */
const qrBatchMintedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    batch_size: z.number().int().positive(),
    // Whether the run was handed to a rep as it was minted. A boolean, never
    // an id: who holds a batch is staff PII and the question here is only
    // whether the bulk path is used at all.
    assigned_on_mint: z.boolean().optional(),
  })
  .strict();

/**
 * Every way a scan can end, and NOTHING about which code or which restaurant.
 *
 * `REDIRECT` is the success case; the other four are the fallback pages. ERROR
 * is in the enum because the public router swallows its own exceptions to keep
 * a diner off the JSON envelope — this event is then the ONLY external signal
 * that the terminal error handler fired at all.
 */
export const QR_SCAN_OUTCOMES = [
  'REDIRECT',
  'NOT_YET_LIVE',
  'REPLACED',
  'UNKNOWN',
  'ERROR',
] as const;

/**
 * One scanned standee. `outcome` is the entire payload — deliberately. A code
 * identifies one restaurant's menu; a scan identifies one diner's presence
 * there. Neither belongs in an analytics property, and there is no actor to
 * hash because the client is an anonymous phone camera.
 */
const qrCodeScannedProps = z.object({ outcome: z.enum(QR_SCAN_OUTCOMES) }).strict();

/** How a rep's activation attempt ended. */
export const QR_ACTIVATION_OUTCOMES = ['ACTIVATED', 'ALREADY_ACTIVE', 'CODE_UNAVAILABLE'] as const;

/**
 * One activation attempt. The rep is hashed per the house rule; the restaurant
 * appears nowhere, because "which restaurant did a rep sign up" is answerable
 * from the CatalogDelegation ledger by someone with a reason to ask, and does
 * not belong in an analytics stream.
 */
const qrCodeActivatedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    outcome: z.enum(QR_ACTIVATION_OUTCOMES),
  })
  .strict();

/**
 * Assigning or unassigning one standee.
 *
 * `rep_id_hash` is optional because UNASSIGNED has no rep — the standee came
 * back off somebody's list and onto nobody's. Modelled as an absent property
 * rather than a null or a sentinel string so a query for "assignments to rep X"
 * cannot accidentally match the give-backs.
 */
const qrCodeAssignedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    rep_id_hash: z.string().min(1).optional(),
    outcome: z.enum(['ASSIGNED', 'UNASSIGNED']),
  })
  .strict();

/**
 * Registry mapping every event name to its property schema. The `satisfies`
 * clause makes this EXHAUSTIVE: forgetting a schema for any AnalyticsEventName
 * is a compile error.
 */
// ── In-app notifications ─────────────────────────────────────────────────────
//
// `kind` and `audience` are enums; `recipient_count` is null for a broadcast.
// No title, message, detail or action url — see the registry note.
const notificationSentProps = z
  .object({
    actor_id_hash: z.string().min(1),
    kind: z.enum(NOTIFICATION_KINDS),
    audience: z.enum(NOTIFICATION_AUDIENCE_TYPES),
    recipient_count: z.number().int().nonnegative().nullable(),
    has_action: z.boolean(),
    has_detail: z.boolean(),
  })
  .strict();

const notificationRetractedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    kind: z.enum(NOTIFICATION_KINDS),
    audience: z.enum(NOTIFICATION_AUDIENCE_TYPES),
  })
  .strict();

// `scope`: one notification tapped, or "mark all read".
const notificationReadProps = z
  .object({
    user_id_hash: z.string().min(1),
    scope: z.enum(['one', 'all']),
  })
  .strict();

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
  [AnalyticsEvent.ADMIN_PROJECT_OWNER_VIEWED]: adminProjectOwnerViewedProps,
  [AnalyticsEvent.REP_RESTAURANT_ACCOUNT_VIEWED]: repRestaurantAccountViewedProps,
  [AnalyticsEvent.MODEL_GENERATION_REQUESTED]: modelGenerationRequestedProps,
  [AnalyticsEvent.MODEL_GENERATION_DECLINED]: modelGenerationDeclinedProps,
  [AnalyticsEvent.MODEL_APPROVED]: modelApprovedProps,
  [AnalyticsEvent.MODEL_IMAGE_UPLOADS_GENERATED]: modelImageUploadsGeneratedProps,
  [AnalyticsEvent.MODEL_UPLOAD_URL_GENERATED]: modelUploadUrlGeneratedProps,
  [AnalyticsEvent.MODEL_UPLOAD_SUBMITTED]: modelUploadSubmittedProps,
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
  [AnalyticsEvent.PUBLISH_BLOCKED_BY_SUBSCRIPTION]: publishBlockedBySubscriptionProps,
  [AnalyticsEvent.SUBSCRIPTION_TRIAL_STARTED]: subscriptionTrialStartedProps,
  [AnalyticsEvent.SUBSCRIPTION_TRIAL_REFUSED]: subscriptionTrialRefusedProps,
  [AnalyticsEvent.SUBSCRIPTION_NUDGE_SENT]: subscriptionNudgeSentProps,
  [AnalyticsEvent.SUBSCRIPTION_NUDGE_REFUSED]: subscriptionNudgeRefusedProps,
  [AnalyticsEvent.SUBSCRIPTION_ORDER_CREATED]: subscriptionOrderCreatedProps,
  [AnalyticsEvent.SUBSCRIPTION_PAYMENT_RECORDED]: subscriptionPaymentRecordedProps,
  [AnalyticsEvent.SUBSCRIPTION_PAYMENT_FAILED]: subscriptionPaymentFailedProps,
  [AnalyticsEvent.SUBSCRIPTION_DUPLICATE_PAYMENT_FLAGGED]: subscriptionDuplicatePaymentFlaggedProps,
  [AnalyticsEvent.SUBSCRIPTION_MANUAL_PAYMENT_SUBMITTED]: subscriptionManualPaymentSubmittedProps,
  [AnalyticsEvent.SUBSCRIPTION_MANUAL_PAYMENT_DECIDED]: subscriptionManualPaymentDecidedProps,
  [AnalyticsEvent.SUBSCRIPTION_REFUND_ISSUED]: subscriptionRefundIssuedProps,
  [AnalyticsEvent.SUBSCRIPTION_GRACE_EXTENDED]: subscriptionGraceExtendedProps,
  [AnalyticsEvent.SUBSCRIPTION_OVER_CAP_ON_ACTIVATE]: subscriptionOverCapOnActivateProps,
  [AnalyticsEvent.RAZORPAY_WEBHOOK_REJECTED]: razorpayWebhookRejectedProps,
  [AnalyticsEvent.ADMIN_ALERT_SENT]: adminAlertSentProps,
  [AnalyticsEvent.SUBSCRIPTION_DISPUTE_RECEIVED]: subscriptionDisputeReceivedProps,
  [AnalyticsEvent.SUBSCRIPTION_DISPUTE_CLOSED]: subscriptionDisputeClosedProps,
  [AnalyticsEvent.SUBSCRIPTION_STATE_CHANGED]: subscriptionStateChangedProps,
  [AnalyticsEvent.SUBSCRIPTION_AR_ENTITLEMENT_SYNCED]: subscriptionArEntitlementSyncedProps,
  [AnalyticsEvent.SUBSCRIPTION_PAGE_STATE_SYNCED]: subscriptionPageStateSyncedProps,
  [AnalyticsEvent.SUBSCRIPTION_PENDING_PAYMENT_STARTED]: subscriptionPendingPaymentStartedProps,
  [AnalyticsEvent.SUBSCRIPTION_PENDING_PAYMENT_EXPIRED]: subscriptionPendingPaymentExpiredProps,
  [AnalyticsEvent.SUBSCRIPTION_SWEEP_RAN]: subscriptionSweepRanProps,
  [AnalyticsEvent.SUBSCRIPTION_STANDEES_ISSUED]: subscriptionStandeesIssuedProps,
  [AnalyticsEvent.SUBSCRIPTION_RECEIPT_DOWNLOADED]: subscriptionReceiptDownloadedProps,
  [AnalyticsEvent.CATALOG_QR_RENDERED]: catalogQrRenderedProps,
  [AnalyticsEvent.QR_BATCH_MINTED]: qrBatchMintedProps,
  [AnalyticsEvent.QR_CODE_ASSIGNED]: qrCodeAssignedProps,
  [AnalyticsEvent.QR_CODE_SCANNED]: qrCodeScannedProps,
  [AnalyticsEvent.QR_CODE_ACTIVATED]: qrCodeActivatedProps,
  [AnalyticsEvent.NOTIFICATION_SENT]: notificationSentProps,
  [AnalyticsEvent.NOTIFICATION_RETRACTED]: notificationRetractedProps,
  [AnalyticsEvent.NOTIFICATION_READ]: notificationReadProps,
} satisfies Record<AnalyticsEventName, z.ZodTypeAny>;

/** Compile-time map: event name → its validated property type. */
export type EventPropsMap = {
  [K in AnalyticsEventName]: z.infer<(typeof EVENT_SCHEMAS)[K]>;
};
