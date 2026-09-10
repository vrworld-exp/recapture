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
- **Envelope carve-out — the public router only.** Every route in this API
  returns the JSON envelope. `src/routes/public.ts` (`GET /r/:code`, the printed
  standee) is the single exception: its client is a phone camera opening a
  browser, so it returns `302` redirects and `text/html`, never
  `{status, code, message}`. It therefore carries its **own terminal error
  handler**, mounted inside the router, so a thrown error renders the fallback
  page instead of falling through to `errorHandler.ts` and showing a diner a
  JSON blob. **No other router may copy this** — the carve-out is justified by
  the client, not by the route being public (`/remote-config` is public and
  still uses the envelope).
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
- **"Created by" — the ONE unmasked-contact exception, ADMIN-only.** An admin
  looking at a bad capture needs to reach the person who made it, and a mask
  cannot be dialled. So:
  - `GET /admin/projects` adds a compact **`owner`** (`{id, displayName,
    hasAvatar}`) to each item **when the caller is ADMIN** — enough for the
    Live-projects card's "Created by" label, and **no identifier, not even a
    mask**. Below ADMIN the field is **absent** and the opaque `ownerId` is all
    staff get. Absent is also what an owner id that no longer resolves produces,
    so the client falls back to the opaque line rather than rendering a blank.
  - `GET /admin/users/:id` (`requireRole('ADMIN')`, `services/adminUsersService.ts`)
    is the **only route in this API that answers with a RAW phone/email**. It is
    bounded on every side: ADMIN-only, **on demand** (one person per call — never
    decorating a list), metered per admin (`ADMIN_USER_LOOKUP_*`), audited
    (`admin_project_owner_viewed`, hashed ids + a `contact_channels` enum — note
    the prop NAME: `has_phone`/`has_email` would be stripped by the emit layer
    and drop the whole audit event), and answered with `Cache-Control: no-store`.
    **Widening any of those bounds is a PII policy decision and belongs in this
    file first.**
  - `GET /admin/users/:id/avatar/bytes` proxies that person's picture. **Bytes,
    not the presigned `avatarUrl`**, for the reason `GET /auth/me/avatar/bytes`
    exists: the raw bucket serves no CORS, so a presigned URL renders on the apk
    and shows nothing at all on web. One route serves both builds. The key comes
    from the user document — there is no `?key=`, and adding one would make this
    an arbitrary-object reader for the private bucket.
  - Client: `ProjectOwnerSummary` / `ProjectOwnerDetail`
    (`domain/entities/project_owner.dart`) are two types on purpose — the summary
    is list-safe, the detail is not. `projectOwnerProvider` is **autoDispose with
    no keepAlive** so the raw contact lives exactly as long as the sheet showing
    it; the avatar provider IS kept alive, because a picture is not the thing
    being bounded. Nothing is persisted to Hive, logged, or sent to analytics.
    Guardrails: `tests/admin-project-owner.test.ts` +
    `test/projects/live_project_owner_test.dart`.
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
  `utils/s3Keys.ts`, whose parser is strict about its own 6-segment scheme).
  The avatar space KEEPS `{userId}`; the capture space does not (see §S3 key
  scheme) — two schemes, two parsers, deliberately not unified.
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
  (a HUMAN made it — today that means staff SUBMITTED a `.glb`; see below). The
  client's "Created by Meshy AI" badge reads that flag and nothing else, which
  is why a submitted model correctly wears no badge with zero client changes.
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
  - `MODEL_OPTIMIZE_THRESHOLD_BYTES` is **binary** (5 MiB). The client's
    `formatBytes` uses the same 1024 divisor deliberately; mix them and a model
    reads "5.0 MB" with no button beside it. It is **advisory** — it gates the
    button and the route the button calls, and nothing else. No upload, save or
    scene load is refused for crossing it.
- ⚠ **`meshopt()` puts `EXT_meshopt_compression` in `extensionsRequired`, and
  `<model-viewer>` has NO default meshopt decoder location** (it does have DRACO
  and KTX2 ones). Unconfigured, `GLTFLoader` throws and EVERY optimized model
  shows the generic "couldn't load this model". The decoder is already bundled
  inside `model-viewer.min.js`; the URL is only a trigger, so a no-op `data:`
  script is enough. It must be set in **both** `web/index.html` and
  `_lifecycleJs` in `model_render_view.dart` — two separate pages, and fixing
  one ships the feature broken on the other platform.
  `test/projects/meshopt_decoder_test.dart` guards the pair.
