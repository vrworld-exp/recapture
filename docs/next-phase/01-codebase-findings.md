
✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅
# 01 — Codebase Findings

Factual snapshot of both codebases as they exist today. **No proposals in this file.**
Everything below was read from source; file paths are cited so any claim can be re-checked.

Repos inspected:

| Repo | Path | Role in this phase |
|---|---|---|
| ReCapture | `phase2/ReCapture/` (Flutter client at root + `recapture-api/` Node backend) | Where new code lands |
| Mirage backend | `phase2/mirage-be/` | Read-only reference — the API surface ReCapture will call |
| Mirage frontend | `phase2/mirage-fe/` | Read-only — consulted only to determine the public catalog URL shape |

---

## ReCapture — Tech Stack

Authoritative conventions file: `ReCapture/AGENTS.md` (439 lines). `ReCapture/CLAUDE.md` is a
12-line pointer to it. AGENTS.md declares itself the tie-breaker over any task prompt.

**Client — Flutter/Dart** (`pubspec.yaml`). Flutter 3.22.x, Dart `>=3.4.0 <4.0.0`.

| Concern | Package | Version |
|---|---|---|
| State | `flutter_riverpod` + `riverpod_annotation` | ^2.5.1 / ^2.3.5 |
| Navigation | `go_router` | ^17.3.0 |
| HTTP | `dio` | ^5.4.3 |
| Secure token storage | `flutter_secure_storage` | ^11.0.0 |
| Non-secret cache | `hive` / `hive_flutter` | ^2.2.3 / ^1.1.0 |
| Config | `flutter_dotenv` | ^6.0.1 |
| 3D viewer | `model_viewer_plus` | ^1.9.3 |
| Share sheet | `share_plus` | ^13.2.0 |
| Gallery picker | `image_picker` | ^1.1.2 |
| Connectivity | `connectivity_plus` | ^7.1.1 |
| Codegen | `freezed_annotation` ^2.4.1, `json_annotation` ^4.9.0 | |
| Hashing | `crypto` | ^3.0.3 |
| Permissions | `permission_handler` ^13.0.0 (pinned override `permission_handler_android: 13.0.1`) | |

**Backend — Node/TypeScript** (`recapture-api/`). Node ≥ 20, Express + TypeScript `strict`,
Mongoose (MongoDB Atlas), Zod validation, `@aws-sdk/client-s3`. Dev via `tsx watch`; build is
`tsc` + `tsc-alias` (the alias rewrite is load-bearing — `@/*` → `src/*`).
Tests: Vitest + Supertest + `mongodb-memory-server`. Deploy: Render (`render.yaml`, region
`singapore`). **No Redis anywhere** — an explicit stack decision (AGENTS.md §0.4).

There is **no shared package** between client and backend. The Project DTO and analytics event
names are **hand-synced** between `lib/domain/entities/*.dart` and `recapture-api/src/models|services`.

---

## ReCapture — Folder Structure

**Client** (`lib/`) — layered clean architecture, dependencies flow
`domain → data → application → presentation`:

| Folder | Contents |
|---|---|
| `lib/domain/` | Pure Dart entities/value types, no Flutter or IO. `entities/` has ~45 files (`project.dart`, `project_model.dart`, `user_profile.dart`, `user_role.dart`, …) |
| `lib/data/` | `remote/` (Dio client + interceptors), `local/` (Hive), `repositories/` (5: account, auth, config, live_projects, projects), `datasources/`, `models/` |
| `lib/application/` | Riverpod notifiers — pure state, call repositories, **never touch network directly**. Sub-folders: auth, capture, config, connectivity, offline, projects, upload, warmup |
| `lib/presentation/` | `screens/` (auth, capture, preview, profile, projects), `widgets/`, `providers/`, `state/` |
| `lib/app/` | `routes/` (`app_router.dart`, `auth_router_notifier.dart`), `theme/`, bootstrap |
| `lib/platform/` | `ar/`, `camera/`, `permissions/` — native seams |
| `lib/utils/` | Cross-cutting (`analytics.dart`, `constants.dart`) |
| `test/` | Hive temp-dir hermetic tests: auth, config, offline, projects, storage |

**Backend** (`recapture-api/src/`) — layering is `routes → services → models`; routers stay thin:

| Folder | Contents |
|---|---|
| `config/` | `env.ts` (Zod-validated, fail-fast at boot), `db.ts`, `s3.ts` |
| `routes/` | `auth.ts` (745), `projects.ts` (651), `jobs.ts` (454), `admin.ts` (973), `remoteConfig.ts`, `health.ts` |
| `services/` | 15 files — `projectsService.ts`, `projectModelsService.ts` (1091), `adminProjectsService.ts`, `s3ObjectStore.ts`, `s3MultipartService.ts`, `modelOptimizerService.ts`, `otpService.ts`, … |
| `models/` | `User.ts`, `Project.ts`, `ProjectModel.ts`, `Job.ts`, `ClientConfig.ts`, `OtpCode.ts`, `RefreshToken.ts`, `RateWindow.ts`, `VerifyThrottle.ts` + `types/` |
| `middleware/` | `auth.ts`, `requireRole.ts`, `validate.ts`, `errorHandler.ts`, `notFound.ts`, `requestLogger.ts` |
| `validation/` | Zod schemas per route group |
| `worker/` | `jobQueue.ts`, `processorRegistry.ts`, `worker.ts`, `processors/` (capture, meshy, optimization) |
| `utils/` | `analytics.ts`, `s3Keys.ts`, `avatarKeys.ts`, `rateLimit.ts`, `tokens.ts`, `otp.ts`, `cursor.ts`, `errors.ts`, `asyncHandler.ts`, `etag.ts`, `maskIdentifier.ts` |
| `modules/asset-pipeline/` | glTF-Transform optimization library + CLI |

**Route mount points** (`src/app.ts:53-60`):
`/health`, `/auth`, `/projects`, `/jobs`, `/remote-config`, `/admin`.

Existing endpoints relevant as patterns:

| Method | Path | Source |
|---|---|---|
| GET/PATCH | `/auth/me` | `routes/auth.ts:111,140` |
| POST | `/auth/me/avatar/upload-url` | `routes/auth.ts:208` |
| PUT / DELETE | `/auth/me/avatar` | `routes/auth.ts:400,494` |
| GET / POST | `/projects` | `routes/projects.ts:56,182` |
| GET / PATCH / DELETE | `/projects/:id` | `routes/projects.ts:121,532,591` |
| GET | `/projects/:id/models` | `routes/projects.ts:408` |
| POST | `/projects/:id/models/:modelId/optimize` | `routes/projects.ts:444` |
| POST | `/projects/:id/model` | `routes/projects.ts:235` |

