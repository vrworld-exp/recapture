# Blur threshold policy (REJECT / WARN / ACCEPT)

Classifies the sharpness score (variance of Laplacian @ 640px, from
[blur-detection](./blur-detection.md)) into three actionable bands using
configurable thresholds. This is the **policy** layer on top of the metric — it
turns a score into a band the capture flow + UI act on; it does NOT recompute the
metric, and it does NOT wire the concrete capture action.

## Bands & boundaries

```
score < rejectBelow            → REJECT   (default rejectBelow = 40)
rejectBelow ≤ score ≤ acceptAbove → WARN   (inclusive BOTH ends)
score > acceptAbove            → ACCEPT   (default acceptAbove = 80)
```

So **exactly 40 → WARN** and **exactly 80 → WARN**. The WARN band is an
intentional buffer that avoids a hard sharp/blurry flip at a single cutoff.

| Band | Meaning (semantics) |
|------|---------------------|
| REJECT | Too blurry — don't use the frame (discard / "hold steady" hint). |
| WARN | Borderline — usable but flagged; the capture flow decides (accept-with-caution / count differently / prompt). |
| ACCEPT | Sharp enough — use the frame. |

This task defines the band **meaning**; the capture/auto-capture flow wires the
concrete action (skip / keep / prompt).

## Configurable, validated thresholds

`rejectBelow` (default 40) and `acceptAbove` (default 80) are configurable —
content- and device-sensitive magic numbers, intended to be remote-config-tunable
(P1 `GET /remote-config` "thresholds") without an app release. Validation
(`BlurThresholdPolicy.validated`):

- A **non-finite** input falls back to that field's default.
- An **inverted** pair (`rejectBelow > acceptAbove`) is nonsensical → falls back to
  **both** defaults (40/80) — no nonsensical band, no silent garbage.
- `rejectBelow == acceptAbove` is **allowed**: the WARN band is then empty (binary
  reject/accept).

A runtime `update(...)` applies to **subsequent** classifications (past frames are
not reclassified); the result reports the **active** thresholds used.

## Fail-safe

A **non-finite (NaN/Inf) or negative** score must never classify as ACCEPT. The
classifier returns **REJECT** for non-finite scores (negative finite scores are
`< rejectBelow` → REJECT naturally). The Dart `BlurResult` always carries a band
(derived locally with the same policy if the native band is somehow absent).

## Integration

The band is computed natively in `BlurAnalysisManager` and added to every blur
event, alongside the active thresholds:

```
{ sharpnessScore, sharp, band:"reject"|"warn"|"accept", rejectBelow, acceptAbove,
  width, height, timestampNs, frameIndex }
```

`band` rides the SAME frame association (`timestampNs`, the camera clock) as the
score, so the capture flow rejects/flags the correct frame. `rejectBelow`/
`acceptAbove` are passed on the blur channel's listen args (alongside the single
`blurThreshold`). The Dart-side `BlurThresholdPolicy` mirrors the native semantics
so the capture flow can also classify a score from any source (e.g. a captured
frame's sidecar) consistently with the live stream.

> The single `sharp` flag (score ≥ `blurThreshold`, default 100) from the
> blur-detection task is independent of these band thresholds; for three-band
> capture decisions prefer `band`.

## Pieces

| Layer | File | Role |
|-------|------|------|
| Native | `android/.../camera/BlurThresholdPolicy.kt` | `BlurBand` enum + pure, validated, runtime-updatable classifier. JVM-testable. |
| Native | `android/.../camera/BlurAnalysisManager.kt` | Applies the policy per frame; emits `band` + active thresholds; reads band thresholds from listen args. |
| Dart | `lib/platform/blur_policy.dart` | `BlurBand` + `BlurThresholdPolicy` (client-side classification, mirrors native). |
| Dart | `lib/platform/blur_channel.dart` | `BlurResult` carries `band`/`rejectBelow`/`acceptAbove`; stream forwards band thresholds. |

## Tests

- `android/.../test/.../camera/BlurThresholdPolicyTest.kt` — boundary table
  (40/80 → WARN), custom thresholds, invalid→defaults, non-finite-field fallback,
  equal→empty-WARN, runtime update, non-finite/negative→REJECT (fail safe), wire.
- `test/blur/blur_policy_test.dart` — mirrors the classification + validation +
  fail-safe; `BlurBand.fromWire`.
- `test/blur/blur_channel_test.dart` — `BlurResult` carries the native band; derives
  it locally when absent; band thresholds forwarded on listen.
