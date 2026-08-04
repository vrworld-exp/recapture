# AGENTS.md — ReCapture / Projects Hub

> Project-context and conventions file for **MayasabhaXR — ReCapture** (guided
> photogrammetry capture app + its backend). This is the single source of truth
> for cross-cutting decisions. Downstream task prompts are written to **defer to
> this file**; when a per-task prompt disagrees with a foundational convention
> here, **this file wins**.
>
> Scope: covers **both** codebases in this repo — the Flutter/Dart client (repo
> root) and the Node/TypeScript backend (`recapture-api/`).
>
> Keep this honest and as-built. If you change a convention, update this file in
> the same change. Sections marked **NOT YET BUILT** are deliberate gaps, not
> aspirations — do not describe them as if they exist.

---

## 0. Stack decisions (the foundational choices)

| # | Decision | Choice (as-built) |
|---|---|---|
| 1 | **Repo topology** | Single repo. Flutter app at root; backend in `recapture-api/`. **No shared package** — shared shapes (the Project DTO, analytics event names) are **hand-synced** between `lib/domain/entities/*.dart` and `recapture-api/src/models|services`. |
| 2 | **Backend framework** | **Express** + TypeScript. |
| 3 | **Datastore** | **MongoDB** (Atlas) via **Mongoose** ODM. Atomicity via conditional `findOneAndUpdate` (no multi-doc transactions in use). Soft-delete via a `deletedAt` field. |
| 4 | **Cache / rate-limit backend** | **No Redis.** Rate limiting is **DB-backed sliding windows** (see §Data layer). Do not add Redis without revisiting this file. |
| 5 | **Client state** | **Riverpod** (`flutter_riverpod` + `riverpod_annotation`). |
| 6 | **Client HTTP** | **Dio** (chosen for the interceptor pipeline the auth-refresh seam plugs into). |
| 7 | **Analytics destination** | **Not wired.** Both sides have a single emit seam that logs in non-prod (`trackEvent` backend / `Analytics.logEvent` client). Real pipeline is a TODO. |
| 8 | **Secrets / config** | Env files + a **Zod-validated typed loader that fails fast at boot** (`recapture-api/src/config/env.ts`). Backend secrets injected via Render env vars (`sync: false`); client config via `flutter_dotenv` (`.env`). **Never commit secrets.** |
| 9 | **SMS / email providers** | **Stubbed** (`recapture-api/src/providers/{sms,email}.ts`). Real vendor TBD; the call sites are stable. |
| 10 | **Hosting / deploy** | Backend → **Render** (`recapture-api/render.yaml`, region `singapore`). Client → **Play Store** via Fastlane (Android internal track, CI job on push to `main`); **iOS CI is a disabled stub**. |
| 11 | **Versions (pinned)** | **Node ≥ 20**; **Flutter 3.22.x** / **Dart `>=3.4.0 <4.0.0`**. CI uses Flutter `3.22.x`. |

---

## 1. Repository layout

```
ReCapture/
├── AGENTS.md                  ← this file (conventions; source of truth)
├── CLAUDE.md                  ← pointer to this file
├── README.md                  ← onboarding / run steps
├── docker-compose.yml         ← local MongoDB for backend dev
├── .github/workflows/ci.yml   ← CI: backend (tsc+lint) + Flutter (analyze+test) + deploy
├── lib/                       ← Flutter client (layered clean architecture)
│   ├── domain/                ← entities, value types (pure Dart, no Flutter/IO)
│   ├── data/                  ← local/ (Hive), remote/ (Dio), repositories/
│   ├── application/           ← Riverpod notifiers (state; never touches network)
│   ├── presentation/          ← screens/, widgets/
│   ├── app/                   ← routes/, theme/, bootstrap
│   └── utils/                 ← cross-cutting helpers (e.g. analytics)
├── test/                      ← Flutter tests (auth, config, offline, projects, storage)
└── recapture-api/             ← Node/TS backend
    └── src/
        ├── config/            ← env.ts (typed, fail-fast), db.ts, s3.ts
        ├── routes/            ← thin Express routers (auth, projects, health)
        ├── services/          ← business logic (pure-ish; no Express types)
        ├── models/            ← Mongoose schemas + interfaces
        ├── middleware/        ← auth, validate, errorHandler, notFound, requestLogger
        ├── validation/        ← Zod schemas per route group
        ├── providers/         ← SMS/email seams (stubs)
        ├── utils/             ← otp, tokens, rateLimit, cursor, analytics, asyncHandler
        └── types/             ← express.d.ts (req.user augmentation)
```

