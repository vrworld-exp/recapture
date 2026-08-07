# Implementation prompt — "Optimize" action + `OPT` model variant

**Branch:** `feature/meshy-model-opt-2`
**Codebases:** `recapture-api/` (Node/TS backend + worker) and the Flutter client at the repo root.
**Read `AGENTS.md` first.** Where this prompt disagrees with a foundational convention, AGENTS.md wins.

---

## 1. What we are building, in one paragraph

A generated 3D model (a `ProjectModel` record) can be **large** — a raw Meshy GLB is
routinely 15–60 MB, which is a bad download on a phone and slow to first paint in
`<model-viewer>`. We are adding a one-tap **Optimize** action to the per-project model
list. When a model's GLB is **larger than 8 MB**, the row shows an **Optimize** button.
Tapping it enqueues a background job that runs the model through a glTF-Transform
pipeline (dedup / prune / weld / texture recompression / meshopt) and writes the result
back into **the same project's model list** as a new entry badged **`OPT`**. Once an
optimized entry exists for a model, the button disappears from that row — a model is
optimized at most once.

The button and the badge must be **visually distinct**: the button is an action
affordance, the badge is a state label. They must never be confusable.

---

## 2. Ground truth — what already exists on this branch

Do not re-derive these; read them before writing code.

### Backend

| Thing | Location |
| --- | --- |
| Model record schema | `recapture-api/src/models/ProjectModel.ts` |
| Shared model types (`MODEL_SOURCES`, `MODEL_STATUSES`, `ModelArtifacts`, …) | `recapture-api/src/models/types/projectModel.types.ts` |
| Service + DTOs (`ProjectModelDto`, `OwnerModelDto`, `listProjectModels`, `latestSucceededModel`, `pendingOwnerGenerationFor`, `approveModel`) | `recapture-api/src/services/projectModelsService.ts` |
| Staff routes: `GET /admin/projects/:id/models`, `POST /admin/projects/:id/models/:modelId/approve` | `recapture-api/src/routes/admin.ts` |
| Owner routes (`GET /projects/:id` returns `model` + `generation`) | `recapture-api/src/routes/projects.ts` |
| Job types + queue document | `recapture-api/src/models/Job.ts` (`CAPTURE_PROCESSING_JOB_TYPE`, `MESHY_MODEL_GENERATION_JOB_TYPE`) |
| Processor registry | `recapture-api/src/worker/processorRegistry.ts`, registered in `src/worker/workerRuntime.ts` |
| Reference processor (S3 re-host, fenced stages, progress writes, retry vs terminal) | `recapture-api/src/worker/processors/meshyModelProcessor.ts` |
| S3 helpers (`getObjectBytes`, `putObjectBytes`, `headObject`, `copyObject`) | `recapture-api/src/services/s3ObjectStore.ts` |
| Artifact bucket + CDN base | `recapture-api/src/config/s3.ts` (`BUCKET_ARTIFACTS`, `CLOUDFRONT_BASE`) |

Key facts:

* Artifacts live at **`{captureJob.upload.rawPrefix}models/{modelId}/model.glb`** in
  `BUCKET_ARTIFACTS`, and only our CloudFront URLs are ever persisted
  (`meshyModelProcessor.rehostArtifacts`).
* `ModelArtifacts` **has no size field today.** That is the first thing to add — the
  8 MB rule has nothing to read otherwise.
* `MODEL_SOURCES` is `['meshy', 'manual']`.
* `listProjectModels(projectId)` returns the whole history newest-first; that is exactly
  what the staff list screen renders.

### Client

| Thing | Location |
| --- | --- |
| Model entity + both parsers | `lib/domain/entities/project_model.dart` (`ProjectModelView.tryFromStaffMap` / `tryFromOwnerMap`) |
| Staff model list UI (`_ModelRow`, `_ApprovedBadge`, `_RowThumbnail`) | `lib/presentation/screens/projects/model_history_screen.dart` |
| Polling notifier for that list | `lib/application/projects/model_generation_notifier.dart` |
| HTTP calls | `lib/data/repositories/live_projects_repository.dart` (`/admin/projects/$id/models`, `…/approve`, …) |
| Viewer + `<model-viewer>` host | `lib/presentation/screens/projects/model_render_view.dart` (`ModelViewer(src: srcFor(glbUrl), relatedJs: _lifecycleJs)`) |
| Web `<model-viewer>` script tag | `web/index.html` |
| Role split for the Models button | `lib/presentation/screens/projects/projects_screen.dart` → `_onModels` |

