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

  // ── Profile pictures (/auth/me/avatar — docs/prompts/profile-avatar-prompt.md) ─
  /**
   * Hard ceiling on a stored avatar object, in bytes. The client downscales to
   * 512×512 / q85 natively before uploading, so 2 MiB is generous headroom for
   * that while still refusing a full-resolution phone photo someone PUT by
   * hand. Presigning cannot enforce a size, so this is only real at COMMIT
   * time, where the route HEADs the object and deletes an oversized one.
   */
  AVATAR_MAX_BYTES: z.coerce.number().int().positive().default(2_097_152), // 2 MiB
  /**
   * Presigned-PUT TTL for an avatar upload slot (seconds). Short on purpose:
   * the picker uploads immediately after requesting the slot — 15 min covers a
   * slow connection with margin, and the URL is a WRITE credential.
   */
  AVATAR_UPLOAD_URL_TTL_SECONDS: z.coerce.number().int().positive().default(900),
  /**
   * Presigned-GET TTL for the avatarUrl on the account snapshot (seconds).
   * Matches ADMIN_EXPORT_URL_TTL_SECONDS. A backgrounded app WILL outlive it,
   * which is why the client degrades an expired URL to initials rather than to
   * a broken image.
   */
  AVATAR_GET_URL_TTL_SECONDS: z.coerce.number().int().positive().default(3600),
  /** Max avatar upload slots one user may request per window. */
  AVATAR_UPLOAD_MAX_PER_WINDOW: z.coerce.number().int().positive().default(10),
  /** Sliding window for the avatar upload-slot cap (seconds). */
  AVATAR_UPLOAD_WINDOW_SECONDS: z.coerce.number().int().positive().default(3600),

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
  /**
   * Hard cap on total wait for one generation before giving up (ms).
   *
   * 30 min, not the 10 it used to be. MESHY_TARGET_POLYCOUNT now asks for 200k
   * triangles and MESHY_TEXTURE_RESOLUTION for 4k maps, and both cost Meshy
   * wall-clock time. Blowing this budget raises MESHY_TIMEOUT, and the worker's
   * retry SPENDS CREDITS AGAIN — so the budget must be generous enough that a
   * slow-but-succeeding task is never killed just short of the finish line.
   *
   * This is a total budget only: it does NOT change the poll cadence.
   * MESHY_POLL_INTERVAL_MS stays at 5 s because each poll doubles as the claim
   * lease renewal against WORKER_CLAIM_TIMEOUT_MS (120 s) — see below.
   */
  MESHY_TASK_TIMEOUT_MS: z.coerce.number().int().positive().default(1_800_000),
  /** Presigned-GET TTL for the source images handed to Meshy (seconds). */
  MESHY_SOURCE_URL_TTL_SECONDS: z.coerce.number().int().positive().default(3600),
  /**
   * Triangle budget asked of Meshy's remesher — a GENERATION-QUALITY knob, not
   * the phone's budget. Those used to be the same number; they are not anymore.
   *
   * ── The policy, in one line ─────────────────────────────────────────────────
   * Meshy generates HIGH, the asset pipeline delivers LOW. Generation optimizes
   * for fidelity; src/modules/asset-pipeline optimizes for delivery, and its
   * simplify stage is what produces the mesh a phone actually loads.
   *
   * ── Why it moved off 12k ────────────────────────────────────────────────────
   * A 12k budget made the raw GLB directly servable, but it was destroying
   * geometry at the source: thin features — handles, rims, stems, cup lips —
   * came back holed or broken, and no downstream stage can put back detail the
   * generator never produced. Decimating a good 200k mesh with meshoptimizer
   * (which optimizes for silhouette error) beats asking Meshy to hit 12k in one
   * step, because the simplifier gets to see the real surface first.
   *
   * ── The WebView history, which is WHY the pipeline must now decimate ────────
   * Meshy's remesh phase defaults to OFF on its newer models, and the raw mesh
   * it returns for a captured object is unbounded: live results ranged from 55k
   * to 1.2M triangles (4 MB to 38 MB GLB). Past roughly a few hundred thousand
   * triangles an Android WebView runs out of heap or loses its WebGL context
   * while parsing the GLB, model-viewer fires `error`, and the owner sees "We
   * couldn't load this model" for a generation that in fact succeeded.
   *
   * That failure has NOT gone away — it has moved. At 200k the untouched
   * original is on the wrong side of that line, so it is no longer what an owner
   * is served: a validated pipeline run auto-promotes `optimized.activeVariant`
   * to 'web' (see worker/processors/assetOptimizationProcessor.ts). Raising this
   * number WITHOUT that promotion, or without the pipeline's simplify stage,
   * reintroduces the crash for every model.
   *
   * ── The number ──────────────────────────────────────────────────────────────
   * 200k leaves headroom under Meshy's hard 300k cap (anything outside
   * 100–300,000 comes back a terminal 400) and is a PINNED budget, which is the
   * point: `should_remesh: true` plus a fixed target is what makes output
   * deterministic. Turning remesh off would give the raw unbounded mesh and make
   * this value ignored entirely — see MESHY_PRESET.
   */
  MESHY_TARGET_POLYCOUNT: z.coerce.number().int().min(100).max(300_000).default(200_000),
  /**
   * Base-colour texture resolution requested from Meshy — again a SOURCE
   * quality knob, not what ships. The pipeline resamples every texture to the
   * active profile's per-slot budget (profiles/food.json), so this decides how
   * much real detail that resample has to work from, not how much decoded
   * texture memory the WebView has to find.
   *
   * '4k' rather than Meshy's own '2k' default: the served baseColor is 2048, and
   * downsampling 4096 → 2048 keeps visibly more of the dish's surface than
   * asking Meshy for 2048 directly. '8k' is not worth it — it costs generation
   * time against MESHY_TASK_TIMEOUT_MS for detail two resamples throw away.
   *
   * If a profile's baseColor budget ever drops back to 1024, drop this to '2k'
   * with it: paying for source detail nothing samples is pure latency.
   */
  MESHY_TEXTURE_RESOLUTION: z.enum(['2k', '4k', '8k']).default('4k'),
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

  // ── On-demand model generation (docs/prompts/on-demand-model-generation.md) ─
  /**
   * The gate on the HUMAN-triggered "Generate 3D model" button, which runs the
   * same server-side photo selection as the automatic path.
   *
   * DELIBERATELY SEPARATE from AUTO_MODEL_GENERATION_ENABLED. Sharing one flag
   * would make the button dead until automatic generation is enabled — and
   * enabling that also turns on unattended per-capture spend, which is exactly
   * the risk this button exists to de-risk. The button is how the selector gets
   * exercised against real captures, one deliberate press at a time, BEFORE the
   * automatic trigger is ever switched on.
   */
  MANUAL_MODEL_GENERATION_ENABLED: z
    .string()
    .optional()
    .transform((v) => v === 'true' || v === '1'),
  /**
   * Button-triggered generations one OWNER may accrue per rolling 24h.
   *
   * Counted against the SAME ceiling as automatic ones — it is the same money,
   * and a per-source cap would just be two ways to spend twice as much.
   */
  MANUAL_MODEL_MAX_PER_USER_PER_DAY: z.coerce.number().int().positive().default(5),
  /** The same ceiling for MODEL_ARTIST/ADMIN actors: higher, never exempt. */
  MANUAL_MODEL_MAX_PER_STAFF_PER_DAY: z.coerce.number().int().positive().default(25),

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
