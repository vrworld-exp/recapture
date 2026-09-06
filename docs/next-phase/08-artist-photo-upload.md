# 08 — Artist Photo-Upload Projects

Architecture plan for letting a **MODEL_ARTIST** create a project and upload an existing photo set
from local storage, instead of walking around an object with the guided capture flow. The artist
then explicitly asks for a 3D model from the photos they uploaded.

Every convention here defers to `ReCapture/AGENTS.md`. Where this document adds something new, it
says so explicitly and gives the reason. Written as a plan, not a task breakdown — see
`04-task-breakdown.md` for the format that work items take once this is agreed.

---

## Context

Today a project can get its photos exactly one way: the guided camera flow (`CaptureMode.full`,
48 shots, or `CaptureMode.meshy`, one EYE ring of 6), packed into a bundle with a
`capture_manifest.json`, uploaded via presigned multipart, and finalized against a manifest the
server validates ring-by-ring.

An artist working from a photo shoot has no way in. They already have the images on disk. They
should be able to name a project, upload that set, and press **Generate 3D model**.

### What already exists — do not rebuild

The capture upload pipeline is layered, and only the *top* layer is capture-shaped. Everything
below it is reusable **unchanged**:

| Layer | Where | Capture-specific? |
|---|---|---|
| Orchestrator (pack bundle, build manifest, capture context) | `lib/application/upload/upload_flow.dart` | **Yes — bypass this** |
| Session input `{path, key, size}` | `lib/domain/upload/upload_session_spec.dart` | No |
| Chunked engine (parts, retry, resume, progress) | `lib/application/upload/chunked_upload_manager.dart` | No |
| Session retry / backoff | `lib/application/upload/resilient_upload_runner.dart` | No |
| `/jobs/:jobId/uploads/*` adapter | `lib/application/upload/jobs_multipart_upload_api.dart` | No — job-scoped only |
| Interceptor-free S3 PUT client | `DioS3PartClient`, `lib/application/upload/multipart_upload_api.dart:146` | No |
| Meshy submit → poll → re-host | `src/worker/processors/meshyModelProcessor.ts` | No — resolves `${rawPrefix}${selectedKey}` |
| Presign / list / head / move / prefix-delete | `src/services/s3ObjectStore.ts` | No |

### The finding that shapes this whole plan

`loadUploadableJob` (`src/services/jobsService.ts:734`) is the guard behind `initiate`,
`part-url` and `complete`. It checks *owned job → state `CREATED`/`UPLOADING` → plan window open →
key contained under `rawPrefix`*. It applies **no `jobType` filter**, and its ring/level check
fires only when the job-relative key begins with `images/`.

A relative key of `uploads/photo_0001.jpg` therefore passes it **today, unmodified**.

> **`POST /jobs/:jobId/uploads/{initiate,part-url,complete}` needs zero changes.** The artist
> photo set moves over the identical presigned-multipart transport the capture flow uses, with
> the identical resume, retry and progress behaviour.

### What is genuinely not reusable, and why

| | Why |
|---|---|
| `POST /jobs` | Demands `objectSize` + `captureVariant` + `expectedFilesCount` inside the shape matrix (`src/models/types/captureVariants.ts`). An artist set has no rings. → new session route |
| `POST /jobs/:jobId/finalize` | Requires `capture_manifest.json` to exist and validates its content ring-by-ring. → new commit route |
| `autoPhotoSelectionService` | Selects photos by reading blur and yaw **out of the manifest**. An uploaded set has none, so **auto-selection is unavailable** — the artist picks 3–4 by hand, and `POST /projects/:id/model` (owner auto-generate) must never be pointed at an upload project |

---

## Decisions taken

Confirmed with the product owner before this plan was written.

| # | Decision |
|---|---|
| D1 | The existing `MODEL_ARTIST` role — no new rank, no migration, no grant UI |
| D2 | Upload and generation are **two explicit steps**; pressing Generate is what spends credits |
| D3 | Up to ~50 photos per project |
| D4 | Mobile **and** web |
| D5 | The **same presigned direct-to-S3 multipart transport** the capture flow already uses |
| D6 | Photo source is a property of the **project** (`Project.source`), not a new `ProjectStatus` |