**Backend imports** use the `@/*` path alias → `src/*` (tsconfig `paths`). Dev runs
via `tsx watch`; build is `tsc` + `tsc-alias` (the alias rewrite is required —
do not remove it).

---

## 2. Conventions

### Code & structure
- **TypeScript `strict` is on.** `tsc --noEmit` must pass with zero errors.
- Backend layering: **routes → services → models**. Routers stay thin (parse,
  delegate, map result → HTTP). Business logic lives in `services/`; services
  avoid Express types and return typed result unions the route maps to responses.
- Flutter layering: **domain → data → application → presentation**. Notifiers are
  pure state and call repositories; repositories own all HTTP + error translation.
- **Lint/format both sides, enforced in CI:**
  - Backend: ESLint (`eslint:recommended` + `@typescript-eslint/recommended` +
    `prettier`), `no-explicit-any: error`, `no-unused-vars: error`
    (ignore `^_`). Prettier for format.
  - Client: `flutter_lints` via `analysis_options.yaml` (generated `*.g.dart` /
    `*.freezed.dart` excluded). `flutter analyze` + `dart format`.

### API contract (the ONE envelope)
- **Success:** `{ "status": "success", ... }`.
- **Error:** `{ "status": "error", "code": "<UPPER_SNAKE>", "message": "..." }`
  (plus optional `retryAfter`, `fields`, etc.).
- The **global error handler** (`middleware/errorHandler.ts`) maps a thrown
  error's `statusCode`/`code` onto the response; uncaught errors → `500`.
  Async route bodies are wrapped in `asyncHandler` so rejections reach it.
- **Validation** uses **Zod**. Body validation goes through the `validateBody`
  middleware (emits the `400 INVALID_REQUEST` envelope); query/param validation
  is done inline with `schema.safeParse` in the handler, mapped to the same
  envelope. Schemas live in `src/validation/`.
- **Enumeration-safe principle (security):** auth/ownership failures must be
  **indistinguishable at the API boundary**. e.g. OTP verify collapses
  no-record / expired / wrong-code / locked into one identical `401`; the
  distinction lives only in analytics. Apply the same to not-found vs not-owned
  (return the same status; never leak existence).
- **KNOWN INCONSISTENCY:** `middleware/auth.ts` (`requireAuth`) still returns the
  legacy `{ error: "..." }` shape, not the standard envelope. New code must use
  the envelope; standardize `requireAuth` when convenient (don't silently depend
  on the legacy shape).

### Roles & staff access (`/admin` route group)
- `User.role`: `USER | MODEL_ARTIST | ADMIN` (default `USER`; pre-role docs read
  as `USER` via the schema default — no migration). Granted **only** by
  `scripts/set-user-role.ts` (DB flag); there is deliberately **no grant UI or
  endpoint**.
- Privilege is **inclusive upward** (`ADMIN ⊇ MODEL_ARTIST ⊇ USER`). Every check
  goes through `hasRoleAtLeast` (`models/User.ts`) — exact-equality role checks
  are a bug.
- `middleware/requireRole.ts` (`requireRole(minRole)`) runs **after**
  `requireAuth`, resolves the role with a **fresh DB read per request** (role is
  NOT a JWT claim, so grants/revocations apply immediately), attaches it to
  `req.user.role`, and rejects with a standard-envelope `403 FORBIDDEN`
  (+ `admin_access_denied` analytics).
- The **`/admin` route group** (`routes/admin.ts`) is staff-only (min role
  `MODEL_ARTIST`): cross-user live-projects list/detail, a presigned-GET
  **export manifest**, an ADMIN-only photo soft-delete, and the **Meshy model
  generation** surface (below). Staff DTOs carry an opaque `ownerId` — **never**
  owner phone/email. The client learns its own role via `GET /auth/me`.