Key fact: **there is no owner-facing models LIST endpoint on this branch.** Staff open
the history screen (`/admin/projects/:id/models`); a non-staff owner's "Models" tap falls
through to `_onView` and opens the newest finished model directly. Section 6 says what to
do about that.

---

## 3. The optimizer

Use this as the starting pipeline. It is **known-good in shape but not yet correct for
this repo** — the required corrections are listed underneath, and you must apply them.

```js
import fs from "node:fs";
import { NodeIO } from "@gltf-transform/core";
import { ALL_EXTENSIONS } from "@gltf-transform/extensions";
import { dedup, prune, weld, textureCompress, meshopt } from "@gltf-transform/functions";
import { MeshoptEncoder } from "meshoptimizer";
import sharp from "sharp";

export async function optimize(input, output) {
  await MeshoptEncoder.ready;

  const io = new NodeIO()
    .registerExtensions(ALL_EXTENSIONS)
    .registerDependencies({ "meshopt.encoder": MeshoptEncoder });

  const doc = await io.read(input);

  await doc.transform(
    dedup(),   // merge duplicate materials/accessors
    prune(),   // drop unused nodes + orphan textures
    weld(),    // merge split vertices (Meshy leaves a lot)

    // Base color does all the visual work → keep 1K
    textureCompress({
      encoder: sharp, targetFormat: "webp", slots: /baseColor/,
      resize: [1024, 1024], quality: 82,
    }),
    // Roughness/metallic/AO are low-frequency → 512 is invisible on a phone
    textureCompress({
      encoder: sharp, targetFormat: "webp", slots: /(metallicRoughness|occlusion|emissive)/,
      resize: [512, 512], quality: 80,
    }),
    // Normals artifact badly under lossy → same size, higher quality
    textureCompress({
      encoder: sharp, targetFormat: "webp", slots: /normal/,
      resize: [512, 512], quality: 92,
    }),

    meshopt({ encoder: MeshoptEncoder, level: "high" }),
  );

  await io.write(output, doc);

  const mb = fs.statSync(output).size / 1e6;
  const bbox = getSize(doc);
  console.log(`${output}: ${mb.toFixed(2)} MB, longest dim ${bbox.toFixed(3)} m`);
  if (mb > 2) console.warn("⚠ over 2MB budget — drop baseColor to 768");
  if (bbox > 0.6 || bbox < 0.02) console.warn("⚠ auto_size looks wrong — set scale override manually");

  return output;
}

function getSize(doc) {
  let max = 0;
  for (const mesh of doc.getRoot().listMeshes())
    for (const prim of mesh.listPrimitives()) {
      const pos = prim.getAttribute("POSITION");
      const min = pos.getMinNormalized([]), mx = pos.getMaxNormalized([]);
      for (let i = 0; i < 3; i++) max = Math.max(max, mx[i] - min[i]);
    }
  return max;
}
```

### Required corrections before it goes in

1. **Port it to TypeScript**, put it at
   `recapture-api/src/services/modelOptimizerService.ts`, and export a pure function:
   `optimizeGlb(input: Uint8Array, opts): Promise<OptimizeGlbResult>`.
2. **No filesystem.** The worker runs on Render with an ephemeral, sometimes read-only
   FS. Use `io.readBinary(bytes)` / `io.writeBinary(doc)` — never `io.read(path)` /
   `io.write(path)` / `fs.statSync`. Output size is `out.byteLength`.
3. **`prune()` must run again after the `textureCompress` passes**, not only before —
   recompression orphans the originals. Order: `dedup → weld → prune → texture… → prune → meshopt`.
4. **Measure the bbox BEFORE `meshopt()`.** After meshopt the position accessors are
   quantized/compressed and `getMinNormalized` no longer describes the source geometry.
5. **The bbox is per-primitive and ignores node transforms**, so calling it "metres" is
   wrong for any scene whose nodes carry scale. Either walk the node graph and apply the
   world matrix, or rename it to `localBboxLongestAxis` and stop presenting it as metres.
   Do not ship a warning that fires on correct models.
6. **The size budget must be a parameter, not a hardcoded `2`.** The gate for this
   feature is 8 MB (§4); a warning that fires at 2 MB in a system with an 8 MB threshold
   is noise. Take `budgetBytes` in `opts` and return a boolean rather than
   `console.warn` — worker code logs through `@/worker/workerLog`, never `console`.