---

## Known constraint — web needs a CORS policy on the raw bucket

The capture flow is native-only, so it never hit this. Both S3 buckets deliberately serve **no
CORS policy** (`docs/aws-storage-and-cdn.md:124`), which is why the avatar and product-image
features proxy bytes through the API instead — and `src/routes/auth.ts:280` states in so many
words that that reasoning *"does NOT extend to capture uploads, which must stay direct-to-S3."*
A 50-photo artist set is capture-sized, not avatar-sized, so it stays direct-to-S3.

A browser cannot PUT to a presigned URL until `msxr-raw-captures` carries a CORS policy.
`docs/aws-storage-and-cdn.md:568` already anticipates exactly this step. Scope it narrowly:

| Field | Value |
|---|---|
| `AllowedOrigins` | the app's web origins only — **never** `*` |
| `AllowedMethods` | `PUT`, `GET` |
| `AllowedHeaders` | `content-type` |
| `ExposeHeaders` | `ETag` — the engine reads it off every part response |

**Build order:** the feature ships working on Android/iOS the day it lands; the bucket policy is a
separate one-line infra task that switches web on. Until it is applied the web build shows the
upload option disabled. Record the change in `docs/aws-storage-and-cdn.md` and `AGENTS.md` when it
happens — it reverses a documented decision and must not be a silent console edit.

---

## Part 1 — Data model

### `Project.source` — a new field, not a new status

`src/models/Project.ts` gains `source: 'capture' | 'upload'` with a schema default of `'capture'`,
so pre-existing documents read correctly with no migration — the same pattern `User.role`,
`Job.captureVariant` and `Job.captureMode` already use.

`objectSize` and `mode` become **conditionally required**, the exact idiom `Job.projectId` already
uses (`src/models/Job.ts:311`):

```ts
objectSize: {
  type: String,
  enum: ['SMALL', 'MEDIUM', 'LARGE'],
  required(this: IProject) { return this.source !== 'upload'; },
}
```

Storing a placeholder `MEDIUM`/`MANUAL` on an upload project would be a lie that later reads act
on — the size preset drives camera-distance guidance that an uploaded set never receives.

Deliberately **no new `ProjectStatus` value.** An upload project stays `DRAFT` until it has a
model; the client branches on `source`, not on status, to decide what a card's primary action
does. Adding a status would touch the schema enum, the admin `?status=` filter and the client's
label/colour/action tables for no gain.

`source` ships on `ProjectListItem` through `toProjectListItem` (`src/services/projectsService.ts:339`)
— the ONE Project DTO mapper — and is hand-synced onto the Flutter `Project` entity, since the DTO
is identical across `GET /projects`, `POST /projects` and the entity by contract (AGENTS.md §0.1, §4).

### `PHOTO_UPLOAD` job type

`src/models/types/job.types.ts` gains `PHOTO_UPLOAD_JOB_TYPE = 'PHOTO_UPLOAD'`.

State path: `CREATED` → `UPLOADING` (flipped by the existing `initiate`) → `UPLOADED`.

**It never enters `QUEUED`, so the worker never claims it** — `claimNextJob`
(`src/worker/jobQueue.ts:37`) filters on `state: 'QUEUED'` alone, jobType-agnostically. No
processor is registered for this type, and none should be: there is nothing to process, only
photos to hold.

The job carries an ordinary `upload` block, which means the hard-delete prefix sweep in
`adminDeleteProject` (`src/services/adminProjectsService.ts:434`) purges its objects from **both**
buckets for free — that loop iterates every job with an `upload` block and needs no change.

### Key namespace

Reuse `buildJobKeyPrefix`. The job id makes the prefix unique, so an upload job and a capture job
on the same project can never collide. Add to `src/utils/s3Keys.ts` — the one builder and parser
for this key space; an inline template anywhere else is a bug:

```
{env}/{projectSlug}_{projectId}/{jobId}/uploads/photo_{nnnn}.{jpg|png|webp}
```

- `export const UPLOADED_PHOTOS_KEY_PREFIX = 'uploads/'` — a sibling of `deleted/` and
  `model-input/`
- `buildUploadedPhotoKey(scope, index, ext)` and `isUploadedPhotoRelativeKey(relative)`

Keys are **server-assigned**, never client-named, so extension and charset stay controlled.

No exclusion is needed in `buildProjectExport`. `model-input/` needs one because it shares a
*capture* job's prefix; an upload job is its own prefix, and `findExportableJob` never resolves to
it.

---

## Part 2 — API surface

New routes live in `src/routes/projects.ts`, **not** `/admin`: an artist uploads into their **own**
project, so ownership is proven by `getProject(userId, id)` exactly as every other route in that
router does, and missing / not-owned / soft-deleted collapse into one identical 404.

`requireRole('MODEL_ARTIST')` is applied **per-route**, never router-level — the existing owner
routes must stay open to `USER`.

| Route | Does |
|---|---|
| `POST /projects/:id/photos/session` | Body `{ files: [{ contentType, size }] }`, 1–`PROJECT_PHOTO_MAX_COUNT`. Creates the `PHOTO_UPLOAD` job and returns the server-assigned relative keys plus the same `uploadPlan` shape `POST /jobs` returns. Honours `Idempotency-Key` — the unique partial index on `(userId, idempotencyKey)` already exists on `Job` |
| *(transfer)* | **Existing, unchanged** `POST /jobs/:jobId/uploads/{initiate,part-url,complete}` |
| `POST /projects/:id/photos/commit` | Body `{ jobId }`. Lists `{rawPrefix}uploads/`, enforces `PROJECT_PHOTO_MAX_BYTES` per object — deleting an over-cap object, the same stance the avatar and product-image commits take, because presigning cannot enforce a size — writes `upload.uploadedFilesCount`, and flips `CREATED`/`UPLOADING` → `UPLOADED` with a conditional `findOneAndUpdate`. Idempotent once `UPLOADED` |
| `GET /projects/:id/photos` | The newest `PHOTO_UPLOAD` job's objects with presigned GETs, mirroring `buildProjectExport`'s list-then-presign shape. A presigned URL is a bearer credential: it may appear in this body and nowhere else — never in logs or analytics |
| `DELETE /projects/:id/photos` | Body `{ keys }`. Moves them into the job's `deleted/` namespace via `moveObject`, gated by `isContainedRelativeKey` **and** `isUploadedPhotoRelativeKey`. Fail-closed: one escaping key refuses the whole request and moves nothing |
| `POST /projects/:id/photos/generate` | Body `{ keys: [3–4] }` → `createMeshyModelRequest({ projectId, keys, actor, jobId, idempotencyKey })`. Keeps the existing `meshy-create:{userId}` rate window and the `Idempotency-Key` replay guard — this is the step that spends credits |

### One surgical widening in the generation path

`createMeshyModelRequest` (`src/services/projectModelsService.ts:491`) resolves its source job two
ways: `findExportableJobById` when an explicit `jobId` is passed, `findExportableJob` otherwise.
The artist path **always** passes an explicit `jobId`, so only the first branch is touched.

Add to `src/services/adminProjectsService.ts`:

```ts
export const PHOTO_UPLOAD_SOURCE_JOB_STATES = ['UPLOADED'] as const;
export async function findModelSourceJobById(projectId, jobId): Promise<IJob | null>;
```

matching `(CAPTURE_PROCESSING | null, UPLOAD_FINALIZED_JOB_STATES)` **or**
`(PHOTO_UPLOAD, ['UPLOADED'])` — an explicit list of allowed pairs, never a removed filter.
AGENTS.md calls the `jobType` filter load-bearing and it stays that way: `findExportableJob` and
`findExportableJobById` are untouched, so export, the preview gallery and photo soft-delete keep
ignoring `PHOTO_UPLOAD` jobs entirely.