- **`GET`/`PATCH /auth/me` are MASKED-ONLY, not PII-free.** The raw phone/email
  still never leaves the API. The account snapshot adds `contactMasked`
  (`+91 ••••• ••210` / `a•••@gmail.com`), `contactChannel`, and an optional
  `displayName`, so the Profile screen can say *which* account is signed in
  without ever receiving the identifier. The one mask lives in
  `utils/maskIdentifier.ts` and mirrors the client's
  `OtpRequest.maskedDestination`; an unmaskable identifier returns `null`, never
  a partial raw value. `PATCH /auth/me` (`.strict()`, display name only) is the
  ONLY writable field on an account — role stays DB-flag-only. The guardrail is
  `tests/auth-me-profile.test.ts`, which asserts no raw identifier substring
  appears in either response body.
- **Profile pictures: the DB stores the S3 KEY, the API derives the URL.**
  `User.avatarKey` holds `{env}/avatars/{userId}/{uuid}.{jpg|png}`
  (`utils/avatarKeys.ts` — a SEPARATE key space from the capture-job
  `utils/s3Keys.ts`, whose parser is strict about its own 7-segment scheme).
  A presigned URL is a bearer credential that expires within the hour, so it is
  never persisted: `accountSnapshot` presigns per response and ships
  `avatarUrl` + `avatarUrlExpiresAt`, and `avatarKey` appears in NO response
  body. Avatars live in **`BUCKET_RAW` (private)**, never
  `BUCKET_ARTIFACTS`/CloudFront — a face photo attached to an account is PII,
  and moving it behind the CDN is a policy change that belongs in this file.
  Upload is **three steps** (presign → client PUTs straight to S3 → commit):
  the commit is where the server re-derives ownership from the token,
  `parseAvatarKey`s the caller-supplied key (**a key belonging to another user
  is a 403** — the security boundary of the feature), HEADs the object, and
  enforces `AVATAR_MAX_BYTES`, which presigning cannot. The pointer flips
  BEFORE the best-effort prefix sweep, so a crash orphans an object rather than
  breaking an avatar. `GET /auth/me/avatar/bytes` is the web-only fallback (the
  raw bucket has no CORS), reading the key from the token's user document, never
  from the caller. Guardrails: `tests/avatar-keys.test.ts` +
  `tests/auth-me-avatar.test.ts`.
- Export URLs are presigned S3 GETs with TTL `ADMIN_EXPORT_URL_TTL_SECONDS`
  (default 3600), rate-limited per user via the generic `consumeRateWindow`
  (`ADMIN_EXPORT_MAX_PER_WINDOW`/`ADMIN_EXPORT_WINDOW_SECONDS`). A presigned URL
  is a bearer credential: it may appear ONLY in the export response body —
  never in logs or analytics.

### 3D models: two origins, one shape
- A model is a **`ProjectModel`** record (`models/ProjectModel.ts`), one per
  generation attempt (full history — artists regenerate, compare, and `approve`
  one). Its **`source`** flag is the origin: `'meshy'` (built) or `'manual'`
  (RESERVED for the in-house pipeline). The client's "Created by Meshy AI" badge
  reads that flag and nothing else.
- **Meshy generation is ADDITIVE and human-triggered**, never automatic: staff
  pick 3–4 Preview-gallery photos → `POST /admin/projects/:id/model` → a
  **`MESHY_MODEL_GENERATION`** worker job (a peer job type, registered beside
  `CAPTURE_PROCESSING`). The capture→finalize→processing pipeline and
  `reconstructionEngine.ts` are **untouched** and remain the fallback. Design:
  `recapture-api/docs/meshy-integration-implementation-prompt.md`.
- **Generations cost credits.** Three guards, all load-bearing — do not remove
  one without replacing it: (1) `Idempotency-Key` on create (unique partial
  index on `(createdByUserId, idempotencyKey)`, same pattern as `POST /jobs`);
  (2) `meshyTaskId` persisted the instant the task exists, so a re-claim RESUMES
  instead of resubmitting; (3) a per-user rate window
  (`MESHY_CREATE_MAX_PER_WINDOW`). Error routing is the fourth: quota/`402`,
  bad input, and task-`FAILED` are `NonRetryableJobError` (terminal) so a quota
  failure can never retry-burn credits.
