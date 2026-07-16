# Implementation Prompt — Meshy AI Reconstruction Engine

> Hand this whole document to a coding agent (or use it as your own worklist).
> It is self-contained: context, exact files, signatures, tests, and a
> definition of done. Companion design doc:
> [`meshy-integration.md`](./meshy-integration.md). When anything here disagrees
> with `AGENTS.md`, **AGENTS.md wins**.

---

## Context (read first)

We are **adding** a **Meshy AI Multi-Image to 3D** cloud engine as a **second,
selectable** reconstruction backend — **not** replacing the existing in-house
path. Meshy generates the model from a few captured photos; we download the
result and store it on **our** S3 (`BUCKET_ARTIFACTS`), keeping only our
non-expiring CloudFront URL in Mongo.

> **Decision (important):** the current built-in path (the `stub` today, the real
> backend photogrammetry engine later) MUST stay in place and fully functional.
> A single config switch (`RECONSTRUCTION_ENGINE`) chooses which engine the
> worker uses per deploy, so we can run Meshy in production and still fall back
> to — or later build out — the backend way without touching this code. **Do not
> delete, gut, or bypass `stubReconstructionEngine` or the built-in path.**

This plugs into an existing seam — **do not** re-architect the worker, the stage
state machine, the finalize endpoint, or the mobile app. Meshy is one more
`ReconstructionEngine` implementation living beside the built-in one; both
satisfy the same interface and the orchestrator can't tell them apart.

Key existing files to understand before writing:

- [`src/worker/engine/reconstructionEngine.ts`](../src/worker/engine/reconstructionEngine.ts)
  — the `ReconstructionEngine` interface (`reconstruct`/`texture`/`optimize`),
  the `EngineStageInput`/`EngineArtifacts`/`OptimizeOutput` types, the `stub`
  engine, and `setReconstructionEngine()`. **This is the seam you implement.**
- [`src/worker/processors/captureProcessingPipeline.ts`](../src/worker/processors/captureProcessingPipeline.ts)
  — the orchestrator: drives `PROCESSING → TEXTURING → OPTIMIZING`, threads each
  stage's return value into the next as `priorOutputs[STAGE]`, and persists
  transitions atomically. Read it to understand the idempotency/resume contract.
- [`src/config/env.ts`](../src/config/env.ts) — Zod env schema (add vars here).
- [`src/config/s3.ts`](../src/config/s3.ts) — `s3Client`, `BUCKET_ARTIFACTS`,
  `CLOUDFRONT_BASE`.
- [`src/worker/index.ts`](../src/worker/index.ts) — worker entry point; register
  the engine here.
- [`src/worker/workerTypes.ts`](../src/worker/workerTypes.ts) — `NonRetryableJobError`.
- The capture manifest per-photo shape (client-authored, read at the engine):
  `photos[]` each carry `imagePath`, `ringName` (EYE/TOP/LOW), `segmentIndex`,
  `quality.blurScore` (variance of Laplacian — **higher = sharper**),
  `orientation.yawDegrees`. Source of truth:
  [`lib/domain/upload/capture_manifest.dart`](../../lib/domain/upload/capture_manifest.dart).

### Non-negotiable contracts (from the seam header)

1. **Idempotent per stage** — a stage may be re-run after a crash, lease
   takeover, or retry. Same inputs → same outputs. Deterministic artifact keys;
   overwrite, never append.
2. **`onProgress` is the lease renewal** — a stage that can outlast
   `WORKER_CLAIM_TIMEOUT_MS` (default 120 s) MUST call `onProgress` periodically
   or the job gets re-claimed mid-flight. `onProgress` also **throws**
   `JobCanceledError`/`ClaimLostError` when the job is canceled/stolen — let it
   propagate; never swallow it.
3. **Error routing** — throw plain `Error` for transient trouble (worker retries
   with backoff, resuming at the same stage) or `NonRetryableJobError` for input
   problems retrying can't fix (terminal `FAILED`).
