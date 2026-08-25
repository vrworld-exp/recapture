# Implementation Prompt — Automatic Model Generation After Capture

> Hand this whole document to a coding agent (or use it as your own worklist).
> It is self-contained: context, exact files, signatures, tests, and a
> definition of done. Companion docs:
> [`meshy-integration-implementation-prompt.md`](./meshy-integration-implementation-prompt.md)
> (the staff-triggered flow this builds on) and
> [`meshy-integration.md`](./meshy-integration.md). When anything here disagrees
> with `AGENTS.md`, **AGENTS.md wins**. This spans BOTH codebases — the Node/TS
> backend (`recapture-api/`) and the Flutter client (repo root).

---

## The decision (read first)

Today a **staff user** picks 3–4 photos by hand and taps **Create Model**. This
change makes that happen **automatically**: when a capture job finishes
processing, the server **selects the four best photos itself** from the capture
manifest, enqueues a Meshy generation, and the **owner sees the finished 3D
model in their project** without anyone asking for it.

The user's experience becomes: *capture the object → wait a few minutes → the
model is there.*

### This SUPERSEDES two clauses of the Meshy prompt

The companion prompt's "What this is NOT" section says the flow is **not**
worker-driven and **not** an automatic image picker. **Both are now reversed —
deliberately.** Everything else in that document still stands: the job type, the
processor, the money contract, the re-hosting rule, the record shape. Update
that section to point here rather than leaving it contradictory.

### What this is still NOT

- **Not** a change to `meshyModelProcessor`. It already takes a `modelId` and
  does not care who enqueued it. It should be touched **only** if a test proves
  it must be.
