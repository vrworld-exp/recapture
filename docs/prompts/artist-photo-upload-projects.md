# Prompt — Artist Photo-Upload Projects (pick → S3 → project → Generate)

> Copy everything below the first horizontal rule as the task prompt.
> Written against `feature/uplaod-for-artist` @ `adff681`. Design basis:
> `08 — Artist Photo-Upload Projects`. Every file/line reference below was
> verified against the tree at that commit.

---

## Context you must read first

Read **AGENTS.md** before writing a line of code. It is the single source of
truth for both codebases (Flutter client at the repo root, Node/TS backend in
`recapture-api/`): the API response envelope, roles, the S3 key scheme, the
config/secrets rules, PII/logging, the analytics seam, and the testing
conventions. **Where this prompt disagrees with AGENTS.md, AGENTS.md wins** —
tell me about the conflict instead of silently picking one.

Then read the layers you are extending. You are wiring existing machinery to a
new front door; you are not building an upload engine.

| What | Where | Reuse verdict |
|---|---|---|
| Upload orchestrator (packs a capture bundle, assembles the manifest) | `lib/application/upload/upload_flow.dart` | **Bypass** — the only capture-shaped layer |
| Session input `{path, key, size}` | `lib/domain/upload/upload_session_spec.dart` | Reuse unchanged |
| Chunked engine (parts, retry, resume, progress) | `lib/application/upload/chunked_upload_manager.dart:48` | Reuse unchanged — already takes an injectable `PartByteSource` (line 52) |
| Session retry / backoff | `lib/application/upload/resilient_upload_runner.dart` | Reuse unchanged |
| `/jobs/:jobId/uploads/*` adapter | `lib/application/upload/jobs_multipart_upload_api.dart` | Reuse unchanged |
| Interceptor-free S3 PUT client | `DioS3PartClient`, `lib/application/upload/multipart_upload_api.dart` | Reuse unchanged |
| Upload guard behind initiate/part-url/complete | `loadUploadableJob`, `recapture-api/src/services/jobsService.ts:727` | **Reuse unchanged — see below** |
| Meshy submit → poll → re-host | `src/worker/processors/meshyModelProcessor.ts` | Reuse unchanged |
| Presign / list / head / move / prefix-delete | `src/services/s3ObjectStore.ts` | Reuse unchanged. **Do not construct a second `S3Client`** — `config/s3.ts` owns the one client |
| Presigned-PUT + commit precedent | The avatar flow — `src/routes/auth.ts`, `src/utils/avatarKeys.ts`, `tests/auth-me-avatar.test.ts` | Copy its *stance*: server assigns the key, commit verifies rather than trusts |

### The finding this whole feature rests on — verify it before you build on it

`loadUploadableJob` (`src/services/jobsService.ts:727`) is the shared guard
behind `initiate`, `part-url` and `complete`. Read it. It checks:

1. job exists **and is owned by the caller** (`userId` from the token),
2. state is `CREATED` or `UPLOADING`,
3. the upload plan window has not expired,
4. the key is contained under `job.upload.rawPrefix`, non-empty remainder,
   within `KEY_MAX_LENGTH`, conservative charset, no `..` segments,
5. **and only if the job-relative key starts with `images/`**, that the ring
   segment is one the job's capture variant planned.

It applies **no `jobType` filter**. A job-relative key of
`uploads/photo_0001.jpg` therefore passes it **today, unmodified** — check 5
never fires because the first segment is `uploads`, not `images`.

> **`POST /jobs/:jobId/uploads/{initiate,part-url,complete}` needs ZERO
> changes.** The artist's photo set moves over the identical presigned-multipart
> transport, with identical resume, retry and progress behaviour. If you find
> yourself editing `jobsService.ts`, stop and tell me — something in my reading
> is wrong and the plan needs revisiting.

### What is genuinely not reusable, and why

| | Why |
|---|---|
| `POST /jobs` | Demands `objectSize` + `captureVariant` + `expectedFilesCount` inside the shape matrix (`src/models/types/captureVariants.ts`). An artist's photo set has no rings. → new session route |
| `POST /jobs/:jobId/finalize` | Requires `capture_manifest.json` to exist and validates it ring-by-ring. → new commit route |
| `autoPhotoSelectionService` | Picks photos by reading blur and yaw **out of the capture manifest**. An uploaded set has none. **Auto-selection is unavailable on upload projects** — the artist picks 3–4 by hand |

---

## Goal — in the product owner's words

> When an artist presses the `+` icon they get one more option: **Upload
> capture**. Choosing it opens the Create Project page with the project fields
> plus one more field for the upload. Tapping that lets them add up to 48
> photos from the gallery. Once photos are selected the primary button becomes
> **Upload** instead of **Capture**. Pressing Upload uploads the photos and the
> project exists with everything on it — after that, the admin and the user have
> every option they have today.

Concretely, the five screens/steps:

```
Projects Hub  [ + ]
   └─ capture-mode sheet, now THREE cards:
         Full Capture · Maya AI Capture · Upload photos   ← new, staff-only
            └─ Create Project screen (upload variant)
                  NAME · CATEGORY · PHOTOS  ("Add photos" → gallery, 3..48)
                  primary CTA reads UPLOAD, not START CAPTURE
                     └─ POST /projects            (source: 'upload')
                        POST /projects/:id/photos/session
                        existing engine → /jobs/:jobId/uploads/*  → S3
                        POST /projects/:id/photos/commit
                           └─ Project Photos screen
                                 grid of the uploaded set, select 3–4
                                 └─ Generate 3D model  ← this is what spends credits
                                       └─ the EXISTING model screens, unchanged
```