- ⚠ **`<model-viewer>` DISABLES iOS AR Quick Look inside an app WebView**, so
  the `ar`/`arModes`/`iosSrc` attributes alone never produce AR on iOS. Its
  `IS_AR_QUICKLOOK_CANDIDATE` returns, when `window.webkit.messageHandlers`
  exists (i.e. any WKWebView — our JS channel guarantees it), only whether the
  user agent matches `CriOS/|EdgiOS/|FxiOS/|GSA/|DuckDuckGo/`. The stock
  WebView UA matches none, both routes to its QUICK_LOOK mode require that
  flag, so `canActivateAR` is permanently false and model_viewer_plus's own
  Quick Look intercept (an exact match on `iosSrc`) never sees a navigation.
  `ModelRenderView` therefore presents **native `QLPreviewController`** itself
  (`canQuickLook` there → `ArQuickLookChannel` → iOS `ARQuickLookManager`).
  Three things that look like simpler fixes and are not:
  - **`launchUrl` on the CloudFront USDZ** (tried, rejected): it opens a
    browser on the model page, so AR needs a SECOND tap. Not one-tap AR.
  - **Spoofing the UA** to match the whitelist: changes the UA for every
    request the page makes, including the CloudFront GLB fetch.
  - **Deleting the bypass** in favour of the `ar`/`arModes`/`iosSrc`
    attributes: they are already set, and are not sufficient.
  `QLPreviewController` previews FILES, so the manager downloads the USDZ into
  `Caches/ar-quicklook` first, keyed by a hash of the full URL. It MUST reject
  non-2xx responses — a cached CloudFront 403 body under a `.usdz` name is a
  permanent un-openable "model". Web is unaffected: real Safari passes the
  `relList.supports('ar')` branch, so it keeps using the web component.
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
- **`Project.source` (`capture` | `upload`) says where a project's photos came
  from — a field, deliberately NOT a new `ProjectStatus`.** The client branches
  on `source`, not on status, to decide what a card's primary action opens. A
  new status would touch the schema enum, the admin list's `?status=` filter and
  the client's label/colour/action tables for no gain — and it would defeat the
  whole point of the promotion below, which is that the rest of the system does
  NOT have to learn what an upload project is. The schema
  default backfills every pre-existing document as `capture`, so there is **no
  migration**. It ships on `ProjectListItem` through `toProjectListItem` (the ONE
  Project DTO mapper) and is hand-synced onto the Flutter `Project` entity —
  including its `toMap()` round-trip, without which a cached upload project
  would read back as a capture and offer a capture action.
- **A committed photo upload is promoted `DRAFT → PROCESSING`, and that single
  write is what makes an artist's upload a first-class project.** `PROCESSING`
  is in `LIVE_PROJECT_STATUSES`, so the project appears on the staff **Live
  projects** list where every other artist and admin can work on it, and it is
  the status the exportable surfaces gate on — Preview, Export, Models and
  Generate all switch on with no per-surface upload special-casing. Left in
  `DRAFT` (the original design) an upload was a private draft nobody but its
  owner could ever see, which is the bug this fixes.
  The write lives in `commitPhotoUpload`'s **one funnel**
  (`finalizeUploadProject`), alongside the `stats.totalPhotos` write and
  modelled on finalize's `queuedResult`: a replay RE-ASSERTS both rather than
  skipping, so a crash between the job's `UPLOADED` flip and the status write
  self-heals on the next commit. A project already `PROCESSING`/`COMPLETED` is
  left alone — the first is a self-transition, the second would drag a project
  with a finished model backwards. `PHOTO_UPLOAD` jobs still never reach
  `QUEUED` and are still never processed; the PROJECT moves, the job does not.
  Because of it, `Project.objectSize` and `Project.mode` are **conditionally
  required**: present on a capture project, absent on an upload one. A client
  sending either on an upload project gets a `400`, not a silent ignore — they
  are capture concepts (object size drives camera-distance guidance an uploaded
  set never receives; mode drives a flow that never runs), and a placeholder
  `MEDIUM`/`GUIDED` would be a lie later reads act on.
- **On the client, an upload is its own screen and it ENDS at the Projects
  hub.** The Create form (upload variant) collects a NAME and the photo set and
  nothing else — no category field, and no object size / capture mode (see
  above). Its CTA **pushes** `PhotoUploadProgressScreen`, which starts the run
  itself and shows a row per photo: queued / uploading / uploaded / failed. When
  it finishes it refreshes `projectsProvider` and goes to `/projects`, so the
  new project appears in the list like any other — it does **not** continue to
  the photo grid. Generating a model is a separate decision the artist makes
  later, from the project's card.
  On the hub, an upload project's card is **Preview + Models**, plus "Generate
  3D model" while nothing is built yet — the same row a captured project settles
  on, with pill, photo count and ⋮ shared. The promotion above makes it
  exportable, so the existing status-driven gating turns those on by itself, and
  "like a normal captured project" is the requirement.
  `Project.cardAction` returns **`none` for an upload project on every status**,
  resolved without consulting `ProjectStatus.cardAction` at all — not by falling
  through for the statuses that happen to agree. Every word in that table is a
  capture word, and the fall-through is what would let `DRAFT` offer "Resume"
  (opening pre-capture: a ring flow the project has no plan for and can never
  complete) or `PROCESSING` — which every committed upload lands in — render a
  "Processing…" spinner that never stops, because no worker ever claims a
  `PHOTO_UPLOAD` job. `ProjectCardAction` has no upload-specific member.
  **"View" is deliberately absent even once a model exists**, though it would
  have worked: it opens the NEWEST finished model, a strict subset of what
  Models opens, and a third labelled button in the card's `Expanded` row
  ellipsizes all three down to unreadable stubs on a phone. Two buttons, one way
  in, and the one that shows the whole history.
  **Models is shown on an upload card even with nothing in it** — the one
  gating difference from a capture card, which requires `modelCount > 0`. With
  no primary action, Models is that card's standing entry point, and its empty
  state is not a dead end: it names the next step ("open Preview, pick 3–4
  photos, tap Create Model").
- **Hand-picking photos for a generation lives in ONE place: Preview.** The
  staff gallery's app-bar "Create Model" → pick 3–4 → "Create Model" CTA is the
  single door, for an uploaded set exactly as for a capture — it resolves
  through `findExportableJob`, which now finds either. `project_photos_screen`
  (the artist grid at `/projects/:id/photos`) is therefore **no longer linked
  from anywhere**; it is kept for deep links but must not become the
  destination of a new affordance — add that to Preview instead. Every photo
  route is `requireRole('MODEL_ARTIST')`, so every upload-project owner is
  staff and can always reach Preview; a second picker would only drift.
  The card's "Generate 3D model" remains the no-decision path (the server picks
  — see the selection rule below), and Preview is how that choice is overridden.
  Two constraints hold the upload screen together: the push (not a `go()` replacement) is
  what keeps the autoDispose `projectPhotosProvider` — which holds the picked
  set — alive under the progress screen; and the per-photo status is DERIVED
  from the engine's aggregate `filesUploaded` count, which is a valid cursor
  ONLY because `ChunkedUploadManager` uploads files strictly sequentially in
  spec order. That coupling is pinned by a test in
  `test/upload/chunked_upload_manager_test.dart` — make files concurrent and it
  fails there rather than the screen quietly naming the wrong photo.
