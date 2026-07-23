


# Meshy capture → single-ring 6-shot circle (eye→top)

## Goal

Replace the Meshy AI capture experience with one short, easy capture: the user
walks **one circle** around the object and takes **6 photos**, spaced ~60° apart
in yaw. Across those 6 shots the phone tilt lives anywhere in **90°–180°**
(eye-level up to top-down), so the single ring covers both the eye view and the
top of the object at once. No separate Top ring, no Bottom ring, no
"can you photograph the bottom?" question.

The project-name screen and the pre-capture instructions for the Meshy flow
**already work and must not change** — this task is only the capture step and the
plumbing that carries the new shape to the backend.

## Locked product decisions (do not re-litigate)

1. **Shape:** one ring, 6 shots, evenly spaced around the circle (6 yaw slots,
   60° apart).
2. **Tilt window:** each shot must be taken with camera tilt in **[90°, 180°)**.
   Any tilt in that window is fine — there is no per-slot tilt target.
3. **Tilt gating is HARD:** a shot outside [90, 180) does not count (shutter
   blocked / shot discarded). Below 90° (aiming below eye level) is rejected.
4. **Guidance = guided yaw, MANUAL shutter:** show a 6-slot coverage ring that
   fills as slots are captured; the user taps the shutter at each slot. **No
   auto-capture** in Meshy mode (hide/disable the AUTO affordance).
5. **All 6 required:** coverage floor stays 100%. The user cannot finish/upload
   until all 6 slots are filled.
6. **Backend shape replaced entirely:** the old Meshy shape (EYE 6 / TOP 2 /
   LOW 2 = 10) never shipped live — delete it, don't keep it behind a flag.
7. **Variant-less:** Meshy no longer has `with_bottom` / `without_bottom`. It is
   one fixed flow.
8. **Photos sent to Meshy:** unchanged — the server still auto-selects the best
   **4 of the 6** via the existing selection service. Do not send all 6 to Meshy.

## Tilt / vocabulary primer — get this right before touching anything

- Camera tilt is a single 0–180° scalar (`lib/domain/capture/camera_tilt.dart`):
  **0° = aimed at sky, 90° = horizon (eye level), 180° = aimed at ground
  (top-down).** So the Meshy window **[90, 180) = eye-level → top-down**, which
  is exactly "eye and top". The physical 180° is clamped to
  `kCameraTiltMaxDegrees = 179.999` so a `maxDegrees`-exclusive band still admits
  a flat-down phone.
- Ring names in S3 keys / manifest are **EYE / TOP / LOW** (uppercase). Client
  band ids are **mid / high / low**. Client levels **A / B / C** map to
  **EYE / TOP / LOW**. The Meshy single ring keeps the canonical first ring name
  **EYE** (see "Ring naming" below) so nothing new ripples into `s3Keys`.

---

## Backend (`recapture-api/`) — contained, mostly mechanical

`src/models/types/captureVariants.ts` is the **single source of truth** for
shapes; every server consumer derives ring sets and counts from its helpers.
Change the shape there and the rest should follow — but verify each consumer.

### 1. `captureVariants.ts` — reshape `meshy`
- `SHAPE_DEFS.meshy`: make **both** variants the same single-ring shape:
  ```ts
  meshy: {
    with_bottom:    { rings: ['EYE'], perRing: { EYE: 6 } },
    without_bottom: { rings: ['EYE'], perRing: { EYE: 6 } },
  },
  ```
  (Keeping both keys identical preserves the type structure and the
  "without_bottom is a prefix of with_bottom" invariant while making the variant
  irrelevant to Meshy.)
- `MIN_RING_COVERAGE_PCT_BY_MODE.meshy` stays **100** (all 6 required).
- `LEGACY_PER_RING.meshy` stays **`[]`** (still never shipped live — no old
  capture to accept).