After commit the project is an ordinary project. It appears in the Hub, in the
staff Live-projects list, it renames, it soft-deletes, it hard-deletes with its
S3 objects, it lists models, it optimizes, it opens in the viewer and in AR.
**None of that needs new code** — it works because the upload job carries an
ordinary `upload` block and the project is an ordinary `Project` document.

---

## Decisions already made — implement them, do not relitigate

| # | Decision |
|---|---|
| D1 | The existing **`MODEL_ARTIST`** role. No new rank, no migration, no grant UI. Granted only by `scripts/set-user-role.ts`, as AGENTS.md requires |
| D2 | Upload and generation are **two explicit steps**. Pressing **Generate** is what spends Meshy credits — uploading never does |
| D3 | **3 minimum, 48 maximum** photos per project (`PROJECT_PHOTO_MIN_COUNT` / `PROJECT_PHOTO_MAX_COUNT`) |
| D4 | Mobile **and** web — but see the CORS blocker; native ships first |
| D5 | The **same presigned direct-to-S3 multipart transport** the capture flow uses |
| D6 | Photo source is a property of the **project** (`Project.source`), **not** a new `ProjectStatus` |
| D7 | The project row is created **before** the photos upload, by the ordinary `POST /projects`. An abandoned upload leaves a `DRAFT` project with no photos — exactly what an abandoned capture leaves today |
| D8 | The upload path is **online-only** on the client. It must not go through the offline outbox (see §2.9) |

### Where the product owner's wording and design-doc 08 differ — how I resolved it

Read these; flip any of them before you start if you disagree, but do not
decide silently mid-implementation.

| Point | 08 said | Owner said | **Build this** |
|---|---|---|---|
| Photo count | "up to ~50" | "48 pics" | **48**, via `PROJECT_PHOTO_MAX_COUNT` default 48. It matches `CaptureMode.full`'s 48 shots, so the two paths produce comparably sized sets. Raising it later is a one-line env change |
| Create-project fields | Hide OBJECT SIZE + CAPTURE MODE | "all project fields should present" | **Hide them.** They are capture concepts: OBJECT SIZE drives camera-distance guidance an uploaded set never receives, and CAPTURE MODE drives a flow that never runs. Writing a placeholder `MEDIUM`/`GUIDED` is a lie later reads act on. NAME and CATEGORY — the two fields that describe the *project* rather than the capture — do show |
| "one more project should get created" | — | ambiguous | Read as **one** project, created once at form submit (D7), photos attached to it. Not two projects, and not a project created twice |
| "admin and user have every option that is coming right now" | Auto-selection is unavailable | — | Every option **except** server-side photo auto-selection, which is physically impossible without a manifest. `POST /projects/:id/model` and `/admin/projects/:id/model/auto` must **refuse an upload project with deliberate copy** (§1.8), not fail confusingly. The artist reaches generation by hand-picking 3–4, which is the same door staff already use |

---

## Known blocker — web needs a CORS policy on the raw bucket

The capture flow is native-only, so it never hit this. Both S3 buckets
deliberately serve **no CORS policy** (`docs/aws-storage-and-cdn.md:124`), which
is why avatars proxy bytes through the API instead — and `src/routes/auth.ts`
states in so many words that that reasoning *"does NOT extend to capture
uploads, which must stay direct-to-S3."* A 48-photo artist set is capture-sized,
not avatar-sized, so it stays direct-to-S3. **Do not add a bytes-proxy route for
this feature.**

A browser cannot PUT to a presigned URL until `msxr-raw-captures` carries a CORS
policy. Scope it narrowly:

| Field | Value |
|---|---|
| `AllowedOrigins` | the app's web origins only — **never** `*` |
| `AllowedMethods` | `PUT`, `GET` |
| `AllowedHeaders` | `content-type` |
| `ExposeHeaders` | `ETag` — the engine reads it off every part response |

**Build order:** the feature ships working on Android/iOS the day it lands. The
bucket policy is a **separate one-line infra task** that switches web on. Until
it is applied, the web build shows the Upload option **disabled with a reason**,
never enabled-and-broken. When the policy is applied, record it in
`docs/aws-storage-and-cdn.md` **and** `AGENTS.md` — it reverses a documented
decision and must not be a silent console edit.

---

## Part 1 — Backend (`recapture-api/`)

### 1.1 `Project.source` — a new field, not a new status

`src/models/Project.ts` gains:

```ts
export const PROJECT_SOURCE_VALUES = ['capture', 'upload'] as const;
export type ProjectSource = (typeof PROJECT_SOURCE_VALUES)[number];
```

on the schema with `default: 'capture'`, so every pre-existing document reads
correctly with **no migration** — the same pattern `User.role`,
`Job.captureVariant` and `Job.captureMode` already use.

`objectSize` and `mode` become **conditionally required**, the exact idiom
`Job.projectId` already uses (`src/models/Job.ts:311`):

```ts
objectSize: {
  type: String,
  enum: ['SMALL', 'MEDIUM', 'LARGE'],
  required(this: IProject) { return this.source !== 'upload'; },
},
```

Same for `mode`. Both become optional on `IProject`.

**Deliberately no new `ProjectStatus` value.** An upload project stays `DRAFT`
until it has a model. The client branches on `source`, not on status, to decide
what a card's primary action does. A new status would touch the schema enum
(`PROJECT_STATUS_VALUES`), the admin list's `?status=` filter and the client's
label/colour/action tables for no gain.