- **Server-side photo selection runs a DIFFERENT RULE on an upload project, not
  a relaxed version of the capture one.** `selectPhotosForAutoGeneration` reads
  blur and yaw out of the capture manifest; an uploaded set has none, so putting
  one through it declines 100% of real uploads on `droppedNoBlurScore` — a
  measurement gap reported as a quality verdict. `selectPhotosFromUploadedSet`
  is the counterpart: it takes the first `AUTO_TARGET_PHOTOS` in KEY ORDER,
  which is upload order, because a capture is ~48 automatic frames (choosing 4
  is the whole problem) while an upload is a handful a person already chose. It
  still DECLINES below `AUTO_MIN_PHOTOS` — a bad generation costs what a good
  one does. `generateModelOnDemand` picks the branch ONCE (`isUpload`), skips
  the manifest step rather than recording a false failure, and narrows the
  listing to the `uploads/` namespace — which is also what keeps a soft-deleted
  photo, parked under `deleted/`, from being selected straight back out.
  There is no `AUTO_SELECTION_UNAVAILABLE` refusal any more; `NOT_EXPORTABLE`
  covers both sources, and its owner copy names no pipeline internal.
  Hand-picking 3–4 photos (`POST /projects/:id/photos/generate`) is still there
  — as the way to OVERRIDE that choice, not as the only way in.
- **The artist upload surface lives on `/projects`, not `/admin`.** An artist
  uploads into their OWN project, so ownership is proved by
  `getProject(userId, id)` exactly as every other route in that router does, and
  missing / not-owned / soft-deleted collapse into one identical `404`.
  `requireRole('MODEL_ARTIST')` is applied **per-route**, never
  `router.use(...)` — the owner routes must stay open to a plain `USER`.
  Uploading costs nothing; **generating is what spends credits**, and that route
  keeps all three load-bearing guards (the shared `meshy-create:{userId}` rate
  window, the `Idempotency-Key` replay, and the unique-index race authority).
  Its source job is resolved SERVER-SIDE (the project's newest `UPLOADED`
  photo-upload job) and is never taken from the body.
- **Job resolution is a PRECEDENCE rule, never one widened `$or`.**
  `findExportableJob` runs the CAPTURE match first and falls back to an
  `UPLOADED` photo-upload job only when the project has no capture job at all.
  The tempting one-query version is a real bug: on a project owning both, a
  photo-upload job created later wins a shared `createdAt: -1` sort and the
  export silently ships the wrong set. `findExportableJobById` CAN be one query
  (an id names exactly one document, so precedence is meaningless), and
  `findModelSourceJobById` is now a pure alias for it — one implementation, so
  the two rules cannot drift apart again.
  `tests/photo-upload-guardrail.test.ts` pins all of it, including that a
  CREATED (unverified) photo set resolves for nobody.
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
  `findExportableJob`, where omitting it silently breaks export/preview/delete
  (a MESHY_MODEL_GENERATION job is newer and carries no `upload` block). The
  photo-upload fallback there is a SECOND filtered query, not a loosened one.
- **`PHOTO_UPLOAD` is a job type that is NEVER PROCESSED.** It holds an artist's
  uploaded photo set: `CREATED → UPLOADING` (flipped by the *existing*
  `/jobs/:jobId/uploads/initiate`) `→ UPLOADED`, and it stops there.
  - **No processor is registered for it, and a no-op one must not be added.**
    `claimNextJob` filters on `state: 'QUEUED'` alone, jobType-agnostically — a
    job that never queues is simply never in the claimable set. The missing
    registration is the design, not an oversight.
  - It carries an ordinary `upload` block, which is what makes
    `adminDeleteProject`'s prefix sweep purge its objects from **both** buckets
    for free.
  - `upload.manifestKey` is **optional** because of it: an uploaded set has no
    capture manifest. Every CAPTURE job still gets one at creation; the readers
    that need one (finalize, the capture processor, the auto-photo selector)
    treat its absence as `manifest_missing` rather than assuming a placeholder
    key pointing at no object.
  - **`POST /jobs/:jobId/uploads/{initiate,part-url,complete}` is UNCHANGED and
    must stay so.** Its shared guard (`loadUploadableJob`) applies no `jobType`
    filter, and its capture-ring containment check fires only when the
    job-relative key starts with `images/` — so `uploads/photo_0001.jpg` passes
    it as written, with identical resume, retry and progress behaviour. That is
    the whole reason this feature is small.
    `tests/photo-upload-transfer.test.ts` is the regression that keeps it true.
