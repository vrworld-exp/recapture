# Implementation Prompt — Meshy AI On-Demand Model Generation | ✅

> Hand this whole document to a coding agent (or use it as your own worklist).
> It is self-contained: context, exact files, signatures, tests, and a
> definition of done. Companion design doc:
> [`meshy-integration.md`](./meshy-integration.md). When anything here disagrees
> with `AGENTS.md`, **AGENTS.md wins**. This spans BOTH codebases — the
> Node/TS backend (`recapture-api/`) and the Flutter client (repo root).

---

## The decision (read first)

A **staff user** (ADMIN **or** MODEL_ARTIST) opens a project's **Preview
gallery**, **selects 3–4 captured photos**, and taps **Create Model**. That
kicks off **Meshy AI Multi-Image to 3D**. When Meshy finishes, we download the
model, store it on **our** S3 (`BUCKET_ARTIFACTS`), and persist a per-project
**model record** with the model URL and an **origin flag** (`source: 'meshy'`).
The project owner (and staff) can then **view the generated 3D model** in the
app, badged **"Created by Meshy AI."** If everyone is satisfied with the Meshy
result, no manual model creation is needed; if not, the existing backend path
remains available.

### What this is NOT

- **Not** an automatic/worker-driven replacement of the capture pipeline. The
  existing capture→finalize→processing pipeline (the in-house "backend/manual
  way", `stubReconstructionEngine` today) is **left untouched** and remains the
  fallback. Meshy generation is a **separate, human-triggered** flow.
- **Not** an automatic image picker — a human chooses the 3–4 images. (Meshy
  Multi-Image to 3D accepts exactly 1–4 images; we enforce **min 3, max 4**.)

### Flow end-to-end

1. Staff opens Preview gallery → multi-selects **3–4** photos → **Create Model**.
2. `POST /admin/projects/:id/model { keys: [...] }` validates and **enqueues a
   `MESHY_MODEL_GENERATION` worker job**; creates a `ProjectModel` record
   (`status: QUEUED`, `source: 'meshy'`) and returns it.
3. The worker claims the job: presigns GET URLs for the selected keys → submits
   to Meshy → polls to completion (lease-renewing) → downloads the GLB/USDZ/
   thumbnail → re-uploads to **our** S3 → updates the record to
   `SUCCEEDED` with our CloudFront URLs.
4. Client polls the record; on `SUCCEEDED` shows **View 3D Model** (rendered via
   `model_viewer_plus`) with the **Meshy** badge. Staff/owner can **approve** it.

---

## Existing pieces to REUSE (do not reinvent)

- **Roles** — [`src/models/User.ts`](../src/models/User.ts): `USER < MODEL_ARTIST
  < ADMIN`, compared via `hasRoleAtLeast`. "Artist" = `MODEL_ARTIST`. Gate the new
  staff endpoints with `requireRole('MODEL_ARTIST')` (ADMIN passes by
  inheritance) — see [`src/routes/admin.ts`](../src/routes/admin.ts).
- **The selected keys** — the client already holds them: `PreviewPhoto.key`
  ([`lib/domain/entities/preview_manifest.dart`]) is the **relative
  export-manifest key**, the exact shape the admin soft-delete endpoint accepts.
  Reuse its **containment validator** (`softDeleteProjectPhotos` /
  `adminProjectsService.ts`) so a key that escapes the job prefix is refused.
- **Async infra** — the worker supports multiple job types via
  `registerProcessor(jobType, processor)`
  ([`src/worker/index.ts`](../src/worker/index.ts)). Add a **new job type**;
  reuse the claim/lease/retry/resume machinery (do NOT block the API for the
  minutes Meshy takes, and do NOT hand-roll a new async system).
- **Meshy transport** — the `meshyClient` + status→error mapping specced in the
  companion doc [`meshy-integration.md`](./meshy-integration.md) §Meshy client.
- **Preview gallery** —
  [`lib/presentation/screens/projects/preview_gallery_screen.dart`] and
  [`lib/application/projects/preview_gallery_notifier.dart`]. Add selection +
  the CTA here; the screen is already staff-only.

---

## Non-negotiable contracts

1. **Additive & non-destructive** — do NOT modify or bypass the capture
   processing pipeline, `reconstructionEngine.ts`, finalize, or the automatic
   worker path. Meshy generation is a new, parallel job type.
2. **Idempotent / no double-charge** — Meshy generations cost credits. The
   create endpoint honors `Idempotency-Key`; the worker persists `meshyTaskId`
   on the `ProjectModel` record the instant the task is created and **resumes
   polling** an existing task on re-claim rather than resubmitting.
3. **`onProgress` = lease renewal** — the generation stage can outlast
   `WORKER_CLAIM_TIMEOUT_MS` (120 s). Poll-and-report on every tick or the job
   gets re-claimed mid-flight. `onProgress` throws on cancel/claim-loss — let it
   propagate.
4. **Error routing** — plain `Error` = retryable (429/5xx/network); Meshy
   `402`/quota, `400`/`422` bad input, and task-`FAILED` → `NonRetryableJobError`
   (terminal). A quota failure must NOT retry-burn credits.
5. **Never store Meshy URLs in the DB** — they expire. Download and re-host to
   `BUCKET_ARTIFACTS`; the record stores only our CloudFront URLs.
6. **Containment** — every caller-supplied key is validated to live under the
   project's job prefix before anything is presigned or fetched.
7. **Secrets & PII** — `MESHY_API_KEY` env-only, never logged; analytics carry
   **hashed** ids + counts only, never keys or presigned URLs (match existing
   admin routes).
8. **CI never hits the live Meshy/AWS APIs** — mock the transport and S3.

---

## Data model — `ProjectModel` (history, one record per generation)

**File (new):** `src/models/ProjectModel.ts` (+ types).

We keep **full history**: each Create-Model tap is its own record, so artists can
regenerate with different photos, compare, and **approve** the best one.

```ts
export type ModelSource = 'meshy' | 'manual';
export type ModelStatus = 'QUEUED' | 'PROCESSING' | 'SUCCEEDED' | 'FAILED';

interface ProjectModel {
  projectId: ObjectId;            // owning project (indexed)
  jobId: ObjectId;               // the source capture job the photos came from
  source: ModelSource;           // 'meshy' — the origin flag ("Created by Meshy AI")
  status: ModelStatus;
  selectedKeys: string[];        // 3–4 relative export-manifest keys chosen by staff
  meshyTaskId?: string;          // persisted for idempotent resume (never a URL)
  artifacts?: {                  // populated on SUCCEEDED (our keys/URLs only)
    glbKey: string; usdzKey?: string; previewImageKey?: string;
    cdnUrls: { glb: string; usdz?: string; preview?: string };
  };
  approved?: { at: Date; byUserId: ObjectId };   // the "we're satisfied" gate
  error?: { code: string; message: string };
  createdByUserId: ObjectId;     // the staff actor
  createdByRole: UserRole;       // MODEL_ARTIST | ADMIN (for audit)
  createdAt: Date; updatedAt: Date;
}
```

Index `{ projectId: 1, createdAt: -1 }`. `source: 'manual'` is reserved for the
future backend path so both origins coexist under one shape.

---

## Backend tasks

### T1 — Env config

[`src/config/env.ts`](../src/config/env.ts) (+ `.env.example`):

```ts
MESHY_API_KEY: z.string().min(1, 'MESHY_API_KEY is required'),
MESHY_BASE_URL: z.string().url().default('https://api.meshy.ai'),
MESHY_POLL_INTERVAL_MS: z.coerce.number().int().positive().default(5000), // << WORKER_CLAIM_TIMEOUT_MS
MESHY_TASK_TIMEOUT_MS: z.coerce.number().int().positive().default(600_000),
/** Presigned-GET TTL for the images handed to Meshy (s). */
MESHY_SOURCE_URL_TTL_SECONDS: z.coerce.number().int().positive().default(3600),
/** Create-Model rate cap per staff user. */
MESHY_CREATE_MAX_PER_WINDOW: z.coerce.number().int().positive().default(20),
MESHY_CREATE_WINDOW_SECONDS: z.coerce.number().int().positive().default(3600),
```

**Acceptance:** worker + API boot with these set; missing `MESHY_API_KEY` fails
fast with a clear message.

### T2 — `meshyClient` (transport only)

**File (new):** `src/worker/engine/meshy/meshyClient.ts`. Exactly as the
companion doc §Meshy client: `createMultiImageTask(imageUrls)` / `getTask(id)` /
optional `cancelTask(id)`; `Authorization: Bearer`; normalize Meshy's fields into
typed `MeshyTask`; **status → error-class mapping** per contract #4. Confirm the
live request/response shape against
[Multi-Image to 3D](https://docs.meshy.ai/en/api/multi-image-to-3d). Never log
the key or full image URLs. **Tests:** each HTTP status → correct error class,
mocked transport.

### T3 — `ProjectModel` model + service

**Files:** `src/models/ProjectModel.ts`, `src/services/projectModelsService.ts`.

Service functions (pure-ish, thin over Mongo):
- `createMeshyModelRequest({ projectId, keys, actor }) → ProjectModel | Outcome`
  — resolves the project's exportable job (reuse `adminProjectsService` helpers),
  validates **3 ≤ keys ≤ 4** and **containment** of every key under the job
  prefix, creates the record (`QUEUED`), returns it. Outcomes mirror the admin
  routes: `PROJECT_NOT_FOUND`, `NOT_EXPORTABLE`, `INVALID_KEY`, `INVALID_COUNT`.
- `listProjectModels(projectId)` — history, newest first.
- `approveModel(modelId, actor)` — sets `approved`; only a `SUCCEEDED` record.

### T4 — `POST /admin/projects/:id/model` (create)

Add to [`src/routes/admin.ts`](../src/routes/admin.ts) (router-level
`requireRole('MODEL_ARTIST')` already applies):

- Validate `:id` and body `{ keys: string[] }` (Zod: 3–4 non-empty strings).
- **Rate-limit** per staff user (`consumeRateWindow`, `MESHY_CREATE_*`) — each
  generation costs credits.
- **`Idempotency-Key`** header: if a record already exists for this
  (project, actor, key) within a short window, return it instead of enqueuing a
  second job (no double charge on a double-tap).
- Call `createMeshyModelRequest(...)`; map outcomes to the standard envelope
  (`404` / `409 NOT_EXPORTABLE` / `400 INVALID_REQUEST` — never echo the
  offending key, per the existing soft-delete route).
- **Enqueue** a `MESHY_MODEL_GENERATION` Job carrying `{ modelId, projectId,
  jobId, selectedKeys }` (state `QUEUED`).
- `track(...)` with **hashed** ids + `key_count` only.
- `201` with the `ProjectModel` record.

Also add **`GET /admin/projects/:id/models`** (list history) and include the
latest `SUCCEEDED` model in `GET /admin/projects/:id` detail.

### T5 — Worker processor `MESHY_MODEL_GENERATION`

**Files:** `src/worker/processors/meshyModelProcessor.ts`, register it in
[`src/worker/index.ts`](../src/worker/index.ts) via `registerProcessor`.

Processing (single logical stage; reuse the lease/progress helpers):
1. Load the `ProjectModel` by `modelId`; flip → `PROCESSING`.
2. **Resume guard:** if `record.meshyTaskId` exists, skip submission and resume
   polling it.
3. Otherwise resolve `selectedKeys` → absolute S3 keys under the job's
   `rawPrefix` (same resolution the soft-delete/export path uses) → presign
   short-lived GET URLs (`MESHY_SOURCE_URL_TTL_SECONDS`) →
   `createMultiImageTask(urls)` → **persist `meshyTaskId` on the record
   immediately**.
4. Poll every `MESHY_POLL_INTERVAL_MS` until terminal or `MESHY_TASK_TIMEOUT_MS`;
   renew the lease each tick (contract #3). `FAILED` → `NonRetryableJobError`;
   timeout → plain `Error`.
5. Download the GLB/USDZ/thumbnail (they expire), `PutObject` into
   `BUCKET_ARTIFACTS` under deterministic per-model keys
   (`{env}/{projectSlug}_{projectId}/{jobId}/models/{modelId}/model.glb`, etc. —
   overwrite = idempotent).
6. Update the record → `SUCCEEDED` with `artifacts` (our keys + `CLOUDFRONT_BASE`
   URLs). On any thrown terminal error, set `status: FAILED` + `error`.

**Tests** (fake `meshyClient` + mocked S3): happy path; **resume-with-existing-
`meshyTaskId` asserts no second `createMultiImageTask`**; `402`/task-FAILED →
record `FAILED` (terminal); `429`/`5xx` → retry; artifacts carry CloudFront
(never Meshy) URLs.

### T6 — Owner-facing surface + approval

- Surface the latest `SUCCEEDED` model (URL + `source` flag + `approved`) on the
  **owner** project detail (`GET /projects/:id`) so the user's app can show it.
  Owner sees only their own project's model; keys/presigned URLs never leak
  (serve the CloudFront URL).
- **`POST /admin/projects/:id/models/:modelId/approve`** → `approveModel`.

---

## Client tasks (Flutter)

### C1 — Multi-select + Create Model CTA (Preview gallery)

In [`preview_gallery_screen.dart`] / [`preview_gallery_notifier.dart`]:
- Add a **selection mode**: tap-to-select tiles, tracked as a `Set<String>` of
  `PreviewPhoto.key`. Show a selected count and a checkmark overlay on tiles.
- A **Create Model** bottom CTA, **enabled only when `3 ≤ selected ≤ 4`** (mirror
  the backend rule; show a hint otherwise). Staff-only screen already, but gate
  the CTA on `isStaffProvider` (MODEL_ARTIST+) to be safe.
- On tap → `POST /admin/projects/:id/model` with the selected keys → navigate to
  a generation-status view. Map failures to friendly copy only (reuse
  `failureCopy`).

### C2 — Generation status (polling)

- A `ModelGenerationNotifier` (family by `modelId`) that polls
  `GET /admin/projects/:id/models` (or a status endpoint) on an interval while
  `QUEUED`/`PROCESSING`, stopping on `SUCCEEDED`/`FAILED`. Backoff + a cap.
- UI: progress state → on success, a **View 3D Model** CTA; on failure, mapped
  copy + Retry (which re-opens selection).

### C3 — 3D model viewer + Meshy badge

- Add `model_viewer_plus` to `pubspec.yaml`. A `ModelViewerScreen` that renders
  the record's `artifacts.cdnUrls.glb` with orbit controls (and AR where
  available). Show a **"Created by Meshy AI"** badge driven by `source == 'meshy'`.
- Handle load/error states (never surface a raw URL/error).

### C4 — Owner "View 3D Model" + approve

- On the owner's project screen, when a `SUCCEEDED` model exists, show **View 3D
  Model** (same viewer) with the Meshy badge.
- Staff get an **Approve** action (calls the approve endpoint) — the "we're
  satisfied, skip manual creation" gate. Reflect `approved` state in the UI.

---

## Better-implementation suggestions (baked into the plan above)

1. **Reuse the worker job queue** (new `MESHY_MODEL_GENERATION` type) instead of
   blocking the API or building new async — you inherit crash-resume, retries,
   and lease handling for free. *(chosen)*
2. **Keep model history** (one record per generation) so artists can iterate and
   **approve** the best attempt — directly serves the "if satisfied, skip manual"
   goal. *(chosen)*
3. **`model_viewer_plus`** for the fastest cross-platform GLB viewer. *(chosen)*
4. **Reuse existing plumbing**: the export-manifest keys the client already holds,
   the containment validator, the rate-limit util, the role gate, the standard
   envelope, and the hashed-id analytics. Almost no new patterns.
5. **Idempotency-Key + persisted `meshyTaskId`** — the two guards that make
   double-taps and crash-retries cost **zero** extra credits.
6. **Per-model artifact prefix** (`…/models/{modelId}/`) keeps generations from
   overwriting each other and makes history self-cleaning per record.
7. **Origin flag from day one** (`source`) with a reserved `'manual'` value, so
   the backend path can later drop in as a peer without a schema change.

---

## Tests & verification

- **Backend unit** (Vitest, hermetic): `meshyClient` mapping; `projectModelsService`
  validation (count/containment/outcomes); create-endpoint (role, rate-limit,
  idempotency, envelope); worker processor (happy/resume/terminal/retry) with a
  fake client + mocked S3.
- **Regression:** full `recapture-api` suite green; nothing in the capture
  pipeline changed.
- **Client:** widget tests for selection-count gating (CTA disabled outside 3–4)
  and the status→CTA transitions; the viewer behind an injectable URL.
- **Manual E2E (staging):** real capture → select 4 → Create Model → GLB lands in
  `BUCKET_ARTIFACTS` under `…/models/{modelId}/`, record `SUCCEEDED`, owner sees
  the badged model; a forced worker kill mid-poll resumes the **same** Meshy task
  (exactly one generation charged).

---

## Definition of done

**Status: BUILT** (2026-07-16) except the two items that need a human/staging.

- [x] Env vars added (schema + `.env.example`); boot validates them. **Deviation:**
      `MESHY_API_KEY` is `.optional()` in the shared schema and enforced at
      **worker** boot via `assertMeshyConfigured()` — only the worker calls
      Meshy, and requiring it in `config/env.ts` would stop the API (and every
      existing deployment/dev shell) booting over a credential it never uses.
- [x] `meshyClient.ts` + status→error mapping + tests (`tests/meshy-client.test.ts`).
      Contract verified against the live docs: `POST /openapi/v1/multi-image-to-3d`
      with `{ image_urls }` → `{ result: taskId }`.
- [x] `ProjectModel` model + `projectModelsService` (count/containment/history/approve) + tests.
- [x] `POST /admin/projects/:id/model` (role, rate-limit, Idempotency-Key, enqueue)
      + `GET …/models` + tests. **Deviation:** the enqueue lives in the SERVICE,
      not the route — AGENTS.md keeps routers thin, and record+job creation is one
      business operation.
- [x] `MESHY_MODEL_GENERATION` processor, resume-safe, re-hosts to our S3,
      CloudFront URLs + tests; registered in `index.ts`.
- [x] Owner project detail surfaces the latest `SUCCEEDED` model; approve endpoint.
- [x] Preview gallery multi-select (3–4) + Create Model CTA; generation status polling.
- [x] `model_viewer_plus` viewer with **"Created by Meshy AI"** badge; owner + staff
      entry points. The owner's entry is the existing **View** button on a
      COMPLETED project (its `TODO(viewer)` is now resolved).
- [x] Capture pipeline untouched; full `recapture-api` suite green (301 tests).
- [ ] **Manual staging E2E notes recorded** (badge shows; resume charges one
      generation). NOT DONE — needs a real Meshy key + a real capture.
- [x] `meshy-integration.md`, `AGENTS.md`/memory updated to describe the
      admin-triggered flow.

### Found while building (not in the original plan)

- **`findExportableJob` would have broken.** It resolved "the project's most
  recent job in a post-QUEUED state", and a `MESHY_MODEL_GENERATION` job is
  newer than the capture job and passes through those same states — so it would
  have won the sort, and (having no `upload` block) turned every export /
  preview-gallery / soft-delete call into `NOT_EXPORTABLE`. Fixed by filtering
  on `jobType`; regression-tested in `tests/project-models.test.ts`.
- **`Job.payload`** was added (`Schema.Types.Mixed`) — `CAPTURE_PROCESSING`
  describes its work with `upload`/`objectSize`, but a generation job needs
  `{ modelId }`. The "there is no payload field" note in `workerTypes.ts` was
  updated rather than left to rot.
- **Record vs job status.** A retrying job bounces QUEUED↔PROCESSING; the record
  must not flap with it. The processor only writes `FAILED` when the error is
  terminal **or** it was the job's last attempt — otherwise the record stays
  `PROCESSING`, which is the truth while a retry is pending.

---

## Open items to confirm while implementing (don't guess — verify)

1. **Exact Meshy multi-image contract** (create/retrieve field names; images as
   URLs vs. base64; result URL + expiry fields) against the live docs.
2. **`key` → absolute S3 key resolution** — reconcile the export-manifest
   relative `key` with the job's `upload.rawPrefix`
   (`{env}/{projectSlug}_{projectId}/{jobId}/`) using the SAME resolution the
   soft-delete/export path uses. See [`src/utils/s3Keys.ts`](../src/utils/s3Keys.ts)
   and `adminProjectsService.ts`.
3. **Owner exposure shape** — confirm how much of the model record the owner
   endpoint should return (URL + source + approved only; no keys, no actor ids).
4. **Product sign-off** on Meshy fidelity from 3–4 real capture photos before
   building the client viewer (§ companion doc §2.1).