`source` ships on `ProjectListItem` through **`toProjectListItem`**
(`src/services/projectsService.ts:339`) — the ONE Project DTO mapper — and is
hand-synced onto the Flutter `Project` entity, because the DTO is identical
across `GET /projects`, `POST /projects` and the entity **by contract**
(AGENTS.md §0.1, §4). `createProject` (line 118) accepts and persists it.

### 1.2 `PHOTO_UPLOAD` job type

`src/models/types/job.types.ts` gains, beside its three siblings:

```ts
/** An artist's uploaded photo set. Holds objects; is never processed. */
export const PHOTO_UPLOAD_JOB_TYPE = 'PHOTO_UPLOAD';
```

State path: `CREATED` → `UPLOADING` (flipped by the **existing** `initiate`) →
`UPLOADED`. It stops there.

**It never enters `QUEUED`, so the worker never claims it.** `claimNextJob`
(`src/worker/jobQueue.ts:37`) filters on `state: 'QUEUED'` alone,
jobType-agnostically — a `PHOTO_UPLOAD` job that never queues is invisible to
it. **Register no processor for this type**, and do not add a no-op one: there
is nothing to process, only photos to hold. Add a comment saying so, or the next
person will "fix" the missing registration.

The job carries an ordinary `upload` block (`UploadInfo`), which means the
hard-delete prefix sweep in `adminDeleteProject`
(`src/services/adminProjectsService.ts:434`) purges its objects from **both**
buckets for free — that loop iterates every job with an `upload` block and needs
no change. Confirm this with a test rather than by reading.

### 1.3 Key namespace — `src/utils/s3Keys.ts`

Reuse `buildJobKeyPrefix`. The job id makes the prefix unique, so an upload job
and a capture job on the same project can never collide. Add to
`src/utils/s3Keys.ts` — **the one builder and parser for this key space; an
inline key template anywhere else is a bug** (AGENTS.md):

```
{env}/{projectSlug}_{projectId}/{jobId}/uploads/photo_{nnnn}.{jpg|png|webp}
```

- `export const UPLOADED_PHOTOS_KEY_PREFIX = 'uploads/'` — a sibling of
  `deleted/` and `model-input/`
- `buildUploadedPhotoKey(scope: JobKeyScope, index: number, ext: string)`
- `isUploadedPhotoRelativeKey(relative: string): boolean`

Rules, matching the file's existing stance:

- **Keys are server-assigned, never client-named.** The client sends only
  `{ contentType, size }` per file; the server returns the keys. Extension and
  charset stay controlled, and a hostile filename never reaches S3.
- `index` is 1-based and zero-padded to 4 (`photo_0001`), assigned in the order
  the client listed the files, so the set has a stable order for the gallery.
- Extension derives from the **validated `contentType`**, not from a name.
  `image/jpeg → jpg`, `image/png → png`, `image/webp → webp`. Anything else is
  rejected at validation, never defaulted.
- Every composed segment goes through the file's existing `requireSegment()`.

**No exclusion is needed in `buildProjectExport`.** `model-input/` needs one
because it shares a *capture* job's prefix; an upload job is its own prefix, and
`findExportableJob` never resolves to it (§1.7).

### 1.4 Config — `src/config/env.ts` **and** `.env.example` together

Every tunable has a safe default so existing deployments boot (AGENTS.md).

| Var | Default | Note |
|---|---|---|
| `PROJECT_PHOTO_MIN_COUNT` | `3` | Below this there is nothing Meshy could ever use |
| `PROJECT_PHOTO_MAX_COUNT` | `48` | D3 |
| `PROJECT_PHOTO_MAX_BYTES` | `15_728_640` (15 MiB) | Per object. See the risk note below |
| `PROJECT_PHOTO_URL_TTL_SECONDS` | `3600` | Matches `ADMIN_EXPORT_URL_TTL_SECONDS` |
| `PROJECT_PHOTO_UPLOAD_MAX_PER_WINDOW` | `10` | Sessions per user per window |
| `PROJECT_PHOTO_UPLOAD_WINDOW_SECONDS` | `3600` | |

> **15 MiB × 48 is a ~720 MiB ceiling per project in the raw bucket.** That is a
> storage-cost decision, not just a validation constant. Flag it to me before
> launch, and **confirm the raw bucket has an `AbortIncompleteMultipartUpload`
> lifecycle rule** — it is the abandoned-upload reaper the whole multipart path
> already relies on.

Use the generic `consumeRateWindow` (`utils/rateLimit.ts`) for the new limiter —
do not write a bespoke one.

### 1.5 Validation — new `src/validation/projectPhotoSchemas.ts`

Zod, `.strict()` everywhere, mirroring `src/validation/projectSchemas.ts`.
Reuse its `OBJECT_ID_RE`-style param schema rather than re-deriving one.

- `photoSessionSchema` — `{ files: [{ contentType: z.enum(['image/jpeg','image/png','image/webp']), size: z.number().int().positive().max(PROJECT_PHOTO_MAX_BYTES) }] }`,
  array length `MIN..MAX`
- `photoCommitSchema` — `{ jobId }`
- `photoDeleteSchema` — `{ keys: string[] }`, 1..MAX
- `photoGenerateSchema` — `{ keys: string[] }`, length 3..4 (reuse
  `MIN_SELECTED_PHOTOS` / `MAX_SELECTED_PHOTOS` from `projectModelsService`)

And in `src/validation/projectSchemas.ts`, `createProjectSchema` (line 33) is
`.strict()` with `size` and `mode` **required** today. Add
`source: z.enum(PROJECT_SOURCE_VALUES).optional()` and a `superRefine`:

- `source === 'upload'` → `size` and `mode` must be **absent** (present is a 400,
  not silently ignored — a client sending them has a bug worth surfacing)