7. **`sharp` is optional at runtime.** If `sharp` fails to load (missing native binary
   for the platform), the texture passes must be skipped and the mesh passes must still
   run, with the degradation recorded on the result — a broken native dep must not turn
   into a hard failure of the whole feature.
8. **Guard the input size.** Refuse anything over `MODEL_OPTIMIZE_MAX_INPUT_BYTES`
   (new env var, default 250 MB) with a terminal error. glTF-Transform holds the whole
   document in memory; a 400 MB GLB will OOM the worker and take the API down with it if
   `RUN_WORKER_IN_PROCESS` is on.

### Dependencies

Add to **`dependencies`** (not devDependencies) in `recapture-api/package.json`:
`@gltf-transform/core`, `@gltf-transform/extensions`, `@gltf-transform/functions`,
`meshoptimizer`, `sharp`. Note in the PR description that `sharp` ships a platform-native
binary and confirm the Render build installs the linux-x64 variant.

---

## 4. Backend data model

### 4.1 Record the GLB size

Add to `ModelArtifacts` (`projectModel.types.ts`) and the mongoose sub-schema:

```ts
/** Byte length of the GLB in S3. Written when the artifact is stored; the ONLY
 *  input to the "is this worth optimizing?" rule. Optional because every record
 *  written before this field existed has none. */
glbBytes?: number;
```

* `meshyModelProcessor.rehostArtifacts` already has the downloaded buffer — record
  `bytes.length` there. Free.
* **Backfill for existing records:** in `listProjectModels`, for any SUCCEEDED record
  with `artifacts.glbKey` and no `glbBytes`, `headObject` it once and write the value
  back. Do this concurrently and **best-effort** — a HEAD failure must degrade to
  "size unknown", never fail the list request.
* **`glbBytes` absent ≠ small.** Absent means *unknown*; the Optimize button must not
  render on an unknown size. Say this in a comment — it is the same class of bug as
  treating a missing flag as `false`.

### 4.2 Represent the optimized model

Add `'optimized'` to `MODEL_SOURCES` and two fields to `ProjectModel`:

```ts
/** Set on an OPTIMIZED record: the id of the model it was derived from. A record
 *  with this set is a DERIVATIVE, never a paid generation. */
optimizedFrom?: Types.ObjectId;

/** Byte savings, for the UI's "OPT · 4.2 MB (−68%)" label. */
optimization?: { sourceBytes: number; outputBytes: number; at: Date };
```

Add a **unique partial index** on `optimizedFrom` — this is the race authority that
makes a double-tap create one record, not two:

```ts
ProjectModelSchema.index(
  { optimizedFrom: 1 },
  { unique: true, partialFilterExpression: { optimizedFrom: { $exists: true } } }
);
```

**Why a separate record and not a `variants[]` array on the existing one:** the ask is
that the optimized model *appears in the model list*. A separate record gets that from
`listProjectModels` for free, keeps `approve` semantics unchanged, and keeps the
optimized artifact in its own S3 prefix. If you choose otherwise, say so and justify it.

### 4.3 Four consequences you must handle

These are the places an extra record leaks somewhere it should not:

1. **`pendingOwnerGenerationFor`** returns the newest non-SUCCEEDED record. A running
   optimization would show the owner a "generating your model…" spinner for a model they
   already have. **Exclude `source: 'optimized'`** from that query.
2. **`countServerSelectedGenerationsInLast24h`** filters on
   `createdBySystem`/`createdByManualButton`; optimization records set neither, so they
   correctly don't consume generation credits. Add a test that pins this — optimization
   costs no Meshy money and must never eat the daily cap.
3. **`latestSucceededModel`** will now return the OPT record once it succeeds. That is
   **desirable** (the owner should get the small file), but it changes what
   `GET /projects/:id` returns and what `_onView` opens. Verify the OPT record's
   `usdzUrl`/`previewUrl` are populated (§5) or you will silently break AR and thumbnails.
4. **`Project.modelCount`** (the aggregation that decides whether the "Models" button
   renders) will increment. Harmless, but confirm the aggregation counts SUCCEEDED only
   and note the behaviour change.

---

## 5. Backend — the job

New job type `MODEL_OPTIMIZATION_JOB_TYPE = 'MODEL_OPTIMIZATION'` in `src/models/Job.ts`,
exported alongside the existing two. New processor
`src/worker/processors/modelOptimizationProcessor.ts`, registered in
`src/worker/workerRuntime.ts` next to the others.