- **`MESHY_API_KEY` is optional in `config/env.ts` and required at WORKER boot**
  (`assertMeshyConfigured()`): only the worker calls Meshy, so the API must not
  fail to boot over a secret it never uses.

### Staff "Submit model" (a hand-made GLB, no generation)

The staff counterpart to Create-Model: a MODEL_ARTIST or ADMIN hands a finished
`.glb` to a project they do NOT own, from the **Live projects** list. The result
is an ordinary `SUCCEEDED` `ProjectModel` with `source: 'manual'`, so it reaches
the owner's `modelCount`, their models list and the project detail's viewer with
**no owner-facing code involved** — that is the whole design.

- **Two calls, and the bytes never touch the API.**
  `POST /admin/projects/:id/model/upload-url` presigns a PUT; the client uploads
  direct to S3; `POST /admin/projects/:id/model/upload` commits the key. The
  avatar bytes-proxy precedent **does not extend here** for the same reason it
  does not extend to photo sets: a 100 MiB model would go through a 512 MB
  instance.
- **Staged in the RAW bucket, promoted to ARTIFACTS.** `msxr-model-artifacts`
  serves **no CORS**, so a browser cannot PUT to it at all; `msxr-raw-captures`
  does (see the web-upload section). So the slot is
  `{rawPrefix}model-upload/{sessionId}/model.glb` in the raw bucket, and the
  commit does a **server-side cross-bucket copy** to the record's own
  `{rawPrefix}models/{modelId}/model.glb`. No bytes transit the API either way.
- **`model-upload/` is a reserved job namespace**, exactly like `model-input/`.
  Both are now excluded through ONE predicate — `isReservedJobNamespace()` in
  `adminProjectsService` — used by the export/photo listing, the capture
  processor's object-count re-verification, and the automatic photo selector. A
  namespace that reaches only two of the three is a capture job that fails its
  own count, or a GLB offered to Meshy as a photo.
- **The record exists before the copy, and only then goes SUCCEEDED.** The
  artifacts key is derived from the record id, so the row has to be inserted
  first; a crash between the two leaves an honest `PROCESSING`/`FAILED` row, never
  a SUCCEEDED one pointing at a URL that 404s.
- **The bytes decide what the file is.** `utils/glb.ts` checks the glTF 2.0
  magic, the container version, and the header's own length field against the
  object's real size — read through a **ranged GET of 12 bytes**, never by
  downloading the model. The declared Content-Type and the `.glb` extension are
  both caller-supplied and prove nothing.
- **Double-submit is guarded by the staged object, not an Idempotency-Key.** The
  commit deletes the staging key once promoted, so a replay is `UPLOAD_MISSING`
  rather than a duplicate model in someone else's list. Two DIFFERENT uploads are
  two models on purpose — this is a history, like generation.
- **The project's status is NOT flipped to COMPLETED**, mirroring the Meshy
  processor, which does not either. What keeps the owner's card honest is the
  rule that a project with `modelCount > 0` hides a stale `Processing` pill
  (`ProjectCard._showStatusPill` and its twin on the Live card).
- Client: `model_file_picker.dart` (file_picker — the only picker in the tree
  that opens a general file browser; it hands back a **stream**, never bytes),
  `model_upload_client.dart` (its own interceptor-free Dio — an `Authorization`
  header BREAKS a presigned signature), `model_submission_notifier.dart`,
  `submit_model_screen.dart`. Pinned by `test/projects/model_submission_test.dart`
  and `recapture-api/tests/admin-model-upload.test.ts`.

### Standee assignment (who is carrying which code)

- **`QrCode.assignedToUserId` is ADVISORY and must stay that way.**
  `activationService` does not read it, and no test may be written that assumes
  it does — `tests/standee-assignment.test.ts` asserts the opposite in both
  directions (a code assigned to rep A still activates for rep B; a code nobody
  holds still activates for anyone). Assignment changes what each side can
  **see**: the rep's own stock list, the recommendations on their activation
  screen, and the admin's view of where a batch went. Turning it into a
  reservation is a product decision about the walk-up standee — the one nobody
  assigned — not a refactor.
- **It is a POINTER, not a ledger.** `QrCodeAssignment` records what a code
  *points at* and its history is load-bearing (scan rollups are bucketed by it,
  so reassignment closes a row and opens a new one). Who is *carrying* a standee
  is a mutable fact about the present with no downstream reader, so reassignment
  is a plain field overwrite. Do not add a second ledger for it.
- **Three doors to the same sheet, one composer.** `GET /admin/qr-codes/:code/qr`
  (ADMIN, any code), `GET /rep/standees/:code/qr` (the holder only) and
  `GET /admin/qr-batches/:batchId/sheet` (ADMIN, the whole run) all go through
  `services/standeeSheetService.ts`, which owns `STANDEE_TAGLINE` and the RETIRED
  rule. A rep-printed standee, an admin-printed one and one cut off a batch sheet
  must be the same physical object; a second renderer is how that stops being
  true. The LAYOUT differs between the one-up sheet and the batch grid; what is
  printed on a card does not.
