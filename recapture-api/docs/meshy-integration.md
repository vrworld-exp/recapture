# Meshy AI Integration — 3D Model Generation

**Status:** BUILT (staff-triggered flow) · **Owner:** backend · **Last updated:** 2026-07-16

> ✅ **Built and as-described in
> [`meshy-integration-implementation-prompt.md`](./meshy-integration-implementation-prompt.md)
> — read that for the design.** A MODEL_ARTIST/ADMIN picks **3–4 photos** in the
> Preview gallery and taps **Create Model**, which enqueues a
> **`MESHY_MODEL_GENERATION` worker job**; the result is re-hosted on our S3 and
> shown to the owner badged **"Created by Meshy AI"**. The capture processing
> pipeline is **untouched** and remains the fallback.
>
> **As-built map** (§1–§4 below describe the SUPERSEDED design — see the note
> there):
>
> | Concern | File |
> | --- | --- |
> | Meshy transport + status→error mapping | `src/worker/engine/meshy/meshyClient.ts` |
> | Generation record (history, origin flag, approval) | `src/models/ProjectModel.ts` |
> | Validation / containment / enqueue / approve | `src/services/projectModelsService.ts` |
> | Staff endpoints (create / history / approve) | `src/routes/admin.ts` |
> | Worker processor (resume-safe, re-hosts to our S3) | `src/worker/processors/meshyModelProcessor.ts` |
> | Owner surface (`model` on `GET /projects/:id`) | `src/routes/projects.ts` |
> | Client: selection, polling, viewer + badge | `lib/presentation/screens/projects/{preview_gallery,model_generation,model_viewer}_screen.dart` |
>
> Two deviations from the prompt, both deliberate:
> 1. **`MESHY_API_KEY` is optional in `config/env.ts`, required at WORKER boot**
>    (`assertMeshyConfigured()`). Only the worker calls Meshy; making the API
>    refuse to boot over a credential it never uses would break the existing
>    deployment on upgrade for no safety gain.
> 2. **The enqueue lives in the service, not the route** — AGENTS.md keeps
>    routers thin (parse, delegate, map), and record+job creation is one
>    business operation.
>
> **Recipe budget (updated 2026-08-04) — generation asks for QUALITY, not for
> what ships.** `MESHY_TARGET_POLYCOUNT` is **200,000** (not the 12,000 it
> launched with) and `MESHY_TEXTURE_RESOLUTION` is **4k**; the low budget was
> destroying thin features — handles, rims, stems came back holed — and no
> downstream stage can restore geometry that was never generated. The returned
> GLB is now an **archive and a pipeline input**: `src/modules/asset-pipeline`
> decimates and resamples it into the `web` variant a viewer actually loads, and
> auto-promotes that variant once it passes its gates. `MESHY_TASK_TIMEOUT_MS`
> is **1,800,000** (30 min) to fit the slower tasks — note the §3 snippet below
> still shows the old 600,000, along with the rest of that superseded design.
> `MESHY_POLL_INTERVAL_MS` stays 5 s regardless: each poll is also the worker's
> claim-lease renewal against `WORKER_CLAIM_TIMEOUT_MS`.
>
> `should_remesh` stays **true**. Setting it false returns the raw unbounded
> mesh and makes `target_polycount` ignored entirely (observed 55k–1.2M
> triangles for the same kind of object) — the goal is a high **pinned** budget,
> not an unbounded one.

---

> ⚠️ **§1–§4 below are SUPERSEDED.** They describe an **earlier exploration**
> that auto-ran Meshy *inside* the capture pipeline via a `RECONSTRUCTION_ENGINE`
> selector and a 3-stage engine mapping. **That was not built** — there is no
> `RECONSTRUCTION_ENGINE` env var, no `engineSelection.ts`, and no
> `MeshyReconstructionEngine`. The sections are kept because the *mechanics* they
> work through (polling + lease renewal, idempotent `meshyTaskId` resume,
> URL-expiry re-hosting, error mapping) are exactly what the new job processor
> does — §5–§8 remain accurate in spirit and were the basis for it.

Adds **Meshy AI** cloud model generation. Meshy generates the 3D model from a few
captured photos; we store the resulting model on **our** S3 and keep only our
(non-expiring) CDN URL in Mongo. The in-house pipeline stays in place as the
fallback.

