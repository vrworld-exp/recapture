# Detach asset optimization from model generation

## Why

The `ASSET_OPTIMIZATION` pass adds a multi-minute tail to every generation and
the `web` variant it produces does not render better than the Meshy original in
practice. We are **detaching** it: Meshy's GLB becomes the model we ship, on all
three generation paths, with nothing queued behind it.

**Detach, not delete.** The pipeline module, its CLI, its tests, and the admin
variant PATCH all stay in the tree. This must be reversible by flipping one
environment variable, so a later quality pass does not mean rebuilding it.

## The one fact that shapes this task

There is **ONE** attach point, not three.

All three generation triggers create the same `MESHY_MODEL_GENERATION` job:

| Trigger (user's words)            | Entry point                                                        |
| --------------------------------- | ------------------------------------------------------------------ |
| "select and make model" (staff)   | `createMeshyModelRequest` via `POST /admin/projects/:id/models`      |
| "maya capture then make model"    | `maybeAutoGenerateModel` → `captureProcessingProcessor.ts:147`       |
| "generate model btn" (owner)      | `generateModelOnDemand` → `onDemandModelGenerationService.ts`        |

Every one of them lands in `meshyModelProcessor`, which enqueues the
optimization from a **single line**, `recapture-api/src/worker/processors/meshyModelProcessor.ts:152`:

```ts
await enqueueAssetOptimization(job, record);
```

So: **do not touch the three trigger services.** Editing
`createMeshyModelRequest`, `maybeAutoGenerateModel`, or `generateModelOnDemand`
is out of scope and is the most likely way to break a path this change is
supposed to leave alone. Gate the one call site and all three follow.

## The one thing that CANNOT stay unchanged

Read this before writing any code. Detaching optimization is **not** a no-op for
everything else, and shipping only the switch below would make rendering worse,
not better.

`MESHY_TARGET_POLYCOUNT` is currently **200,000** and `MESHY_TEXTURE_RESOLUTION`
is **`'4k'`**. Both were raised to those values *specifically because the
pipeline decimates and resamples afterwards*. They are SOURCE-quality knobs
feeding a resample — not what ships today. `env.ts:162-167` states the coupling
outright:

> At 200k the untouched original is on the wrong side of that line, so it is no
> longer what an owner is served: a validated pipeline run auto-promotes
> `optimized.activeVariant` to 'web'. Raising this number WITHOUT that
> promotion, or without the pipeline's simplify stage, reintroduces the crash
> for every model.

What owners actually load today is the pipeline's `web` build:
**60,000 triangles**, ≤8 MB, baseColor 2048 / normal 1024
(`src/modules/asset-pipeline/profiles/food.json`). Detach the pipeline and leave
these two env values alone, and every new model ships at 200k triangles with 4k
textures — past the point where an Android WebView loses its WebGL context while
parsing the GLB. The user's complaint is that models do not render smoothly;
that change would guarantee it.

So move the triangle budget from "post-process it" to "**ask Meshy for it
directly**". `MESHY_PRESET.should_remesh` is already `true`, which means
`target_polycount` is Meshy's own decimation target — the same job the pipeline's
simplify stage was doing:

- `MESHY_TARGET_POLYCOUNT`: `200_000` → **`60_000`**, matching
  `profile.simplify.targetTriangles`, the number known to load on real devices.
- `MESHY_TEXTURE_RESOLUTION`: `'4k'` → **`'2k'`**, matching the 2048 baseColor
  budget the pipeline resampled to. Paying for 4k source that nothing resamples
  is pure latency and extra decoded texture memory on the phone.

**Do NOT change anything else in `MESHY_PRESET`.** Keep `should_remesh: true`
(false gives the raw unbounded mesh, 55k–1.2M triangles), keep
`alpha_thumbnail` (coupled to `preview.png` re-hosting), keep every other field
verbatim. Only these two env defaults move.

Honest trade-off to state in the PR, not to solve here: Meshy's remesh is a
different simplifier from meshoptimizer's silhouette-error decimation, so 60k
from Meshy will not be pixel-identical to 60k from the pipeline. The old 12k
budget destroyed thin features (handles, rims, stems) at the source — at 60k that
risk is far smaller, but it is not zero, and it wants a real-device look before
this is called good. One upside: no pipeline means no `EXT_meshopt_compression`,
so new models no longer depend on the meshopt decoder at all.

## Design: one env kill switch

Add `ASSET_OPTIMIZATION_ENABLED` (boolean, **default `false`**) to
`recapture-api/src/config/env.ts` alongside the other worker/Meshy vars, and to
`recapture-api/.env.example` with a comment saying it is off deliberately.

Default `false`, not "absent means on": an operator who forgets the var must get
the detached behaviour, since that is now the intended product.

The flag governs **two** things — the write side and the read side.

### 1. Write side (the actual detach)

In `meshyModelProcessor.ts`, guard the call at line 152:

```ts
if (env.ASSET_OPTIMIZATION_ENABLED) {
  await enqueueAssetOptimization(job, record);
}
```

Guard the **call**, not the body of `enqueueAssetOptimization` — the function's
own doc comment explains the QUEUED-marker contract, and leaving it intact and
unreachable is what makes the flag a true switch. Log once at `info` when the
flag is off ("Asset optimization disabled — serving the Meshy original") so a
production log can prove which behaviour is live.

Critical consequence, and the reason this is safe: with the enqueue skipped,
`markOptimizationQueued` never runs, so `record.optimized` stays **absent**, and
`isOptimizationPending()` returns **false** for absent
(`assetManifest.types.ts:201`). Both clients therefore read new models as
`optimizationPending: false` → settled → openable immediately, with **no client
change required** for the new-model path. Do not "help" by writing a `SKIPPED`
marker; absence is already the correct, already-handled signal.

Leave `assetOptimizationProcessor` **registered** in `workerRuntime.ts:40`. Any
`ASSET_OPTIMIZATION` job already sitting QUEUED in the database must still drain
cleanly rather than dead-letter. The flag stops new ones being created; it is not
a reason to strand old ones.

### 2. Read side (legacy records already carrying a `web` variant)

> **This half is a deliberate behaviour change, not part of the detach.** The
> write-side guard alone leaves already-optimized models serving their `web`
> build forever. Everything below changes what EXISTING models serve. It is
> recommended — the complaint is about that build's quality — but if the intent
> is strictly "stop making new ones, leave what exists alone", **skip this
> entire section** and ship only the write-side guard plus the polycount change.
> Nothing else in this document depends on it.

Records generated before this change may already have
`optimized.activeVariant === 'web'`, and those keep serving the optimized build
unless we say otherwise. Since the complaint is about the optimized build's
quality, the flag should also force reads back to the original.

In `recapture-api/src/models/types/assetManifest.types.ts`:

- `resolveActiveModelUrl(...)` → return `originalUrl` immediately when the flag
  is off, **except** when `optimized.variantPinnedByAdmin` is true. A pinned
  variant is a human's explicit decision and outranks the automation in both
  directions (AGENTS.md §"An admin's choice is PINNED"); silently overriding it
  would break the one guarantee that flag exists to make.
- Leave `isOptimizationPending` alone. It is already correct for both cases.

In `recapture-api/src/services/projectModelsService.ts`:

- `toProjectModelDtos` (line 333) and `listOwnerModelsFor` (line 805) expand one
  record into one entry **per rendition**. With the flag off, suppress the `web`
  expansion so both lists collapse back to one row per generation — again,
  unless `variantPinnedByAdmin`.
- Do **not** change the `id` semantics or start deduping by id. The rule that two
  entries share one id (one record, one paid generation) still holds whenever a
  pinned record expands, and `countServerSelectedGenerationsInLast24h` counts
  rows.

`toOwnerModelDto` derives `activeVariant` from `resolveActiveModelUrl` already,
so fixing the resolver fixes `glbUrl`, `isOptimized`, and `isActiveVariant`
together. `optimizedGlbUrl` may stay populated — it is a URL, not a claim about
what is being served, and the admin surface still uses it to compare.

## Client (Flutter): leave almost everything alone

The `optimizationPending` plumbing is **not** dead code and must not be ripped
out — it is what makes a client tolerate both a flag-on and a flag-off backend,
and what keeps already-deployed builds correct during rollout.

Keep, unchanged:

- `ProjectModelView.optimizationPending` / `isSettled` — [project_model.dart:302](lib/domain/entities/project_model.dart#L302), [:311](lib/domain/entities/project_model.dart#L311). Both default to
  "settled" when the field is absent, which is exactly the new payload.
- `OwnerModelState.isGenerating` / `hasViewableModel` — [projects_repository.dart:170-178](lib/data/repositories/projects_repository.dart#L170-L178).
- The optimization-tail poll budget in [owner_model_state_notifier.dart:83-108](lib/application/projects/owner_model_state_notifier.dart#L83-L108)
  and the `optimizationPending` term in [model_generation_notifier.dart:66](lib/application/projects/model_generation_notifier.dart#L66).
  With the flag off these conditions are simply never true; the loops stop at
  `SUCCEEDED` on their own, which is the desired behaviour.
- **The meshopt decoder wiring in `web/index.html` and the mobile viewer's
  `relatedJs`.** It is the fix for the OPT variant failing to load at all, it
  costs nothing when no meshopt asset is served, and removing it would silently
  re-break every legacy pinned `web` model. Do not touch it.
- The "Finishing up" row in [model_building_screen.dart:447](lib/presentation/screens/projects/model_building_screen.dart#L447) — driven by
  `optimizationPending`, so it self-hides.

**Expected Flutter diff: zero to one file.** Every widget above already renders
off `optimizationPending` / `isOptimized` / `metrics`, all of which simply go
false-or-absent under the new payload, so the UI self-corrects with no edit.

`owner_models_screen.dart`, `model_history_screen.dart`, `project_card.dart`,
`model_render_view.dart` and `preview_gallery_screen.dart` all have
**uncommitted work in progress** on this branch. Do not refactor them, do not
tidy them, do not touch them at all unless one contains a string that
UNCONDITIONALLY promises optimization ("we're optimizing your model", a hardcoded
OPT badge) — i.e. text that renders even when the row carries no optimized data.
If a badge or label is already driven by row data, it is correct as-is and must
stay: it is what still labels a pinned legacy `web` row. Report any file you
changed here and why.

## Tests

Update — these currently assert the attached behaviour and will fail:

- `recapture-api/tests/meshy-model-processor.test.ts:397-470` — the
  "queues ASSET_OPTIMIZATION", "surfaces the wait as optimizationPending", and
  the idempotency assertions. Rewrite as: with the flag **off**, a succeeded
  generation queues **zero** `ASSET_OPTIMIZATION` jobs, leaves `optimized`
  absent, and reports `optimizationPending: false` on **both** the staff and
  owner shapes.
- Keep a flag-**on** case for each, so the switch is proven in both positions and
  the pipeline does not rot.
- `recapture-api/tests/meshy-client.test.ts:93` —
  `expect(env.MESHY_TARGET_POLYCOUNT).toBeGreaterThanOrEqual(100_000)` and
  `:109` — `expect(['4k','8k']).toContain(env.MESHY_TEXTURE_RESOLUTION)`. **Both
  fail** once the budgets drop, and both must be retuned rather than deleted:
  they are the guard that generation asks for a deliberate budget. Invert their
  premise — the served asset is now what Meshy returns directly, so assert the
  budget sits at a directly-servable target (`<= 80_000`, the profile's old hard
  gate) and that the texture resolution is `'2k'`. Update the comments above
  them, which currently explain the resample that no longer happens.
  Leave the `MESHY_PRESET` deep-equal at `:130` untouched — the preset itself
  does not change.

Add:

- Flag off + a legacy record with `activeVariant: 'web'` → owner `glbUrl` is the
  original, `isOptimized` is false, and `listOwnerModelsFor` returns one row.
- Flag off + `variantPinnedByAdmin: true` → still serves `web`, still expands to
  two rows. This is the guard against overriding a human.
- Flag off + a pre-existing QUEUED `ASSET_OPTIMIZATION` job → still processes.

Leave untouched: `asset-pipeline-{plan,execute,validate}.test.ts` and
`asset-optimization-processor.test.ts`. The pipeline still works; it is just not
being called.

Run both suites — `npm test` in `recapture-api/` (2267 tests) and `flutter test`
at the root (620+). Report real counts, including any pre-existing failures.

## Docs

- `AGENTS.md` §"Asset optimization" (around line 249-289): the section stays as
  the description of how the pipeline works, but state up front that it is
  **detached by default** behind `ASSET_OPTIMIZATION_ENABLED`, and that
  "promotion is automatic" only applies when the flag is on.
- `recapture-api/docs/meshy-integration.md`: note that a generation now ends at
  `SUCCEEDED` with nothing queued behind it.
- **`env.ts` doc blocks for both budgets you changed.** The comment above
  `MESHY_TARGET_POLYCOUNT` (lines ~145-175) argues at length for 200k *because
  the pipeline decimates after it*, and the one above
  `MESHY_TEXTURE_RESOLUTION` (~177-191) calls 4k "the resample source". Both
  rationales are now false. Rewrite them to say the budget is what ships
  directly, and keep the WebView history — it is the reason the new number is
  what it is. A stale comment here is how the next person re-raises it to 200k.
- `AGENTS.md:226-247` carries the same two numbers in prose. Move them with it.

## Out of scope — do not do these

- Editing the three generation triggers or their idempotency keys
  (`capture:{jobId}` and the manual variants). Meshy behaviour, the 24h ceiling,
  and the duplicate-model guard must come out of this byte-identical.
- Deleting `src/modules/asset-pipeline/`, its CLI, its npm script, or the
  `ASSET_OPTIMIZATION` job type / processor registration.
- Removing the meshopt decoder wiring.
- Any `MESHY_PRESET` field. The two env budgets move; the preset does not. It is
  deep-equal asserted against a literal, and an unknown or flipped field comes
  back a terminal 400 that burns the request.
- Refactoring, reformatting, or "tidying" the five Flutter files that have
  uncommitted changes on this branch.
- A data migration that strips `optimized` blocks from existing records. It is
  irreversible, and the read-side flag already makes them serve the original.

## Verification before calling it done

1. Flag off (default), all three paths: staff select→generate, capture→auto, and
   the owner Generate button each produce a `SUCCEEDED` model with **no**
   `ASSET_OPTIMIZATION` job in `jobs`, and the app opens it without waiting.
2. **The served GLB actually loads.** One real generation, opened on a real
   Android device, not just in tests: confirm the returned mesh is near 60k
   triangles and the viewer renders it without "We couldn't load this model".
   This is the whole point of the change and the one thing no unit test proves.
3. The owner model list shows **one** row per generation, not two.
4. A legacy `web`-active record serves its original; a **pinned** one still
   serves `web`.
5. Flag on: everything behaves exactly as it does today — including
   `MESHY_TARGET_POLYCOUNT`, which stays at its new value. If quality at 60k is
   judged too low later, raising it again is only safe WITH the pipeline on.
6. Both test suites, with actual numbers.

Nothing here has been run against a device or live Meshy output — state clearly
what was verified by tests versus by hand.