- **Rewrite the stale doc comments** in this file: the header block, the `meshy`
  line in `SHAPE_DEFS`, and the `MIN_RING_COVERAGE_PCT_BY_MODE` comment all
  describe "8–10", "6/2/2", "two photos per ring", "ten photos total". Replace
  with the single-ring-of-6 reality. `expectedImageCount('…','meshy')` must now
  return **6** for both variants; `minimumImageCount` also 6.

### 2. Verify (and only fix if they hardcode) the consumers
Read each and confirm it derives from the helpers, not a literal 10/8 or a
"Meshy has 3 rings" assumption:
- `src/services/jobsService.ts` — create-job expected-count cross-check.
- `src/services/manifestValidationService.ts` — finalize/worker manifest bounds
  (`photosByRing`, per-ring min/max). With one ring these collapse to `{EYE:{6,6}}`.
- `src/validation/jobSchemas.ts` and `src/validation/remoteConfigSchema.ts` —
  any Meshy count bounds.
- `src/models/Job.ts` / `manifest.types.ts` — the `captureMode` field added in
  commit `94d5651`; confirm it round-trips.
- `src/worker/processors/captureProcessingProcessor.ts`.

### 3. `src/services/autoPhotoSelectionService.ts` — must pick 4 from one ring
The selector currently spreads picks **across rings**. With a single EYE ring of
6, verify it degrades to "pick 4 best-spread-by-yaw + sharpest **within** the one
ring" rather than needing ≥1 per ring or returning fewer than 4. Fix if it
assumes multiple rings.

### 4. `POST /jobs` must accept and honor `captureMode: 'meshy'`
Confirm create-job reads `captureMode` from the body (default `'full'`) and uses
it to compute the expected count. If it currently ignores it, add it — this is
the field the client will now send. Without it the server expects 48 and rejects
the 6-shot bundle.

### 5. Backend tests
Update the three added in `94d5651`:
- `tests/capture-modes.test.ts` — Meshy totals 10→6, ring set `['EYE']`.
- `tests/jobs-meshy-mode.test.ts` — expected count / accepted count = 6.
- `tests/auto-photo-selection.test.ts` — selecting 4 from a single-ring 6-photo
  manifest.

### Ring naming
Keep the one ring named **`EYE`**. It now spans eye→top tilt, so the name is a
mild misnomer — document that in the `SHAPE_DEFS` comment. Do **not** invent a
new ring name: `s3Keys.ts`'s `CaptureLevelSegment` union (`EYE|TOP|LOW`), key
containment, and every existing key path would all have to change for zero user
benefit.

---

## Client (Flutter, repo root) — the larger piece

Today the client has **no** Meshy capture path: it always runs the config-driven
A/B/C flow and `POST /jobs` never sends `captureMode`. The Meshy capture must
become a real, distinct flow.

### 0. First, trace the real entry point (verify before building)
The user reports "Meshy → project name → instructions" already works. Find how
that flow is entered and where it currently hands off to capture. Hang the new
capture off that hand-off. Determine how the app knows a project is a Meshy
project (a `captureMode`/flag on create-project, a route arg, or a provider) and
carry that flag into the capture flow. `POST /projects` currently sends
`mode: guided|manual` (auto-capture mode) — that is **not** full/meshy; you need
a separate capture-mode signal.

### 1. A dedicated Meshy `CaptureConfig` (single band)
Reuse the existing band-driven machinery rather than writing a parallel screen.
Provide a Meshy config with **one** pitch band:
```dart
PitchBand(id: 'eye_top', minDegrees: 90, maxDegrees: 180, segments: 6)
```
- `thresholds.minCoveragePct = 100`.
- Map this single band → the **EYE** ring → a single level (level "A"). The
  band-id→ring/level mapping (`capture_flow_variant.dart`, `guidance_resolver`,
  `guidance_engine`) needs a Meshy branch so one band yields one level instead of
  requiring the mid/high/low triple.
- The progression builder (`level_progression_builder.dart`,
  `level_segment_machines.dart`) must produce a **single-level** progression
  (no A→B→C). Confirm the segment machine handles a lone level cleanly.

