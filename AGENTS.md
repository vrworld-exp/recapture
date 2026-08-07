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
- **`source: 'optimized'` is the exception that proves the rule: it is a
  DERIVATIVE, not an origin.** One tap on **Optimize** (staff row action, or the
  owner's viewer) inserts a SECOND `ProjectModel` — `optimizedFrom` naming its
  parent — and enqueues a **`MODEL_OPTIMIZATION`** worker job that runs the
  parent's GLB through glTF-Transform (`services/modelOptimizerService.ts`:
  dedup → weld → prune → texture recompress → prune → meshopt) and writes the
  result under the NEW record's own artifact prefix. A separate record, not a
  `variants[]` array, because the ask is that the small model *appear in the
  model list* — which `listProjectModels` then gives for free, with `approve`
  semantics unchanged. Consequences to hold in mind:
  - it **costs CPU, never Meshy credits**: it sets neither `createdBySystem` nor
    `createdByManualButton`, so `countServerSelectedGenerationsInLast24h` cannot
    see it, and an optimization must never consume the 24h spend ceiling;
  - it is **not a generation**: `pendingOwnerGenerationFor` filters
    `source != 'optimized'`, or the owner sees "creating your 3D model…" for a
    model they already have;
  - `latestSucceededModel` **now returns the OPT record** once one succeeds
    (intended — the owner should get the small file), which is why the processor
    `copyObject`s the parent's USDZ and preview onto it. Skip that and the first
    optimization silently kills iOS AR Quick Look and the project thumbnail;
  - eligibility is the SERVER's verdict, shipped as `canOptimize` on both DTOs.
    The client never re-derives it. `artifacts.glbBytes` is the only input, and
    **absent means UNKNOWN, not small** — no size, no button.
  - `MODEL_OPTIMIZE_THRESHOLD_BYTES` is **binary** (8 MiB). The client's
    `formatBytes` uses the same 1024 divisor deliberately; mix them and a model
    reads "8.0 MB" with no button beside it.
- ⚠ **`meshopt()` puts `EXT_meshopt_compression` in `extensionsRequired`, and
  `<model-viewer>` has NO default meshopt decoder location** (it does have DRACO
  and KTX2 ones). Unconfigured, `GLTFLoader` throws and EVERY optimized model
  shows the generic "couldn't load this model". The decoder is already bundled
  inside `model-viewer.min.js`; the URL is only a trigger, so a no-op `data:`
  script is enough. It must be set in **both** `web/index.html` and
  `_lifecycleJs` in `model_render_view.dart` — two separate pages, and fixing
  one ships the feature broken on the other platform.
  `test/projects/meshopt_decoder_test.dart` guards the pair.
- **`sharp` must resolve to ONE copy in `node_modules`.** `@gltf-transform/functions`
  pulls it in transitively via `ndarray-pixels`; two libvips native addons in one
  process break GObject type registration and every texture pass fails with
  `colourspace: parameter space not set`. Our `sharp` range is pinned to match
  `ndarray-pixels`' so npm hoists a single copy — check that before bumping either.
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
  The trace is **staff-only**: it is on `ProjectModelDto` and on NO owner
  DTO, because it names our S3 key layout and our pipeline's internals.
- **A project's models are read through TWO parallel surfaces, never one with a
  role flag.** Staff read `GET /admin/projects/:id/models` → `ProjectModelDto`;
  an owner reads `GET /projects/:id/models` → `OwnerModelListItemDto`, scoped by
  `getProject(userId, id)` so a foreign project is an identical 404 (an ADMIN
  who does not own it gets that 404 too — privilege lives on `/admin`, and this
  route must not become a second, weaker door). The owner projections are built
  FIELD BY FIELD, never by spreading a record: a spread is how a staff-only
  field reaches an owner the next time the schema grows. Same rule for the
  write side — the owner's Optimize goes to `POST /projects/:id/models/:modelId/
  optimize`, never the `/admin` twin. On the client this is mirrored as two
  repository methods (`listModels` / `listOwnerModels`), two notifiers, and two
  parsers (`tryFromStaffMap` / `tryFromOwnerListMap`); only the ROW WIDGET is
  shared, because it renders no staff-only action.
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