- `source` absent or `'capture'` → `size` and `mode` required, exactly as today

### 1.6 Five new routes — in `src/routes/projects.ts`, **not** `/admin`

An artist uploads into their **own** project, so ownership is proven by
`getProject(userId, id)` exactly as every other route in that router does, and
missing / not-owned / soft-deleted collapse into **one identical 404** — no
existence leak (AGENTS.md, enumeration-safe principle).

`requireRole('MODEL_ARTIST')` is applied **per-route**, never
`router.use(...)` — the existing owner routes must stay open to `USER`. Privilege
is inclusive upward, so `ADMIN` passes.

Services go in a new `src/services/projectPhotosService.ts`, returning
discriminated result unions the routes map to HTTP — routers stay thin
(AGENTS.md layering). No Express types in the service.

---

**`POST /projects/:id/photos/session`** — `requireRole('MODEL_ARTIST')`

Body `{ files: [{ contentType, size }] }`, `MIN..MAX` entries.

1. `getProject(userId, id)` → 404 on miss.
2. Refuse if `project.source !== 'upload'` → `409 NOT_AN_UPLOAD_PROJECT`. A
   capture project must not grow an uploads namespace (risk 5).
3. `consumeRateWindow('photo-upload-session:' + userId, ...)` → 429 with
   `retryAfter`.
4. Create the `PHOTO_UPLOAD` job: `state: 'CREATED'`, `upload` block built from
   `buildJobKeyPrefix` — `rawPrefix` persisted **once**, never rebuilt
   (AGENTS.md), `expectedFilesCount = files.length` (no manifest to add),
   `uploadMethod: 'S3_PRESIGNED_MULTIPART'`, `checksumAlgo` as the capture path
   sets it. **`manifestKey` is not applicable** — leave it unset if the schema
   allows, otherwise say so and I will decide.
5. Honour the `Idempotency-Key` header. The unique partial index on
   `(userId, idempotencyKey)` **already exists** on `Job` — catch the duplicate
   key error and replay the existing job, the same shape `POST /jobs` uses.
6. Respond `201` with the same `uploadPlan` shape `POST /jobs` returns
   (`keyPrefix`, expiry, part size — read the real route and match it field for
   field) **plus** `files: [{ key }]` in request order.

---

**(transfer)** — `POST /jobs/:jobId/uploads/{initiate,part-url,complete}`.
**Existing. Unchanged. Do not touch.**

---

**`POST /projects/:id/photos/commit`** — `requireRole('MODEL_ARTIST')`

Body `{ jobId }`.

1. Own the project; resolve the job by `(projectId, jobId, jobType: PHOTO_UPLOAD)`
   → 404 on miss.
2. **Idempotent:** already `UPLOADED` → return the same success body without
   re-listing S3.
3. List `{rawPrefix}uploads/`. For each object, enforce
   `PROJECT_PHOTO_MAX_BYTES` from its **HEAD/list size**, because presigning
   cannot enforce a size. An over-cap object is **deleted** and the request is
   `413 PHOTO_TOO_LARGE` — the same stance the avatar commit takes.
4. Fewer than `PROJECT_PHOTO_MIN_COUNT` objects present → `400 TOO_FEW_PHOTOS`.
5. Write `upload.uploadedFilesCount` and flip `CREATED`/`UPLOADING` → `UPLOADED`
   with a **conditional `findOneAndUpdate`** guarded on the current state, so a
   double commit is race-safe (AGENTS.md: atomicity without transactions).
6. Write `Project.stats.totalPhotos` = the verified count. **Do this** — risk 6
   in the design doc: `stats.totalPhotos` is written by the capture finalize
   funnel and would otherwise stay 0, so the Hub card would read "0 photos" on a
   project that has 48. Reuse `setProjectCaptureStats`
   (`src/services/jobsService.ts`) if its signature fits; if it insists on
   capture semantics, write the field directly and say why in a comment.
7. **Do not** set `Job.state = 'QUEUED'` and do not touch `Project.status`.

---

**`GET /projects/:id/photos`** — `requireRole('MODEL_ARTIST')`

The newest `PHOTO_UPLOAD` job's objects with presigned GETs
(`PROJECT_PHOTO_URL_TTL_SECONDS`), mirroring `buildProjectExport`'s
list-then-presign shape. Returns relative keys + URLs + sizes, in key order.

> **A presigned URL is a bearer credential.** It may appear in this response
> body and **nowhere else** — never in a log, never in analytics (AGENTS.md).

---

**`DELETE /projects/:id/photos`** — `requireRole('MODEL_ARTIST')`

Body `{ keys }` (relative). Moves each into the job's `deleted/` namespace via
`moveObject` — the same soft-delete park the admin photo delete uses. Never a
hard delete.

Each key is gated by `isContainedRelativeKey` **and**
`isUploadedPhotoRelativeKey`. **Fail closed:** one escaping key refuses the
**whole** request with `400 INVALID_KEY` and moves **nothing**. Validate the
entire list before moving the first object.

---

**`POST /projects/:id/photos/generate`** — `requireRole('MODEL_ARTIST')`

Body `{ keys: [3..4] }` → `createMeshyModelRequest({ projectId, keys, actor, jobId, idempotencyKey })`.

`jobId` is the project's newest `UPLOADED` `PHOTO_UPLOAD` job, resolved
server-side — **not** taken from the body. Keep the existing
`meshy-create:{userId}` rate window and the `Idempotency-Key` replay guard
untouched: **this is the step that spends credits**, and AGENTS.md names three
load-bearing guards on generation. Do not remove one without replacing it.

