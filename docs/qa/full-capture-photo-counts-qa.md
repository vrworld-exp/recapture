# Full Capture — Per-Flow-Variant Photo Counts QA

Verifies that a full Guided Capture produces the expected number of photos, per
level and in total, for **both capture flow variants** (the "can you capture the
bottom?" answer on the Pre-Capture Checklist):

| Variant (wire id) | Rings | Per-ring segments | Total photos |
|---|---|---|---|
| `with_bottom` | A (Eye/`mid`) → B (Top/`high`) → C (Bottom/`low`) | 12 / 12 / 12 | **36** |
| `without_bottom` | A (Eye/`mid`) → B (Top/`high`) | 18 / 18 | **36** |

Automated coverage:

- `test/capture/full_capture_photo_counts_test.dart` — the per-level / total
  targets a full capture must hit for each variant (driven through the real
  `LevelSegmentMachine` simulation seam, no camera/sensors), the active-level
  lists (2-ring is a prefix of 3-ring), the 36-photo budget shared by both
  variants, and the remote-config override / malformed-input fallback behaviour.
- `test/capture/capture_flow_variant_test.dart` — the `effectiveSegmentsFor`
  precedence chain and `VariantSegments` parsing/sanitizing.

## Where the counts come from

Counts resolve through the single `effectiveSegmentsFor(config, variant, bandId)`
resolver (`capture_config.dart`), with precedence:

1. remote-config `guided_capture_variant_segments` override
   (variant id → band id → count),
2. the bundled variant defaults (the table above),
3. the band's legacy `PitchBand.segments` (only for bands unknown to the
   variant map — old cached configs),
4. a final floor of 12.

Every flow layer — the progression builder (`levelStatesFromConfig`), the
per-level machines (`levelSegmentMachinesFromConfig`), the live HUD providers
(`activeLevelSegmentCountProvider` → fill state + yaw→segment bucketing), and
the Capture Summary — goes through this one resolver, so no two layers can
disagree on N.

> **History:** the earlier object-size → segments derivation
> (`object_size_segments.dart`, Small 36 / Medium 30 / Large 24, never wired)
> was **removed** on 2026-07-09 when variant-based counts replaced it as the
> single source of segment counts. The legacy bundled band counts
> (`mid`=10 / `high`=8 / `low`=12) remain in `pitchBands` only as the deep
> fallback for unknown bands.

## Manual / future QA

- [ ] Device run, checklist answered **Yes**: Level A/B/C ring maps each show 12
      positions; a full session ends at 36 accepted photos; `capture_session_complete`
      fires after C.
- [ ] Device run, checklist answered **No**: A/B show 18 positions; Level B
      completion routes to the Capture Summary; Level C routes are unreachable;
      the session ends at 36 accepted photos with `levels_total: 2`.
- [ ] Confirm a remote `guided_capture_variant_segments` change flows through to
      the per-level target (no app release) and completion re-evaluates against
      the new count (`reconcileWithConfig`).