- **Meshy's result URLs expire** — the worker re-hosts the GLB/USDZ/thumbnail to
  `BUCKET_ARTIFACTS` under `…/{jobId}/models/{modelId}/`. Only OUR CloudFront
  URLs are ever persisted or served. Never store a Meshy URL.
- **Server-selected generation has TWO triggers and TWO flags.** Besides the
  hand-picked staff path above, `autoPhotoSelectionService.ts` can choose the
  3–4 photos itself (spread first, sharpness second; declining is a feature).
  That selector is reached from two places, gated independently **on purpose**:
  `AUTO_MODEL_GENERATION_ENABLED` (the capture processor, unattended, per
  capture) and `MANUAL_MODEL_GENERATION_ENABLED` (the "Generate 3D model"
  button — `POST /admin/projects/:id/model/auto`, and the owner-facing
  `POST /projects/:id/model` whose client entry point is not wired yet). One
  shared flag would make the button dead until unattended spend was switched
  on, which is exactly backwards: the button is how the selector gets exercised
  on real captures before that. Both count against ONE rolling 24h ceiling
  (`countServerSelectedGenerationsInLast24h` — `createdBySystem` OR
  `createdByManualButton`); hand-picked staff selections are excluded and keep
  their own rate window. Live kill switches are the `autoModelGenerationEnabled`
  / `manualModelGenerationEnabled` fields on the `client_configs` document, read
  via `getServerFlag` and deliberately NOT in `remoteConfigSchema`.
- **Every generation persists a `generationTrace`** on its `ProjectModel`: the
  six synchronous request steps and the selector's counters. Those steps all
  run INSIDE one sub-second request and arrive complete in the response — there
  is no streaming and nothing to poll (the minutes-long half is `progress`).
  The trace is **staff-only**: it is on `ProjectModelDto` and on NEITHER owner
  DTO, because it names our S3 key layout and our pipeline's internals.
- **`model-input/` namespace (reserved, currently unused by the client).**
  `POST /admin/projects/:id/model-images/upload-urls` presigns PUTs into the
  exportable job's reserved `model-input/` namespace under `rawPrefix`, and
  `GET /admin/projects/:id/photo-bytes` reads one capture photo through the
  API. Both exist for staff-edited model inputs; the client's editing screen
  was removed on 2026-07-31 (selection now goes straight to Create-Model), so
  nothing calls them today. The namespace rules stay: sibling of `deleted/`,
  excluded from the export manifest and from the capture processor's
  object-count re-verification, covered by the admin hard-delete purge.
- **`jobType` is now a real discriminator.** A project owns jobs of more than one
  type, so any query meaning "the capture job" MUST filter
  `jobType: CAPTURE_PROCESSING` (`models/types/job.types.ts`) — see
  `findExportableJob`, where omitting it silently breaks export/preview/delete.
- **`MESHY_API_KEY` is optional in `config/env.ts` and required at WORKER boot**
  (`assertMeshyConfigured()`): only the worker calls Meshy, so the API must not
  fail to boot over a secret it never uses.
- **The generation recipe is ONE preset, not scattered defaults.**
  `MESHY_PRESET` (`worker/engine/meshy/meshyClient.ts`) is sent verbatim on
  every task so a result is reproducible across environments and across Meshy
  changing its own defaults — which has bitten this repo once already
  (`should_remesh` defaults to FALSE on meshy-6, which `ai_model: 'latest'`
  resolves to; omitting it returns an unbounded mesh the WebView cannot load).
  Only `target_polycount` and `texture_resolution` stay env-tunable, because
  those are what an operator retunes against a device test.
  **Coupled fields:** `alpha_thumbnail: true` means the poster is a transparent
  PNG, so `meshyModelProcessor` re-hosts it as `preview.png` / `image/png`.
  Change one and you must change the other.