---

## Part 3 — Client

The artist picks a photo source on the Create Project form. Choosing **Upload from device** hides
OBJECT SIZE and CAPTURE MODE — both are capture concepts — and routes to the photo screen instead
of the pre-capture checklist, skipping the `captureModeProvider.persistFor`, `saveObjectSize` and
`ActiveSession` writes that exist purely to hand the capture flow its context.

The upload itself builds an `UploadSessionSpec` from the picked files plus the server-assigned
keys and runs the **existing** `ResilientUploadRunner` over `ChunkedUploadManager`, against
`JobsMultipartUploadApi` and `DioS3PartClient`. It never touches the bundle packer or the manifest
assembler.

**Web needs one new seam.** `UploadFileSpec.path` is a device-absolute path streamed from disk by
`FilePartByteSource`; a browser-picked file has no path. `ChunkedUploadManager` already takes an
injectable `PartByteSource`, so a bytes-backed implementation slots in with no engine change.
Native keeps `FilePartByteSource` so 50 photos never sit in RAM at once.

---

## Files to touch

**New — backend**

```
src/services/projectPhotosService.ts     ← session / commit / list / delete
src/validation/projectPhotoSchemas.ts
```

**Modified — backend**

```
src/models/Project.ts                    + source; objectSize/mode conditionally required
src/models/types/job.types.ts            + PHOTO_UPLOAD_JOB_TYPE
src/utils/s3Keys.ts                      + UPLOADED_PHOTOS_KEY_PREFIX, build/is helpers
src/routes/projects.ts                   + 5 photo routes (requireRole per-route)
src/services/projectsService.ts          toProjectListItem + source; createProject accepts it
src/services/adminProjectsService.ts     + PHOTO_UPLOAD_SOURCE_JOB_STATES, findModelSourceJobById
src/services/projectModelsService.ts     explicit-jobId branch → findModelSourceJobById
src/validation/projectSchemas.ts         createProjectSchema + source, superRefine
src/validation/analyticsSchemas.ts       + 3 events (EVENT_SCHEMAS is exhaustive by `satisfies`)
src/config/env.ts + .env.example         PROJECT_PHOTO_MAX_COUNT (50), _MAX_BYTES (15 MiB),
                                         _URL_TTL_SECONDS (3600),
                                         _UPLOAD_MAX_PER_WINDOW/_WINDOW_SECONDS  (add together)
```

**New — client**

```
lib/domain/entities/project_source.dart           ProjectSource {capture, upload}
lib/utils/image_content_type.dart                 extracted magic-byte sniffer (see below)
lib/data/datasources/project_photo_picker.dart    pickMultiImage + sniff + caps
lib/data/repositories/project_photos_repository.dart
lib/application/upload/photo_set_upload_flow.dart thin orchestrator over the existing engine
lib/application/upload/bytes_part_byte_source.dart (+ _io/_web/_stub split)
lib/application/projects/project_photos_notifier.dart
lib/presentation/screens/projects/project_photos_screen.dart
```

**Modified — client**

```
lib/domain/entities/project.dart                  + source (hand-synced with the DTO)
lib/presentation/screens/projects/create_project_screen.dart   PHOTOS section, staff-gated
lib/app/routes/app_router.dart                    + projectPhotos path + name
lib/presentation/widgets/project_card.dart        upload-source action → photos screen
lib/presentation/widgets/project_options_sheet.dart   same
```

Reuse rather than re-derive: `utils/rateLimit.ts::consumeRateWindow` for the new limiter,
`utils/analytics.ts::trackEvent` plus a schema entry, `utils/otp.ts::hashIdentifier` for any
hashed identifier, `isContainedRelativeKey` for every caller-supplied key, and
`selectable_option_card.dart` for the new picker cards.