- **The batch sheet: the square is a FIXED PHYSICAL SIZE and is never scaled.**
  `STANDEE_SHEET_QR_INCHES` (1.67in, ~501px at 300dpi) is the edge the standee
  artwork was cut for. A QR printed smaller than the distance it is scanned from
  is a standee that does not work, and that is discovered by a diner at a table
  after the paper is cut. So `computeSheetLayout` clamps
  `STANDEE_SHEET_COLUMNS`/`_ROWS` **down** to whatever fits (2 × 3 = six per A4
  by default) rather than shrinking the code. Never invert that trade.
- **RETIRED codes are SKIPPED on a batch sheet, not refused.** The single-code
  endpoints answer `409 CODE_RETIRED` because rendering one hands somebody a dead
  sheet; a whole batch cannot be refused over one dead code. The count comes back
  in `X-Standee-Sheet-Skipped-Retired` (and `-Standees`/`-Pages`) because the body
  is the PDF — all three are in `app.ts`'s CORS `exposedHeaders`, without which
  the **web** admin silently loses the "2 retired were skipped" line. An
  *entirely* retired batch is `409 NOTHING_TO_PRINT`; a run past
  `STANDEE_SHEET_MAX_CODES` is `409 BATCH_TOO_LARGE` (recovery is the vendor CSV,
  not a retry — both codes have client copy in `catalog_error_copy.dart`).
- **PDFs are still written by hand, now out of `services/pdfPrimitives.ts`.** One
  module counts bytes for the xref table; `catalogQrService` (one-up) and
  `standeeSheetPdf` (grid) both use it. Do not add a PDF library — every one
  worth using stamps a `CreationDate`, which breaks the byte-identity two renders
  of the same code are required to have.
- **Captions are ASCII-folded (`asciiFold`) before they are drawn.** Nothing
  embeds a font or declares an `/Encoding`, so a base-14 font reads one byte per
  glyph and a UTF-8 caption prints one glyph per byte. The batch label is free
  text and the house shape the mint dialog suggests (`Vendor A — Oct 2026,
  run 3`) contains an em dash, so this is load-bearing, not cosmetic.
- **The rep download is scoped by ASSIGNMENT, not by role.** `findRepStandee`
  puts the rep id in the query, and a code the rep does not hold answers the
  same `404 CODE_NOT_FOUND` a nonexistent code gives — a rep must not be able to
  probe which codes have been minted.
