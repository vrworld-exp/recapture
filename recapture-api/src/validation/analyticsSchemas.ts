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
import { PROJECT_STATUS_VALUES } from '@/models/Project';

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
  ADMIN_ACCESS_DENIED: 'admin_access_denied',
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
    object_size: z.enum(OBJECT_SIZE_VALUES),
    mode: z.enum(CAPTURE_MODE_VALUES),
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

/** requireRole rejected an authenticated caller (role below the minimum). */
const adminAccessDeniedProps = z
  .object({
    actor_id_hash: z.string().min(1),
    route: z.string().min(1),
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
  [AnalyticsEvent.ADMIN_ACCESS_DENIED]: adminAccessDeniedProps,
} satisfies Record<AnalyticsEventName, z.ZodTypeAny>;

/** Compile-time map: event name → its validated property type. */
export type EventPropsMap = {
  [K in AnalyticsEventName]: z.infer<(typeof EVENT_SCHEMAS)[K]>;
};