---

## ReCapture — Auth Flow

- **Phone/email OTP.** `POST /auth/send-otp` → `POST /auth/verify-otp` → access + refresh token pair;
  `POST /auth/refresh` rotates (`routes/auth.ts:597,639,692`).
- **Client token storage:** `flutter_secure_storage` (OS Keychain/Keystore) — **not Hive**. Hive holds
  only non-secret cache (`active_session`, `projects_cache`, `config_cache`, `offline_queue`;
  names centralized in `data/local/box_names.dart`).
- **Attachment:** `lib/data/remote/auth_interceptor.dart` in the Dio interceptor pipeline attaches the
  bearer token and handles 401-refresh. `AuthRepository` deliberately uses a **bare Dio**, so refresh
  never rides its own 401-refresh interceptor (`lib/data/remote/api_client.dart:9-14`).
- **Roles:** `User.role` ∈ `USER | MODEL_ARTIST | ADMIN`, granted **only** by
  `scripts/set-user-role.ts` — no grant UI or endpoint. Privilege is inclusive upward via
  `hasRoleAtLeast` (`models/User.ts:20-22`); exact-equality role checks are a bug.
  `middleware/requireRole.ts` does a **fresh DB read per request** — role is not a JWT claim.
- **Enumeration-safety** is a stated security invariant: not-found and not-owned must be
  indistinguishable at the API boundary.
- **KNOWN INCONSISTENCY** (AGENTS.md §API contract): `middleware/auth.ts` (`requireAuth`) still
  returns the legacy `{ error: "..." }` shape, not the standard envelope.

---

## ReCapture — API Client

- **One response envelope.** Success `{ "status": "success", ... }`; error
  `{ "status": "error", "code": "<UPPER_SNAKE>", "message": "..." }` (+ optional `retryAfter`, `fields`).
- Global `middleware/errorHandler.ts` maps a thrown error's `statusCode`/`code`; uncaught → 500.
  Async route bodies are wrapped in `asyncHandler` so rejections reach it.
- **Validation is Zod.** Body via the `validateBody` middleware (emits `400 INVALID_REQUEST`);
  query/params inline with `schema.safeParse`, mapped to the same envelope. Schemas in `src/validation/`.
- **Client side:** one configured Dio in `dioProvider` (`lib/data/remote/api_client.dart:15-24`) —
  base URL + timeouts from `AppConfig`, `AuthInterceptor` wired in. Repositories
  (`ProjectsRepository`, `AccountRepository`, `LiveProjectsRepository`) own all HTTP **and** error
  translation; notifiers never call HTTP.
- Cursor pagination helper: `utils/cursor.ts`; ETag support: `utils/etag.ts`.

---

## ReCapture — State Management

Riverpod (`flutter_riverpod` + `riverpod_annotation` codegen via `build_runner`). Notifiers live in
`lib/application/<feature>/`, are pure state, and call repositories. Connectivity is a mockable
abstraction behind providers so offline behaviour is testable without a network.
Role/staff UI reads `userRoleProvider` / `isStaffProvider` from `GET /auth/me`, defaults to `USER`,
and is **fail-closed** on any fetch failure; it is cached as a warm-start hint in the
`active_session` Hive box (not secure storage — it is server-enforced, not a secret).

---

## ReCapture — File & Model Upload Flow

**Two distinct key spaces, deliberately not unified** (AGENTS.md §Profile pictures / §S3 key scheme).

**Capture jobs** — `utils/s3Keys.ts` is the ONE builder and parser; inline key templates elsewhere
are a bug:

```
{env}/{projectSlug}_{projectId}/{jobId}/images/{EYE|TOP|LOW}/{name}.jpg
{env}/{projectSlug}_{projectId}/{jobId}/capture_manifest.json
{env}/{projectSlug}_{projectId}/{jobId}/model-input/…      ← reserved namespace
{env}/{projectSlug}_{projectId}/{jobId}/deleted/…          ← soft-delete park
{env}/{projectSlug}_{projectId}/{jobId}/models/{modelId}/… ← 3D artifacts
```

- `{env}` (`dev|staging|prod`) is config-driven from `NODE_ENV`, **never hardcoded** — it is the
  firewall that stops a non-prod deploy from deleting prod objects (project delete wipes **by prefix**).
- `{projectSlug}` is a **label, never an identifier** — one-way, nothing resolves a project by it.
- `{userId}` is **not** in the path. Ownership is enforced in the DB and by the token.
- Keys are built **once** and persisted on `Job.upload` (`rawPrefix`, `manifestKey`) at job creation;
  every later read/list/move/delete resolves from the persisted values. Rebuilding a prefix for an
  existing job would be data loss.
- The client never builds keys — it receives `keyPrefix`/`keyTemplate` in the upload plan.

**Avatars** — a separate space, `utils/avatarKeys.ts`: `{env}/avatars/{userId}/{uuid}.{jpg|png}`.
Upload is **three steps**: presign → client PUTs straight to S3 → commit. The commit re-derives
ownership from the token, parses the caller-supplied key (**a key belonging to another user is a
403**), HEADs the object, and enforces `AVATAR_MAX_BYTES` (2 MiB), which presigning cannot.
Avatars live in `BUCKET_RAW` (private) — never CloudFront — because a face photo is PII.
A presigned URL is a bearer credential and is **never persisted**; `avatarUrl` is derived per response.

**Buckets / CDN** (`config/s3.ts`):
`BUCKET_RAW` = `msxr-raw-captures` (private), `BUCKET_ARTIFACTS` = `msxr-model-artifacts`,
`CLOUDFRONT_BASE` = `env.CLOUDFRONT_BASE_URL`. Both buckets use the **identical prefix** so
`deleteProject` can wipe both with one prefix. Only ReCapture CloudFront URLs are ever persisted —
Meshy's own result URLs expire and are re-hosted by the worker; **never store a Meshy URL**.

---

## ReCapture — Existing Catalog/Product/Model Concepts

**There is no catalog, no product, and no publish concept in ReCapture today.** The nearest
existing concepts are `Project` (one captured physical object) and `ProjectModel` (one generation
attempt). Verbatim schemas:

`recapture-api/src/models/Project.ts:31-124`:

```ts
export const PROJECT_STATUS_VALUES = [
  'DRAFT', 'CAPTURING', 'UPLOADING', 'PROCESSING', 'COMPLETED', 'FAILED',
] as const;

export interface IProject extends Document {
  userId: Types.ObjectId;
  name: string;
  objectSize: ObjectSize;          // 'SMALL' | 'MEDIUM' | 'LARGE'
  mode: CaptureMode;               // 'GUIDED' | 'MANUAL'
  category?: string;               // free-text, maxlength 50
  status: ProjectStatus;
  statusUpdatedAt?: Date | null;
  activeJobId?: Types.ObjectId;
  latestCompletedJobId?: Types.ObjectId;
  stats?: ProjectStats;            // { totalPhotos, warnings, lastCaptureAt }
  deletedAt?: Date;
  createdAt: Date;
  updatedAt: Date;
}
// Indexes
ProjectSchema.index({ userId: 1, updatedAt: -1, _id: -1 });
ProjectSchema.index({ userId: 1, status: 1 });
ProjectSchema.index({ status: 1, updatedAt: -1, _id: -1 });
```

`recapture-api/src/models/ProjectModel.ts` — the artifact carrier. Relevant sub-schemas
(`ProjectModel.ts:114-134`):

```ts
const ModelCdnUrlsSchema = new Schema<ModelCdnUrls>({
  glb:     { type: String, required: true },
  usdz:    { type: String },
  preview: { type: String },
}, { _id: false });

const ModelArtifactsSchema = new Schema<ModelArtifacts>({
  glbKey:          { type: String, required: true },
  usdzKey:         { type: String },
  previewImageKey: { type: String },
  cdnUrls:         { type: ModelCdnUrlsSchema, required: true },
  glbBytes:        { type: Number, min: 0 },   // absent means UNKNOWN, never "small"
}, { _id: false });
```

Key `IProjectModel` fields: `projectId`, `jobId`, `source` (`'meshy' | 'manual' | 'optimized'`),
`status`, `selectedKeys[]`, `meshyTaskId`, `progress`, `artifacts`, `approved`, `error`,
`idempotencyKey`, `optimizedFrom`, `optimization`, `createdByUserId`, `createdByRole`,
`createdBySystem`, `createdByManualButton`, `generationTrace`.

Indexes (`ProjectModel.ts:218-243`) — note the two **unique partial** ones, both described in-code
as "the race authority":

```ts
ProjectModelSchema.index({ projectId: 1, createdAt: -1 });
ProjectModelSchema.index({ createdByUserId: 1, idempotencyKey: 1 },
  { unique: true, partialFilterExpression: { idempotencyKey: { $exists: true } } });
ProjectModelSchema.index({ createdByUserId: 1, createdAt: -1 });
ProjectModelSchema.index({ optimizedFrom: 1 },
  { unique: true, partialFilterExpression: { optimizedFrom: { $exists: true } } });
```

**Owner-facing DTO** (`services/projectModelsService.ts:156-172`) — what a business user can already
read for their own model, and therefore what a catalog product can consume:

```ts
{ id, source, status, glbUrl?, usdzUrl?, previewUrl?, approved, isAutoGenerated,
  sizeBytes?, isOptimized, canOptimize, progressPercent?, error?, createdAt }
```

`previewUrl` is a **generated thumbnail** — 3D products get one for free.

Two parallel read surfaces exist by design: staff `GET /admin/projects/:id/models` →
`ProjectModelDto`, owner `GET /projects/:id/models` → `OwnerModelListItemDto`. Owner projections are
built **field by field, never by spreading a record**.

`latestSucceededModel` returns the **OPT (optimized) record** once one succeeds — the owner is meant
to get the small file. `MODEL_OPTIMIZE_THRESHOLD_BYTES` = 5 MiB (binary), advisory only.

**`ClientConfig`** (`models/ClientConfig.ts`) is **not** business branding — it is a **single global
document** (`collection: 'client_configs'`, `strict: false`) holding capture tuning served by
`GET /remote-config`. The comment states: "There is intentionally no per-user/per-project config."

**`User`** (`models/User.ts:24-57`) carries `authProvider`, `authUid`, `email?`, `phone?`,
`displayName?`, `avatarKey?`, `avatarUpdatedAt?`, `emailVerified`, `phoneVerified`, `role`.
**No business name, logo, address, website, or social links.**

---

## ReCapture — Background Worker

This is the existing async machinery any sync layer would reuse.

- **`worker/jobQueue.ts:38-70` — `claimNextJob`** is ONE conditional `findOneAndUpdate`. Multiple
  worker instances cannot double-claim. Its header comment says it is "the only module the planned
  BullMQ migration replaces (keep the exported signatures stable)". It also re-claims **stale**
  `CLAIMED/PROCESSING/TEXTURING/OPTIMIZING` jobs whose lease is older than `claimTimeoutMs` — crash recovery.
- **Retry backoff** (`jobQueue.ts:19-20`): 1 min → 2 → 4 …, capped at 30 min. Deliberately hardcoded,
  not env — "a queue-shape constant, not an ops tunable".
- **`worker/processorRegistry.ts`** — `jobType → processor` map. New job types plug in via
  `registerProcessor` "without touching the polling loop".
- Existing job types (`models/types/job.types.ts`): `CAPTURE_PROCESSING`,
  `MESHY_MODEL_GENERATION`, `MODEL_OPTIMIZATION`. **`jobType` is a real discriminator** — any query
  meaning "the capture job" MUST filter `jobType: CAPTURE_PROCESSING`.
- Worker tunables in `env.ts`: `RUN_WORKER_IN_PROCESS`, `WORKER_POLL_INTERVAL_MS` (5000),
  `WORKER_CLAIM_TIMEOUT_MS` (120000), `WORKER_CONCURRENCY` (2), `WORKER_HEARTBEAT_EVERY_N_POLLS` (20).
- `NonRetryableJobError` marks terminal failures (quota/402, bad input) so they can never retry-burn credits.

---

## ReCapture — Existing Mirage Integration Surface

**None. This is greenfield.**

A repo-wide search for `mirage` across `recapture-api/src`, `lib`, and `.env.example` returns only:

- `lib/app/theme/app_colors.dart:28` — `static const Color mirageRed = Color(0xFFE10600)` and its
  theme uses (brand colour only).
- `recapture-api/src/models/types/assetManifest.types.ts:4` — a comment naming "the Mirage Menu web
  viewer" as a downstream consumer of the asset manifest shape.

There is **no** `MIRAGE_API_BASE_URL`, no API key, no client credential, no adapter, no Postman
collection, and no documented Mirage contract anywhere in the ReCapture repo. Full `env.ts` variable
list confirms it: the only external-service block is `MESHY_*`.

---

## ReCapture — Conventions & Gotchas