- **`GET /admin/sales-reps` is a picker, not a user directory.** It lists
  accounts that already hold a script-granted staff role (rank ≥ `SALES_REP`,
  via `hasRoleAtLeast`'s ladder — never `role === 'SALES_REP'`), carries
  `displayName` + `contactMasked` and no raw phone/email, and is deliberately
  unpaged and unsearchable. The in-app user-management surface stays unbuilt;
  if this ever needs a search box, that decision changed and belongs here.
- **Client:** the rep's list (`/rep/standees`) has **no assign control** —
  assignment is ADMIN-gated, so a button there would answer 403. Tapping a row
  or a recommendation chip is a **prefill**, never a submit, matching the
  scanner and the `?code=` deep link: the preflight still runs and the rep can
  still edit the field.

### Catalog publish (ReCapture → Mirage)

- **Publishing is an explicit user action that runs as ONE background job over a
  SNAPSHOT** — never per-edit auto-sync. `POST /catalog/publish` creates a
  `CatalogPublishRun`, enqueues a **`MIRAGE_CATALOG_PUBLISH`** job (a fourth
  `jobType`, peer of the other three), and takes the catalog's lock. The whole
  catalog is read ONCE (`services/catalog/publishSnapshot.ts`, deep-frozen) and
  every later decision reads that object, so a user who keeps editing during a
  run gets what they pressed the button on.
- **`Job.projectId` is now OPTIONAL** — conditionally required by `jobType`. A
  catalog publish has no project, and a placeholder id would poison every
  `{projectId, createdAt}` query. Readers that mean "the capture job" already
  filter on `jobType`.
- **The planner is PURE** (`services/catalog/publishPlanner.ts`): snapshot + mode
  → an ordered plan, no IO, no clock, no randomness. Order is load-bearing —
  restaurant, then categories, then products — because Mirage's create-item
  rejects a missing category ObjectId. The product diff is a TABLE keyed by
  `PRODUCT_DIFF_FIELDS` declared as a total `Record`, so adding a field without
  giving it accessors is a **compile error**. Never `JSON.stringify` two objects
  to compare them, and never spread a document into a snapshot: a field the diff
  forgets reads back as "unchanged" and the user's edit silently never publishes.
- **Only `SUCCEEDED` advances `publishedRevision`.** Zero failures → SUCCEEDED;
  ≥1 success and ≥1 failure → PARTIAL; zero successes → FAILED. A PARTIAL run's
  successes are live, but "draft changes not yet live" is the truth, so the badge
  stays on. `hasDraftChanges` is DERIVED (`draftRevision > publishedRevision`),
  never a stored flag. `activePublishRunId` is cleared on **every** terminal path
  including a thrown processor error — a catalog holding a dead run id can never
  be published again.
- **Mirage has no idempotency keys and no upserts.** A replayed create answers
  `400 "… already exist"` WITHOUT the id. Two mechanisms make "publish twice ⇒
  one item" true: (1) `mirageItemId`/`mirageCategoryId` are persisted the instant
  the create returns, before anything else that can throw; (2) RECONCILIATION —
  a duplicate refusal triggers a list, an exact-name match, and adoption of the
  existing id. An adopted item already CLAIMED by another row of the same catalog
  is a sibling collision, not our orphan, and fails with a rename instruction.
- **Mirage's prose never escapes the adapter.** Its `message` is a
  classification input inside `services/mirage/mirageErrors.ts` and stops there.
  What lands on `syncError`, in a run entry, or in any response body is an
  `UPPER_SNAKE` ReCapture code (`services/catalog/publishSyncErrors.ts`) plus OUR
  sentence — resolved FROM the code at read time, so improving a message improves
  history too.
- **Category names: send Mirage the NORMALIZED form** (lowercase, spaces →
  underscores). Its duplicate check compares the RAW request name against stored
  (already-normalized) names, so posting "Garden Chairs" against a stored
  `garden_chairs` passes the check and creates a twin. ReCapture's display name
  stays authoritative — never write Mirage's echo back over it.
- **Assets stream, they are never buffered.** `MirageFileUpload` is a union:
  `kind: 'bytes'` for things small by construction (a logo), `kind: 'stream'`
  for anything model-sized. `mirageClient` encodes the multipart body BY HAND so
  a 90 MiB GLB pipes from S3 into the socket a chunk at a time; a `FormData` +
  `Blob` version would hold the whole model in RAM, twice. Preflight
  (`assetPreflight.ts`) HEADs every asset BEFORE any Mirage call — missing,
  oversize and wrong-content-type are TERMINAL row failures that cost one round
  trip instead of ninety seconds of doomed upload. An asset whose S3 **ETag**
  matches `publishedSnapshot.assetIdentities` is not re-uploaded.
  `MIRAGE_ASSET_TRANSFER_MODE` defaults to `bytes`; `url` needs Mirage prompt M1
  and publishes assetless products until then.
- **Never `delete-restaurant` from a publish path — `DELETE /catalog` is the ONE
  exception.** Unpublish removes the ITEMS and flips `restaurant.isPublished`.
  `mirageRestaurantId`, `publicUrl` and `publicUrlScheme` are written ONCE and
  frozen — a printed QR resolves through them, and `assertMappingImmutable`
  THROWS on an attempt to rewrite. The QR is rendered server-side from the STORED
  `publicUrl` verbatim; `catalogQrService` does not import
  `MIRAGE_PUBLIC_BASE_URL`, and it should stay that way.

  The exception exists because "delete my catalog and start over" cannot be
  honoured any other way, and it is the one action where giving up the URL is the
  user's stated intent rather than a side effect. Leaving the restaurant behind
  would be actively worse than deleting it: the old page keeps serving the old
  products at the old link, and provisioning ADOPTS a name-matching restaurant
  (§7.5), so the user's "fresh" catalog would silently re-adopt it on its first
  publish and inherit everything they just deleted. `DELETE /catalog` therefore
  calls `deleteRestaurant` FIRST and aborts the whole delete if Mirage refuses,
  which keeps "the mapping is never orphaned" true. Guarded by
  `tests/catalog-delete.test.ts`, which is the deliberate opposite of
  `tests/catalog-unpublish.test.ts` — read both before changing either. No other
  caller may reach for it.
- **Gates run BEFORE Mirage, and they all run.** Every reason a catalog cannot
  publish is a ReCapture-side fact, so `POST /catalog/publish` returns EVERY
  failing gate in one 422 (the client shows a checklist) and an empty catalog is
  never provisioned.
- **Analytics are a PROXY, not a redirect.** Mirage's three report endpoints are
  admin-scoped and its own in-code note forbids opening them to client scope.
  ReCapture reads them with its admin credential and FORCES `restaurant` from the
  caller's mapping — an empty value makes Mirage's `buildMatch` drop the filter
  and return every business's numbers, so an unprovisioned catalog returns empty
  with ZERO calls. Responses are built field by field; `byRestaurant`,
  `byDevice`, `topCategories` and `topZoomed` are cross-client panels that must
  never be spread into a per-business response.

### Catalog names: STORED as a slug, SHOWN de-slugged

- **Every catalog, category and product name is stored as a lowercase underscore
  slug** — `"Chicken Biryani"` → `chicken_biryani`. The name doubles as the
  public URL segment and as an S3 key prefix on Mirage, neither of which
  tolerates a space. Three files implement the same rule and must stay in
  lockstep: `recapture-api/src/utils/catalogNames.ts` (applied at the Zod
  boundary, so a service never sees an un-slugged name),
  `mirage-be/src/helper/helper.js`, and `lib/domain/catalog/catalog_names.dart`.
- **The underscore is an INTERNAL detail and must never reach a screen.** Print
  `displayName` (`CatalogProduct`, `CatalogCategory`, `Catalog`,
  `BusinessProfile`, `PublishProductStatus`, `TopProduct`), and seed every name
  INPUT with it too. Mirage's public menu already does this
  (`mirage-fe/src/helper/removeCharacters.ts`); a screen that prints `.name`
  raw is out of step with the page the customer sees.
- **⚠ NEVER decide "did this name change?" with `typed != stored`.** The field
  holds the display form and the row holds the slug, so raw equality is dirty
  from the moment a screen opens — and it lets a retype through as a rename that
  the server then normalises back to the value already stored. The save reports
  success, the row does not move, and nothing reaches the menu because nothing
  changed. Use `catalogNameChanged(typed, stored, maxLength: …)`, which compares
  slugs and therefore also gets the honest answer for case- and
  separator-only edits.
- **Report the SERVER's name back, not the typed one.** A confirmation built
  from what the user typed promises a spelling the catalog does not hold.

### S3 key scheme (capture jobs)
- **One builder, one parser: `utils/s3Keys.ts`.** Inline key templates anywhere
  else are a bug. The exact scheme:

  ```
  {env}/{projectSlug}_{projectId}/{jobId}/images/{EYE|TOP|LOW}/{name}.jpg
  {env}/{projectSlug}_{projectId}/{jobId}/capture_manifest.json
  {env}/{projectSlug}_{projectId}/{jobId}/model-input/…      ← reserved namespace
  {env}/{projectSlug}_{projectId}/{jobId}/deleted/…          ← soft-delete park
  {env}/{projectSlug}_{projectId}/{jobId}/models/{modelId}/… ← 3D artifacts
  {env}/{projectSlug}_{projectId}/{jobId}/uploads/photo_{nnnn}.{jpg|png|webp}
                                                             ← artist photo set
  ```

- **`uploads/` is the artist photo-upload namespace** — a sibling of `deleted/`
  and `model-input/`, written ONLY under a `PHOTO_UPLOAD` job's own prefix.
  Because that job owns its prefix outright (a capture job never shares it), it
  needs **no exclusion anywhere**: `model-input/` needs one only because it sits
  inside a *capture* job's prefix. Builders/parser:
  `buildUploadedPhotoKey` / `isUploadedPhotoRelativeKey` / `UPLOADED_PHOTOS_KEY_PREFIX`.
- **Uploaded photo keys are SERVER-ASSIGNED, never client-named.** The client
  sends only `{contentType, size}` per file; the server returns the keys. The
  index is 1-based and zero-padded to 4 in REQUEST ORDER (so the set has a
  stable gallery order), and the extension derives from the **validated
  content type** (`image/jpeg → jpg`, `image/png → png`, `image/webp → webp`) —
  never from a filename, which is how a hostile name would otherwise reach S3.
  The assigned relative keys are persisted on the job (`payload.photoKeys`) so
  an `Idempotency-Key` replay returns the identical set rather than re-deriving
  one from content types it no longer has.

- **`{env}` (`dev|staging|prod`) is config-driven from `NODE_ENV`, never
  hardcoded.** It is the firewall that stops a non-prod deploy from writing —
  or, more importantly, **deleting** — production objects, since the
  project-delete path wipes objects **by prefix**. Non-negotiable.
- **`{projectSlug}` is a LABEL, never an identifier.** `projectNameSlug()`
  lowercases, NFKD-strips diacritics, collapses anything outside `[a-z0-9_]` to
  a single `-`, trims leading/trailing separators, and truncates to 24 chars. It
  is **pure and deterministic**, and it is **one-way** — nothing resolves a
  project by reading it back. It exists so a human debugging in the S3 console
  can identify a project without cross-referencing Mongo. A name that slugifies
  to nothing (all-emoji is a real input, and must not throw) degrades the segment
  to a bare `{projectId}` — never a leading `_`. `{projectId}` is what keeps the
  path unique and machine-parseable, and the composed segment always goes
  through `requireSegment()` so a slugifier bug cannot emit a traversal.
- **`{userId}` is NOT in the path.** Ownership is enforced in the DB and by the
  token, never by key prefix. (`Job.userId` is unchanged — only the key lost it.)
- **`parseImageKey` splits the project segment on its LAST underscore**, which is
  unambiguous because project ids are ObjectId hex (`[a-f0-9]{24}`, no
  underscore). It is strict at exactly 6 segments and returns a discriminated
  failure, never a partial parse — so an old-format key is a clean `ok: false`.
- **Both buckets use the IDENTICAL prefix.** `msxr-raw-captures` and
  `msxr-model-artifacts` must never diverge: `deleteProject`
  (`adminProjectsService.ts`) runs `deleteObjectsUnderPrefix` against the same
  prefix in both. Accepted consequence: the project name is visible in public
  CloudFront URLs. Conscious tradeoff, not an oversight.
- **Keys are built ONCE and persisted** on `Job.upload` (`rawPrefix`,
  `manifestKey`) at job creation. Every later read/list/move/delete resolves
  from those persisted values, so changing this scheme needs **no migration and
  no backfill** — old objects stay where they are and old jobs keep uploading,
  finalizing, generating, exporting and deleting. **Rebuilding a prefix for an
  already-created job would turn a scheme change into data loss — don't.**
- The client never builds keys: it receives `keyPrefix` / `keyTemplate` in the
  upload plan and composes relative paths under them.

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
- The typed `AnalyticsEvent` registry and its per-event Zod schemas now exist
  (`src/validation/analyticsSchemas.ts` — the single tracking-plan source of
  truth); `EVENT_SCHEMAS` is exhaustive by a `satisfies
  Record<AnalyticsEventName, …>` clause, so a new event name without a schema is
  a compile error. Add the name and its schema together.
  `photo_upload_session_created` / `photo_upload_committed` /
  `photo_upload_generation_requested` follow that rule; like every other event
  they carry **no S3 keys and no presigned URLs**.
- ⚠ The emit layer STRIPS any prop whose NAME contains one of
  `FORBIDDEN_KEY_SUBSTRINGS` (`utils/analytics.ts`) — including "code" — as a
  suspected OTP/secret leak. A failure code therefore travels as
  `failure_reason`, never as `code`/`error_code`/`failure_code`: those are
  dropped (with a console warning, not an error) and the event arrives with no
  diagnosis at all.
- **NOT YET BUILT:** a real destination integration. Until then the sink logs in
  non-prod only.

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

### Web upload of artist photo sets (LIVE on web and native)
- The presigned part PUTs go **direct to S3**, and the avatar bytes-proxy
  precedent explicitly **does not extend here** — a 48-photo set is
  capture-sized, not avatar-sized. Do not add a bytes-proxy route for it.
- `msxr-raw-captures` now **does serve a CORS policy**, applied specifically so
  those part PUTs survive preflight in a browser. This **reverses** the earlier
  "no CORS on the raw bucket" decision for `PUT`/`GET` only; everything else
  about the bucket is unchanged (private, presigned-only, public access
  blocked). Recorded here and in `docs/aws-storage-and-cdn.md`.
- The Upload option is therefore offered on **every platform** — the old
  `kPhotoUploadEnabledOnWeb` gate in `capture_mode_sheet.dart` is gone. The
  remaining gate is `isStaffProvider` (staff-only, UX; the backend re-checks the
  role on every request).
- The applied policy is `AllowedMethods`: `PUT`, `GET`, `HEAD`;
  `AllowedHeaders`: `content-type`; `ExposeHeaders`: `ETag` (the engine reads it
  off every part response). **`AllowedOrigins` is currently `*` — tighten it to
  the app's web origins.** A wildcard origin does not leak objects (they stay
  presigned-only), but it lets any page that obtains a presigned URL use it from
  a browser, which is wider than this feature needs.
