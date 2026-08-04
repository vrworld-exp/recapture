# Task — Raise Meshy generation quality, let the asset pipeline pay for it

## Context (read first)

`AGENTS.md` at the repo root is the source of truth for conventions. This task is
**backend only** (`recapture-api/`); no Flutter changes.

Today the Meshy recipe is tuned for a *phone-first, small-file* result: the
generation itself is deliberately capped low so the raw GLB is directly
servable. Live results show that cap is destroying geometry — thin features,
handles, rims and stems come back broken or holed ("unwanted breaks").

**The decision has been made and is not up for re-litigation:** ask Meshy for the
highest-fidelity result it will give us, and stop treating generation output as
the thing we serve. The downstream asset pipeline
(`recapture-api/src/modules/asset-pipeline/`) becomes the component responsible
for producing the small, phone-safe asset. Generation optimizes for *quality*;
the pipeline optimizes for *delivery*.

## The three knobs that exist today

| Where | What |
|---|---|
| `recapture-api/src/worker/engine/meshy/meshyClient.ts:113` | `MESHY_PRESET` — the fixed half of every request |
| `recapture-api/src/config/env.ts:148` | `MESHY_TARGET_POLYCOUNT`, default `12_000`, Zod-bounded `100 … 300_000` |
| `recapture-api/src/config/env.ts:154` | `MESHY_TEXTURE_RESOLUTION`, default `'2k'`, enum `2k \| 4k \| 8k` |

Both env values are merged into the payload at `meshyClient.ts:241-249`.

## ⚠️ Why the one-line change is a trap — the part that MUST be handled

Raising `MESHY_TARGET_POLYCOUNT` on its own makes the product **worse**, not
better. Verify each of these in the code before you start; they are the real
scope of this task.

### Trap 1 — the pipeline has no simplify stage at all

`execute.ts:23-28` deliberately omits `simplify`, with the stated reasoning
"simplify is a no-op at our budget (the generation preset already asks Meshy for
12k triangles via its own remesher, which is better at it)". **That premise is
exactly what this task invalidates.** The pipeline's entire size win is currently
texture-side.

### Trap 2 — the gates will reject every high-poly result

`profiles/food.json` sets `gates.maxTriangles: 50000` and
`gates.maxOutputBytes: 3145728` (3 MB). `validate.ts:44` fails the run when the
*produced* variant exceeds them, and `index.ts:153` then returns
`variant: undefined`.

So with a 200k-triangle source and no simplify stage: the pipeline produces a
200k-triangle variant → fails `maxTriangles` → variant discarded → nothing
optimized is ever published.

### Trap 3 — the original is what users get by default

`optimized.activeVariant` starts as `'original'` and only an **admin** flips it
(`assetOptimizationProcessor.ts:13-15`,
`assetManifest.types.ts:130`, `projectModelsService.ts:825`). The
`ASSET_OPTIMIZATION` job *is* auto-enqueued by the Meshy processor
(`meshyModelProcessor.ts:171-190`), but promotion is manual.

Combine traps 1–3: raising the polycount ships a **bigger raw GLB to every
viewer** with no optimized sibling to promote. That is the precise regression
recorded in `MESHY_TARGET_POLYCOUNT`'s own doc comment (`env.ts:125-147`) —
Android WebView loses its WebGL context mid-parse, `model-viewer` fires `error`,
and the owner sees *"We couldn't load this model"* for a generation that in fact
succeeded.

### Trap 4 — generation time vs. the task timeout

`MESHY_TASK_TIMEOUT_MS` defaults to `600_000` (10 min). Higher polycount **and**
higher texture resolution both increase Meshy's wall-clock time. Blowing the
budget raises `MESHY_TIMEOUT`, and the retry **spends credits again**.

### Trap 5 — a 4k texture that gets thrown away

`profiles/food.json` resizes `baseColor` to `1024` and everything else to `512`.
Asking Meshy for `4k` while the pipeline still downsamples to 1024 buys only a
better *source* for the resample — real, but small. If the intent is a visibly
sharper served asset, the profile's texture rules have to move too.

## What to implement

### 1. Generation — go high

- `MESHY_TARGET_POLYCOUNT`: `12_000` → **`200_000`** (headroom under Meshy's hard
  300k cap; anything outside `100 … 300_000` comes back a terminal 400).
- `MESHY_TEXTURE_RESOLUTION`: `'2k'` → **`'4k'`**.
- `MESHY_TASK_TIMEOUT_MS`: `600_000` → **`1_800_000`** (30 min). Confirm the
  poll-as-lease-renewal invariant still holds: `MESHY_POLL_INTERVAL_MS` must stay
  well under `WORKER_CLAIM_TIMEOUT_MS` (see `env.ts:115-120`) — raising the total
  budget must not change the poll cadence.
- **Keep `should_remesh: true`.** Setting it false gives the raw unbounded mesh
  and makes `target_polycount` ignored entirely — observed 55k–1.2M triangles,
  i.e. non-deterministic output. A high, *pinned* budget is the goal, not an
  unbounded one. If you believe raw-mesh is worth testing, do it as a separate
  documented experiment, not in this change.
- **Do not touch `alpha_thumbnail`.** It is coupled to the re-hosted poster being
  `preview.png` / `image/png` in `meshyModelProcessor.ts:345-349`; the two must
  change together or not at all.
- Before adding any *new* preset field (e.g. symmetry / texture-prompt style
  options), verify it against `recapture-api/docs/meshy-integration.md` **and**
  the live Meshy API reference for `/openapi/v1/multi-image-to-3d`. Do not invent
  parameters — an unknown field risks a 400, which is terminal.

