# Full 3-Level Capture — Per-Object-Size Photo Counts QA

Verifies that a full three-level (A→B→C) Guided Capture produces the expected
number of photos, per level and in total, and that the object-size → frame-target
derivation matches the documented targets for every supported size class.

Automated coverage:

- `test/capture/full_capture_photo_counts_test.dart` — the per-level / total
  targets a full capture must hit (driven through the real `LevelSegmentMachine`
  simulation seam, no camera/sensors), plus the object-size → Level A density
  matrix and the size-scaling guard.

## Convention reconciliation (read first)

The task brief assumes **object size drives the per-level (A/B/C) targets for all
three levels**, and that **larger objects need more photos**. This codebase does
**not** work that way. The tests encode the production contract, not the brief:

### 1. Per-level A/B/C targets come from band config, not object size

Each level resolves to a `PitchBand` via the single level→band map
`pitchBandIdForLevel` (`capture_level_events.dart`):

| Level | Band   | Bundled `segments` (target photos) |
|-------|--------|------------------------------------|
| A     | `mid`  | 10                                 |
| B     | `high` | 8                                  |
| C     | `low`  | 12                                 |
| **Total** |    | **30**                             |

These counts are read from `CaptureConfig.bundledDefault.pitchBands`
(remote-config-overridable) and are **independent of object size**. The factory
`levelSegmentMachinesFromConfig` sizes each level's machine from exactly that
band's `segments`, and `CaptureConfig.totalSegments` is their sum. A full orbit of
every ring fills `segmentCount` segments (`fillThreshold` = 1), so a complete
A→B→C capture produces **30** photos on the bundled config — asserted via a full
simulated capture, not a hardcoded total.

### 2. The only size-dependent count is the Level A Eye-Ring density — and it is INVERTED

`eyeRingSegmentCount(size)` (`object_size_segments.dart`) is the one place object
size maps to a count:

| Object size | Eye-Ring segments (Level A) |
|-------------|-----------------------------|
| Small       | 36                          |
| Medium      | 30                          |
| Large       | 24                          |

The documented **product rule is the opposite of the brief**: *smaller* objects
get *more* segments (finer angular coverage at a closer orbit), larger fewer. So
the scaling guard asserts the counts are **non-increasing as size grows**
(small ≥ medium ≥ large), and a regression that flips it to "bigger ⇒ more" fails.

Null / unset size → the documented **Medium** default (30); validation never
throws (`eyeRingSegmentCount(null)` returns normally).

### Important: the size→density derivation is NOT wired into the live flow

`eyeRingSegmentCount` is the design source of truth for size→Level-A density, but
the live capture screen currently sizes its ring from `CaptureConfig.eyeRingSegments`
(the `mid` band = 10), **not** from object size — the Project model has no size
field wired through yet (deferred). Therefore the per-size **matrix** in the test
(Level A = `eyeRingSegmentCount(size)`, B/C = fixed band counts, total = their sum:
small 56 / medium 50 / large 44) represents the **design intent**, not the photo
count the running app produces today. The test documents this explicitly so the
numbers are not mistaken for current live behaviour.

## Meta-checks (teeth — verified, then reverted)

- Changed the `high` band `segments` 8 → 9 in `capture_config.dart` → the Level B
  case, the total/sum case, the full-capture simulation, and the per-size rows
  (which assert the `+8+12` band contribution) **failed** (7 failures). ✓
- Inverted `kDefaultEyeRingSegments` (small 24 / large 36) in
  `object_size_segments.dart` → the per-size literal rows, the smallest/largest
  edge case, the NON-INCREASING scaling guard, and the per-size-total guard
  **failed** (5 failures). ✓

Both production edits were reverted; `git diff` of `capture_config.dart` and
`object_size_segments.dart` is empty. No production code changed.

## Manual / future QA

- [ ] **When object size is wired into the live capture screen:** confirm a Small
      project's Level A actually targets 36 positions, Medium 30, Large 24, and
      that the ring map / completion gate reflect that count. Until then, the live
      Level A ring uses the `mid` band count (10) regardless of object size.
- [ ] Confirm a remote-config change to any band's `segments` flows through to the
      per-level target (no app release) and that completion re-evaluates against
      the new count (`reconcileWithConfig`).