Map the service's result union to the same status codes the staff route already
maps — read it and match, do not invent new codes.

### 1.7 One surgical widening in the generation path

`createMeshyModelRequest` (`src/services/projectModelsService.ts:491`) already
accepts an optional `jobId` (interface at line 412) and resolves its source job
two ways at lines 504–506:

```ts
const job = input.jobId
  ? await findExportableJobById(projectId, input.jobId)
  : await findExportableJob(projectId);
```

The artist path **always** passes an explicit `jobId`, so **only the first
branch is touched**. Add to `src/services/adminProjectsService.ts`, beside
`UPLOAD_FINALIZED_JOB_STATES` (line 52) and `findExportableJobById` (line 494):

```ts
export const PHOTO_UPLOAD_SOURCE_JOB_STATES = ['UPLOADED'] as const;

/** Resolves a model-source job by id: an exportable CAPTURE job, or an
 *  UPLOADED photo-upload job. An explicit list of allowed pairs — never a
 *  removed filter. */
export async function findModelSourceJobById(
  projectId: string,
  jobId: string
): Promise<IJob | null>;
```

It matches `(jobType ∈ [CAPTURE_PROCESSING, null], UPLOAD_FINALIZED_JOB_STATES)`
**or** `(PHOTO_UPLOAD, ['UPLOADED'])` — an `$or` of two explicit pairs.

Then point **only** the explicit-`jobId` branch of `createMeshyModelRequest` at
`findModelSourceJobById`.

> AGENTS.md calls the `jobType` filter **load-bearing**, and it stays that way.
> `findExportableJob` (line 469) and `findExportableJobById` (line 494) are
> **untouched**, so export, the preview gallery and photo soft-delete keep
> ignoring `PHOTO_UPLOAD` jobs entirely. Prove this with the guardrail test.

### 1.8 Auto-selection must refuse, not fail confusingly

`autoPhotoSelectionService` reads blur and yaw out of the capture manifest. An
uploaded set has no manifest, so it has nothing to sort by.

- `POST /projects/:id/model` (owner auto-generate) and
  `POST /admin/projects/:id/model/auto` must check `project.source === 'upload'`
  **before** any spend path and return a distinct, deliberate refusal —
  `409 AUTO_SELECTION_UNAVAILABLE`, message along the lines of *"This project's
  photos were uploaded, so photos must be chosen by hand. Select 3–4 photos and
  generate."*
- Pick the owner-facing copy deliberately: it must not name Meshy, the selector,
  key layout or any pipeline internal (AGENTS.md — the owner surfaces strip
  every internal fact).
- Do **not** silently fall through to the hand-pick path, and do **not** return
  the generic `NOT_EXPORTABLE`.

### 1.9 Analytics

`src/validation/analyticsSchemas.ts` — `EVENT_SCHEMAS` (line 495) is exhaustive
by `satisfies Record<AnalyticsEventName, z.ZodTypeAny>`, so a new name without a
schema is a **type error**, not a runtime surprise. Add name + schema together:

| Event | Props |
|---|---|
| `photo_upload_session_created` | `user_id_hash`, `project_id`, `file_count` |
| `photo_upload_committed` | `user_id_hash`, `project_id`, `job_id`, `photo_count`, `total_bytes` |
| `photo_upload_generation_requested` | `user_id_hash`, `project_id`, `job_id`, `selected_count` |

Emit through `utils/analytics.ts → track`. **Non-PII props only** — hash any
identifier with `utils/otp.ts → hashIdentifier`, never invent a second hashing
scheme. **No S3 keys and no presigned URLs in analytics props.**

---

## Part 2 — Client (Flutter)

Layering is **domain → data → application → presentation** (AGENTS.md).
Notifiers hold state and call repositories; repositories own all HTTP and error
translation. Do not put a Dio call in a notifier or a widget.

### 2.1 Domain — `lib/domain/entities/project_source.dart`

```dart
enum ProjectSource { capture, upload }
```

with `apiValue` / `fromApiValue`, defaulting to `capture` on anything unknown —
the same defensive-parse stance `ProjectStatusDisplay.fromApiValue` already
takes.

`lib/domain/entities/project.dart` gains `final ProjectSource source;`
(default `capture`), parsed in `Project.fromMap` and round-tripped in
`toMap()`. **`toMap` round-trip is not optional** — a cached row read back
without it would show a capture action on an upload project until the next
successful fetch, exactly the bug the `modelCount` comment at line 62 warns
about.

Note the entity carries **no** `objectSize` or `mode` today, so hiding those
fields on the create form costs the entity nothing.

### 2.2 The `+` sheet — `lib/presentation/screens/projects/capture_mode_sheet.dart`

Today `showCaptureModeSheet` resolves to `CaptureMode?` and the caller
(`projects_screen.dart:568` FAB → `_onCreateProject` at line 553) pushes
`createProject` with `extra: mode`.

Add a **third card**, "Upload photos". But **do not add an `upload` value to
`CaptureMode`** — `CaptureMode` is the capture vocabulary; it is persisted via
`captureModeProvider.persistFor`, read by the pre-capture and capture screens,
and sent to the server as a capture mode. Polluting it would put a fake value
in all of those.

Instead introduce a small result type in the sheet's file:

```dart
sealed class ProjectCreationChoice { ... }
class CaptureChoice  extends ProjectCreationChoice { final CaptureMode mode; }
class UploadChoice   extends ProjectCreationChoice { const UploadChoice(); }
```