Flow, modelled closely on `meshyModelProcessor`:

1. Read `payload.modelId` → the **OPT record**. Malformed payload or missing record →
   `NonRetryableJobError`.
2. Load the source record via `optimizedFrom`; load its capture `Job` for
   `upload.rawPrefix`. Missing source artifacts → `NonRetryableJobError`.
3. `enterStage(job._id, claimedBy, 'PROCESSING')`, set the OPT record `PROCESSING`,
   `reportProgress(record, 'PREPARING', 0)`.
4. `getObjectBytes(BUCKET_ARTIFACTS, source.artifacts.glbKey)`.
   Enforce `MODEL_OPTIMIZE_MAX_INPUT_BYTES`.
5. `reportProgress(record, 'GENERATING', 50)` → `optimizeGlb(bytes, { budgetBytes })`.
   Reuse the existing `MODEL_PROGRESS_PHASES` rather than inventing new ones, so the
   client's `ModelProgressPhase` enum and its `unknown` fallback keep working.
6. **Reject a non-win.** If `outputBytes >= sourceBytes * 0.95`, fail the record
   terminally with `OPTIMIZATION_INEFFECTIVE` / "This model is already close to its
   smallest size." A duplicate entry that is 3 % smaller is clutter, not a feature.
   *(Judgment call — flag it in the PR so it can be reversed cheaply.)*
7. `reportProgress(record, 'FINALIZING', 100)`; write artifacts under the **OPT record's
   own** prefix `{rawPrefix}models/{optModelId}/`:
   * `model.glb` ← the optimized bytes (`putObjectBytes`, `model/gltf-binary`).
   * `preview.jpg` ← **`copyObject`** from the source record's `previewImageKey` if it
     has one, so the OPT row has a thumbnail instead of a grey placeholder.
   * `model.usdz` ← **`copyObject`** from the source's `usdzKey` if present. The USDZ is
     **not** optimized (it is a different format and AR Quick Look consumes it directly);
     copying it keeps the iOS AR path alive on the record that `latestSucceededModel`
     now returns.
   Keys are deterministic per OPT record, so a retried re-host overwrites rather than
   duplicating — same guarantee the Meshy processor relies on.
8. `status = 'SUCCEEDED'`, set `artifacts` (with `glbBytes = outputBytes`) and
   `optimization`, `clearProgress`.
9. Error routing: S3/network → plain `Error` → worker retry/backoff. Parse failures,
   oversize input, ineffective result, missing source → `NonRetryableJobError` → terminal
   `FAILED` with a mapped, user-safe message. Never interpolate a presigned URL or an S3
   key into an error message that reaches the client.

---

## 6. Backend — the routes

One service function, `requestModelOptimization({ projectId, modelId, actor })`, in
`projectModelsService.ts`, returning a typed result union (no Express types in services):

```
| { outcome: 'PROJECT_NOT_FOUND' }
| { outcome: 'MODEL_NOT_FOUND' }
| { outcome: 'NOT_OPTIMIZABLE'; reason: 'NOT_SUCCEEDED' | 'NO_GLB' | 'SIZE_UNKNOWN' | 'BELOW_THRESHOLD' | 'ALREADY_OPTIMIZED' | 'IS_OPTIMIZED' }
| { outcome: 'REPLAYED'; model: IProjectModel }   // an OPT record already exists
| { outcome: 'CREATED';  model: IProjectModel }
```

**The server is the authority.** The client's button visibility is a courtesy; every one
of these conditions is re-checked here, and the unique `optimizedFrom` index is what
actually prevents a double-tap from creating two records (catch `E11000` → `REPLAYED`,
exactly like `createMeshyModelRequest` does).

Order of operations mirrors the money contract in `createMeshyModelRequest`: **insert the
OPT record first, then enqueue the `Job`.** If the enqueue throws, flip the record to
`FAILED` with `ENQUEUE_FAILED` so it cannot sit `QUEUED` forever.

Two routes, both thin:

* **Staff:** `POST /admin/projects/:id/models/:modelId/optimize` in `admin.ts`, behind
  the existing router-level MODEL_ARTIST+ gate. Place it next to `…/approve` and copy its
  param validation and analytics shape.
* **Owner:** `POST /projects/:id/models/:modelId/optimize` in `projects.ts`, scoped to
  the authenticated owner of the project. Collapse `MODEL_NOT_FOUND` and
  "not your project" into one 404 — the enumeration-safety rule the owner routes already
  follow.