One deliberate tidy-up: `sniffContentType` is currently duplicated between
`avatar_image_picker.dart` and `product_image_picker.dart:164`. Extract it to
`lib/utils/image_content_type.dart` and re-point both, rather than landing a third copy.

---

## Risks and open items

1. **Web is blocked on the raw-bucket CORS policy** (above). Native ships first; do not let the
   web leg silently ship half-working. Gate the option on a platform check until the policy is
   live.
2. **Auto photo-selection does not work on uploaded sets** — the selector reads blur and yaw out
   of the capture manifest. `POST /projects/:id/model` and `/admin/projects/:id/model/auto` must
   refuse an upload project rather than decline confusingly; pick the error copy deliberately.
3. **`PROJECT_PHOTO_MAX_BYTES` at 15 MiB × 50** is a 750 MiB project ceiling in the raw bucket.
   That is a storage-cost decision, not just a validation constant — confirm the number before
   launch, and confirm the raw bucket's `AbortIncompleteMultipartUpload` lifecycle rule exists
   (the abandoned-upload reaper the whole multipart path relies on).
4. **An abandoned session leaves orphaned objects** under a `PHOTO_UPLOAD` job that never commits.
   They are purged with the project's hard delete, but nothing collects them sooner. Acceptable at
   this scale; revisit if artists abandon often.
5. **A project could hold both a capture job and an upload job.** The prefixes are disjoint so
   nothing corrupts, but `Project.source` then describes only how it *started*. Decide whether the
   UI offers "add photos" on a capture project at all — this plan assumes it does not.
6. **`Project.stats.totalPhotos`** is written by the capture finalize funnel and stays 0 for upload
   projects, so the Hub card reads "0 photos". Either write it at commit or leave the count off
   upload cards; do not leave it showing a wrong number.

---

## Verification

**Backend** (`cd recapture-api`) — `npm run type-check && npm run lint && npm test`. New vitest
suites follow the existing per-file `MongoMemoryServer` pattern, faking S3 via
`vi.spyOn(s3Client,'send')` and Meshy via `setMeshyClient` — CI never calls a live API.

- `photo-upload-session.test.ts` — `USER` gets 403 and `MODEL_ARTIST` 201; count bounds enforced;
  `Idempotency-Key` replays vs conflicts; another user's project is an identical 404.
- `photo-upload-transfer.test.ts` — **the regression that matters**: a `uploads/photo_0001.jpg`
  key passes the existing, unmodified `/jobs/:jobId/uploads/initiate` guard, and a key outside the
  job prefix is still a 400.
- `photo-upload-commit.test.ts` — an over-cap object is a 413 **and** is deleted; the state flip is
  conditional and race-safe; a second commit replays without re-verifying.
- `photo-upload-generate.test.ts` — the 3–4 bound holds; a `jobId` belonging to another project
  resolves to null → 404; a `PHOTO_UPLOAD` job still in `CREATED` is not a valid source.
- Guardrail — `findExportableJob` and `buildProjectExport` still ignore `PHOTO_UPLOAD` jobs, so
  export, the preview gallery and photo soft-delete are provably unchanged for capture projects.

**Client** — `flutter analyze && flutter test`: picker sniff and caps, `UploadSessionSpec` built
from picked files, the notifier's state machine, `BytesPartByteSource` range reads, and a
create-project test asserting the route branches on `ProjectSource`.

**End-to-end** — grant the role with `recapture-api/scripts/set-user-role.ts`, then drive the app
with the `run-recapture` skill: create an *Upload* project → pick ~10 photos → watch multipart
progress → commit → gallery renders → select 4 → Generate → poll to `SUCCEEDED` → open the viewer.
Run it on a device build first. The web leg is only meaningful after the raw-bucket CORS policy is
applied — before that the presigned PUTs fail preflight, which is the expected result, not a bug.

**Docs** — update `AGENTS.md` in the same change, per its own rule: the `uploads/` namespace beside
`deleted/` and `model-input/`, the `PHOTO_UPLOAD` job type and why it never queues, `Project.source`,
and the raw-bucket CORS decision if it is taken.