and change the sheet to resolve to `ProjectCreationChoice?`. `null` still means
"dismissed — navigate nowhere", which the existing caller comment at line 553
is explicit about. Only `CaptureChoice` calls
`captureModeProvider.notifier.select(...)`.

Gating on the new card, both enforced here:

- **Staff-only**: visible only when `isStaffProvider` is true. It is
  fail-closed by default (AGENTS.md), and the backend re-checks the role on
  every request — the client gate is UX, never the security boundary.
- **Web**: rendered **disabled with a visible reason** ("Uploading from a
  browser isn't available yet") until the raw-bucket CORS policy lands. Use a
  single named constant for the flag so switching it on is a one-line change.

Reuse `selectable_option_card.dart`. Match the existing cards' subtitle style —
"Up to 48 photos from your gallery."

### 2.3 Create Project screen — `create_project_screen.dart`

Currently takes `CaptureMode` via `extra` and always renders `OBJECT SIZE`
(line 207) and `CAPTURE MODE` (line 216).

Take `ProjectCreationChoice` instead and branch:

| | Capture (unchanged) | Upload |
|---|---|---|
| NAME | shown | shown |
| CATEGORY | shown | shown |
| OBJECT SIZE | shown | **hidden** |
| CAPTURE MODE | shown | **hidden** |
| PHOTOS | — | **new section** |
| Primary CTA | "Start Capture" | **"Upload"** |
| On submit | today's path | §2.5 |

The upload branch **skips** `captureModeProvider.persistFor` (line 126),
`saveObjectSize` (line 137) and the `ActiveSession` write (line 150). Those
three exist purely to hand the capture flow its context; an upload project never
enters that flow, and a stale `ActiveSession` would send a later resume into a
capture screen for a project with no rings. Read lines 120–165 before you edit —
the comment at line 143 explains why the `ActiveSession` write exists.

The CTA is **disabled until** the name is valid **and**
`photoCount >= PROJECT_PHOTO_MIN_COUNT`. Show the count on it
("Upload 12 photos") so the artist sees what they are about to send.

### 2.4 Picker — new `lib/data/datasources/project_photo_picker.dart`

`image_picker: ^1.1.2` is already a dependency (`pubspec.yaml:44`) and exposes
`pickMultiImage`. Use it — **do not add `file_picker`** or any image-processing
package.

Per picked file:

- **Sniff the content type from magic bytes**, never from the file extension or
  the OS-reported MIME. `avatar_image_picker.dart:150` already has a private
  `_sniffContentType`. **Extract it** to a new
  `lib/utils/image_content_type.dart` and re-point the avatar picker at it,
  rather than landing a second copy. (Design doc 08 also names
  `product_image_picker.dart` as a third copy — **that file does not exist in
  this tree**. Extract from the one real copy and move on.)
- Accept `image/jpeg`, `image/png`, `image/webp`. Anything else is dropped with
  a per-file reason surfaced to the user — never silently.
- Enforce `PROJECT_PHOTO_MAX_BYTES` per file and `PROJECT_PHOTO_MAX_COUNT`
  total, client-side, so the artist finds out at pick time rather than after a
  minute of uploading. The server enforces both again; the client check is UX.
- Return a list carrying `{ path?, bytes?, size, contentType }` — `path` on
  native, `bytes` on web. **Never read all 48 files into memory on native.**

### 2.5 Upload orchestrator — new `lib/application/upload/photo_set_upload_flow.dart`

A **thin** orchestrator. It must not touch `capture_bundle_packer.dart` or
`capture_manifest_assembler.dart`, and must not import `upload_flow.dart`.

```
1. POST /projects                     (source: 'upload', name, category)  → projectId
2. POST /projects/:id/photos/session  ({files:[{contentType,size}]})      → jobId, keys, plan
3. build UploadSessionSpec            (picked file  ×  server key  ×  size, same order)
4. ResilientUploadRunner over ChunkedUploadManager
      → JobsMultipartUploadApi(jobId) → DioS3PartClient
5. POST /projects/:id/photos/commit   ({jobId})
```

Notes that are not optional:

- Step 3 pairs by **index**. The session response's `files` array is in request
  order — assert the lengths match and fail loudly if they do not, rather than
  uploading photo N's bytes to photo M's key.
- Progress comes from the engine's existing `UploadProgressSource`. Reuse
  `upload_progress_provider.dart`'s reporting rather than inventing a second
  progress shape.
- Steps 1 and 2 are separate calls, so a crash between them leaves an empty
  `DRAFT` project (D7). Acceptable. A crash between 2 and 5 leaves orphaned
  objects under an uncommitted job — also acceptable at this scale (risk 4),
  purged with the project's hard delete. **Do not build a reaper for this now**;
  say if you think it is needed.
- The **whole flow is resumable at step 4 only**, because that is where the
  existing engine's resume lives. Do not add a second resume mechanism.

### 2.6 The one new engine seam — bytes-backed `PartByteSource`

`UploadFileSpec.path` (`lib/domain/upload/upload_session_spec.dart`) is a
device-absolute path streamed from disk by `FilePartByteSource`. A
browser-picked file has no path.

`ChunkedUploadManager` **already** takes an injectable `PartByteSource`
(`chunked_upload_manager.dart:52`, defaulting to `const FilePartByteSource()`),
so a bytes-backed implementation slots in **with no engine change**. Add
`lib/application/upload/bytes_part_byte_source.dart` with the repo's usual
`_io` / `_web` / `_stub` conditional-import split (mirror
`model_viewer_load_probe*.dart`).

**Native keeps `FilePartByteSource`** so 48 photos never sit in RAM at once.
Only the web build uses the bytes source. If honouring that means widening
`UploadFileSpec` (e.g. making `path` nullable and adding a bytes handle), keep
the change minimal and **update every existing construction site** — it is a
pure-Dart domain type with no Flutter/IO imports, and it must stay that way.

### 2.7 State + screen

- `lib/application/projects/project_photos_notifier.dart` — a plain state
  machine: `idle → picking → creating → uploading(progress) → committing →
  ready | failed(reason)`. Pure state; all HTTP goes through the repository.
- `lib/data/repositories/project_photos_repository.dart` — the four photo
  routes plus generate. Owns error translation into the app's existing failure
  types; no envelope parsing leaks into the notifier.
- `lib/presentation/screens/projects/project_photos_screen.dart` — the grid of
  presigned thumbnails, multi-select with a **3–4** bound enforced in the UI,
  a delete affordance, and a **Generate 3D model** CTA. Route it to the
  **existing** model screens on success — `model_generation_screen.dart` /
  `model_building_screen.dart` — do not build new ones.

### 2.8 Entry points into the photos screen

- `lib/app/routes/app_router.dart` — add `AppRoutes.projectPhotos` +
  `AppRouteNames.projectPhotos` beside the existing entries (line ~219 pattern).
  If `lib/app/routes/flow_back.dart` carries a back mapping per route, add one —
  check before assuming.
- `lib/presentation/widgets/project_card.dart` — when
  `project.source == ProjectSource.upload`, the primary action opens the photos
  screen, **never** pre-capture.
- `lib/presentation/widgets/project_options_sheet.dart` — same branch.
- The staff Live-projects view and every model/viewer surface are **unchanged**.
  If you find yourself editing them, you have gone outside the scope.

### 2.9 The gotcha: project creation goes through the offline outbox

`projects_notifier.dart:92–120` creates a project **optimistically with a
temporary local id** and enqueues a durable `OfflineActionType.createProject`
(`offline_queue_notifier.dart:136`) when offline. Read that code.

The upload path **cannot** use it: step 2 needs the **real server project id**,
and a temporary local id would produce a 404 or, worse, a key prefix built from
a fake id.

So: the upload flow calls the repository's create **directly**, online-only, and
surfaces a plain "You need to be online to upload photos" when the connectivity
abstraction reports offline. Do **not** enqueue it, and do **not** let an upload
project appear in the Hub with `isPending: true`.

---

## Part 3 — Tests

### Backend (`cd recapture-api`) — `npm run type-check && npm run lint && npm test`

New Vitest suites follow the existing per-file `MongoMemoryServer` pattern.
S3 is faked via `vi.spyOn(s3Client, 'send')` and Meshy via `setMeshyClient` —
**CI never calls a live API** (AGENTS.md). Read `tests/auth-me-avatar.test.ts`
and `tests/jobs-upload-urls.test.ts` for the house shape.

| Suite | Must prove |
|---|---|
| `photo-upload-session.test.ts` | `USER` → 403, `MODEL_ARTIST` → 201, `ADMIN` → 201 (inclusive-upward). Count bounds at `MIN-1`, `MIN`, `MAX`, `MAX+1`. `Idempotency-Key` replays vs conflicts. Another user's project is an **identical 404** to a nonexistent one. A `source: 'capture'` project → 409 |
| `photo-upload-transfer.test.ts` | **The regression that matters.** A job-relative key `uploads/photo_0001.jpg` passes the existing, **unmodified** `/jobs/:jobId/uploads/initiate` guard; a key outside the job prefix is still a 400; another user's job is still rejected |
| `photo-upload-commit.test.ts` | An over-cap object is a **413 and is deleted**. The state flip is conditional and race-safe (fire two commits concurrently). A second commit replays without re-listing. `stats.totalPhotos` gets the verified count. The job **never** reaches `QUEUED` |
| `photo-upload-generate.test.ts` | The 3–4 bound holds. A `jobId` belonging to another project resolves to null → 404. A `PHOTO_UPLOAD` job still in `CREATED` is **not** a valid source. The rate window and idempotency guard still apply |
| `photo-upload-guardrail.test.ts` | **`findExportableJob` and `buildProjectExport` still ignore `PHOTO_UPLOAD` jobs**, so export, the preview gallery and photo soft-delete are provably unchanged for capture projects. Also: `adminDeleteProject` purges the upload job's objects from **both** buckets |
| existing suites | `npm test` stays green. `jobs-create.test.ts`, `jobs-finalize.test.ts` and `project-status-lifecycle.test.ts` must not need edits — if one does, the conditional-required change went too far |

### Client — `flutter analyze && flutter test`

- picker: magic-byte sniff, rejected type, per-file byte cap, total count cap
- `image_content_type.dart`: the extracted sniffer, plus the avatar picker still
  passing its existing tests after re-pointing
- `UploadSessionSpec` built from picked files pairs key↔file by index, and
  throws on a length mismatch
- `project_photos_notifier` state machine, including the failure branches
- `BytesPartByteSource` range reads (first part, last short part, single-part
  file)
- `Project.fromMap` / `toMap` round-trips `source`, and an absent `source`
  defaults to `capture`
- a create-project widget test asserting the route branches on the choice: an
  `UploadChoice` renders no OBJECT SIZE / CAPTURE MODE section and an "Upload"
  CTA

### End-to-end

Grant the role with `recapture-api/scripts/set-user-role.ts`, then drive the app
with the **`run-recapture`** skill: create an *Upload* project → pick ~10 photos
→ watch multipart progress → commit → gallery renders → select 4 → Generate →
poll to `SUCCEEDED` → open the viewer. **Run it on a device build first.**

The web leg is only meaningful **after** the raw-bucket CORS policy is applied.
Before that the presigned PUTs fail preflight — that is the **expected result,
not a bug**.

---

## Files to touch

**New — backend**
```
src/services/projectPhotosService.ts        session / commit / list / delete
src/validation/projectPhotoSchemas.ts
tests/photo-upload-session.test.ts
tests/photo-upload-transfer.test.ts
tests/photo-upload-commit.test.ts
tests/photo-upload-generate.test.ts
tests/photo-upload-guardrail.test.ts
```

**Modified — backend**
```
src/models/Project.ts               + source; objectSize/mode conditionally required
src/models/types/job.types.ts       + PHOTO_UPLOAD_JOB_TYPE
src/utils/s3Keys.ts                 + UPLOADED_PHOTOS_KEY_PREFIX, build/is helpers
src/routes/projects.ts              + 5 photo routes (requireRole PER-ROUTE)
src/services/projectsService.ts     toProjectListItem + source; createProject accepts it
src/services/adminProjectsService.ts + PHOTO_UPLOAD_SOURCE_JOB_STATES, findModelSourceJobById
src/services/projectModelsService.ts explicit-jobId branch → findModelSourceJobById
src/services/onDemandModelGenerationService.ts  refuse source:'upload'
src/routes/admin.ts                 /model/auto refuses source:'upload'
src/validation/projectSchemas.ts    createProjectSchema + source + superRefine
src/validation/analyticsSchemas.ts  + 3 events
src/config/env.ts + .env.example    6 new vars (added together)
```

**New — client**
```
lib/domain/entities/project_source.dart
lib/utils/image_content_type.dart                   extracted sniffer
lib/data/datasources/project_photo_picker.dart
lib/data/repositories/project_photos_repository.dart
lib/application/upload/photo_set_upload_flow.dart
lib/application/upload/bytes_part_byte_source.dart  (+ _io / _web / _stub)
lib/application/projects/project_photos_notifier.dart
lib/presentation/screens/projects/project_photos_screen.dart
```

**Modified — client**
```
lib/domain/entities/project.dart                  + source (hand-synced with the DTO)
lib/data/datasources/avatar_image_picker.dart     re-point at the extracted sniffer
lib/presentation/screens/projects/capture_mode_sheet.dart   3rd card, new result type
lib/presentation/screens/projects/projects_screen.dart      _onCreateProject branches
lib/presentation/screens/projects/create_project_screen.dart PHOTOS section, staff-gated
lib/app/routes/app_router.dart                    + projectPhotos path + name
lib/presentation/widgets/project_card.dart        upload-source action → photos screen
lib/presentation/widgets/project_options_sheet.dart  same
```

**Reuse rather than re-derive:** `utils/rateLimit.ts::consumeRateWindow`,
`utils/analytics.ts::track`, `utils/otp.ts::hashIdentifier`,
`isContainedRelativeKey`, `s3ObjectStore.ts`'s primitives, and
`selectable_option_card.dart`.

**Docs — in the same change**, per AGENTS.md's own rule: the `uploads/`
namespace beside `deleted/` and `model-input/`, the `PHOTO_UPLOAD` job type and
why it never queues, `Project.source`, and the auto-selection refusal. Add the
raw-bucket CORS decision to `AGENTS.md` **and** `docs/aws-storage-and-cdn.md`
only when the policy is actually applied.

---

## Out of scope — do not build, do not leave TODOs promising them

- A grant UI or endpoint for `MODEL_ARTIST` — it is a DB flag, by decision
- Any change to `POST /jobs`, `POST /jobs/:jobId/finalize`, the capture bundle
  packer, the manifest assembler, or `reconstructionEngine.ts`
- A worker processor for `PHOTO_UPLOAD`
- Auto photo-selection for uploaded sets
- Adding photos to an existing **capture** project (risk 5 — this plan assumes
  the UI does not offer it)
- A bytes-proxy route for photos (the avatar precedent explicitly does not
  extend here)
- An orphan-object reaper for abandoned sessions
- The raw-bucket CORS policy itself — separate infra task; ship the native leg
  first with the web option disabled

---

## Definition of done

1. `cd recapture-api && npm run type-check && npm run lint && npm test` — all
   clean, including the five new suites and every pre-existing one.
2. `flutter analyze && flutter test` — clean, including the new client tests.
3. A `MODEL_ARTIST` on a **device build** can go `+` → Upload photos → name it →
   pick 10 → Upload → see the gallery → select 4 → Generate → open the finished
   model in the viewer.
4. A plain `USER` sees no Upload card, and gets a `403` from every new route if
   they call it directly.
5. A capture project created before this change still lists, captures, uploads,
   finalizes, exports, generates, optimizes and deletes exactly as before —
   proven by the guardrail suite, not by inspection.
6. `AGENTS.md` updated in the same change.

## Tell me before you start if

- `loadUploadableJob` turns out to reject `uploads/…` keys after all — the whole
  "zero transport changes" claim rests on it
- Making `objectSize`/`mode` conditionally required forces edits to existing
  tests or services beyond `createProject` — that would mean something reads
  them unconditionally and my read was wrong
- `Job.upload.manifestKey` is non-optional in the schema and a `PHOTO_UPLOAD`
  job cannot be created without one
- Honouring web needs a wider change to `UploadFileSpec` than making `path`
  nullable
- You think the 48-photo cap, the 15 MiB per-photo cap, or hiding OBJECT SIZE /
  CAPTURE MODE on the upload form is the wrong call — those three are the ones
  the product owner and design doc 08 disagreed on, and they are cheap to flip
  now and expensive to flip later