Both return `{ status: 'success', model: <dto> }` with **201** on `CREATED` and **200**
on `REPLAYED`; `NOT_OPTIMIZABLE` → **409** with a stable `code`.

Rate-limit the owner route with the existing rate-window helper (it is CPU-expensive even
though it costs no Meshy credits).

### Exposing eligibility

* **`ProjectModelDto`** (staff): add `glbBytes?`, `optimizedFromId?`,
  `optimization?: { sourceBytes; outputBytes }`, and a computed
  **`canOptimize: boolean`** — the server's own verdict, so the client never
  re-implements the rule and the two can never disagree.
* **`OwnerModelDto`**: add `sizeBytes?`, `isOptimized: boolean`, `canOptimize: boolean`.
  Nothing else — no S3 keys, no `optimizedFrom` ObjectId, no staff actor ids. The owner
  DTO's existing minimalism is deliberate.

`canOptimize` is true iff: `status === 'SUCCEEDED'` **and** the record has a GLB **and**
`glbBytes` is known **and** `glbBytes > MODEL_OPTIMIZE_THRESHOLD_BYTES` **and**
`source !== 'optimized'` **and** no OPT child exists in `QUEUED | PROCESSING | SUCCEEDED`.

* Threshold: new env `MODEL_OPTIMIZE_THRESHOLD_BYTES`, default **`8 * 1024 * 1024`**
  (8 MiB). Pin the binary-vs-decimal choice in the config comment — "8 MB" is ambiguous
  and the client's displayed size must use the same divisor as the gate, or a model will
  read "8.0 MB" with no button.
* A **`FAILED`** OPT child does **not** hide the button — otherwise one transient S3
  error permanently removes the only way to optimize that model. *(This is a deliberate
  reading of "if opt is present, remove the button": present means present-and-not-broken.
  Flag it in the PR.)*

---

## 7. Client

### 7.1 Entity

In `lib/domain/entities/project_model.dart`, extend `ProjectModelView` with
`sizeBytes`, `isOptimized`, `canOptimize`, `optimizationSavingPercent`. Parse them in
**both** `tryFromStaffMap` (`glbBytes`, `source == 'optimized'`, `canOptimize`,
`optimization`) and `tryFromOwnerMap` (`sizeBytes`, `isOptimized`, `canOptimize`).
Follow the file's existing discipline: every new field defaults to the safe value when
absent, so an older backend degrades to "no button, no badge" rather than throwing.

Add `'optimized'` to `ModelSource.parse`. Give it `badgeLabel => null` — the OPT chip is
its own thing and must not also print "Created by Maya AI".

### 7.2 The list row — `model_history_screen.dart`

Modify `_ModelRow`:

* **Secondary line** shows the size when known: `4 photos · 21.4 MB`. Use a small
  `_formatBytes` helper with the **same divisor as the backend threshold**.
* **`_OptBadge`** — the label. Must read as a *state*, not a button:
  a filled pill, `AppColors` accent that is **not** `mirageRed` (that colour already means
  "Approved" on this row — reusing it makes two different facts look identical), radius
  `AppRadius.xs`, uppercase `OPT`, plus the saving: `OPT · 6.8 MB (−68%)`.
  Non-interactive, no ripple, no chevron of its own.
* **`_OptimizeButton`** — the action. A compact **outlined** trailing button labelled
  `Optimize` with a "compress"/`Icons.compress` leading icon, sitting where the chevron
  is, so it is unmistakably tappable and unmistakably not the badge. Rendered **only**
  when `model.canOptimize`. Shows an inline spinner and goes disabled while its request
  is in flight.
* A **pending OPT record** is just another row (`status.isPending`) — the existing
  spinner branch and the notifier's polling already handle it. Give its `_detail` line
  optimization-specific copy (`Optimizing — shrinking textures and geometry…`) keyed off
  `source == optimized`, rather than the generic generation copy.

### 7.3 Wiring

* `live_projects_repository.dart`: add `optimizeModel(projectId, modelId)` hitting the
  staff route, and `optimizeOwnerModel(...)` hitting the owner route. Map the 409 `code`
  to friendly copy through the existing `failureCopy` path — never surface a raw code.
* `model_generation_notifier.dart`: after a successful POST, `refresh()` so the new
  pending OPT row appears immediately and the existing polling loop drives it to done.
  Do not add a second polling loop.