- **Generation optimizes for QUALITY; the pipeline optimizes for DELIVERY.**
  `MESHY_TARGET_POLYCOUNT` is **200,000** and `MESHY_TEXTURE_RESOLUTION` is
  **4k** — a low generation budget (the old 12k) was destroying thin features
  (handles, rims, stems) at the source, and no downstream stage can restore
  detail that was never generated. The GLB Meshy returns is therefore an
  **archive and a pipeline input, not a deliverable**: what a viewer loads is the
  `web` variant produced by `src/modules/asset-pipeline`. These two numbers move
  together with that module's `simplify` stage and the profile's texture rules —
  raising them without it ships a GLB the WebView cannot parse.
  `MESHY_TASK_TIMEOUT_MS` is **1,800,000** (30 min) to fit those tasks;
  `MESHY_POLL_INTERVAL_MS` stays 5 s regardless, because each poll is also the
  claim-lease renewal against `WORKER_CLAIM_TIMEOUT_MS`.

### Asset optimization (`src/modules/asset-pipeline/`)
- **`src/modules/` is a THIRD backend directory kind**, alongside `services/`
  and `worker/`. It holds **pure libraries**: no Express, no Mongoose, no AWS,
  no queue. `asset-pipeline` takes bytes and returns bytes, which is what lets
  its CLI run on a local GLB with no credentials and its tests run without a
  database. The single exception is `publish.ts` (the S3 writer), which the CLI
  deliberately never imports. Do not put business logic that reads the database
  here — that is still `services/`.
- **Four separated stages, not one `optimize()`:** `inspect` (pure read) →
  `plan` (pure function: report + profile → decisions) → `execute` (the only
  side-effecting stage) → `validate` (hard gates). Meshy output varies enormously
  per object, so every decision must be traceable to a measurement and both must
  land in `report.json`. `plan()` is pure specifically so it is unit-testable
  without a GLB — keep it that way.
- **Optimization NEVER gates a generation.** It runs as its own
  **`ASSET_OPTIMIZATION`** job, enqueued by `meshyModelProcessor` only after the
  record is already `SUCCEEDED` with a usable original. A pipeline failure marks
  `optimized.status = 'FAILED'` and leaves the model `SUCCEEDED` — the untouched
  Meshy GLB keeps serving. Nothing in the optimization path may write the
  model's own `status`. A failing re-run also **preserves** any manifest and
  active variant a previous successful run produced: it records the failure, it
  does not retract something that already worked.
- **The `web` variant is what a viewer receives, and promotion is automatic.**
  A run that passes its gates sets `optimized.activeVariant = 'web'` itself.
  This reversed with `ASSET_PIPELINE_VERSION` 2: promotion was manual while the
  Meshy GLB was directly servable, and at 200k triangles it is not — leaving
  `'original'` active would ship "We couldn't load this model" to every viewer.
  Everything ambiguous still falls back to `'original'` (a skipped run, a gate
  failure, a manifest with no `web` entry).
- **An admin's choice is PINNED and beats the automation.**
  `PATCH /admin/projects/:id/models/:modelId/variant` sets
  `variantPinnedByAdmin`, and no later pipeline run may move a pinned variant in
  **either** direction. That flag exists because `activeVariant === 'original'`
  cannot distinguish a deliberate demotion from the untouched default — without
  it, a re-run would silently re-promote over a human's decision. "Passed the
  gates" and "looks right" are still different claims; reverting to `'original'`
  must always be permitted.
- **The pipeline is what makes high-fidelity generation shippable.** `plan()`
  decides the decimation (`simplifyRatio`, from `profile.simplify.targetTriangles`
  — 35k against a 50k gate) and `execute()` runs `simplify` **after `weld`**
  (split vertices are seams it cannot collapse across) and **before `meshopt`**
  (which quantizes and reorders geometry). Remove that stage and a 200k source
  produces a variant that fails `gates.maxTriangles`, is discarded, and nothing
  optimized ever ships.
- **The original is immutable and load-bearing.** `…/models/{modelId}/model.glb`
  is never rewritten: it is the only way to re-run an improved recipe later.
  Variants go under a version prefix `…/models/{modelId}/v{n}/` served
  `public, max-age=31536000, immutable`; a changed recipe means a NEW
  `ASSET_PIPELINE_VERSION` and a new prefix, never an overwrite.
