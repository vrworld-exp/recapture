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
  // ── Config delivery ───────────────────────────────────────────────────────
  REMOTE_CONFIG_SERVED: 'remote_config_served',
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

const remoteConfigServedProps = z
  .object({
    config_version: z.number().int().nonnegative(),
    served_defaults: z.boolean(),
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
  [AnalyticsEvent.REMOTE_CONFIG_SERVED]: remoteConfigServedProps,
} satisfies Record<AnalyticsEventName, z.ZodTypeAny>;

/** Compile-time map: event name → its validated property type. */
export type EventPropsMap = {
  [K in AnalyticsEventName]: z.infer<(typeof EVENT_SCHEMAS)[K]>;
};
