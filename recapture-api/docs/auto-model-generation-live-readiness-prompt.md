# Implementation Prompt — Auto Model Generation: Live-Readiness Fixes

Read [AGENTS.md](../../AGENTS.md) first; it wins over anything here.
Companion to [auto-model-generation-implementation-prompt.md](./auto-model-generation-implementation-prompt.md),
which specified the feature. This one fixes the four defects that stand
between that implementation and its **first live run**.

**Order matters: do B4 before B3.** B3's fix needs the job identity B4 pins
down; done in the other order, B3 lists keys from one job and validates them
against another, silently dropping every candidate.

## Context — why this exists

The auto-generation feature is built on both sides and its tests are green
(341 backend / 2128 Flutter), but it has never processed a real capture. An
audit found that on a real device capture it would **silently decline 100% of
the time** and never call Meshy. The backend tests pass because their manifest
fixtures carry fields the shipping client does not actually emit.

Do not treat a green suite as evidence here. The bug class in B1 and B4 is
specifically "the synthetic setup disagrees with the real one" — a fixture that
carries fields the producer doesn't emit (B1), and a test project that only
ever has one capture job (B4). The fixtures are the thing under suspicion.

An audit of everything downstream of a `SELECTED` outcome found the rest of the
chain sound, and these facts are load-bearing — do not "fix" them:

- The trigger runs at the processor's tail, **before** `markCompleted`
  (`src/worker/worker.ts:168-169`), so the job is still in `OPTIMIZING` when
  `findExportableJob` runs. That state is in `UPLOAD_FINALIZED_JOB_STATES`
  (`src/services/adminProjectsService.ts:52-60`), which is the only reason job
  resolution succeeds at all. Narrowing that list to `COMPLETED` would kill the
  feature a second, independent way.
- The replay guard is a real unique index with a partial filter on
  `{createdByUserId, idempotencyKey}` (`src/models/ProjectModel.ts:148-150`),
  so records without a key do not collide.
- The owner surface agrees on both sides: the route returns
  `{project, model, generation}` (`src/routes/projects.ts:153-157`) and
  `OwnerGenerationView.tryParse` reads exactly those field names
  (`lib/domain/entities/project_model.dart:266-278`).

---

## B1 — The shipping manifest emits no blur scores (FATAL)

### The defect

`selectPhotosForAutoGeneration` requires a finite numeric blur score per photo
and `continue`s past anything else:

```ts
// src/services/autoPhotoSelectionService.ts:259-260
const blurScore = photo.quality?.blurScore;
if (typeof blurScore !== 'number' || !Number.isFinite(blurScore)) continue;
```

The client drops that value before the manifest is written. The data exists at
the source and is discarded one hop later:

| Stage | `blurScore` | Location |
|---|---|---|
| `CapturedPhotoRecord` | present, non-null `double` | `lib/application/capture/ledger/captured_photo_record.dart:17` |
| → `BundleSourceImage` | **dropped** | `lib/application/upload/capture_bundle_packer.dart:153-158` |
| → `PlannedBundleImage` | no such field | `lib/domain/upload/capture_bundle.dart:88-121` |
| → `ManifestPhoto` | never passed | `lib/application/upload/capture_bundle_packer.dart:234-248` |

Result: every real bundle uploads
`"quality": {"blurScore": null, "meanLuminance": null}` and
`"orientation": {"yawDegrees": null, "pitchDegrees": null}`, so
`candidates.length === 0` and the outcome is always
`SKIPPED / NOT_SELECTABLE / NO_USABLE_PHOTOS`.

`capture_manifest_assembler.dart:167-170` populates all four fields correctly —
but that producer is **not** the one in the upload path. `capture_bundle_packer.dart`
is. Use the assembler as the reference for what the packer should be doing.

### The fix

Thread four fields — `blurScore`, `meanLuminance`, `yawDegrees`, `pitchDegrees`
— from the ledger record through to the manifest photo.

1. **`lib/domain/upload/capture_bundle.dart`** — add the four fields to
   `BundleSourceImage` and to `PlannedBundleImage`. Make them **required and
   non-nullable** (`double`): `CapturedPhotoRecord` declares all four as
   required non-null, so nullability here would invent an absent case that
   cannot occur, and `required` makes the compiler enforce every construction
   site. Carry them across in the `planBundleImages` loop
   (`capture_bundle.dart:151`) alongside `segmentIndex` / `warned`.
   Leave `_compareSources` and `_dedupePerSegment` alone — ordering and
   per-segment collapse must not change behaviour.

2. **`lib/application/upload/capture_bundle_packer.dart:153-158`** — pass
   `rec.blurScore`, `rec.meanLuminance`, `rec.yawDegrees`, `rec.pitchDegrees`
   into `BundleSourceImage`.

