# Full Run Photo Counts — Small ≈ 90 / Medium ≈ 72 / Large ≈ 54

Verifies that a full three-level (EYE/TOP/LOW) Guided Capture produces the expected
per-object-size **total** photo counts, and that the count **decreases** as object
size increases.

Automated coverage:

- `recapture-api/tests/full-run-photo-counts.test.ts` — derives the per-size totals
  from the protocol source-of-truth constants and asserts ≈ 90/72/54, the
  min↔capacity band, the descending direction, and the per-ring split.

Run: `cd recapture-api && npm test` (Vitest). Deterministic — pure constant
derivation, no DB / sensors / camera / timers.

## Where the numbers come from (source of truth)

The 90/72/54 totals are defined in **`recapture-api/src/models/types/capture.types.ts`**
and nowhere else in the repo. The guided-capture protocol is **three rings**
(EYE / TOP / LOW), each taking a per-object-size count:

| Object size | Segments/ring `SEGMENT_COUNT_BY_SIZE` | Min photos/ring `MIN_PHOTOS_PER_RING_BY_SIZE` | Min total (×3) | Capacity (×3) |
|-------------|---------------------------------------|-----------------------------------------------|----------------|---------------|
| Small       | 36                                    | 30                                            | **90**         | 108           |
| Medium      | 30                                    | 24                                            | **72**         | 90            |
| Large       | 24                                    | 18                                            | **54**         | 72            |

- The spec's **≈ 90 / 72 / 54 are the full-run MINIMUMS** = `3 × MIN_PHOTOS_PER_RING_BY_SIZE`.
  These are exact (derived from exact integer constants), so the "≈" lower bound is
  asserted with **tolerance 0**.
- A real run accepts at most ring **capacity** = `3 × SEGMENT_COUNT_BY_SIZE` = 108/90/72.
  The "~" in the brief is this `[min, capacity]` headroom (uniformly +18 photos per
  size), asserted as the upper bound rather than fudged into a symmetric ±.
- Direction is **descending**: Small (90) > Medium (72) > Large (54). Smaller objects
  need denser coverage. The ordering is asserted independently of the magnitudes so a
  flipped mapping fails distinctly from a magnitude drift.

The ring count (3) is read from `DEFAULT_REMOTE_CONFIG.pitchBands` (the EYE/TOP/LOW
bands the API serves), not hardcoded, so a change to the ring set is caught.

## Convention reconciliation (important — read before "fixing" anything)

The brief points at `lib/features/guided_capture/` and prescribes `flutter test` /
`flutter analyze`. **That does not fit this repo, and the 90/72/54 contract is not in
the Flutter client at all:**

- There is no `lib/features/guided_capture/`; the client is clean-arch
  (`domain`/`application`/`presentation`).
- The Flutter client's per-level counts come from fixed `PitchBand.segments`
  (Level A→`mid`=10, B→`high`=8, C→`low`=12 → **30 photos for every object size**).
  Only Level A's eye ring is size-driven (`eyeRingSegmentCount` = 36/30/24), and that
  derivation is **not wired** into the live capture screen (the Project model carries
  no size field through yet). See `docs/qa/full-capture-photo-counts-qa.md` and
  `test/capture/full_capture_photo_counts_test.dart`.
- Therefore the client produces **30 photos per full run regardless of size** today —
  it does not yet realize the 90/72/54 protocol. A `flutter test` asserting 90/72/54
  would have nothing to read and could only fail.

The numbers are authoritative in the **backend protocol constants**, so the
verification lives there (decision confirmed with the requester). This is a tracked
client gap, not a backend bug — do not "fix" the backend constants to match the
client.

**Prerequisite to close the client gap:** wire `objectSize` through the Project →
remote-config `segmentCounts`/`thresholds` → all three rings (not just Level A), and
set the client per-level min-accepted from `MIN_PHOTOS_PER_RING_BY_SIZE` instead of
the current default of 1.

## Meta-checks (teeth — verified, then reverted)

- Changed `MIN_PHOTOS_PER_RING_BY_SIZE.MEDIUM` 24 → 20 → the three MEDIUM magnitude
  cases AND the descending-direction test **failed** (4 failures), with the message
  `size=MEDIUM expected≈72 (±0) actual=60`. ✓
- Swapped `MIN_PHOTOS_PER_RING_BY_SIZE` SMALL↔LARGE (18/24/30) → the SMALL+LARGE
  magnitude cases AND the descending-direction test **failed** (7 failures), the
  ordering test failing distinctly. ✓

Both production edits were reverted; `git diff` of `capture.types.ts` is empty. No
production code changed.

## Manual full-run QA checklist (physical device)

Automated tests assert the *targets*; only a real capture confirms the running app
actually accepts that many frames. Run on a mid-range Android device, guided mode.
**Caveat:** until the client gap above is closed, the live app caps a full run at the
band-config total (≈30) and does **not** vary by object size — record the observed
count and flag the divergence rather than treating ≈30 as a pass.

For each object size, complete a full EYE → TOP → LOW capture and record the count:

- [ ] **Small** — complete all three rings; expected ≈ **90** (range 90–108). Observed: ____
- [ ] **Medium** — complete all three rings; expected ≈ **72** (range 72–90). Observed: ____
- [ ] **Large** — complete all three rings; expected ≈ **54** (range 54–72). Observed: ____
- [ ] Confirm the ordering on-device: Small count > Medium count > Large count.
- [ ] Confirm each ring individually reaches at least its per-ring minimum
      (Small 30 / Medium 24 / Large 18) before the level is allowed to complete.
- [ ] Confirm no ring completes with 0 accepted photos.
- [ ] Note any divergence from the protocol totals here and link it to the client
      wiring gap above: ________________________________________________
