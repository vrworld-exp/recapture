# Low Ring (Level C) — Pitch Band & Cutoff QA

Covers the two capture-gating dimensions for the Level C "Low Ring" pass. Automated
coverage lives in:

- `test/capture/low_ring_pitch_band_acceptance_test.dart` — pitch-band acceptance +
  the real out-of-band guidance analytics (`tilt_meter_out_of_band`).
- `test/capture/low_ring_cutoff_rejection_test.dart` — the cutoff detection
  primitive + the intended "both conditions" contract.
- `test/capture/low_ring_base_capture_test.dart` — "captures the base without
  cutting it off": band enforcement driven through the REAL auto-capture decision
  (`shouldCapture` fires at the in-band base angle, refuses the horizontal/Level-A
  angle that would clip the base) + the base-cutoff guidance being Level-C-specific
  (present in the Level C cycle, absent from A/B), with an in-file sabotage group
  (mis-wiring Level C to the horizontal band inverts the safeguard). The pixel-level
  "base in frame" guarantee remains the manual step below.

## Convention reconciliation (read first)

The task brief frames Low Ring as an **upward tilt** and references a **negative**
band (−30…−10°). **This codebase does not use a negative band.** Level C resolves to
`pitchBandIdForLevel(CaptureLevel.c) == 'low'`, and the bundled `low` band is the
**positive `[0, 30)`** slice — the lowest of the `[0, 90]` capture range. The Level C
copy is "Lower the phone, tilt slightly up", i.e. the accepted posture is a low
positive pitch reached by a slight upward tilt from level. The automated tests
encode this production convention; the direction-lock tests fail if the band sign is
ever inverted (verified — see Meta-checks).

Band membership (`CapturePitchGuide.isInBand`): **min inclusive, max exclusive**
(`0 ≤ pitch < 30`). The brief's "inclusive both edges" is asserted against the
**actual** behaviour, not imposed.

## ⚠️ Production gap: cutoff gating is NOT wired (do not mask)

Cutoff / object-in-frame gating **does not exist in the capture acceptance path**:

- `capture_screen.dart` renders `PlacementBoxOverlay` as a guide only and states
  *"placement is not gated yet (no detection)"*.
- `PlacementBox.containsNormalized` is documented as a *"render-only helper for later
  gating logic"*; `PlacementStatus` is *"INJECTED … by a parent (future
  detection/sensor logic) — never self-detected"*.
- There is **no object detector** producing a bounding box, **no code that rejects an
  in-band frame because the object is cut off**, and **no cutoff-rejection analytics
  event**.

Therefore:
- The cutoff **detection primitive** that exists (`PlacementBox.containsNormalized`)
  is tested directly (geometry contract).
- The **"both conditions required"** contract (in-band pitch AND object fully in
  frame) is asserted at the **helper-composition level** — it demonstrates the
  intended rule and guards it for when wiring lands. It is **not** claimed the live
  capture path enforces cutoff today.
- A cutoff-rejected-frame analytics event is treated as **absent** (a tracked gap);
  the observable outcome (composed predicate rejects) is asserted instead.

**Prerequisite to close the gap:** an object detector feeding a normalized bounding
box into a capture-time gate that ANDs `CapturePitchGuide.isInBand` with
`PlacementBox.containsNormalized`, plus a frame-rejection event carrying a
`reason: cutoff`. Until then, dimension 2 is device-/future-only.

## Analytics naming note

The brief's `guided_capture_capture_started` / `guided_capture_pitch_out_of_band`
do not exist. The real, wired guidance event is **`tilt_meter_out_of_band`**
(direction `above|below`, `target_band_id`, `level`, `pitch`), **debounced** by the
tilt indicator's `outSustain` + `outCooldown`. The canonical capture-start event is
`capture_level_started` (carries `level`).

## Meta-checks (teeth — verified, then reverted)

- Inverted the `low` band to `[-30, 0)` → the direction-lock and 15°-accept tests
  **failed** (6 failures). ✓
- Stubbed `PlacementBox.containsNormalized` to always return `true` → the cutoff and
  combined "in-band + cutoff" tests **failed** (5 failures). ✓

Both production edits were reverted; `git diff` of `capture_config.dart` and
`placement_box.dart` is empty.

## Manual QA checklist (physical device only)

Real motion smoothing/jitter and real camera framing are not unit-testable:

- [ ] At Level C, hold the correct Low Ring posture (slight upward tilt) and confirm
      the indicator reads ready/in-band and frames are accepted.
- [ ] Tilt out of band in **both** directions and confirm corrective guidance
      appears ("Tilt up" / "Tilt down") and frames are not accepted.
- [ ] Confirm sensor jitter near the band edge does **not** flicker the UI or spam
      guidance (the `tilt_meter_out_of_band` debounce holds on-device).
- [ ] Confirm the advisory fallback when the motion sensor is disabled: no crash, the
      user is not permanently blocked (matches the 6C sensor-unavailable contract).
- [ ] **Cutoff (once gating is implemented):** frame the object so part of it is cut
      off and confirm those frames are rejected **even when the posture is correct**.
      *Until the gap above is closed, on-device cutoff frames are NOT rejected — this
      item validates the future feature, not current behaviour.*
