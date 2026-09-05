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

  // ── CORS (src/app.ts) ──────────────────────────────────────────────────────
  /**
   * Browser origins allowed to call this API — comma-separated, matched
   * EXACTLY (scheme + host + port, no path, no trailing slash).
   *
   * Only browsers are affected: the Flutter mobile builds send no Origin
   * header, so they bypass this entirely. localhost/127.0.0.1 on any port is
   * additionally allowed outside production, for `flutter run -d chrome`
   * (which picks a random port every launch).
   */
  CORS_ALLOWED_ORIGINS: z
    .string()
    .default('https://recapture-live.onrender.com')
    .transform((v) =>
      v
        .split(',')
        .map((o) => o.trim().replace(/\/+$/, ''))
        .filter(Boolean),
    ),

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
  /** Hard cap on total wait for one generation before giving up (ms). */
  MESHY_TASK_TIMEOUT_MS: z.coerce.number().int().positive().default(600_000),
  /** Presigned-GET TTL for the source images handed to Meshy (seconds). */
  MESHY_SOURCE_URL_TTL_SECONDS: z.coerce.number().int().positive().default(3600),
  /**
   * Triangle budget for a generated model — the size the phone has to render.
   *
   * NOT cosmetic. Meshy's remesh phase defaults to OFF on its newer models, and
   * the raw mesh it returns for a captured object is unbounded: live results
   * ranged from 55k to 1.2M triangles (4 MB to 38 MB GLB). Past roughly a few
   * hundred thousand triangles an Android WebView runs out of heap or loses its
   * WebGL context while parsing the GLB, model-viewer fires `error`, and the
   * owner sees "We couldn't load this model" for a generation that in fact
   * succeeded. Asking for a fixed budget is what keeps every result viewable on
   * the device it was captured with.
   *
   * 100k sits well inside Meshy's own 100–300,000 range: high enough to keep the
   * surface detail of a captured object, low enough to load on a mid-range phone
   * (~8 MB GLB). Raise it only alongside a device test.
   */
  MESHY_TARGET_POLYCOUNT: z.coerce.number().int().min(100).max(300_000).default(100_000),
  /**
   * Base-colour texture resolution requested from Meshy. '2k' is Meshy's own
   * default and the one a phone can hold comfortably; '4k'/'8k' multiply the
   * decoded texture memory that the same WebView has to find.
   */
  MESHY_TEXTURE_RESOLUTION: z.enum(['2k', '4k', '8k']).default('2k'),
  // ── Artist photo-upload projects (POST /projects/:id/photos/*) ─────────────
  //
  // An artist uploads a hand-picked photo set instead of running a guided
  // capture. Uploading costs nothing; GENERATING is what spends Meshy credits,
  // and that path keeps its own guards (MESHY_CREATE_* below).
  /**
   * Fewest photos an upload project may commit. Below three there is nothing
   * Meshy could ever build from — the generation surface itself requires 3–4.
   */
  PROJECT_PHOTO_MIN_COUNT: z.coerce.number().int().positive().default(3),
  /**
   * Most photos one upload project may hold. 48 matches CaptureMode.full's shot
   * count, so a hand-uploaded set and a guided capture produce comparably sized
   * sets. Raising it later is a one-line env change.
   */
  PROJECT_PHOTO_MAX_COUNT: z.coerce.number().int().positive().default(48),
  /**
   * Hard ceiling on ONE uploaded photo, in bytes.
   *
   * COST NOTE: 15 MiB x PROJECT_PHOTO_MAX_COUNT is a ~720 MiB worst-case
   * ceiling per project in the raw bucket. Presigning cannot enforce a size, so
   * this is only real at COMMIT time, where the route reads each object's
   * listed size and DELETES an oversized one (the same stance the avatar commit
   * takes). The abandoned-upload reaper this whole multipart path relies on is
   * the raw bucket's AbortIncompleteMultipartUpload lifecycle rule.
   */
  PROJECT_PHOTO_MAX_BYTES: z.coerce.number().int().positive().default(15_728_640), // 15 MiB
  /** Presigned-GET TTL for the photo grid (seconds). Matches
   * ADMIN_EXPORT_URL_TTL_SECONDS — a presigned URL is a bearer credential. */
  PROJECT_PHOTO_URL_TTL_SECONDS: z.coerce.number().int().positive().default(3600),
  /** Max upload SESSIONS one artist may open per window. */
  PROJECT_PHOTO_UPLOAD_MAX_PER_WINDOW: z.coerce.number().int().positive().default(10),
  /** Sliding window for the upload-session cap (seconds). */
  PROJECT_PHOTO_UPLOAD_WINDOW_SECONDS: z.coerce.number().int().positive().default(3600),

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

  // ── Model optimization (docs/prompts/model-optimization-opt-variant.md) ─────
  /**
   * GLB size above which a model is worth optimizing — the ONLY gate on the
   * Optimize button, and the server's own verdict (`canOptimize`) is what the
   * client renders, so the two can never disagree.
   *
   * BINARY, NOT DECIMAL: 5 MiB = 5 * 1024 * 1024 = 5,242,880 bytes. "5 MB" is
   * ambiguous and the client formats displayed sizes with the SAME 1024 divisor
   * — mix the two and a 5,100,000-byte model reads "5.1 MB" with no button, or
   * "4.9 MB" with one.
   *
   * ADVISORY ONLY. Nothing uploads, saves or loads worse for being over it: the
   * only things it gates are the Optimize button and the route that button
   * calls. The hard limits live elsewhere (MODEL_OPTIMIZE_MAX_INPUT_BYTES is
   * the one that actually refuses work).
   */
  MODEL_OPTIMIZE_THRESHOLD_BYTES: z.coerce
    .number()
    .int()
    .positive()
    .default(5 * 1024 * 1024),
  /**
   * Hard ceiling on the GLB the optimizer will even open (bytes).
   *
   * glTF-Transform holds the WHOLE document in memory (and meshopt re-encodes
   * every buffer), so a pathological input does not fail slowly — it OOMs the
   * process. When RUN_WORKER_IN_PROCESS is on that process is the API, so this
   * is the difference between one failed optimization and an outage.
   */
  MODEL_OPTIMIZE_MAX_INPUT_BYTES: z.coerce
    .number()
    .int()
    .positive()
    .default(250 * 1024 * 1024),
  /** Max optimize requests one OWNER may make per window (CPU, not credits). */
  MODEL_OPTIMIZE_MAX_PER_WINDOW: z.coerce.number().int().positive().default(20),
  /** Sliding window for the owner optimize cap (seconds). */
  MODEL_OPTIMIZE_WINDOW_SECONDS: z.coerce.number().int().positive().default(3600),

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

  // ── Mirage catalog publishing (docs/next-phase/03-architecture-proposal.md) ─
  /**
   * Origin of the Mirage backend, WITHOUT the `/api/v1` prefix — the adapter
   * (src/services/mirage/) appends it. Trailing slashes are stripped so a
   * copy-pasted value cannot produce `//api/v1`.
   *
   * Optional in this shared schema for the same reason MESHY_API_KEY is: only
   * the publish worker and the analytics proxy ever talk to Mirage, so a
   * deployment that does neither must not fail to boot over it. Presence is
   * enforced at the call site by assertMirageConfigured().
   */
  MIRAGE_BASE_URL: z
    .string()
    .url()
    .optional()
    .transform((v) => (v ? v.replace(/\/+$/, '') : v)),
  /**
   * Mirage's static `apikey` header (Middlewares/apiKeyValidator.js). Treated as
   * a SECRET here even though Mirage itself ships it in its public web bundle —
   * ReCapture does not get to make someone else's leak worse, and it must never
   * reach the Flutter client.
   */
  MIRAGE_API_KEY: z.string().min(1).optional(),
  /**
   * A pre-minted admin JWT for Mirage's `token` header.
   *
   * PREFERRED over the id/password pair below, because Mirage SIGNS login tokens
   * with `process.env.JWT_SECRET` (Controllers/userController.js:115) but
   * VERIFIES them with `process.env.JWT_SECRET_KEY` (Middlewares/middleware.js:40)
   * — two different variable names. If the deployed Mirage sets only one of
   * them, a token we mint by logging in will not verify, while a token minted in
   * that environment already does. Q2 in docs/next-phase/06-open-questions.md.
   */
  MIRAGE_ADMIN_TOKEN: z.string().min(1).optional(),
  /**
   * Fallback credential: Mirage's `POST /api/v1/login-user` takes `{ id,
   * password }` where `id` is the admin user's 24-character Mongo ObjectId —
   * NOT an email (Controllers/userController.js:93-101). The adapter logs in and
   * caches the token when no MIRAGE_ADMIN_TOKEN is configured.
   */
  MIRAGE_ADMIN_USER_ID: z.string().regex(/^[a-f0-9]{24}$/i).optional(),
  MIRAGE_ADMIN_PASSWORD: z.string().min(1).optional(),
  /**
   * How long a login-derived admin token is reused before being re-minted
   * (seconds). Mirage's own `JWT_EXPIRE` defaults to `1d`, so this stays well
   * inside it — an expired token surfaces as a 403 "jwt expired", which the
   * adapter classifies as `auth` and retries exactly once.
   */
  MIRAGE_ADMIN_TOKEN_TTL_SECONDS: z.coerce.number().int().positive().default(43_200),
  /**
   * Public origin of the Mirage catalog site — the host a QR encodes. The
   * public URL is `{this}/{mirageRestaurantId}`, minted ONCE at provisioning and
   * then frozen (see models/Catalog.ts). Changing this variable does NOT
   * repoint already-issued URLs, by design: they are stored, not computed.
   */
  MIRAGE_PUBLIC_BASE_URL: z
    .string()
    .url()
    .optional()
    .transform((v) => (v ? v.replace(/\/+$/, '') : v)),
  /**
   * The S3 bucket and CDN host Mirage should write ITS copy of our assets to.
   *
   * These are not our buckets and not a ReCapture concern in the usual sense —
   * Mirage reads both FROM THE REQUEST BODY on every write
   * (Controllers/adminController.js:200-201, 530, 798-799, 1045-1046) and bakes
   * the CDN host into the URL it stores. There is no allow-list and no default
   * on its side: omit them and Mirage persists a customer-facing URL that
   * literally starts with the string "undefined". Hence a default here, taken
   * from the values Mirage hardcodes for its own stock upload path
   * (adminController.js:115-116). Q4.
   */
  MIRAGE_ASSET_BUCKET: z.string().min(1).default('maya-restaurants'),
  MIRAGE_ASSET_CDN_URL: z
    .string()
    .url()
    .default('https://d1ubv1fp33ooxl.cloudfront.net')
    .transform((v) => v.replace(/\/+$/, '')),
  /**
   * Per-request timeout against Mirage (ms). Deliberately long: a write is a
   * multipart upload of a whole model, and Mirage buffers the entire file in
   * memory (libs/s3.js readFileSync) on an instance that self-pings every 30 s
   * to stay awake on a sleeping tier — the first call after idle is slow.
   */
  MIRAGE_REQUEST_TIMEOUT_MS: z.coerce.number().int().positive().default(60_000),
  /**
   * Largest asset ReCapture will stream into Mirage (bytes). 90 MiB sits under
   * Mirage's 100 MB multer cap (libs/multer.js) so an oversize model is refused
   * by OUR preflight — with a code the user can act on — instead of dying inside
   * a multipart request as an unclassifiable 413.
   */
  MIRAGE_MAX_ASSET_BYTES: z.coerce.number().int().positive().default(94_371_840), // 90 MiB
  /**
   * How a product's assets reach Mirage.
   *
   *   bytes — read the object out of S3 as a STREAM and pipe it into the
   *           multipart request. Works against Mirage as it exists today, and
   *           costs one round trip of the whole file through this process.
   *   url   — send the ReCapture CloudFront URL and let Mirage fetch it
   *           server-side. Vastly cheaper (a 90 MiB model becomes a message),
   *           but it requires Mirage prompt M1: the current create-item and
   *           update-item handlers read files from `req.files` only and ignore a
   *           URL in the body entirely, so switching this on before M1 lands
   *           publishes products with NO assets.
   *
   * Defaults to `bytes` for exactly that reason — the safe mode is the one that
   * works against the Mirage that is deployed, not the one that is planned.
   */
  MIRAGE_ASSET_TRANSFER_MODE: z.enum(['bytes', 'url']).default('bytes'),
  /** Max publish runs one user may request per window. */
  PUBLISH_MAX_PER_WINDOW: z.coerce.number().int().positive().default(10),
  /** Sliding window for the publish cap (seconds). */
  PUBLISH_WINDOW_SECONDS: z.coerce.number().int().positive().default(3600),
  /**
   * Retries allowed per publish window. Tighter than PUBLISH_MAX_PER_WINDOW on
   * purpose: Retry is one tap sitting next to a list of failures, and a user
   * whose product keeps failing will tap it repeatedly — each tap being another
   * job against a Mirage that has to wake up.
   */
  PUBLISH_RETRY_MAX_PER_WINDOW: z.coerce.number().int().positive().default(20),
  /**
   * QR renders per window. Rendering is cheap but not free — a 2048 px PNG is
   * a real sharp resize — and the response is highly cacheable, so a client
   * hitting this hard is a client ignoring the ETag.
   */
  CATALOG_QR_MAX_PER_WINDOW: z.coerce.number().int().positive().default(60),
  CATALOG_QR_WINDOW_SECONDS: z.coerce.number().int().positive().default(600),

  // ── Same-day activation: pre-printed standees, minting, rep rate limits ────
  /**
   * Origin the pre-printed standees encode: a code resolves at
   * `{PUBLIC_RESOLVER_BASE_URL}/r/{code}`. Written verbatim into
   * `catalog.publicUrl` at activation and then FROZEN, so changing this value
   * later does NOT repoint already-printed codes — it only affects codes minted
   * after the change. Treat it as append-only in production.
   *
   * `.optional()` rather than defaulted ON PURPOSE: an environment that has not
   * set it must not silently mint codes pointing at a guessed host. The mint
   * endpoint and activation both fail loudly when it is absent; the API still
   * boots without it, so this can deploy before the hostname is decided.
   */
  PUBLIC_RESOLVER_BASE_URL: z
    .string()
    .url()
    .optional()
    .transform((v) => (v ? v.replace(/\/+$/, '') : v)),
  /**
   * Origin of the web client — used to build the rep's one-tap activation link
   * on the public resolver's "not live yet" page
   * (`{WEB_APP_BASE_URL}/rep/activate?code={code}`).
   *
   * `.optional()` for the same reason PUBLIC_RESOLVER_BASE_URL is, and the
   * fallback page checks it: when unset the page renders WITHOUT the link
   * rather than with a broken one. A rep tapping through to
   * `undefined/rep/activate` is worse than a rep typing the code into the app,
   * and this page is customer-facing — it is the surface where a guess is most
   * expensive.
   */
  WEB_APP_BASE_URL: z
    .string()
    .url()
    .optional()
    .transform((v) => (v ? v.replace(/\/+$/, '') : v)),
  /** Largest single mint. Bounds one bad admin request, not total inventory. */
  QR_BATCH_MAX_SIZE: z.coerce.number().int().positive().max(10_000).default(2_000),
  /** Per-rep activation rate window — see utils/rateLimit.ts. */
  ACTIVATION_MAX_PER_WINDOW: z.coerce.number().int().positive().default(30),
  ACTIVATION_WINDOW_SECONDS: z.coerce.number().int().positive().default(3600),
  /**
   * Publish runs retained per catalog for the activity log (feature 55).
   *
   * A COUNT, not a TTL. Expiring on age would leave a business that publishes
   * twice a year with an empty history screen while one publishing hourly still
   * accumulated a month of noise; "the last N" is what a history list means to
   * a person. Pruned on write, so the bound holds continuously.
   */
  CATALOG_ACTIVITY_RETAINED_RUNS: z.coerce.number().int().positive().default(50),
  /**
   * Hard ceiling on a stored product image, in bytes. Enforced at COMMIT time
   * (presigning cannot enforce a size) exactly as AVATAR_MAX_BYTES is. Larger
   * than an avatar because this one is catalog content a customer zooms into.
   */
  CATALOG_PRODUCT_IMAGE_MAX_BYTES: z.coerce.number().int().positive().default(5_242_880), // 5 MiB
  /** Presigned-PUT TTL for a product-image upload slot (seconds). */
  PRODUCT_IMAGE_UPLOAD_URL_TTL_SECONDS: z.coerce.number().int().positive().default(900),
  /**
   * Presigned product-image slots per user per window. Higher than the avatar
   * cap: a business setting up a catalog uploads a photo per product, and the
   * whole first session is legitimately dozens of them.
   */
  PRODUCT_IMAGE_UPLOAD_MAX_PER_WINDOW: z.coerce.number().int().positive().default(120),
  /** Sliding window for the product-image slot cap (seconds). */
  PRODUCT_IMAGE_UPLOAD_WINDOW_SECONDS: z.coerce.number().int().positive().default(3600),

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