4. **Secrets** — `MESHY_API_KEY` is env-only, never logged, never sent to the
   client. Follow `AGENTS.md` secrets rules.
5. **CI never calls the live Meshy API** — tests inject a fake engine / mock the
   transport. The `stub` engine remains the default so existing worker tests
   stay hermetic.
6. **Coexistence** — the built-in engine and the Meshy engine both remain
   registered/available; `RECONSTRUCTION_ENGINE` only chooses which one runs.
   Never remove the built-in path.

---

## Task 1 — Env config

**File:** [`src/config/env.ts`](../src/config/env.ts) (+ `.env.example`)

Add to the Zod schema:

```ts
// ── Reconstruction engine selection ───────────────────────────────────────
/**
 * Which reconstruction backend the worker runs. 'builtin' = the in-house
 * pipeline (stub today, real photogrammetry later); 'meshy' = Meshy AI cloud.
 * Both engines stay in the codebase — this only picks the active one per deploy.
 */
RECONSTRUCTION_ENGINE: z.enum(['builtin', 'meshy']).default('meshy'),

// ── Meshy AI (reconstruction engine) ──────────────────────────────────────
// Required ONLY when RECONSTRUCTION_ENGINE=meshy. Keep these optional at the
// schema level and assert MESHY_API_KEY presence when the meshy engine is
// selected (Task 5), so a 'builtin' deploy boots without a Meshy key.
MESHY_API_KEY: z.string().min(1).optional(),
MESHY_BASE_URL: z.string().url().default('https://api.meshy.ai'),
/** Poll cadence for a running Meshy task (ms). Must stay << WORKER_CLAIM_TIMEOUT_MS. */
MESHY_POLL_INTERVAL_MS: z.coerce.number().int().positive().default(5000),
/** Hard cap on total wait for one Meshy task before giving up (ms). */
MESHY_TASK_TIMEOUT_MS: z.coerce.number().int().positive().default(600_000),
/** How many capture photos to send (Meshy multi-image allows max 4). */
MESHY_MAX_IMAGES: z.coerce.number().int().min(1).max(4).default(4),
```

Mirror every var (with a placeholder, no real key) in `.env.example`, and
document `RECONSTRUCTION_ENGINE` there with both allowed values.