- **`AssetManifest` lives in `models/types/assetManifest.types.ts`**, not in the
  module — the pipeline is one producer of that shape, but the shape outlives it
  and is the contract the Flutter app and the Mirage Menu viewer read. It is
  written to S3 as `manifest.json` AND persisted on the record.
- **Two list entries, ONE record, ONE paid generation.**
  `GET /admin/projects/:id/models` `flatMap`s each record through
  `toProjectModelDtos`, so an optimized generation surfaces as two entries —
  `variant: 'original'` and `variant: 'web'` — carrying the SAME `id`, each with
  its own `artifacts.glb` and `metrics`. That is a VIEW, not a second row:
  `ProjectModel` stays one row per PAID generation because
  `countServerSelectedGenerationsInLast24h` counts rows, and a second row would
  double-count Meshy spend against the daily ceiling. Never dedupe this list by
  `id`, and never turn the second entry into a real record.
  The client mirrors this in `ProjectModelView` (`variant` / `isActiveVariant` /
  `metrics`), and the history row badges the optimized one **OPT** plus its
  size. Rows are keyed `model_row_{id}_{variant}` — keyed by id alone they
  would be duplicate sibling keys, which is a Flutter error, not a cosmetic bug.
  "Serving" is shown only when a generation actually has TWO renditions: with
  one rendition there is no choice to label.
  **Remaining client sync debt (2026-08-03):** the OWNER DTO's
  `originalGlbUrl` / `optimizedGlbUrl` / `isOptimized` are not parsed by
  `tryFromOwnerMap` yet — no owner surface needs them until the viewer offers a
  compare toggle.
- **`sharp` must be a single version in the tree.** `@gltf-transform/functions`
  pulls `sharp` transitively via `ndarray-pixels`; two copies means two libvips
  binaries in one process and image ops fail with
  `colourspace: parameter space not set`. If that error appears, check for a
  nested `node_modules/*/node_modules/sharp` and align the top-level version.

### Config & secrets
- **All tunables and secrets come from env.** `config/env.ts` validates them with
  Zod and **exits the process on missing/invalid required vars** (fail fast).
- Every operational tunable has a **safe default** so existing deployments boot
  without new vars. JWT signing key, DB URI, AWS keys are **required, no default**.
- Never hardcode a secret or a tunable. Add new config to `env.ts` **and**
  `.env.example` together.

### Data layer
- Mongoose schemas use `timestamps: true` (→ `createdAt` / `updatedAt`).
- **Soft-delete convention:** a `deletedAt: Date` field. Exclude soft-deleted
  rows with `deletedAt: null` (Mongo null-equality also matches the unset field).
- Ids are Mongo `ObjectId`; expose as `id` (string) in DTOs, never `_id`/`__v`.
- Add a **compound index for each real query path** (e.g. Project lists use
  `{ userId: 1, updatedAt: -1, _id: -1 }` so cursor pagination is deterministic).