- The **avatar** bytes-proxy (`GET /auth/me/avatar/bytes`) still exists and is
  still the right call for displaying raw-bucket objects: reads there are not
  presigned-PUT-shaped and go through the API by design.

#### Native (Android/iOS) specifics for this flow
- **Sniffing reads a HEAD, not a file.** `project_photo_picker.dart` streams the
  first `kImageSniffHeaderBytes` (12 — the WebP RIFF check is the longest
  signature) off each photo via `XFile.openRead(0, n)`. It must never call
  `readAsBytes()` on native: doing so pulled the whole set through RAM at pick
  time (48 x up to 15 MiB of short-lived allocations on the UI isolate) to read
  twelve magic bytes. Only WEB reads full bytes, because there they ARE the
  payload. Pinned by `project_photo_upload_test.dart`.
- **The flow uses the durable `UploadProgressStore`**, exactly like the capture
  flow. Without it the engine is stateless, so every auto-retry re-initiated
  each file and re-sent every part from zero — contradicting the idempotency
  note in `resilient_upload_runner.dart`.
- **The connectivity gate needs a way back.** `ChunkedUploadManager`'s `isOnline`
  gate AUTO-PAUSES a worker that finds the network gone, and only
  `UploadController.resume()` reopens that gate. The capture flow has two callers
  for it (the on-screen upload controls, and the offline queue's
  `autoResumeQueued`); this flow has NEITHER — its progress screen offers only
  Cancel. `RunnerPhotoSetUploadEngine` therefore subscribes to connectivity edges
  for the life of one run and resumes on reconnect. Do not enable the gate
  anywhere without wiring its exit. Pinned by `chunked_upload_manager_test.dart`.