---

## 1. Why this is a small change

The worker was built with a swappable engine seam exactly for this. The whole
integration is **one new file** implementing an existing interface, plus config
and wiring:

- [`src/worker/engine/reconstructionEngine.ts`](../src/worker/engine/reconstructionEngine.ts)
  defines `ReconstructionEngine` (`reconstruct` / `texture` / `optimize`) and a
  `setReconstructionEngine()` registration seam. The current `stub` does no real
  work.
- [`captureProcessingPipeline.ts`](../src/worker/processors/captureProcessingPipeline.ts)
  drives `PROCESSING → TEXTURING → OPTIMIZING`, threading each stage's output
  into the next as `priorOutputs`, and persisting every transition atomically.
- The worker loop, the [stage state machine](../src/worker/processingStages.ts),
  the finalize endpoint, and the mobile app are **untouched**.

We add a `MeshyReconstructionEngine` **beside** the built-in engine and a small
`engineSelection.ts` factory that `src/worker/index.ts` uses to register the one
`RECONSTRUCTION_ENGINE` selects. The built-in `stub` (and the future real
engine) is never removed. That's the surface area.

---

## 2. Two decisions to make BEFORE building

### 2.1 Meshy uses 1–4 images — not the full 48-shot capture

Meshy **Multi-Image to 3D** accepts **1 to 4 images** of the same object from
different angles, and it is **generative** — it *infers* plausible geometry from
a few views. Our capture flow is photogrammetry-shaped (3 rings, tilt bands,
coverage gating, ~48 shots) and produces dense multi-view data.

Consequences to accept consciously:

- We send **~4 selected photos**, not all 48. Ring-coverage density does not
  feed the model.
- Output is **not metrically faithful** — unseen regions are hallucinated. Great
  for "a nice 3D model of my object," weaker for "an exact scan."

**Action:** validate Meshy output on 4 real photos from an actual capture and
confirm the fidelity is acceptable as a **product** decision before writing code.
If exact fidelity is required, Meshy multi-image alone is the wrong tool.

### 2.2 Keep the 3-stage contract (recommended)