### 2. Capture screen behavior in Meshy mode
- **Tilt gate (hard):** the shutter is enabled only when tilt ∈ [90, 180). This
  falls out of band membership for the `[90,180)` band — reuse the existing
  shutter/tilt gate; do not add a second tilt check. Confirm a shot below 90° is
  actually blocked, not just warned.
- **Manual only:** disable the guided auto-capture loop and hide the AUTO pill
  for Meshy (the play/pause gate already gates only the auto-loop — keep it off).
- **6-slot coverage ring:** the ring-coverage overlay shows 6 yaw slots; the slot
  nearest the current yaw fills when the user taps the shutter. Reuse
  `ring_coverage_engine` / the ring-coverage-map overlay with `segments = 6`.
- **Completion:** the level (and thus capture) completes when all 6 slots are
  filled; the completion + upload gates already read `minCoveragePct`/min shots —
  set them so 6/6 is required.
- Review grid, save-&-exit, and summary reuse their single-level forms.

### 3. Upload / job creation wire-up
- `POST /jobs` body must include `captureMode: 'meshy'` and
  `expectedFilesCount = 6` (the manifest is counted separately by the server).
  `captureVariant` is now irrelevant for Meshy — send a fixed value (e.g.
  `without_bottom`) but the server ignores it for shape.
- The capture manifest (`capture_manifest.dart` /
  `capture_manifest_assembler.dart`) must stamp `captureMode: 'meshy'` so
  finalize validates against the 6-shot shape. It currently defaults
  `flowVariant: 'with_bottom'` and carries no mode — add the mode.
- All 6 photos key under the **EYE** ring / level A prefix.

### 4. Client tests
- Meshy `CaptureConfig` yields a single level of 6 segments; completion requires
  6/6.
- A tilt < 90° does not produce an accepted shot.
- Manifest/job payload carries `captureMode: 'meshy'` and expects 6 files.

---

## Wire contract (both sides must agree)

| Field | Full | Meshy (new) |
|---|---|---|
| `POST /jobs` `captureMode` | `full` (default) | **`meshy`** |
| `POST /jobs` `captureVariant` | `with_bottom` / `without_bottom` | fixed, ignored for shape |
| `POST /jobs` `expectedFilesCount` | 48 | **6** |
| manifest `captureMode` | `full` | **`meshy`** |
| rings | EYE/TOP/LOW or EYE/TOP | **EYE only** |
| per-ring count | 16/16/16 or 24/24 | **EYE: 6** |
| server → Meshy | best 4 selected | **best 4 of 6** (unchanged) |

## Invariants & hazards

- **`captureVariants.ts` is the only place shapes live.** If you write `6` or the
  ring list anywhere else, that is the bug this file exists to prevent.
- **Do not touch `full`.** Every `full` count, test, and call site must stay
  byte-for-byte the same. The optional-trailing-`mode` default (`'full'`) is what
  guarantees that — preserve it.
- **Server coverage floor must never exceed the client's.** Both are 100 for
  Meshy — keep them equal, or a client-complete 6/6 becomes un-uploadable
  (`COUNT_INCONSISTENT`).
- **Tilt sign errors are the classic bug.** 90 = eye, 180 = top-down. Below 90 is
  *below* eye level and must be rejected. Re-read the primer before writing any
  comparison.
- **No auto-capture in Meshy** — if the AUTO loop fires, spacing and the manual
  UX both break.
- **Meshy still has never shipped** — no `LEGACY_PER_RING` entry, no backward-compat
  acceptance needed. If you later change 6, append the old count then.

## Out of scope / non-goals

- The Meshy project-name screen and pre-capture instructions (they work).
- The `full` 48-shot photogrammetry flow (untouched).
- The server-side Meshy pipeline, photo selection algorithm, and model viewer
  (unchanged — only the input bundle shrank from 10 to 6).
- The auto-generation and post-capture "Generate 3D model" entry points (their
  own prompts; they consume whatever bundle exists).