- **`FOREGROUND_SERVICE_DATA_SYNC` is declared but this flow does NOT use it.**
  `UploadForegroundServiceClient` is driven only from `offline_upload_queue.dart`
  (the capture path). A photo-set upload therefore survives backgrounding only
  as long as Android leaves the process alive — it is not protected by a
  foreground service. Stated here because the manifest comment reads as though
  every upload is covered.
- **The sniffed content type never reaches S3.** It is used only to choose the
  key's extension (`projectPhotosService.ts` → `buildUploadedPhotoKey`);
  `initiateMultipartUpload` issues `CreateMultipartUploadCommand` with no
  `ContentType`, so objects land at `uploads/….jpg` with S3's default
  `binary/octet-stream`. This does NOT fail the PUT (an `UploadPartCommand`
  presign does not sign content-type) — it is wrong metadata, not a broken
  transfer. **Open; not yet fixed** — the fix is in a service the capture path
  shares, so it changes bundle-object metadata too.

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
- **Don't widen the raw-contact exception.** `GET /admin/users/:id` is the one
  route that ships an unmasked phone/email, and it is ADMIN-only, one-at-a-time,
  metered and audited. Everything else masks — reuse `utils/maskIdentifier.ts`.
- **Don't** make auth/ownership errors distinguishable at the boundary.
- **Do** keep the Project DTO identical across `GET /projects` and
  `POST /projects` (and in sync with the Flutter `Project` entity) — they share
  one shape by contract.
- **Do** update this file when a convention changes.