- **Not** a replacement of `reconstructionEngine`. Meshy is chained as a
  **second job** after capture processing, not jammed into the three-stage
  `reconstruct → texture → optimize` interface (one async call is not three
  stages, and Meshy's resume model is `meshyTaskId` polling, not `stageProgress`).
- **Not** a removal of the staff path. Manual Create-Model and the
  Prepare-Images screen remain as the **regenerate / override** path.

### Flow end-to-end

1. User completes a capture → uploads → finalize → `CAPTURE_PROCESSING` job runs.
2. At the **tail** of `captureProcessingProcessor`, after the pipeline succeeds:
   the **auto-selector** reads the already-parsed manifest and picks 4 photos.
3. Guards run (kill switch, per-job dedupe, per-user cap, quality floor). If any
   declines, **nothing is enqueued** and the capture job still completes normally.
4. `createMeshyModelRequest` is called with a **deterministic idempotency key**
   (`auto:{jobId}`) → `ProjectModel` record (`QUEUED`) + `MESHY_MODEL_GENERATION`
   job. **Unchanged from the staff path.**
5. The existing Meshy processor runs untouched: submit → poll → re-host → record
   `SUCCEEDED` with our CloudFront URLs.
6. The owner's project detail shows **generating → ready**, then the model,
   badged **"AI generated — preview quality."** No approval gate.

---

## Product decisions (settled — do not re-litigate)

1. **No approve gate for auto-generated models.** The owner sees the model as
   soon as Meshy finishes. `approved` remains on the record as a staff quality
   signal, but it does **not** gate owner visibility. This is what makes the flow
   feel automatic; the badge sets expectations instead.
2. **Prepare-Images survives as the regenerate path.** Auto-gen skips it on the
   happy path. If the user dislikes the result, **Regenerate** opens
   Prepare-Images for manual photo choice + lighting adjustment. Do not delete
   or orphan that screen.

---

## Non-negotiable contracts

1. **A failed or skipped generation must NEVER fail the capture job.** The
   capture succeeded; the photos are safe. The enqueue is the last thing the
   processor does and is fully wrapped — any throw is logged and swallowed.
2. **A retried capture job must NEVER pay Meshy twice.** The deterministic
   `auto:{jobId}` idempotency key + the existing unique
   `(createdByUserId, idempotencyKey)` index make a re-run replay the existing
   record instead of enqueuing a second generation.
3. **Decline to spend rather than spend badly.** If the selector cannot find a
   usable spread of sharp photos, skip generation entirely. A bad capture costs
   the same as a good one and produces a model that damages trust.
4. **The selector is PURE** — parsed manifest in, relative keys out. No DB, no
   S3, no async. It is the piece whose quality decides the feature; it must be
   iterable against real manifests with no infrastructure in the loop.
5. **Every selected key passes `isContainedRelativeKey`** before it is presigned,
   exactly like the staff path. No second, driftable validator.
6. **Reuse `createMeshyModelRequest`.** Do not write a second create path. It
   already owns dedupe, count validation, containment, record-before-job
   ordering, and idempotency replay.
7. **Kill switch honored on every run.** Auto-generation must be disableable via
   remote config without a deploy.
8. **CI never hits live Meshy/AWS.** Mock the transport and S3, as today.

---

## Backend tasks

### T1 — The auto-selector (pure)

**File (new):** `src/services/autoPhotoSelectionService.ts`
**Tests (new):** `tests/auto-photo-selection.test.ts`

```ts
export interface AutoSelectionCandidate {
  relativeKey: string;   // e.g. "images/EYE/eye_0001.jpg"
  blurScore: number;
  yawDegrees: number | null;
  segmentIndex: number | null;
  ringName: string;
  verdict: string;
}

export type AutoSelectionResult =
  | { outcome: 'SELECTED'; keys: string[]; reason: string }
  | { outcome: 'DECLINED'; reason: AutoSelectionDeclineReason };

export type AutoSelectionDeclineReason =
  | 'MANIFEST_UNREADABLE'
  | 'NO_USABLE_PHOTOS'      // nothing survived the quality floor
  | 'INSUFFICIENT_SPREAD';  // usable photos, but < 2 distinct yaw quadrants

export function selectPhotosForAutoGeneration(
  manifest: unknown,
  opts?: { minBlurScore?: number; targetCount?: number; availableKeys?: string[] }
): AutoSelectionResult;
```

**Algorithm — in this order:**

1. **Parse defensively.** The manifest arrives as `unknown`. Reuse the Zod
   `.passthrough()` style of `manifestValidationService.ts`; an unreadable
   document is `DECLINED`, never a throw.
2. **Filter to the EYE ring** (Level A, pitch `[60,120)` — the object shot
   straight-on; TOP/LOW are foreshortened and Meshy reasons worst about them).
   Fall back to the full pool only if EYE yields fewer than 3 candidates.
3. **Drop unusable frames:** `verdict === 'warn'` (exposure-warned) when enough
   clean ones remain, and anything below `minBlurScore` (default **40** — the
   existing REJECT floor from the blur-threshold policy). Never filter below 3.
4. **Bucket by yaw quadrant** — 4 buckets of 90°. Use `segmentIndex` as the
   primary key when present (the ring's own quantization; more reliable than raw
   yaw, which drifts), `yawDegrees` as fallback. A photo with neither goes in a
   catch-all bucket used only for backfill.
5. **Pick the sharpest photo in each bucket** (max `blurScore`).
6. **Backfill** empty quadrants from the *most angularly distant* filled
   quadrant's next-sharpest photo. Return 3 if only 3 exist; `DECLINED` below that.

> **Why quadrants first, sharpness second:** the four sharpest photos are very
> often four near-identical frames from one corner of the ring, because
> sharpness correlates with the user standing still. Meshy would receive one
> view four times and hallucinate the other three sides. **Angular spread is the
> constraint; sharpness is the tiebreak within it.** Inverting this is the single
> most likely way to ship a feature that quietly produces bad models.

#### ⚠️ The key-mapping unknown — VERIFY, DO NOT ASSUME

The manifest's `imagePath` is
`recapture/{projectId}/{jobId}/images/EYE/frame.jpg`, but `selectedKeys` must be
**relative to `rawPrefix`** — `images/EYE/frame.jpg` (see the export entry format
at `adminProjectsService.ts` `ExportFileEntry`).

**Before writing the derivation:** dump one real `capture_manifest.json` and one
real `listObjectsUnderPrefix` result for the same job and compare them directly.

Then make it **defensive, not clever**: derive the candidate relative key, and
suffix-match it against the actually-listed objects (pass them via
`opts.availableKeys`). A derived key with no matching object is **skipped**, not
sent — handing Meshy a presigned URL for a nonexistent object wastes a paid
generation on a 404.

**Tests:** golden manifests → expected keys; clustered-sharpness manifest asserts
spread wins over raw sharpness; partial-coverage manifest backfills; all-blurry →
`DECLINED`; single-quadrant → `INSUFFICIENT_SPREAD`; garbage → `MANIFEST_UNREADABLE`;
derived key absent from `availableKeys` → skipped.

### T2 — Guards + trigger service

**File (new):** `src/services/autoModelGenerationService.ts`
**Tests (new):** `tests/auto-model-generation.test.ts`

```ts
export type AutoGenerationOutcome =
  | { outcome: 'ENQUEUED'; modelId: string }
  | { outcome: 'SKIPPED'; reason: AutoGenerationSkipReason };

export type AutoGenerationSkipReason =
  | 'DISABLED'          // remote-config kill switch
  | 'ALREADY_EXISTS'    // this job already has an auto-generation
  | 'USER_CAP_REACHED'
  | 'NOT_SELECTABLE'    // selector declined
  | 'ENQUEUE_FAILED';

export async function maybeAutoGenerateModel(args: {
  job: WorkerJob;
  manifest: unknown;
  availableKeys?: string[];
}): Promise<AutoGenerationOutcome>;
```

**Guards, evaluated in this order (cheapest first):**

1. **Kill switch** — `AUTO_MODEL_GENERATION_ENABLED` (env) AND the remote-config
   flag. Off → `DISABLED`. Checked first so a panic-disable costs nothing.
2. **One generation per capture job, never per project** — the deterministic
   `auto:{jobId}` key. A recapture is a new job → a new deliberate spend. A
   retry is the same job → nothing. Rely on the unique index as the authority
   (a pre-check is a race; the index is the truth), and treat the
   `REPLAYED` outcome from `createMeshyModelRequest` as `ALREADY_EXISTS`.
3. **Per-user daily cap** — count `ProjectModel` records with `source: 'meshy'`
   for this user in the last 24h against `AUTO_MODEL_MAX_PER_USER_PER_DAY`.
   Protects against a stuck client looping finalize.
4. **Quality floor** — the selector's `DECLINED` outcomes → `NOT_SELECTABLE`.

Then call `createMeshyModelRequest({ projectId, keys, actor, idempotencyKey })`.

**The actor problem:** `ProjectModel` requires `createdByUserId` +
`createdByRole`. There is no staff user here. Attribute to the **project owner**
(`job.userId`) with a new `createdBySystem: true` flag on the record, so audit
still answers "who caused this spend" truthfully and the per-user cap has a
subject. Do **not** invent a fake staff user id.

**Tests:** each guard blocks in isolation; double-invocation for the same job
enqueues exactly once; cap boundary; selector-declined → no record created.

### T3 — Env + remote config

`src/config/env.ts` (+ `.env.example`):

```ts
AUTO_MODEL_GENERATION_ENABLED: z.coerce.boolean().default(false), // opt-IN
AUTO_MODEL_MAX_PER_USER_PER_DAY: z.coerce.number().int().positive().default(10),
AUTO_MODEL_MIN_BLUR_SCORE: z.coerce.number().nonnegative().default(40),
```

Default **false**. This ships dark and is turned on deliberately.

Add the remote-config flag alongside (the endpoint that already never 5xxs), so
it can be flipped without a deploy. Env is the hard gate; remote config is the
live switch. **Both must be on.**

### T4 — The chaining trigger

**File:** `src/worker/processors/captureProcessingProcessor.ts` — tail only.

After `runCaptureProcessing` returns, before the processor returns its result:

```ts
// Auto-generation is BEST-EFFORT and strictly after the capture outcome is
// durable. The capture succeeded and the photos are safe; a generation that
// failed to enqueue is a retryable inconvenience, never a reason to fail a
// good capture. Contract #1.
let autoGeneration: AutoGenerationOutcome | undefined;
try {
  autoGeneration = await maybeAutoGenerateModel({ job, manifest: parsedManifest });
} catch (err: unknown) {
  log('error', 'Auto model generation failed to enqueue', {
    jobId: job._id, error: toError(err).message,
  });
}
return { validated: true, filesVerified, ...pipelineResult, autoGeneration };
```

**Why here and not at finalize:** the manifest is already parsed and validated
and the S3 count already verified. Selecting at finalize would mean re-fetching
and re-validating the manifest purely to pick photos — duplicated work and a
second place for validation to drift.

**Tests:** capture job still COMPLETED when the trigger throws; result carries
the outcome; `MESHY_MODEL_GENERATION` job exists after a successful run.

### T5 — Owner-facing status

`OwnerModelDto` (`projectModelsService.ts`) currently only materializes for a
`SUCCEEDED` record with artifacts. The owner now needs the **in-between** state —
"a model is being made for you that you did not ask for" is a new concept in the
app.

- Extend the owner surface to report `QUEUED` / `PROCESSING` / `FAILED` with no
  artifacts, plus progress when available.
- **Keep the DTO minimal.** No `selectedKeys`, no `meshyTaskId`, no S3 keys, no
  actor ids. That minimalism is deliberate — preserve it.
- Add `isAutoGenerated` so the client can drive the badge and the
  regenerate affordance.
- `latestOwnerModelFor` must keep preferring the newest **SUCCEEDED** model. A
  fresh regenerate sits at the head of history as QUEUED; the existing good
  model must not disappear while it runs. Surface the in-flight record
  **alongside** the current model, not instead of it.

---

## Client tasks (Flutter)

### C1 — Three states on project detail

Today: *no model* → *model*. Now: *no model* → **generating** → *model*. The
middle state is the new work.

- Reuse the polling + progress UI already built for the staff Meshy flow
  (`record.progress` phase + %, 10s cap / 120 polls). Do not build a second one.
- Copy: **"Creating your 3D model — this usually takes a few minutes."**
- On failure: friendly mapped copy (`failureCopy`) + **Try again** → the
  Prepare-Images path. Never surface a raw URL or error.

### C2 — The badge

**"AI generated — preview quality"** on auto-generated models. This is the
cheapest quality lever available: a 4-photo Meshy model presented as a finished
product disappoints; the same model presented as an AI preview delights. Do not
drop it because it looks like a caveat.

### C3 — Regenerate → Prepare-Images

A **Regenerate** action on the model view opens the existing Prepare-Images
screen with manual photo selection + lighting adjustment, then the existing
staff create path. This is what keeps today's Prepare-Images work reachable and
gives users an override when auto-selection picks badly.

> Note: Prepare-Images and the manual create endpoint are staff-gated today. If
> owners get Regenerate, the gating has to be revisited — surface this rather
> than silently widening a staff surface to all users.

---

## Tests & verification

**Order matters — the failure modes here are expensive and silent.**

1. **Selector against REAL manifests, offline.** Pull several real
   `capture_manifest.json` files from S3, run the selector, and *eyeball the four
   chosen images*. This is where the heuristic actually gets tuned, and it costs
   nothing. Do this before writing anything downstream.
2. **Key mapping** against a real `listObjectsUnderPrefix` result — the highest
   risk unknown in the whole feature.
3. **Idempotency with the Meshy client stubbed.** Run the capture processor twice
   for the same job; assert exactly one `ProjectModel` and zero second submissions.
4. **Guards:** kill switch off → nothing enqueued; low-quality manifest →
   nothing enqueued; cap reached → nothing enqueued.
5. **Regression:** full `recapture-api` suite green; the capture pipeline's own
   behavior unchanged when auto-gen is disabled (the default).
6. **ONE live end-to-end run** with a real capture and a real Meshy key. One.
   Then *look at the model* before running a second.

---

## Definition of done

- [ ] `autoPhotoSelectionService.ts` — pure, tested against real manifests,
      spread-over-sharpness verified.
- [ ] Key mapping verified against a real S3 listing; unmatched keys skipped.
- [ ] `autoModelGenerationService.ts` — four guards, tested in isolation.
- [ ] Env vars + remote-config flag; **defaults OFF**.
- [ ] Capture processor chains the trigger; a throw there cannot fail the capture.
- [ ] Owner surface reports generating / ready / failed; DTO stays minimal.
- [ ] Client: three states, badge, Regenerate → Prepare-Images.
- [ ] Full suite green; capture pipeline untouched with the flag off.
- [ ] Live E2E recorded: exactly one generation charged; model inspected by a human.

---

## Open items to confirm while implementing (don't guess — verify)

1. **`imagePath` → relative-key mapping** (T1). The one thing that will silently
   waste money if wrong.
2. **Remote-config flag plumbing** — confirm the client/worker both read it and
   that the worker sees changes without a restart.
3. **Regenerate gating** — Prepare-Images is staff-only today (C3).
4. **Meshy fidelity from auto-selected photos.** The staff flow's fidelity
   sign-off is still open in the companion doc. Auto-selection changes the input
   distribution — re-check before enabling the flag in production.