- **One of each seam.** One response envelope, one logger seam, one hashing util
  (`utils/otp.ts → hashIdentifier`, HMAC-SHA256), one analytics entry point per side. Do not add a
  second validation, HTTP, or state library.
- **Config:** every tunable and secret goes through `config/env.ts` (Zod, fail-fast) **and**
  `.env.example`, together. Every operational tunable needs a safe default so existing deployments
  boot without new vars. JWT key, DB URI, AWS keys are required with no default.
- **Data layer:** `timestamps: true`; soft-delete via `deletedAt: Date` (exclude with
  `deletedAt: null` — Mongo null-equality also matches unset). Ids are `ObjectId`, exposed as `id`
  string in DTOs, never `_id`/`__v`. **A compound index for each real query path.**
  **Atomicity without transactions** — conditional `findOneAndUpdate` guarded on current state.
- **Rate limiting is DB-backed** (no Redis). Prefer the generic
  `utils/rateLimit.ts → consumeRateWindow(key, max, windowSeconds)` + `RateWindow` model for new limiters.
- **PII:** never log raw phone, email, OTP code, or tokens. Pass hashed identifiers only.
  A structured logger with an automatic denylist is **NOT YET BUILT** — safety is call-site discipline.
- **Analytics:** one emit entry point per side — backend `utils/analytics.ts → trackEvent(event, props)`,
  client `lib/utils/analytics.dart → Analytics.logEvent(name, props)`. Fire-and-forget, logs only in
  non-prod. **NOT YET BUILT:** typed event registry, per-event Zod schemas, a PII guardrail in the
  emit layer, a real destination, and a tracking-plan artifact. **There is no analytics destination wired.**
- **`meshopt` gotcha:** optimized GLBs put `EXT_meshopt_compression` in `extensionsRequired`, and
  `<model-viewer>` has no default meshopt decoder location. The decoder trigger must be set in
  **both** `web/index.html` **and** `_lifecycleJs` in `model_render_view.dart` — fixing one ships the
  other platform broken. Guarded by `test/projects/meshopt_decoder_test.dart`.
- **`sharp` must resolve to ONE copy** in `node_modules` (two libvips addons break every texture pass).
- **Testing is hermetic** — isolated store, no real network. Backend env is injected by
  `vitest.config.ts` **before** the module graph loads, because `config/env.ts` validates and freezes
  env at import. S3 is scripted via `vi.spyOn(s3Client, 'send')`; Meshy via `setMeshyClient(...)`.
  CI never calls a live API.
- Lint/format enforced in CI both sides. Backend ESLint has `no-explicit-any: error`.

---

## Mirage Backend — Tech Stack

`mirage-be/package.json` — name `backend_cleaned`, entry `index.js`.

- **JavaScript (CommonJS), not TypeScript.** No build step (`"build": "echo 'No build step required'"`).
- **No tests** (`"test": "echo \"Error: no test specified\" && exit 1"`).
- Express ^4.19.2, Mongoose ^8.5.3, `aws-sdk` **v2** ^2.1692.0, multer ^1.4.5-lts.2,
  jsonwebtoken ^9.0.2, ioredis ^5.8.1, lru-cache ^11.2.2, uuid ^10, morgan, cors,
  swagger-jsdoc + swagger-ui-express (docs at `/docs`).
- Body limits 30 MB JSON / urlencoded (`index.js`). CORS is currently **wide open**
  (`app.use(cors())`) — the production allow-list is commented out.
- 404 handler returns HTTP **400** with `{ status: false, message: "Path not found.(400)" }`.

---

## Mirage Backend — Folder Structure

```
mirage-be/
├── index.js                    ← app bootstrap, mongoose connect, route mounting
├── uploads/                    ← multer disk destination
└── src/
    ├── CONSTANT.js             ← config getters (WITH HARDCODED FALLBACK SECRETS)
    ├── Routes/                 ← routes.js, adminRouter.js, userRoutes.js,
    │                             routesModel.js, analyticsRoutes.js
    ├── Controllers/            ← adminController.js (1370), itemController.js (790),
    │                             analyticsController.js (545), userController.js (184),
    │                             restaurantController.js (107)
    ├── Models/                 ← restaurantModel, itemModel, categoryModel,
    │                             userModel, analyticsEventModel, threeDModel
    ├── Middlewares/            ← middleware.js (isAuthorized/isAdmin/isChef),
    │                             apiKeyValidator.js, analyticsRateLimit.js
    ├── libs/                   ← s3.js (aws-sdk v2), multer.js, redis.js
    ├── helper/                 ← helper.js, analyticsHelper.js
    ├── Validation/             ← regex.js, validateData.js
    └── stock_DB_all/           ← a SECOND mongo connection (stock DB) — separate product
```

**Mount points** (`index.js`):

```js
app.use("/api/v1",           apiKeyValidator, routers);       // Routes/routes.js
app.use("/api/v1",           apiKeyValidator, adminRoutes);   // Routes/adminRouter.js
app.use("/api/v1",           apiKeyValidator, userRoutes);    // Routes/userRoutes.js
app.use("/api/v1/stock",     apiKeyValidator, stockRouters);
app.use("/api/get-model",    modelRoutes);
app.use("/api/v1/analytics", analyticsRoutes);                // NO apiKeyValidator — deliberate
```

**Response envelope:** `{ status: <boolean>, message: <string>, data?: … }`. Note this is a
**boolean** `status`, unlike ReCapture's string `"success"`/`"error"`. Errors are frequently `400`
where `404`/`422` would be expected, and validation failures and server errors share shapes.

---

## Mirage Backend — Complete Route Table

Everything catalog-relevant. `apikey` header is required on all `/api/v1` routes except
`/api/v1/analytics/collect`. Admin routes additionally require the `token` header
(`isAuthorized`) and `role === "admin"` (`isAdmin`).

### Write surface — admin (`src/Routes/adminRouter.js`)

All of these carry `uploadFieldsMW` where noted: **multipart/form-data**, multer fields
**`image` (max 1)** and **`object` (max 1)**, 100 MB limit (`src/libs/multer.js`).