* **Owner surface.** There is no owner models list on this branch, so the owner's entry
  point is the viewer: put the same button in `model_render_view.dart` /
  `model_viewer_screen.dart`, driven by the owner DTO's `canOptimize`, with an
  `isOptimized` badge in the same place the source badge renders. If the product wants a
  full owner list instead, that is a separate prompt — do not grow one here.

### 7.4 ⚠ The optimized model will not load unless you do this

`meshopt()` writes `EXT_meshopt_compression` into **`extensionsRequired`**.
`<model-viewer>` ships DRACO and KTX2 decoder locations **by default but not a meshopt
one** — so without configuration `GLTFLoader` throws and the app shows the generic
"couldn't load this model" error for *every* optimized model. The decoder is already
bundled with the `model_viewer_plus` assets; the URL is only a trigger.

Set `meshopt-decoder.js` as the decoder location in **both** places, or the feature ships
broken on one platform:

1. **Web:** on the `<model-viewer>` element in `web/index.html`.
2. **Mobile:** inside `relatedJs` (`_lifecycleJs`) in `model_render_view.dart`, which is
   the WebView's own HTML template and does not inherit anything from `web/index.html`.

**Acceptance for this section is visual, not unit-testable:** an actual optimized GLB
renders in the Android/iOS viewer *and* in the web build. Do not mark the feature done on
green tests alone.

Also relevant: `srcFor(glbUrl)` appends an `rcRetry` cache-buster because a WebView once
cached a truncated GLB. The OPT model is a different URL, so it is unaffected — but if you
ever overwrite a GLB in place, that bug comes back.

---

## 8. Tests

Backend (`vitest` + `supertest` + `mongodb-memory-server`):

* `canOptimize` truth table — under threshold, unknown size, not SUCCEEDED, no GLB,
  already-optimized source, existing `QUEUED`/`PROCESSING`/`SUCCEEDED` OPT child (false)
  vs existing `FAILED` OPT child (true).
* Route: 201 → 200 replay on a second POST; concurrent double POST creates **exactly one**
  record (this is the E11000 path — assert the count, not just the status codes);
  409 + stable code when ineligible; 403 for a non-staff caller on the admin route;
  404 for a cross-user caller on the owner route.
* Optimization does **not** increment `countServerSelectedGenerationsInLast24h`.
* `pendingOwnerGenerationFor` ignores a running optimization.
* Processor: with a small real GLB fixture, asserts the output is smaller, that
  `putObjectBytes` was called with the OPT record's own prefix, and that the source
  record is untouched. Add a fixture GLB under `recapture-api/test/fixtures/`.
* `optimizeGlb` unit: oversize input rejected; `sharp`-unavailable path still returns a
  valid document.

Flutter:

* Parser tests for the new fields in both map shapes, including all-absent → safe defaults.
* Widget matrix on `_ModelRow`: button shown / hidden / badge shown, and button+badge
  never both present on the same row.
* **Trap:** a row with a pending OPT record renders a `CircularProgressIndicator`, so
  `pumpAndSettle` **hangs**. Use `pump(const Duration(milliseconds: 100))`.
* **Trap:** a fake repository whose `list()` *succeeds* sends the notifier down the Hive
  caching path and the test box will not exist. Follow whatever the existing
  `model_generation_notifier` tests do.

---

## 9. Non-negotiables

* `AGENTS.md` layering: routes → services → models. No Express types in services, no
  mongoose documents in routes. Response envelope `{ status: 'success', … }`.
* Analytics: `model_optimize_requested` / `model_optimize_completed` through the existing
  typed `track()`, with `hashIdentifier`-ed ids only. No raw ids, no keys, no PII.
* Never log or persist a presigned URL.
* Additive only. Do not change the Meshy generation path's behaviour, its idempotency
  keys, or the capture pipeline.
* New env vars documented in `.env.example` with defaults and a one-line rationale.

## 10. Deliverables

1. The backend change (types, schema + indexes, service, two routes, job type, processor,
   optimizer service, deps).
2. The client change (entity, row UI, repository, notifier, viewer button, **both**
   meshopt decoder locations).
3. Tests per §8, all green — paste the actual run output.
4. A short PR note listing: the three judgment calls flagged above (separate record vs
   variants, the 95 % ineffectiveness gate, `FAILED` OPT child re-enables the button),
   the `latestSucceededModel` behaviour change, and **explicitly whether the optimized
   model was rendered on a real device/web build or not.**