**Acceptance:** a `builtin` deploy boots with **no** Meshy vars set; a `meshy`
deploy fails fast with a clear message when `MESHY_API_KEY` is missing (asserted
in Task 5's selector, not the raw schema).

---

## Task 2 — Meshy HTTP client (transport only)

**File (new):** `src/worker/engine/meshy/meshyClient.ts`

A thin typed wrapper over the Meshy REST API. No business logic, no S3, no DB.

```ts
export type MeshyTaskStatus =
  | 'PENDING' | 'IN_PROGRESS' | 'SUCCEEDED' | 'FAILED' | 'CANCELED';

export interface MeshyTask {
  id: string;
  status: MeshyTaskStatus;
  progress: number;                 // 0–100
  modelUrls: { glb?: string; usdz?: string; fbx?: string; obj?: string };
  thumbnailUrl?: string;
  expiresAt?: number;               // ms since epoch — result URLs die after this
  error?: { message: string };
}

export interface MeshyClient {
  createMultiImageTask(imageUrls: string[]): Promise<{ taskId: string }>;
  getTask(taskId: string): Promise<MeshyTask>;
  cancelTask?(taskId: string): Promise<void>;
}
```

Requirements:

- `Authorization: Bearer ${MESHY_API_KEY}`; base URL from `MESHY_BASE_URL`.
- Confirm the exact request/response shape against the live docs
  ([Multi-Image to 3D](https://docs.meshy.ai/en/api/multi-image-to-3d)) and
  normalize into the types above (field names may differ — adapt in the client,
  not in callers).
- **Status → error mapping** (throw these; callers rely on the class):
  - `401`/`403` → `NonRetryableJobError('MESHY_AUTH')` (misconfig, don't retry).
  - `402` / insufficient-credits → `NonRetryableJobError('MESHY_QUOTA')`.
  - `400`/`422` bad request/images → `NonRetryableJobError('MESHY_BAD_INPUT')`.
  - `429` → plain `Error` (retryable).
  - `5xx` / network / timeout → plain `Error` (retryable).
- Never log the API key, bearer header, or full presigned image URLs.

**Acceptance:** unit tests (mocked transport) prove each HTTP status maps to the
correct error class; no live network in tests.

---

## Task 3 — Deterministic image selection

**File (new):** `src/worker/engine/meshy/selectImages.ts`

**Pure function** — no IO:

```ts
export function selectMeshyImages(
  manifest: unknown,          // parsed capture_manifest.json
  maxImages: number,          // env.MESHY_MAX_IMAGES
): string[]                   // returns manifest imagePath references, deterministic
```

Selection policy (Meshy wants ≤4 views of the same object from different angles):

1. Read `manifest.photos[]`; keep `verdict !== 'rejected'` entries (manifest only
   contains accepted/warn anyway).
2. Spread across angles: bucket by `orientation.yawDegrees` into `maxImages`
   even yaw ranges (prefer the EYE ring for the primary silhouette; include TOP
   for the crown). Avoid picking near-duplicate yaws.
3. Within each bucket, pick the **sharpest** photo — highest
   `quality.blurScore`.
4. If fewer buckets are populated than `maxImages`, backfill with the next
   sharpest unused photos.
5. **Deterministic:** identical manifest ⇒ identical selection (stable
   tie-breaks on `photoId`). No randomness.

Return the photos' `imagePath` values (the storage-path references); the engine
resolves them to S3 keys under `rawPrefix` in Task 4.

**Acceptance:** unit tests over a synthetic manifest assert: correct count,
angular spread, sharpest-per-bucket, deterministic output, and graceful handling
of `< maxImages` photos.

---

## Task 4 — `MeshyReconstructionEngine`

**File (new):** `src/worker/engine/meshy/meshyReconstructionEngine.ts`
implementing `ReconstructionEngine`. Keeps the 3-stage contract by distributing
Meshy's single async task across the stages.

### `reconstruct(input)` — submit + poll

1. **Resume guard (idempotency):** if
   `input.priorOutputs.PROCESSING?.meshyTaskId` exists, **do not** create a new
   task — jump straight to polling that id.
2. Otherwise: `selectMeshyImages(input.manifest, MESHY_MAX_IMAGES)` → resolve
   each `imagePath` to an S3 key under `input.rawPrefix` (rawBucket = raw
   captures) → **presign short-lived GET URLs** (or use CDN URLs if the raw
   bucket is fronted) → `meshyClient.createMultiImageTask(urls)`.
3. **Persist `meshyTaskId` before the first await-heavy wait** by returning it in
   this stage's output as early as possible — call
   `await input.onProgress(1)` right after creation so a crash post-submit
   resumes the same task instead of double-charging. (The orchestrator persists
   stage output on stage completion; `meshyTaskId` must also survive a mid-poll
   crash — see the resume guard. If the orchestrator does not persist partial
   output, record the task id via a progress side-channel or a dedicated job
   field. **Verify this against `captureProcessingPipeline.ts` / `stageTransitions.ts`
   and choose the mechanism that guarantees the id is durable the moment the
   task is created.**)
4. Poll every `MESHY_POLL_INTERVAL_MS` until `SUCCEEDED`/`FAILED`/`CANCELED` or
   `MESHY_TASK_TIMEOUT_MS`. On **each** poll: `await input.onProgress(task.progress)`
   (lease renewal + cancel/claim-loss check — let those throw propagate; on
   cancel, best-effort `cancelTask`).
5. `status: FAILED` → `NonRetryableJobError('MESHY_TASK_FAILED', task.error?.message)`.
   Timeout → plain `Error` (retryable).
6. Return `{ meshyTaskId, modelUrls, thumbnailUrl, expiresAt }`.

### `texture(input)` — pass-through

Meshy already textures. Emit one or two `onProgress` ticks and return
`input.priorOutputs.PROCESSING` unchanged (so `optimize` still sees the model
URLs). Do **not** call Meshy again.

### `optimize(input)` — download + re-host

1. Read `modelUrls`/`thumbnailUrl` from `input.priorOutputs.PROCESSING`.
2. Download each asset (they **expire** — never store Meshy URLs in the DB).
3. `PutObject` into `BUCKET_ARTIFACTS` under the **deterministic** keys the stub
   already uses (overwrite semantics = idempotent re-run):
   - `${prefix}model.glb` (required)
   - `${prefix}model.usdz` (if Meshy returned usdz)
   - `${prefix}preview.jpg` (thumbnail)
   where `prefix` matches the raw bundle's job scope
   (`{env}/{userId}/{projectId}/{jobId}/`).
4. Return `OptimizeOutput` whose `artifacts` is a valid `EngineArtifacts`:
   `glbKey`, `usdzKey?`, `previewImageKey`, and `cdnUrls` built from
   `CLOUDFRONT_BASE + key`. If no GLB was produced → `NonRetryableJobError`
   (the orchestrator already guards "no artifacts").

Export a singleton: `export const meshyReconstructionEngine: ReconstructionEngine`.

**Acceptance:** unit tests with a fake `MeshyClient` + mocked S3 cover: happy
path end-to-end; **resume with existing `meshyTaskId` asserts `createMultiImageTask`
is NOT called again**; `402`/task-FAILED → `NonRetryableJobError`; `429`/`5xx` →
plain `Error`; cancel-mid-poll propagates `JobCanceledError`; artifacts carry
CloudFront (never Meshy) URLs.

---

## Task 5 — Engine selection (add, don't replace)

The built-in and Meshy engines both stay in the codebase. A **factory** picks the
active one from `RECONSTRUCTION_ENGINE`; the worker registers whatever it returns.

**File (new):** `src/worker/engine/engineSelection.ts`

```ts
import type { ReconstructionEngine } from '@/worker/engine/reconstructionEngine';
import { stubReconstructionEngine } from '@/worker/engine/reconstructionEngine';
import { meshyReconstructionEngine } from '@/worker/engine/meshy/meshyReconstructionEngine';
import { env } from '@/config/env';

/** Resolves the active reconstruction engine from config. Fail-fast on a
 *  misconfigured 'meshy' selection (missing key) — never silently fall back. */
export function resolveReconstructionEngine(): ReconstructionEngine {
  switch (env.RECONSTRUCTION_ENGINE) {
    case 'meshy':
      if (!env.MESHY_API_KEY) {
        throw new Error(
          "RECONSTRUCTION_ENGINE=meshy requires MESHY_API_KEY to be set",
        );
      }
      return meshyReconstructionEngine;
    case 'builtin':
    default:
      return stubReconstructionEngine; // real backend photogrammetry engine slots in here later
  }
}
```

**File:** [`src/worker/index.ts`](../src/worker/index.ts) — in `main()`, before
`startWorker(...)`:

```ts
import { setReconstructionEngine } from '@/worker/engine/reconstructionEngine';
import { resolveReconstructionEngine } from '@/worker/engine/engineSelection';

const engine = resolveReconstructionEngine();
setReconstructionEngine(engine);
log('info', 'Reconstruction engine selected', { engine: env.RECONSTRUCTION_ENGINE });
```

Leave `stubReconstructionEngine` as the module default in `reconstructionEngine.ts`
(tests and the `builtin` path both rely on it).

**Acceptance:** `RECONSTRUCTION_ENGINE=meshy npm run worker` runs Meshy;
`RECONSTRUCTION_ENGINE=builtin` (or unset in a keyless deploy) runs the built-in
engine; `meshy` with no `MESHY_API_KEY` fails fast at startup. Existing
worker/pipeline suites still pass (they inject their own engine and never touch
the selector).

---

## Task 6 — Tests & verification

- **Unit** (Vitest, hermetic — the repo's test stack): Tasks 2, 3, 4 as above.
  Use `setReconstructionEngine` for injection; mock the Meshy transport and S3.
- **Regression:** run the full `recapture-api` test suite — nothing that touched
  the stub should break.
- **Manual E2E (staging only, documented, not in CI):** one real capture pushed
  through with a staging `MESHY_API_KEY`. Verify (a) a GLB lands in
  `BUCKET_ARTIFACTS` under the job prefix, (b) `Job.artifacts.cdnUrls.glb`
  resolves via CloudFront **after** Meshy's `expiresAt` would have passed,
  (c) a forced worker kill mid-poll re-claims and resumes the **same** Meshy task
  (check credits: exactly one generation charged).

---

## Constraints & guardrails (do not violate)

- **Additive only** — do not remove, gut, or bypass `stubReconstructionEngine` or
  the built-in path. Both engines coexist; `RECONSTRUCTION_ENGINE` selects one.
- Touch **only** the worker/engine/config surface + `.env.example`. No changes to
  the stage state machine, finalize endpoint, API routes, or the Flutter app.
- No secrets in code, logs, commits, or test fixtures.
- No live Meshy/AWS calls in unit tests or CI.
- Every Meshy generation costs credits — the resume guard (Task 4 step 1/3) is
  mandatory, not optional.
- Follow existing code conventions: `@/` path aliases, the worker's `log(...)`
  logger, `NonRetryableJobError` for terminal failures, `tsx`/`tsc-alias`
  toolchain. Match surrounding style.

---

## Definition of done

- [ ] `RECONSTRUCTION_ENGINE` + Meshy env vars added (schema + `.env.example`);
      `builtin` boots keyless, `meshy` fails fast without a key.
- [ ] `meshyClient.ts` with verified request/response shapes + status→error map + tests.
- [ ] `selectImages.ts` pure, deterministic, quality/angle-aware + tests.
- [ ] `meshyReconstructionEngine.ts` — 3-stage mapping, resume-safe, re-hosts to
      our S3, returns CloudFront artifact URLs + tests.
- [ ] `engineSelection.ts` factory + wired in `src/worker/index.ts`; **built-in
      path untouched** and still selectable; stub remains the test default.
- [ ] Selector tested both ways (builtin → stub, meshy → meshy, meshy+no-key → throws).
- [ ] Full `recapture-api` suite green.
- [ ] Manual staging E2E notes recorded (artifacts outlive Meshy expiry; resume
      charges exactly one generation).
- [ ] `meshy-integration.md` and `AGENTS.md`/memory updated to state Meshy is a
      **selectable** engine alongside the built-in path (default `RECONSTRUCTION_ENGINE`).

---

## Open items to confirm while implementing (don't guess — verify)

1. **Exact Meshy multi-image endpoint contract** (create + retrieve field names,
   how images are passed — URLs vs. base64, result URL fields) against the live
   docs.
2. **Durable `meshyTaskId` mechanism** — confirm how/when the orchestrator
   persists stage output, and pick the path that makes the task id durable the
   instant the task is created (see Task 4 step 3).
3. **`imagePath` → S3 key resolution** — reconcile the manifest's
   `recapture/{projectId}/{jobId}/images/{level}/<frame>.jpg` references with the
   job's `upload.rawPrefix` (`{env}/{userId}/{projectId}/{jobId}/`) so presigning
   targets the right key. See [`src/utils/s3Keys.ts`](../src/utils/s3Keys.ts).
4. **Product sign-off** on Meshy fidelity from 4 real capture photos (§2.1 of the
   design doc) — this gates the whole effort.