| # | Method | Path | Handler | Auth | Request | Response |
|---|---|---|---|---|---|---|
| M1 | GET | `/api/v1/get-all-restaurants` | `adminController.getAllRestaurants` (`adminController.js:1216`) | apikey + token + admin | — | `{status, message, length, data:[restaurant]}` |
| M2 | POST | `/api/v1/create-restaurant` | `adminController.createRestaurant` (`adminController.js:183`) | apikey + token + admin | multipart. Body: `name` (string, **required, must be globally unique, case-insensitive**), `location` (string, required to be a string), `categories`, `phoneNo` (server prefixes `+91`), `CLOUD_FRONT_URL`, `BUCKET_NAME`. File: `image` → key `res_icons/{Date.now()}-{name}.{ext}` | `201 {status:true, message, data: restaurantDoc}` |
| M3 | PUT | `/api/v1/update-restaurant/:restaurantId` | `adminController.updateRestaurant` (`adminController.js:282`) | apikey + token + admin | multipart, same body. `restaurantId` must be a valid ObjectId. `name` and `location` **must both be strings or it 400s** — this is not a partial update | `201 {status:true, message, data: restaurantDoc}` |
| M4 | DELETE | `/api/v1/delete-restaurant/:restaurantId` | `adminController.deleteRestaurant` (`adminController.js:1245`) | apikey + token + admin | — | `200 {status:true, message}`. **HARD delete** — cascades `categoryModel.deleteMany` + `itemModel.deleteMany` |
| M5 | POST | `/api/v1/create-category` | `adminController.createCategory` (`adminController.js:520`) | apikey + token + admin | multipart. Body: `name` (string; server lowercases + `replaceSpaceWithUnderscore`), `restaurant` (**valid ObjectId, required**), `CLOUD_FRONT_URL`, `BUCKET_NAME`. File: `image` → key `{restaurant.name}/categories/{ts}-{name}.{ext}` | `201 {status:true, message, data: categoryDoc}`. Also `$push`es the id onto `restaurant.categories` |
| M6 | PUT | `/api/v1/update-category/:categoryId` | `adminController.updateCategory` (`adminController.js:647`) | apikey + token + admin | multipart. Body: `name` (**must be a string or 400**), `CLOUD_FRONT_URL`, `BUCKET_NAME`. File: `image` | `201 {status:true, message, data: categoryDoc}` |
| M7 | DELETE | `/api/v1/delete-category/:categoryId` | `adminController.deleteCategory` (`adminController.js:1349`) | apikey + token + admin | — | **STUB — returns the literal string `"Not created now."`**. Does nothing. |
| M8 | POST | `/api/v1/create-item` | `adminController.createItems` (`adminController.js:783`) | apikey + token + admin | multipart. Body: `name` (string, **must be unique within the restaurant**), `price` (dropped if falsy or ≤0), `category` (**valid ObjectId, required**), `restaurant` (**valid ObjectId, required**), `imgOnly`, `annotations` (JSON string or array), `description`, `isNonVeg`, `CLOUD_FRONT_URL`, `BUCKET_NAME`. Files: `image` → `{restaurant.name}/imgs/{ts}-{name}.{ext}`, `object` → `{restaurant.name}/models/{ts}-{name}.{ext}`. **At least one of `image`/`object` is required.** The whole `req.body` is spread into the document | `201 {status:true, message, data: itemDoc}`. Also `$push`es onto `category.products`; if image-without-object it sets `imgOnly:true` and flips `restaurant.clientType = "BOTH"` |
| M9 | PUT | `/api/v1/update-item/:itemId` | `adminController.updateItem` (`adminController.js:1021`) | apikey + token + admin | multipart. Body: `name`, `price`, `isNonVeg`, `annotations`, `CLOUD_FRONT_URL`, `BUCKET_NAME`. Files: `image`, `object`. **Only these fields are applied** — `description`, `category`, `imgOnly` are read out of the destructure but commented out / never written | `200 {status:true, message, data: itemDoc}` |
| M10 | DELETE | `/api/v1/delete-item/:itemId` | `adminController.deleteItems` (`adminController.js:1291`) | apikey + token + admin | — | `200 {status:true, message}`. **HARD delete.** Side effect: if this was the last item in its category, it **hard-deletes the category too** (`adminController.js:1312-1319`) |
| M11 | GET | `/api/v1/get-all-categories-admin/:restaurantId` | `adminController.getALlCategoriesAdmin` (`adminController.js:426`) | apikey + token + admin | param accepts **name (regex) or ObjectId** | `{status, message, length, data:[category], restaurantData}` |
| M12 | GET | `/api/v1/get-all-items-for-cat/:categoryId` | `adminController.getAllItemsForCat` (`adminController.js:473`) | apikey + token + admin | param accepts **name (regex) or ObjectId** | `{status, message, length, data:[item], categoryData}` |
| M13 | POST | `/api/v1/upload-res-icon-from-stock` | `adminController.uploadResIconFromStock` (`adminController.js:99`) | **apikey only** — no `isAuthorized`/`isAdmin`. Gated on `req.headers.origin`/`referer` containing `mayasabhaxr.com` and a `stockUserModel` lookup by `userName` | multipart, file `image`; body `userName`. Bucket/CDN are hardcoded in the handler (`maya-restaurants`, `d1ubv1fp33ooxl.cloudfront.net`) | `201 {status:true, message, imageUrl}` |

### Read surface — public (`src/Routes/routes.js`)

| # | Method | Path | Handler | Auth | Notes |
|---|---|---|---|---|---|
| M14 | GET | `/api/v1/get-data-for-new-ui/:restaurantSlug` | `itemController.getDataForNewUi` (`itemController.js:463`) | apikey | **This is the endpoint the live public catalog page calls.** Returns restaurant block `{name, id, location, phone, icon, description, clientType}` + all categories + all items, both sorted `createdAt: -1` |
| M15 | GET | `/api/v1/restaurants/:restaurantSlug/categories` | `itemController.getCategories` (`itemController.js:56`) | apikey | paginated |
| M16 | GET | `/api/v1/restaurants/:restaurantSlug/items` | `itemController.getItemsByCategory` (`itemController.js:148`) | apikey | paginated, `?categoryId=&page=&limit=` |
| M17 | GET | `/api/v1/get-single-product/:productId` | `itemController.getSingleProductData` (`itemController.js:673`) | apikey | |
| M18 | GET | `/api/v1/get-all-items/:restaurantSlug` | `itemController.getAllItems` (`itemController.js:256`) | apikey | |
| M19 | GET | `/api/v1/get-all-categories/:restaurantSlug` | `itemController.getAllCategories` (`itemController.js:366`) | apikey | |
| M20 | GET | `/api/v1/get-item/:restaurantSlug/:categorySlug/:itemSlug` | `itemController.getSingleItem` (`itemController.js:6`) | apikey | looks up category by a `slug` field that **does not exist** on the category schema |
| M21 | GET | `/api/v1/searchKey?keyword=&restaurantSlug=` | `itemController.newSearchByText` (`itemController.js:400`) | apikey | |
| M22 | GET | `/api/v1/get-all-clients` | `itemController.getAllClientsRes` (`itemController.js:756`) | apikey | |
| M23 | POST | `/api/v1/restaurant-login` | `restaurantController.restaurantLogInContorller` | apikey | |
| M24 | POST | `/api/v1/verify-token` | `restaurantController.verifyToken` | apikey | |
| M25 | POST | `/api/v1/create-user` / `login-user` / `verify-user-token` | `userController.*` (`Routes/userRoutes.js`) | apikey | how an admin JWT is minted |