### 2. Asset pipeline — make it actually reduce geometry

This is the load-bearing half of the task.

- Add a **`simplify` stage** to `execute.ts`, driven by a new plan flag decided
  in `plan.ts` (never hard-coded in `execute.ts` — that file carries out
  decisions, it does not make them; see its header). Use
  `@gltf-transform/functions`' `simplify` with `MeshoptSimplifier`.
- **Order matters and is documented in `execute.ts:7-28`.** `simplify` must run
  after `weld` (it needs merged vertices to work well) and before `meshopt`
  (which quantizes and reorders geometry — anything rewriting vertices must
  already have happened). Extend that header comment to explain the new stage and
  amend the "Deliberately ABSENT" note, which will no longer be accurate.
- Add a `targetTriangles` (and simplify error tolerance) field to
  `OptimizationProfile` in `types.ts` and to `profiles/food.json`. Suggested:
  target **~35k**, comfortably under the 50k gate, with a conservative error
  ratio so silhouettes survive.
- `plan()` must stay **pure** (report + profile in, plan out — no I/O, no clock).
  Decide "simplify or not" there: skip it when the source is already at or under
  the target, so a small model is not needlessly degraded.
- Recheck `gates.minTriangles: 100` still does its job — it exists precisely to
  catch a simplifier that *destroyed* the model rather than reducing it
  (`validate.ts:51-59`). This is the first change that makes that gate live.

### 3. Serving policy — decide it explicitly

With generation output now too large to serve, `activeVariant: 'original'` as the
default is no longer a safe default; it is a broken one. Implement **one** of the
following and document the choice in the module header:

- **(a) Auto-promote on pass (recommended).** When the pipeline run validates ok,
  set `activeVariant: 'web'` automatically — while preserving the existing rule
  that a re-run must never silently demote an admin's deliberate choice
  (`assetOptimizationProcessor.ts:126-128`).
- **(b) Keep manual promotion**, but only if you also add a guard so a
  never-promoted high-poly original is not served to phones.

If you pick (b), say clearly in your summary that every existing model needs an
admin action before it renders.

### 4. Textures (do this only if it stays inside the byte gate)

If raising `MESHY_TEXTURE_RESOLUTION` to `4k` is meant to be visible to the user:
raise `food.json`'s `baseColor.maxSize` `1024` → `2048`, and raise
`gates.maxOutputBytes` to match (3 MB will not hold a 2048 baseColor plus
geometry). Flag the new number in your summary as a **device-test decision**, not
a settled one.

## Comments and docs — mandatory, not optional

Several comments currently argue *for* the old, low values and will be actively
misleading after this change. Rewrite them so the code and its stated reasoning
agree (this repo's convention is that comments explain *why*):

- `env.ts:125-147` — the `MESHY_TARGET_POLYCOUNT` block. Keep the WebView-crash
  history (it is why the pipeline must now decimate) but restate the policy:
  Meshy generates high, the pipeline delivers low.
- `env.ts:149-153` — the `MESHY_TEXTURE_RESOLUTION` block.
- `meshyClient.ts:75-112` — the `MESHY_PRESET` doc block, and `:226-240` on
  `createMultiImageTask`.
- `execute.ts:7-28` — the recipe-order header and the "Deliberately ABSENT" note.
- `recapture-api/.env.example:86-89` — update the commented defaults.
- `AGENTS.md` and `recapture-api/docs/meshy-integration.md` if either states the
  old budget.

## Tests

Existing tests pin the current recipe and **will fail** — update them to assert
the new intent, do not delete them:

- `tests/meshy-client.test.ts:94` deep-equals `MESHY_PRESET` against a literal.
- `tests/meshy-client.test.ts:84-87` asserts the polycount and its 100–300k range.
- `tests/meshy-client.test.ts:113-114` asserts the two tunables are **not** in the
  preset — this must remain true.
- `tests/asset-pipeline-plan.test.ts` — extend for the new simplify decision.

Add new coverage for:
- `plan()` chooses simplify for a high-triangle report and skips it for a
  low-triangle one (pure, no GLB needed).
- `buildTransforms()` emits `simplify` in the correct position — after `weld`,
  before `meshopt`.
- A high-poly source now passes `gates.maxTriangles` end-to-end instead of being
  discarded.
- Auto-promotion (if you implement 3a), including the no-silent-demote rule.

Run the full backend suite (`npm test` in `recapture-api/`) — it was 593 green
before this change — plus `npm run build`, since the prod build is CJS and has
bitten this module before.

## Known environment traps in this module

- **Two `sharp` copies** in the same process produce a libvips `colourspace`
  error — do not add a second image dependency.
- `enterStage` rejects `'OPTIMIZING'`; asset optimization is its **own job type**,
  not a stage of Meshy generation.
- `npm` swallows a bare `--input` flag; use `npm run <script> -- --input=…` when
  driving the CLI.

## Definition of done

1. Meshy is asked for a high-fidelity model (200k / 4k) with a timeout that can
   actually accommodate it.
2. The pipeline reduces that model to a phone-safe asset that **passes all gates**
   — verified on at least one real high-poly Meshy GLB through the CLI, not only
   on synthetic test fixtures.
3. It is unambiguous, and documented, what an end user's WebView receives.
4. Full suite green + prod build clean.
5. Your summary states plainly: measured triangle/byte counts before and after,
   which numbers are guesses awaiting a device test, and anything you could not
   verify without live Meshy credits.

## Out of scope

Flutter/client changes; the capture flow; the poster/thumbnail path;
`MESHY_CREATE_MAX_PER_WINDOW` rate limiting.
