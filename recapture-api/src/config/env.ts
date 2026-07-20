// src/config/env.ts
import { z } from 'zod';
import dotenv from 'dotenv';
dotenv.config();

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'staging', 'production']).default('development'),
  PORT: z.coerce.number().default(3000),
  MONGODB_URI: z.string().min(1, 'MONGODB_URI is required'),
  JWT_SECRET: z.string().min(32, 'JWT_SECRET must be at least 32 characters'),
  JWT_EXPIRES_IN: z.string().default('7d'),
  AWS_REGION: z.string().min(1, 'AWS_REGION is required'),
  AWS_ACCESS_KEY_ID: z.string().min(1, 'AWS_ACCESS_KEY_ID is required'),
  AWS_SECRET_ACCESS_KEY: z.string().min(1, 'AWS_SECRET_ACCESS_KEY is required'),
  S3_BUCKET_RAW: z.string().min(1, 'S3_BUCKET_RAW is required'),
  S3_BUCKET_ARTIFACTS: z.string().min(1, 'S3_BUCKET_ARTIFACTS is required'),
  CLOUDFRONT_BASE_URL: z.string().url('CLOUDFRONT_BASE_URL must be a valid URL'),
  // backedendMakeAliveUrl: z.string().url('backendMakeAliveUrl must be a valid URL'),

  // ── OTP (POST /auth/send-otp) ──────────────────────────────────────────────
  // All tunables come from env; every one has a safe default so existing
  // deployments boot without new required vars.
  /** How long a sent OTP stays valid (seconds). */
  OTP_TTL_SECONDS: z.coerce.number().int().positive().default(300),
  /** Minimum gap between two sends to the same identifier (seconds). */
  RESEND_COOLDOWN_SECONDS: z.coerce.number().int().nonnegative().default(60),
  /** Max sends allowed to one identifier within RATE_WINDOW_SECONDS. */
  MAX_SENDS_PER_WINDOW: z.coerce.number().int().positive().default(5),
  /** Sliding window for the send cap (seconds). */
  RATE_WINDOW_SECONDS: z.coerce.number().int().positive().default(3600),
  /** Secret peppering the OTP/identifier HMAC. Falls back to JWT_SECRET when unset. */
  OTP_HASH_SECRET: z.string().min(16).optional(),
  /** Dev/test toggle: when 'true', the provider dispatch throws (to exercise the 502 path). */
  OTP_SIMULATE_DISPATCH_FAILURE: z
    .enum(['true', 'false'])
    .default('false')
    .transform((v) => v === 'true'),

  // ── OTP verify + session tokens (POST /auth/verify-otp) ────────────────────
  /** Lifetime of the signed JWT access token (seconds). */
  ACCESS_TOKEN_TTL_SECONDS: z.coerce.number().int().positive().default(900),
  /** Lifetime of an issued refresh token (seconds). Default 30 days. */
  REFRESH_TOKEN_TTL_SECONDS: z.coerce.number().int().positive().default(2_592_000),
  /** Wrong-code guesses tolerated on one OTP record before it locks. */
  MAX_OTP_ATTEMPTS: z.coerce.number().int().positive().default(5),
  /** Max verify attempts to one identifier within VERIFY_WINDOW_SECONDS. */
  MAX_VERIFY_ATTEMPTS_PER_WINDOW: z.coerce.number().int().positive().default(10),
  /** Sliding window for the verify-attempt cap (seconds). */
  VERIFY_WINDOW_SECONDS: z.coerce.number().int().positive().default(900),
  /** Max refresh calls from one client signal within REFRESH_WINDOW_SECONDS. */
  MAX_REFRESH_PER_WINDOW: z.coerce.number().int().positive().default(30),
  /** Sliding window for the refresh-attempt cap (seconds). */
  REFRESH_WINDOW_SECONDS: z.coerce.number().int().positive().default(900),
  /** Dev/test toggle: when 'true', access-token signing throws (to exercise the 500 path). */
  JWT_SIMULATE_SIGN_FAILURE: z
    .enum(['true', 'false'])
    .default('false')
    .transform((v) => v === 'true'),

  // ── Upload pipeline (POST /jobs) ────────────────────────────────────────────
  /**
   * Validity window of a job's upload plan (seconds). Bounded but long enough
   * for a full mobile session upload of the largest object size on a slow
   * connection. Default 24h.
   */
  UPLOAD_PLAN_TTL_SECONDS: z.coerce.number().int().positive().default(86_400),

  // ── Staff export (GET /admin/projects/:id/export) ──────────────────────────
  /** Validity of the presigned GET URLs in an export manifest (seconds). */
  ADMIN_EXPORT_URL_TTL_SECONDS: z.coerce.number().int().positive().default(3600),
  /** Max export manifests one staff user may generate per window. */
  ADMIN_EXPORT_MAX_PER_WINDOW: z.coerce.number().int().positive().default(10),
  /** Sliding window for the export cap (seconds). */
  ADMIN_EXPORT_WINDOW_SECONDS: z.coerce.number().int().positive().default(3600),

  // ── Meshy AI model generation (staff-triggered — docs/meshy-integration-*.md) ─
  /**
   * Meshy API key — a SECRET (env only, never logged, never shipped to the
   * client). Optional in this shared schema ON PURPOSE: only the WORKER process
   * talks to Meshy, so requiring it here would stop the API from booting over a
   * credential it never uses (and break every existing deployment/dev shell on
   * upgrade). Presence is enforced where it matters instead — the worker calls
   * assertMeshyConfigured() at boot (src/worker/engine/meshy/meshyClient.ts) and
   * fails fast with a clear message.
   */
  MESHY_API_KEY: z.string().min(1).optional(),
  MESHY_BASE_URL: z.string().url().default('https://api.meshy.ai'),
  /**
   * How often a running Meshy task is polled (ms). Each poll doubles as the
   * worker's claim-lease renewal, so this MUST stay well below
   * WORKER_CLAIM_TIMEOUT_MS or a live generation gets re-claimed mid-flight.
   */
  MESHY_POLL_INTERVAL_MS: z.coerce.number().int().positive().default(5000),
  /** Hard cap on total wait for one generation before giving up (ms). */
  MESHY_TASK_TIMEOUT_MS: z.coerce.number().int().positive().default(600_000),
  /** Presigned-GET TTL for the source images handed to Meshy (seconds). */
  MESHY_SOURCE_URL_TTL_SECONDS: z.coerce.number().int().positive().default(3600),
  /** Max Create-Model requests one staff user may make per window (credits!). */
  MESHY_CREATE_MAX_PER_WINDOW: z.coerce.number().int().positive().default(20),
  /** Sliding window for the Create-Model cap (seconds). */
  MESHY_CREATE_WINDOW_SECONDS: z.coerce.number().int().positive().default(3600),
  /**
   * Presigned-PUT TTL for staff-EDITED model-input images (seconds). Short on
   * purpose: the Prepare-Images screen exports and uploads immediately after
   * requesting the slots — 15 min covers a slow connection with margin.
   */
  MODEL_IMAGE_UPLOAD_URL_TTL_SECONDS: z.coerce.number().int().positive().default(900),
  /** Max model-image upload-urls requests per staff user per window. Cheap
   * (presigns only, no credits), so bounded generously — the credit guards
   * stay on Create-Model itself. */
  MODEL_IMAGE_UPLOAD_MAX_PER_WINDOW: z.coerce.number().int().positive().default(60),
  /** Sliding window for the model-image upload-urls cap (seconds). */
  MODEL_IMAGE_UPLOAD_WINDOW_SECONDS: z.coerce.number().int().positive().default(3600),

  // ── Automatic model generation (docs/auto-model-generation-*.md) ───────────
  /**
   * The HARD gate on generating a model automatically when a capture finishes.
   *
   * Defaults to FALSE: auto-generation spends Meshy credits with no human in
   * the loop, so it ships dark and is enabled deliberately per environment. The
   * remote-config flag is the LIVE switch on top of this (both must be on) —
   * this one cannot be flipped without a deploy, which is the point.
   */
  AUTO_MODEL_GENERATION_ENABLED: z
    .string()
    .optional()
    .transform((v) => v === 'true' || v === '1'),
  /** Auto-generations one user may accrue per rolling 24h — the spend ceiling. */
  AUTO_MODEL_MAX_PER_USER_PER_DAY: z.coerce.number().int().positive().default(10),
  /**
   * Sharpness floor (variance of Laplacian) for an auto-selected photo. Matches
   * the client's REJECT threshold, so a frame the capture UI would have thrown
   * away is never chosen here either.
   */
  AUTO_MODEL_MIN_BLUR_SCORE: z.coerce.number().nonnegative().default(40),

  // ── Background worker (src/worker — separate process, `npm run worker`) ─────
  /**
   * Run the worker loop INSIDE the API process (src/index.ts), instead of as a
   * separate `npm run worker` service.
   *
   * Exists so a single-service deployment (one Render instance, one bill) can
   * process jobs at all. Safe ONLY while every registered processor is
   * I/O-bound: the Meshy path is HTTP + sleep and never occupies the event
   * loop, so it cannot delay API requests. captureProcessingProcessor's
   * pipeline is a stub today — when it becomes real (CPU-bound photogrammetry),
   * this MUST go back to false and a dedicated worker service.
   *
   * Defaults to false so `npm run worker`, tests, and existing deployments are
   * completely unaffected. Only the deployed web service opts in.
   */
  RUN_WORKER_IN_PROCESS: z
    .enum(['true', 'false'])
    .default('false')
    .transform((v) => v === 'true'),
  /** How often the worker polls for claimable jobs (milliseconds). */
  WORKER_POLL_INTERVAL_MS: z.coerce.number().int().positive().default(5000),
  /**
   * Claim lease: a job stuck in CLAIMED/PROCESSING longer than this is
   * considered orphaned (worker crash/OOM) and re-claimed on a later poll.
   * Balance: too low re-runs live jobs; too high delays crash recovery.
   */
  WORKER_CLAIM_TIMEOUT_MS: z.coerce.number().int().positive().default(120_000),
  /** Jobs one worker instance processes concurrently. */
  WORKER_CONCURRENCY: z.coerce.number().int().positive().default(2),
  /** Heartbeat log (with queue-depth breakdown) every N polls. */
  WORKER_HEARTBEAT_EVERY_N_POLLS: z.coerce.number().int().positive().default(20),
});

const parsed = envSchema.safeParse(process.env);

if (!parsed.success) {
  console.error('❌ Invalid environment variables:');
  console.error(parsed.error.flatten().fieldErrors);
  process.exit(1);
}

export const env = parsed.data;