### Analytics surface (`src/Routes/analyticsRoutes.js`)

| # | Method | Path | Handler | Auth | Notes |
|---|---|---|---|---|---|
| M26 | POST | `/api/v1/analytics/collect` | `analyticsController.collectEvents` (`analyticsController.js:22`) | **none** — rate-limited only | Deliberate: `sendBeacon` cannot set the `apikey` header. Emitted by the public catalog page, not by ReCapture |
| M27 | GET | `/api/v1/analytics/summary` | `analyticsController.getSummary` (`analyticsController.js:163`) | apikey + token + **admin** | `?restaurant=<id>&from=&to=&days=&previousFrom=&previousTo=` |
| M28 | GET | `/api/v1/analytics/timeseries` | `analyticsController.getTimeseries` (`analyticsController.js:382`) | apikey + token + **admin** | `?restaurant=<id>&from=&to=` |
| M29 | GET | `/api/v1/analytics/top-products` | `analyticsController.getTopProducts` (`analyticsController.js:459`) | apikey + token + **admin** | `?restaurant=<id>&from=&to=&limit=` (capped 100) |

An in-code note at `analyticsRoutes.js:20-24` and `analyticsController.js:99-105` states that
**client-scoped (restaurant-owner) read routes do not exist yet** and must not be created by
loosening `isAdmin`; owner queries would have to be forced to a token-derived restaurant id.

---

## Mirage Backend — MongoDB Schemas

`src/Models/restaurantModel.js:32-84` (verbatim, comments stripped):

```js
const restaurantSchema = new mongoose.Schema({
    name:       { type: String, required: [true, "Title of product is required."], trim: true,
                  unique: [true, "Name of Restaurant Unique"] },
    location:   { type: String, trim: true, default: "" },
    categories: [{ type: mongoose.Schema.Types.ObjectId, ref: "Category", default: [] }],
    userBelong: { type: String, default: "" },
    icon:       { type: String, default: "https://t3.ftcdn.net/jpg/08/88/25/88/360_F_888258831_….jpg" },
    phone:      { type: String, trim: true },
    bottomViewShow: { type: Boolean, default: false },
    description:    { type: String, default: "" },
    clientType:     { type: String, default: "", enum: ["", "3D_ONLY", "BOTH"] },
}, { timestamps: true });
module.exports = mongoose.model("restaurant", restaurantSchema);
```

`src/Models/itemModel.js:57-178` (verbatim, comments stripped):

```js
const itemSchema = new mongoose.Schema({
    name:        { type: String, required: [true, "Title of product is required."], trim: true },
    description: String,
    image:       { type: String, default: DEFAULT_PRODUCT_IMG_URL },
    model: {
        src:    { type: String, default: "" },
        iosSrc: { type: String, default: "" }
    },
    annotations: { type: [{ _id: false,
        id:          { type: String, required: true, trim: true },
        label:       { type: String, required: true, trim: true },
        description: { type: String, default: "", trim: true },
        position:    { type: String, required: true, trim: true },
        normal:      { type: String, required: true, trim: true } }], default: [] },
    price:          { type: Number },
    isNonVeg:       { type: Boolean, default: false },
    restaurantSlug: { type: String, trim: true },
    isDeleted:      { type: Boolean, default: false },
    views:          { type: Number, default: 0 },
    category:       { type: mongoose.Schema.Types.ObjectId, ref: 'category' },
    restaurant:     { type: mongoose.Schema.Types.ObjectId, ref: 'restaurant' },
    id:             { type: String, default: () => uuid.v4() },
    expiry:         { type: Date, default: null },
    orderBelong:    { type: String, default: "" },
    bottomViewShow: { type: Boolean, default: false },
    variants: { type: [{ name: { type: String, required: true, trim: true },
                         price: { type: Number } }], default: [],
                validate: { validator: v => v.length <= 1,
                            message: "Only one variant is allowed per product" } },
    imgOnly:        { type: Boolean, default: false }
}, { timestamps: true });
module.exports = mongoose.model('item', itemSchema);
```

`src/Models/categoryModel.js:41-71` (verbatim, comments stripped):

```js
const categorySchema = new mongoose.Schema({
    name:       { type: String, required: [true, "Title of product is required."], trim: true },
    restaurant: { type: mongoose.Schema.Types.ObjectId, ref: 'restaurants', required: true },
    image:      { type: String, default: "https://cdn5.vectorstock.com/…category-word…jpg" },
    products:   [{ type: mongoose.Schema.Types.ObjectId, ref: 'item', default: [] }],
    restaurantSlug: { type: String, trim: true },
}, { timestamps: true });
module.exports = mongoose.model('category', categorySchema);
```

`src/Models/userModel.js:5-19` (verbatim) — the admin identity used for `isAuthorized`/`isAdmin`:

```js
const userSchema = new mongoose.Schema({
    password: { type: String, required: true, trim: true, default: "LogIn by google" },
    role:     { type: String, enum: ['admin', 'photographer'], default: 'user' },
}, { timestamps: true })
```

> Note the bug: `default: 'user'` is **not in the enum** `['admin','photographer']`, so a
> default-role document fails validation on save.

`src/Models/analyticsEventModel.js` (verbatim, key parts):