Meshy is **one async task**, not three stages. Rather than collapse the state
machine (which ripples into the app's Upload Step Tracker), distribute Meshy's
lifecycle across the existing stages:

| Stage        | Meshy responsibility                                                        |
| ------------ | -------------------------------------------------------------------------- |
| `PROCESSING` | Select ≤4 images → submit Meshy task → poll to `SUCCEEDED`. Persist taskId. |
| `TEXTURING`  | Pass-through (Meshy already textures). Emit progress, return prior refs.    |
| `OPTIMIZING` | Download Meshy's GLB/USDZ/preview → re-upload to **our** S3 → return refs.  |

---

## 3. Config additions

Add to [`src/config/env.ts`](../src/config/env.ts) (Zod schema) and
`.env.example`:

```ts
// ── Reconstruction engine selection ───────────────────────────────────────
// 'builtin' = in-house pipeline (stub today, real photogrammetry later);
// 'meshy' = Meshy AI cloud. Both engines stay in the code; this picks one.
RECONSTRUCTION_ENGINE: z.enum(['builtin', 'meshy']).default('meshy'),

// ── Meshy AI (reconstruction engine) — required only when engine = meshy ───
MESHY_API_KEY: z.string().min(1).optional(), // presence enforced in the selector when meshy is active
MESHY_BASE_URL: z.string().url().default('https://api.meshy.ai'),
/** How often to poll a running Meshy task (ms). Doubles as lease renewal. */
MESHY_POLL_INTERVAL_MS: z.coerce.number().int().positive().default(5000),
/** Hard cap on total wait for one task before giving up (ms). */
MESHY_TASK_TIMEOUT_MS: z.coerce.number().int().positive().default(600_000),
/** How many capture photos to send (Meshy allows max 4). */
MESHY_MAX_IMAGES: z.coerce.number().int().min(1).max(4).default(4),
```

`MESHY_API_KEY` is a **secret** — env only, never in the client, never logged.
Follow the secrets rules in `AGENTS.md`.

> ⚠️ Keep `MESHY_POLL_INTERVAL_MS` well below `WORKER_CLAIM_TIMEOUT_MS`
> (default 120 s) — each poll is also the claim-lease renewal.

---

## 4. Implementation steps

### Step 1 — Thin Meshy HTTP client

`src/worker/engine/meshy/meshyClient.ts` — no business logic, just transport:

- `createMultiImageTask(imageUrls: string[]): Promise<{ taskId: string }>`
- `getTask(taskId): Promise<MeshyTask>` where `MeshyTask` includes
  `status` (`PENDING|IN_PROGRESS|SUCCEEDED|FAILED|CANCELED`), `progress`
  (0–100), `model_urls` (`glb`, `usdz`/`fbx`, …), `thumbnail_url`, and the
  result `expires_at` timestamp.
- Send `Authorization: Bearer ${MESHY_API_KEY}`.
- Map HTTP status → error class (see §6). Do **not** log the API key or full
  image URLs.

### Step 2 — Image selection

`src/worker/engine/meshy/selectImages.ts` — pure function:

- Input: the parsed `capture_manifest.json` + `rawPrefix`.
- Pick up to `MESHY_MAX_IMAGES` **maximally-different, highest-quality** frames
  (spread across yaw/rings; prefer the **highest** `quality.blurScore` — it's
  variance-of-Laplacian, so higher = sharper — from each angular bucket; blur
  data is already in the manifest). This single choice drives output quality more
  than anything else, so make it deterministic (same job ⇒ same 4 photos).
- Return the S3 keys; presign short-lived GET URLs for Meshy to fetch, OR pass
  public CloudFront URLs if the raw bucket is CDN-fronted.

### Step 3 — `MeshyReconstructionEngine`

`src/worker/engine/meshy/meshyReconstructionEngine.ts` implementing
`ReconstructionEngine`:

- **`reconstruct(input)`**
  1. **Resume check:** if `input.priorOutputs.PROCESSING?.meshyTaskId` exists,
     skip submission and resume polling that task (see §5 — never resubmit).
  2. Otherwise select images (Step 2), `createMultiImageTask(...)`, and persist
     `meshyTaskId` by returning it in this stage's output **on the first
     `onProgress` call** so a crash after submit doesn't double-charge.
  3. Poll every `MESHY_POLL_INTERVAL_MS`; on each poll call
     `await input.onProgress(task.progress)` — this renews the lease AND throws
     `JobCanceledError`/`ClaimLostError` if the job was canceled/stolen, which
     must propagate (let it abort — optionally call Meshy's cancel endpoint).
  4. Return `{ meshyTaskId, modelUrls, thumbnailUrl, expiresAt }`.
- **`texture(input)`** — pass-through: emit a couple of progress ticks, return
  `input.priorOutputs.PROCESSING` (Meshy already textured the mesh).
- **`optimize(input)`** — download each `modelUrl`/`thumbnailUrl` from Meshy
  (they expire!) and `PutObject` into `BUCKET_ARTIFACTS` under the deterministic
  keys the stub already uses:
  `{env}/{userId}/{projectId}/{jobId}/model.glb`, `model.usdz`, `preview.jpg`.
  Return `EngineArtifacts` with `glbKey`, `usdzKey?`, `previewImageKey`, and
  `cdnUrls` built from `CLOUDFRONT_BASE`. Overwrite (never append) so a re-run is
  idempotent.

### Step 4 — Select the engine (add, don't replace)

A factory picks the engine from `RECONSTRUCTION_ENGINE`; the worker registers its
result. The built-in `stub` stays registered and selectable.

`src/worker/engine/engineSelection.ts`:

```ts
export function resolveReconstructionEngine(): ReconstructionEngine {
  switch (env.RECONSTRUCTION_ENGINE) {
    case 'meshy':
      if (!env.MESHY_API_KEY) throw new Error('RECONSTRUCTION_ENGINE=meshy requires MESHY_API_KEY');
      return meshyReconstructionEngine;
    case 'builtin':
    default:
      return stubReconstructionEngine; // real backend engine slots in here later
  }
}
```

In [`src/worker/index.ts`](../src/worker/index.ts) `main()`, before
`startWorker`:

```ts
setReconstructionEngine(resolveReconstructionEngine());
```

Leave the `stub` as the module default so unit tests stay hermetic (tests inject
a fake engine via `setReconstructionEngine`; CI never hits the real API).

### Step 5 — No DB schema change needed

The final artifact refs already flow into `Job.artifacts`
([`job.types.ts`](../src/models/types/job.types.ts) `ArtifactsInfo`), and the DB
stores **our** CloudFront URLs — never Meshy's expiring URLs. `meshyTaskId`
lives in the per-stage `stageOutputs` (used for resume); no new top-level field
is required. Optionally add `meshyTaskId` to `ArtifactsInfo` for support/debug
traceability.

---

## 5. Idempotency & crash resume (do NOT skip)

Meshy generations **cost credits**. The engine contract says a stage may be
re-run after a crash, lease takeover, or retry. Therefore:

- **Persist `meshyTaskId` the instant the task is created**, in the
  `PROCESSING` stage output. On re-claim, `resumeStageFor` re-enters
  `PROCESSING`, and the engine must read `priorOutputs.PROCESSING.meshyTaskId`
  and **resume polling** — never submit a second task.
- **Artifact keys are deterministic** (same job ⇒ same S3 keys). Re-running
  `optimize` overwrites, so no duplicates.

---

## 6. Error mapping (this is where money leaks)

| Meshy / condition                    | Throw                                    | Worker outcome                     |
| ------------------------------------ | ---------------------------------------- | ---------------------------------- |
| `402` insufficient credits / quota   | `NonRetryableJobError`                   | Terminal `FAILED` — **no retry**   |
| `400`/`422` bad/insufficient images  | `NonRetryableJobError`                   | Terminal `FAILED`                  |
| Meshy task `status: FAILED`          | `NonRetryableJobError`                   | Terminal `FAILED`                  |
| `429` rate limit                     | plain `Error`                            | Retry w/ backoff, resumes task     |
| `5xx` / network / timeout            | plain `Error`                            | Retry w/ backoff, resumes task     |
| Job canceled/stolen (via onProgress) | let `JobCanceledError`/`ClaimLostError` propagate | Worker goes silent, stops |

`NonRetryableJobError` is defined in
[`src/worker/workerTypes.ts`](../src/worker/workerTypes.ts). Getting the `402`
row wrong means a quota failure retries forever, burning credits.

---

## 7. Polling, not webhooks (for now)

Meshy supports webhooks, but the worker is poll-based and the host (Render) can
sleep. In-stage polling fits the existing lease/progress model with **zero new
infrastructure** and keeps cancel/resume working. Revisit webhooks only if poll
latency or API cost becomes a real problem.

---

## 8. Testing

- **Unit:** inject a fake `ReconstructionEngine` via `setReconstructionEngine`
  (existing pattern in the worker tests). Cover: happy path, resume-with-existing-taskId
  (asserts **no** second `createTask`), `402` → terminal, `429` → retry,
  cancel-mid-poll propagation.
- **`meshyClient`:** unit-test the HTTP status → error-class mapping with a
  mocked transport. Never call the live API in CI.
- **Manual E2E:** one real capture end-to-end against a staging Meshy key,
  verifying the GLB lands in `BUCKET_ARTIFACTS` and `Job.artifacts.cdnUrls.glb`
  resolves via CloudFront after Meshy's URL would have expired.

---

## 9. Rollout checklist

- [ ] Product sign-off on Meshy fidelity from 4 real capture photos (§2.1)
- [ ] `RECONSTRUCTION_ENGINE` + `MESHY_*` env vars added to schema, `.env.example`, and deploy secrets
- [ ] `meshyClient.ts` + status→error mapping + tests
- [ ] `selectImages.ts` (deterministic ≤4-photo selection) + tests
- [ ] `MeshyReconstructionEngine` (3-stage mapping, resume-safe) + tests
- [ ] `engineSelection.ts` factory wired in `src/worker/index.ts`; **built-in path stays selectable**; stub remains test default
- [ ] Credits/billing alert configured on the Meshy account
- [ ] Manual E2E on staging passes; artifact URLs outlive Meshy's expiry
- [ ] Update `AGENTS.md` / memory: Meshy is a **selectable** engine alongside the built-in path

---

## References

- [Multi-Image to 3D API — Meshy Docs](https://docs.meshy.ai/en/api/multi-image-to-3d)
- [Quickstart — Meshy Docs](https://docs.meshy.ai/en/api/quick-start)
- [Image to 3D API — Meshy Docs](https://docs.meshy.ai/en/api/image-to-3d)