- **Atomicity without transactions:** use a **conditional `findOneAndUpdate`**
  guarded on current state (e.g. refresh-token rotation flips `rotatedAt` only
  when it is still `null`, so concurrent requests can't both win).
- **Rate limiting is DB-backed** (no Redis): a single document per key carries a
  window start + count. Prefer the generic `utils/rateLimit.ts`
  (`consumeRateWindow(key, max, windowSeconds)` + `RateWindow` model) for new
  limiters. (Older one-offs exist: OTP send windows live inline on the `OtpCode`
  doc; verify throttling uses a `VerifyThrottle` model.)

### Logging & PII
- **Never log raw PII or secrets**: phone, email, OTP code, access/refresh
  tokens, passwords. Pass only **hashed identifiers** to logs/analytics.
- **One identifier-hashing util:** `utils/otp.ts → hashIdentifier()`
  (HMAC-SHA256 keyed by `OTP_HASH_SECRET ?? JWT_SECRET`, truncated). Reuse it for
  any `*_id_hash` analytics/log field. Do not invent a second hashing scheme.
- Request logging is a minimal `requestLogger` (method/url/status/ms via
  `console`). **NOT YET BUILT:** a structured logger with an automatic field
  denylist — today PII-safety is enforced by call-site discipline, not a library.

### Analytics
- **One emit entry point per side**, fire-and-forget, logs only in non-prod:
  - Backend: `utils/analytics.ts → trackEvent(event, props)`.
  - Client: `lib/utils/analytics.dart → Analytics.logEvent(name, props)`.
- Callers MUST pass only non-PII props (hashed identifiers, enum values, counts).
- **NOT YET BUILT:** a typed `AnalyticsEvent` registry with per-event Zod schemas,
  a PII guardrail baked into the emit layer, a real destination integration, and
  a tracking-plan artifact. Until then, event names/props are validated by review.

### Client foundations
- **Tokens** live in `flutter_secure_storage` (OS Keychain/Keystore), **not Hive**.
- **Hive** holds non-secret cache/state. Boxes: `active_session`,
  `projects_cache`, `config_cache`, `offline_queue`. Box names are centralized
  (`data/local/box_names.dart`); init/adapter registration in
  `data/local/hive_init.dart`. Tests use a temp-dir Hive helper.
- **Dio** has an interceptor pipeline (`data/remote/`); the auth-refresh
  interceptor is the seam for token rotation.
- **Connectivity** is a mockable abstraction (providers) so offline behavior is
  testable without a real network.
- **Role/staff UI:** the client learns its role from `GET /auth/me`
  (`userRoleProvider` / `isStaffProvider`, default `USER`, **fail-closed** on
  any fetch failure) and persists it as a warm-start hint in the
  `active_session` box (not secure storage — it is server-enforced, not a
  secret). Staff-only surfaces (the Projects screen's "Live projects" tab)
  gate on `isStaffProvider`; the backend re-checks the role on every request.

### Testing
- Hermetic: isolated store, deterministic, no real network, full teardown. Never
  modify prod code just to make a test pass.
- **Client:** `flutter test` with Hive temp-dir helpers — already in place under
  `test/` (auth, config, offline, projects, storage).
- **Backend:** `npm test` → **Vitest + Supertest + mongodb-memory-server**
  (hermetic Mongo), suites in `recapture-api/tests/`. Env is injected by
  `vitest.config.ts` BEFORE the module graph loads (`config/env.ts` validates and
  freezes env at import — a per-test `process.env` write is too late). External
  services are always faked: the S3 client is scripted via `vi.spyOn(s3Client,
  'send')`, and Meshy via `setMeshyClient(...)` — **CI never calls a live API.**

---

## 3. Common commands

**Backend** (`cd recapture-api`):
```
npm install
npm run dev          # tsx watch (needs .env — copy .env.example)
npm run type-check   # tsc --noEmit (must be clean)
npm run lint         # eslint
npm run build        # tsc + tsc-alias → dist/
npm start            # node dist/index.js
npm run worker       # the job-queue worker process

# Asset pipeline, offline — no AWS, no DB. Positional args, because npm claims
# --input/--profile as its own config and never forwards them:
npx tsx scripts/make-sample-glb.ts        # synthesize a Meshy-shaped GLB (~8 MB)
npm run pipeline -- ./samples/dish.glb food
# flag form works only when invoked directly:
npx tsx src/modules/asset-pipeline/cli.ts --input ./samples/dish.glb --profile food
```

**Client** (repo root):
```
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # codegen (riverpod/hive/freezed)
flutter analyze
flutter test
flutter run                                                 # dev flavor
```

**Local Mongo** (for backend dev): `docker compose up -d` (see `docker-compose.yml`).

---

## 4. Guardrails (do / don't)

- **Do** keep one envelope, one logger seam, one hashing util, one analytics
  entry point per side. **Don't** scatter response shapes or add a second
  validation/HTTP/state lib.
- **Don't** hardcode secrets or tunables — they go through `env.ts` + `.env.example`.
- **Don't** log raw PII; hash identifiers via `hashIdentifier`.
- **Don't** make auth/ownership errors distinguishable at the boundary.
- **Do** keep the Project DTO identical across `GET /projects` and
  `POST /projects` (and in sync with the Flutter `Project` entity) — they share
  one shape by contract.
- **Do** update this file when a convention changes.