```js
const EVENT_TYPES = [
   "session_start", "client_page_view", "product_page_view", "category_opened",
   "search_performed", "menu_opened", "product_detail_opened", "ar_view_clicked",
   "ar_session_started", "contact_opened", "contact_channel_clicked",
   "model_interaction", "model_loaded", "model_load_failed", "brand_link_clicked",
];
const RAW_EVENT_TTL_SECONDS = 60 * 60 * 24 * 365;

const analyticsEventSchema = new mongoose.Schema({
      eventId:    { type: String, required: true },      // uuid v4, client-generated dedupe key
      type:       { type: String, required: true, enum: EVENT_TYPES, index: true },
      ts:         { type: Date, required: true },        // client clock, untrusted
      receivedAt: { type: Date, default: Date.now },     // authoritative
      restaurant: { type: mongoose.Schema.Types.ObjectId, ref: "restaurant" },
      restaurantSlug: { type: String, trim: true, lowercase: true },
      visitorId:  { type: String, required: true },
      sessionId:  { type: String, required: true },
      path:       { type: String, default: "" },
      props:      { type: mongoose.Schema.Types.Mixed, default: {} },
      device:     { type: Object, default: {} },
      country:    { type: String, default: "" },
}, { timestamps: false, minimize: false });

analyticsEventSchema.index({ restaurant: 1, type: 1, receivedAt: -1 });
analyticsEventSchema.index({ restaurant: 1, receivedAt: -1, visitorId: 1 });
analyticsEventSchema.index({ eventId: 1 }, { unique: true });   // idempotent ingest
analyticsEventSchema.index({ receivedAt: 1 }, { expireAfterSeconds: RAW_EVENT_TTL_SECONDS });
```

`src/Models/threeDModel.js` — a `ModelCache` (url → Buffer) collection. **Written with ESM
`import`/`export` in a CommonJS codebase**, so it cannot be `require`d; nothing imports it.

**Fields Mirage's item schema does NOT have:** sort/position order, `featured`/`isFeatured`, tags,
availability / in-stock, currency, and any per-product archive flag distinct from `isDeleted`
(which no write endpoint ever sets).
**Fields Mirage's category schema does NOT have:** sort/position order, `slug` (though M20 queries one).
**Fields Mirage's restaurant schema does NOT have:** address (only free-text `location`), website,
social links, and any explicit published/unpublished flag.

---

## Mirage Backend — Server-to-Server Auth Mechanism

Two independent layers, both header-based:

1. **`apikey` header** — `src/Middlewares/apiKeyValidator.js:8-10`. The valid keys are a
   **hardcoded array in source**:
   ```js
   let validApiKeys = [ '35ad8e16-4c92-4d0d-82cd-c63e3ef3f630' ]
   ```
   Also read from a cookie of the same name. A missing or unknown key returns **400** (not 401/403).
   This same key ships inside the public Mirage frontend bundle — the analytics route comment
   (`analyticsRoutes.js:16`) states it plainly: "the API key already ships in the public bundle."

2. **`token` header** — `src/Middlewares/middleware.js:5-110` (`isAuthorized`). A JWT verified with
   `process.env.JWT_SECRET_KEY || "vr_secret"` (**hardcoded dev fallback**). The payload's `id` is
   looked up in `userModel`; `req.tokenUserData = { token, role, userId, id }`. Read from a cookie
   as a fallback. Failures return **401/403** with distinguishable messages.
   `isAdmin` (`middleware.js:137-160`) requires `role === "admin"` — **exact equality**, no hierarchy.
   Its rejection message is a copy-paste bug: "Only chef can access this api."

**There is no dedicated server-to-server credential, no client-credentials grant, no request
signing, no mTLS, and no scoping of an admin token to one restaurant.** Any caller holding the
static API key plus an admin JWT has **full read/write over every restaurant in Mirage**.

**No token issuance for machines**: an admin JWT comes from `POST /api/v1/login-user`
(`Routes/userRoutes.js`) with a stored password. Token TTL is set at signing time in
`userController.js` — a long-lived credential would have to be minted and stored by ReCapture.

---

## Mirage Backend — Asset Upload Flow

`src/libs/multer.js` + `src/libs/s3.js`.

```js
const upload = multer({ dest: 'uploads/', limits: { fileSize: 100 * 1024 * 1024 } });
const uploadFields = upload.fields([{ name: 'image', maxCount: 1 },
                                    { name: 'object', maxCount: 1 }]);
```

```js
exports.uploadToS3 = (filePath, key, contentType, Bucket) => {
    const fileContent = fs.readFileSync(filePath);
    return s3.upload({ Bucket: Bucket || AWS_BUCKET_NAME(), Key: key,
                       Body: fileContent, ContentType: contentType }).promise();
};
```

The flow, per write endpoint: multer writes the upload to local disk `uploads/` → the controller
`fs.readFileSync`s the whole file into memory → `s3.upload` → `fs.unlinkSync` → the stored URL is
composed as `` `${CLOUD_FRONT_URL}/${key}` ``.

Consequences that matter for integration:

- **Mirage accepts file BYTES only. There is no presigned-URL flow and no way to hand it a URL.**
  In `createItems` (`adminController.js:948-955`) the body is spread first and then
  `image` and `model` are **overwritten** by the locally computed values, so a caller-supplied
  `model.src` or `image` URL is discarded.
- **`CLOUD_FRONT_URL` and `BUCKET_NAME` are read from the REQUEST BODY** (`adminController.js:200-201,
  530, 798-799, 1045-1046`) — the caller chooses which bucket Mirage writes to and which CDN host
  is baked into the stored URL. There is no allow-list. If omitted they land in the URL as the
  literal string `undefined`.
- **Only two file fields exist (`image`, `object`).** There is **no field for a USDZ file**, and no
  controller ever writes `item.model.iosSrc` — the schema field exists but is dead on every write path.
- 100 MB per file; the whole file is buffered in memory during upload.
- Key layout is `{restaurant.name}/imgs/…`, `{restaurant.name}/models/…`, `{restaurant.name}/categories/…`,
  `res_icons/…` — i.e. **keyed by the mutable restaurant name**, captured at write time.

---

## Mirage Backend — Idempotency Support

**None.** There are no idempotency keys, no upsert semantics, no request-id dedup, and no
`If-Match`/ETag handling on any write endpoint. The only dedup-like behaviour is incidental
uniqueness checking:

- `createRestaurant` (`adminController.js:213-221`) rejects a name that matches an existing one by
  **case-insensitive unanchored regex** — so a new restaurant named `"Cafe"` is rejected if
  `"Blue Cafe House"` exists.
- `createCategory` (`adminController.js:560-568`) rejects a duplicate `(name, restaurant)` pair.
- `createItems` (`adminController.js:888-897`) rejects a duplicate `(name, restaurant)` pair.

So a retried create returns a **400 "already exist"**, not the original resource — the caller cannot
recover the created id from the retry. Any retry-safety must be built on the ReCapture side.

The **one** idempotent path in the whole repo is analytics ingest, via the unique `eventId` index.

---

## Mirage Backend — Public URL / QR Slug Derivation

This is the single most important finding for feature 32.

**Frontend route** (`mirage-fe/src/App.tsx:217-224`): `path="/:restaurant"` → `<MenuScreen />`.
`MenuScreen` fetches via `mirage-fe/src/features/menu/useFetchApiForNewUi.ts:80`:

```ts
const json = await fetchDataWithGet(`${BACKEND_URL_CONSTANT()}/get-data-for-new-ui/${resName.trim()}`)
```

So the public catalog URL is `https://<mirage-host>/{restaurantSlug}` and that path segment is
passed straight to M14.

**Backend resolution** (`itemController.js:472-484`, and the same two-step pattern in
`getCategories`, `getAllItems`, `getAllCategories`, `getALlCategoriesAdmin`, `getAllItemsForCat`):

```js
let restaurantDetails = await restaurantModel.findOne({
   name: { $regex: restaurantSlug.toLowerCase(), $options: "i" },
});
if (!restaurantDetails && mongoose.isValidObjectId(restaurantSlug)) {
   restaurantDetails = await restaurantModel.findById(restaurantSlug);
}
```

Facts that follow:

1. **There is no `slug` field.** The "slug" is the restaurant's **`name`**, matched by
   case-insensitive **unanchored** regex.
2. **The ObjectId is an equally valid slug** — every public read path falls back to
   `findById(restaurantSlug)` when the name lookup misses and the segment is a valid ObjectId.
   `getItemsByCategory` (`itemController.js:160-166`) uses an exact `name` match plus the same
   ObjectId fallback.
3. **Renaming a restaurant changes its name-based URL** and therefore breaks any QR minted from the
   name. It gets worse: `restaurantSlug` is **denormalized onto every category and item document at
   create time** (`adminController.js:604`, `adminController.js:950`, both `restaurantSlug:
   findRestaurant.name`) and **no update path ever rewrites it**, so after a rename the parent and
   children disagree. `newSearchByText` (`itemController.js:430`) filters on the stale child copy.
4. The unanchored regex means a **substring** match wins: a slug of `cafe` resolves to whichever
   restaurant containing "cafe" `findOne` happens to return first. Short names are genuinely ambiguous.
5. The regex is built from unescaped user input, so a segment containing regex metacharacters is
   interpreted as a pattern.

---

## Mirage Backend — Rate Limits / Batch Endpoints

- **Rate limiting exists on exactly one route**: `analyticsRateLimit`
  (`src/Middlewares/analyticsRateLimit.js`, 64 lines) on `POST /analytics/collect`. No admin or
  public route is rate-limited.
- **No batch or bulk-write endpoints.** Creating N products requires N sequential multipart
  requests. There is no transactional grouping, so a partial failure leaves partial state.
- **No pagination on the admin list endpoints** (M1, M11, M12) — they return everything.
- Redis (`ioredis`) is used only as a cache: `src/libs/redis.js`, for slug→id resolution in analytics
  ingest and for memoizing the analytics report queries.
- The server self-pings every 30 s when `MAKE_UP_AND_RUNNING` is set, to defeat Render's sleep mode
  (`index.js`) — a signal that Mirage runs on a free/sleeping tier.

---

## Cross-Repo Gotchas

Things that will bite implementation later.

1. **Two response envelopes.** ReCapture: `{status: "success"|"error", code, message}`.
   Mirage: `{status: true|false, message, data}`. The adapter must translate at the boundary and
   must not let Mirage's boolean `status` leak into a ReCapture response.

2. **Mirage returns 400 for nearly everything** — validation errors, not-found, bad api key, and the
   global 404 handler all return 400. HTTP status alone cannot classify a Mirage failure as
   retryable vs terminal; the adapter must match on the message body, which is unversioned prose.

3. **Mirage wants bytes; ReCapture has CloudFront URLs.** `ProjectModel.artifacts.cdnUrls.glb` is a
   ReCapture CloudFront URL, and Mirage's `create-item` cannot accept a URL. Any sync must
   re-upload the file, producing a second copy on the `maya-restaurants` bucket behind Mirage's
   CloudFront distribution (`d1ubv1fp33ooxl.cloudfront.net`).

4. **USDZ has no path into Mirage.** `item.model.iosSrc` exists in the schema, multer accepts no
   third file field, and no controller writes it. iOS AR Quick Look on the public page cannot be
   served from a ReCapture-published product today.

5. **Mirage hard-deletes.** `delete-item` removes the document, and silently removes the **category**
   too if it was that category's last item. `delete-category` is a no-op stub. `isDeleted` exists on
   the item schema but no write endpoint ever sets it.

6. **`create-item` requires a category ObjectId.** There is no "uncategorized" affordance on the
   Mirage side — a product cannot be created without a real category document.

7. **Name uniqueness is the de-facto primary key on writes.** Item names must be unique per
   restaurant; restaurant names unique globally by fuzzy regex. Two different businesses cannot both
   have a catalog named "Cafe Mocha", and one business cannot have two products named "Regular".

8. **Mirage `updateItem` silently ignores `description`, `category`, and `imgOnly`.** They are
   destructured-then-commented-out (`adminController.js:1038-1047`) or simply never assigned. An
   edit to any of those three in ReCapture cannot be pushed through M9.

9. **Mirage has no tests and no type checking.** ReCapture's CI (`tsc --noEmit` clean,
   `no-explicit-any: error`, hermetic Vitest) cannot cover the Mirage contract. Every assumption
   about Mirage's behaviour must be pinned by a fake/contract test on the ReCapture side.

10. **ReCapture forbids Redis; Mirage uses it.** They are separate deployments, so this is not a
    conflict — but no ReCapture-side design may lean on Mirage's Redis.

11. **Body-supplied bucket + CDN.** Because Mirage takes `BUCKET_NAME` and `CLOUD_FRONT_URL` from
    the request body, ReCapture must own those values as config, and a typo silently produces a
    stored URL of `undefined/<key>` that fails only when a customer opens the page.

12. **Mirage's analytics reads are admin-scoped only** and, per its own in-code note, must not be
    opened to client scope by loosening `isAdmin`. Any per-business analytics read has to be
    proxied by a trusted server holding admin credentials.

13. 🔴 **Hardcoded production secrets in the Mirage repo.** `src/CONSTANT.js` contains a live
    MongoDB Atlas connection string **with username and password** (three of them: restaurant-prod,
    stock-prod, stock-dev), an **AWS access key id and secret access key**, and the CloudFront host,
    all as `||` fallbacks. `src/Middlewares/apiKeyValidator.js` hardcodes the API key.
    `src/Middlewares/middleware.js:40` defaults the JWT secret to `"vr_secret"`.
    `mirage-fe/src/CONSTENT.ts:40-79` puts the **same AWS access key and secret into the browser
    bundle**. This is reported here as an observation only — no change was made to either repo.