3. **`lib/application/upload/capture_bundle_packer.dart:234-248`** — pass
   `img.blurScore`, `img.meanLuminance`, `img.yawDegrees`, `img.pitchDegrees`
   into `ManifestPhoto`.

Keep `ManifestPhoto`'s own fields **nullable as they are** — that class is
shared with the assembler and with pre-existing persisted manifests. Only the
bundle-path structs tighten.

Blast radius is small: three `BundleSourceImage(` and two `PlannedBundleImage(`
construction sites exist repo-wide (`test/upload/capture_bundle_test.dart` plus
the two lib files above).

### Tests (this is the part that must not be skipped)

- **`test/upload/capture_bundle_packer_test.dart`** — the load-bearing one. Pack
  a bundle from ledger records with known distinct blur/yaw values, then read
  back the **generated manifest JSON** (not the Dart objects) and assert
  `photos[i]['quality']['blurScore']` and `photos[i]['orientation']['yawDegrees']`
  are the expected non-null numbers. Asserting on the intermediate structs would
  miss exactly the bug that shipped. Include an explicit
  "no photo has a null blurScore" assertion over the whole array — that is the
  regression guard.
- **`test/upload/capture_bundle_test.dart`** — assert `planBundleImages`
  preserves the four values, including through the per-segment dedupe path (the
  surviving record's values must be the surviving record's, not the collapsed
  one's).
- **Backend, `recapture-api/tests/`** — add a selector case built from a manifest
  fixture generated by the *real* packer shape (see the verification step below),
  proving it now returns `SELECTED`. Keep the existing `NO_USABLE_PHOTOS` case;
  it is still correct behaviour for a genuinely blur-less manifest.

---

## B2 — The feature flag is off

`AUTO_MODEL_GENERATION_ENABLED` is absent from `recapture-api/.env` and defaults
to `false` (`src/config/env.ts:124-127`), so generation short-circuits at guard 1
with `SKIPPED / DISABLED / env` before anything else runs.

Add to `recapture-api/.env` for local testing only:

```
AUTO_MODEL_GENERATION_ENABLED=true
```

Do **not** change the schema default, and do **not** enable it in
`.env.staging` / `.env.prod` as part of this work. Shipping dark is deliberate
(the env gate requires a deploy by design; the remote-config flag is the live
kill switch on top of it). `MESHY_API_KEY` and `RUN_WORKER_IN_PROCESS=true` are
already set locally, so the rest of the chain is ready.

Leave the remote-config flag unset — unset means enabled, and the env gate is
the opt-in.

---

## B3 — `availableKeys` is computed and then thrown away

`captureProcessingProcessor.ts:133` calls:

```ts
autoGeneration = await maybeAutoGenerateModel({ job, manifest: parsedManifest });
```

without `availableKeys`, despite having listed the job prefix eleven lines
earlier at `captureProcessingProcessor.ts:63-65` (it keeps only `.length`).

That option is the guard that drops a manifest entry whose object never landed,
instead of handing Meshy a presigned URL that 404s and burning a paid
generation. It matters most on a first live run, where a path-shape mismatch
between producer and selector is exactly the failure in play.

### The fix

**Do B4 first.** The listing here comes from the job being processed; the keys
are ultimately presigned against whatever job the model record points at. Until
B4 makes those the same job by construction, passing `availableKeys` can turn a
silent wrong-prefix bug into a silent no-candidates bug.

Retain the filtered listing's keys, convert each to a key **relative to
`upload.rawPrefix`** (the selector compares against relative keys like
`images/EYE/eye_0001.jpg`, not absolute bucket keys — getting this backwards
silently drops every candidate and reintroduces B1's symptom), and pass them
through. Keep the existing count check on the same filtered list so the
`model-input/` exclusion still holds.

Add a processor test asserting that a manifest entry with no corresponding S3
object is excluded from the selection.

---

## B4 — The generation is pinned to the wrong capture job

### The defect

`createMeshyModelRequest` ignores the job its caller is working on and
re-resolves one by project:

```ts
// src/services/projectModelsService.ts:219
const job = await findExportableJob(projectId);
```

`findExportableJob` returns the **newest** finalized capture job for the project
(`adminProjectsService.ts:469-477`, `sort({ createdAt: -1 })`). That was correct
for the staff path, where a human is curating the current state of a project.
It is wrong for the automatic path, which is acting on one specific job — the
one whose manifest the photos were just selected from.

The record stores that re-resolved job (`jobId: job._id`), and the Meshy
processor presigns the selected keys against **its** prefix:

```ts
// src/worker/processors/meshyModelProcessor.ts:112-119, 177-178
const captureJob = await Job.findById(record.jobId).exec();
const { rawBucket, rawPrefix } = captureJob.upload;
...presignObjectGetUrl(rawBucket, `${rawPrefix}${key}`, ...)
```

So if a project acquires a newer finalized capture job between the selection and
the record write — a user recapturing while the first capture is still
processing — job A's keys are presigned under job B's prefix. Best case every
URL 404s and a paid generation is burned on nothing. Worse case the two jobs
share a filename shape and Meshy is handed **photos of a different capture**,
producing a plausible-looking model of the wrong object.

Severity is narrow but the failure is quiet: in the ordinary
one-capture-at-a-time case the processing job *is* the newest, so this works,
which is exactly why it would survive a long time undetected.

### The fix

1. **`src/services/projectModelsService.ts`** — add an optional `jobId` to
   `CreateMeshyModelRequestInput`. When supplied, load that job by id
   (still requiring `job.upload`, still returning `NOT_EXPORTABLE` when it is
   missing or unusable) instead of calling `findExportableJob`. When absent,
   keep the existing behaviour **unchanged** — the staff path depends on
   "newest exportable job" semantics and must not shift.
2. **`src/services/autoModelGenerationService.ts`** — pass `jobId: job._id` in
   the `createMeshyModelRequest` call. The automatic path always knows its job;
   it should never be guessing.

Do not "simplify" by making `jobId` required and updating the staff callers to
pass `findExportableJob`'s result. That moves a resolution rule out of the
service and into every caller, and the staff surface genuinely wants the newest
job at request time.

### Tests

- A project with **two** finalized capture jobs where the OLDER one triggers
  auto-generation: assert `record.jobId` is the older (triggering) job, not the
  newest. This is the regression test — without a second job in the fixture the
  bug is invisible, which is how it got here.
- The staff path with no `jobId` still resolves via `findExportableJob` and
  still picks the newest job.
- `NOT_EXPORTABLE` when an explicitly-passed `jobId` has no `upload` block.

---

## Verification — the actual point of this work

Passing tests do not close this out. Required, in order:

1. **Capture a real bundle on a device** and pull its `capture_manifest.json`
   out of S3. Confirm by eye that `quality.blurScore` and
   `orientation.yawDegrees` are populated for every photo.
2. **Run that real manifest through the selector** (it is pure and synchronous —
   no infrastructure needed) and **eyeball the four chosen photos**. They must
   be sharp and must look at the object from genuinely different sides. Spread
   is the constraint, sharpness only the within-quadrant tiebreak; four crisp
   frames of one face is a failure even though it is a `SELECTED` outcome.
3. **Confirm the quadrant path.** With yaw now populated, verify selection still
   resolves quadrants via `segmentIndex` + `config.segmentCounts` (the
   trustworthy path — yaw drifts over a session through IMU integration error).
   Ring size must come from `config.segmentCounts`, never be inferred from the
   photos present.
4. **One end-to-end run**: capture → upload → worker → real Meshy call → owner
   sees the model badged "AI generated — preview quality". Watch the worker log
   for the `Auto model generation decision` line and confirm `outcome: ENQUEUED`.
5. **Re-run the same job** (re-claim or retry) and confirm the second pass
   reports `SKIPPED / ALREADY_EXISTS` and does **not** spend again.
6. **The two-job case (B4).** Capture the same project twice so a second
   finalized capture job exists, then let the older job's generation run.
   Confirm the resulting model's `jobId` is the older job and that the photos
   Meshy received are that job's photos. Cheapest check: compare the record's
   `selectedKeys` against the objects actually under the triggering job's
   prefix — every key must exist there.

## Definition of done

- [ ] A packer-generated manifest carries non-null `blurScore` and `yawDegrees`
      for every photo, asserted against the emitted JSON.
- [ ] `flutter test` and `npm test` both green; no construction site left behind.
- [ ] A real device manifest yields `SELECTED` with four visually well-spread,
      sharp photos.
- [ ] One live end-to-end generation completed and visible to the owner.
- [ ] Replay of the same capture job spends nothing.
- [ ] An auto-generation triggered by a job that is NOT the project's newest
      still resolves keys against its OWN job prefix.
- [ ] The staff Create-Model path's job resolution is provably unchanged.
- [ ] `AUTO_MODEL_GENERATION_ENABLED` remains absent/false everywhere except
      the local `.env`.

## Do not

- Do not relax the selector's blur requirement to "work around" B1. The absent
  score is the bug; a selector that picks blind would spend money on unusable
  captures, which is the one thing the guards exist to prevent.
- Do not infer ring size from photo `segmentIndex` values.
- Do not change `findExportableJob` itself, or narrow
  `UPLOAD_FINALIZED_JOB_STATES`. B4 is fixed by giving the automatic path a way
  to say which job it means — not by redefining what "exportable" means for the
  staff surfaces that already depend on it.
- Do not make the auto-generation trigger able to fail a capture job. It stays
  strictly last and strictly best-effort — a user must never re-shoot 48 photos
  because a generation could not be enqueued.
