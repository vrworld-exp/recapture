
✅✅✅✅✅✅✅✅
✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅/2
# Task: Capture Flow Variants — API support (recapture-api)

> **Follow-up to** `docs/prompts/capture-flow-variant-client.md` (the Flutter
> client task). Run this AFTER the client task is merged, or at least treat
> its contract as fixed. Work only inside `recapture-api/`.

Read **AGENTS.md** at the repo root first (response envelope, error shapes,
config/secrets rules, PII/logging rules, testing conventions). Its conventions
win over anything here.

---

## 1. Context: what the client now does

The capture flow has two variants, chosen by the user before capture:

| Variant id (wire) | Rings captured | Segments per ring | Total images |
|---|---|---|---|
| `with_bottom` | EYE, TOP, LOW | 12 / 12 / 12 | 36 |
| `without_bottom` | EYE, TOP | 18 / 18 | 36 |

Ring names in the S3 key space are `EYE` / `TOP` / `LOW` (see
`src/utils/s3Keys.ts` — the canonical builder/parser; client levels A/B/C map
to EYE/TOP/LOW). The client's `capture_manifest.json` now carries a
`flowVariant` field (top-level, camelCase — the manifest's key convention)
with the variant id.

Today the API assumes all three rings exist. That breaks the
`without_bottom` variant at three points: the create-job key-space plan, the
upload-urls key containment, and finalize's manifest validation
(`src/services/manifestValidationService.ts` server-derived minimums). This
task makes the variant a first-class job property end to end.

---

## 2. Implementation spec

### 2.1 Canonical variant definition (one module)

Add a single source of truth (e.g. `src/domain/captureVariants.ts` or
alongside the manifest types — follow the repo's layout conventions):

```ts
type CaptureFlowVariant = 'with_bottom' | 'without_bottom';
// with_bottom    → rings ['EYE','TOP','LOW'], expected per-ring 12
// without_bottom → rings ['EYE','TOP'],       expected per-ring 18
```

Export helpers: `ringsForVariant(variant)`, `expectedPerRing(variant)`, and
`expectedImageCount(variant)` (36 for both today — do not hardcode 36
anywhere else). Every service below consumes these helpers; no service
re-declares ring lists or counts.

### 2.2 `POST /jobs` (create-job)

- `src/validation/jobSchemas.ts`: add `captureVariant` to the create-job body
  schema — Zod enum of the two ids, **optional, default `'with_bottom'`**
  (older clients keep working unchanged).
- Persist it on the Job document (`src/models/Job.ts`,
  `src/models/types/job.types.ts`) — required field with default.
- The key-space **plan** must cover only `ringsForVariant(job.captureVariant)`
  (no LOW prefix planned for `without_bottom`).
- The existing size/count cross-check: `expectedFilesCount` must equal
  `expectedImageCount(variant) + 1` (manifest) — reject mismatches with the
  existing validation-error shape. Keep the Idempotency-Key semantics
  untouched; replays with a different `captureVariant` are a conflict, same as
  any other body drift.

### 2.3 Upload-urls (initiate / part-url)

Key containment already rejects keys outside the job's plan. Extend it so a
key whose LEVEL segment is not in `ringsForVariant(job.captureVariant)` is
rejected with the same error family the containment check uses today (e.g. a
`LOW/...` key on a `without_bottom` job). Keep the endpoints stateless as they
are — the variant comes from the job document they already load.

### 2.4 Finalize + manifest validation

`src/services/manifestValidationService.ts` (pure collect-all rules, 422 with
stable rule ids — keep that contract):

- Derive the expected ring set and per-ring minimums from the job's variant
  via the §2.1 helpers — remove any hardcoded three-ring assumption.
- New rules (stable ids following the existing naming scheme):
  - manifest declares a ring not in the variant (e.g. LOW on
    `without_bottom`) → e.g. `manifest.level.unexpected`;
  - a variant ring entirely missing → existing missing-level rule or a new
    one, whichever fits the current rule taxonomy;
  - `manifest.flowVariant` present but ≠ `job.captureVariant` → e.g.
    `manifest.flow_variant.mismatch` (rule ids stay snake_case);
  - `manifest.flowVariant` absent → treat as `with_bottom` (tolerant, same
    default as create-job) — no error.
- Server-derived minimums: per-ring floors come from `expectedPerRing(variant)`
  combined with the existing minimum-percentage/count rules — the point is the
  server never trusts client-sent totals.
- The paginated S3 object-count == expected check in finalize keeps working —
  it must count against the variant's expected total. Idempotent replay
  behavior unchanged.

### 2.5 Remote config

`src/validation/remoteConfigSchema.ts` + the remote-config endpoint defaults:
add the block the client now reads, with defaults **identical to the client's
bundled defaults**:

```json
"guided_capture_variant_segments": {
  "with_bottom":    { "mid": 12, "high": 12, "low": 12 },
  "without_bottom": { "mid": 18, "high": 18 }
}
```

(Client config speaks band ids `mid`/`high`/`low`; the S3/manifest layer
speaks ring names EYE/TOP/LOW — keep both vocabularies where they already
live, do not leak one into the other.) The endpoint's ETag must change with
the new payload; the defaults-fallback-never-5xx behavior stays.

### 2.6 Analytics

If the analytics event schemas (typed `track()` + Zod) validate capture/upload
event properties, allow an optional `flow_variant` string enum on the relevant
events. No PII implications.

---

## 3. Out of scope

- No Flutter changes (already done in the client task).
- No S3 key format changes — `s3Keys.ts` builder/parser stays as is; only
  which rings get planned/allowed changes.
- No processing-worker changes.
- No new endpoints.

---

## 4. Acceptance criteria & tests

Vitest + Supertest + mongodb-memory-server, following the existing test stack
conventions (env-before-import gotcha applies).

1. Create-job: accepts both variant ids; missing field defaults to
   `with_bottom`; invalid value → 422; expectedFilesCount cross-check enforces
   variant totals (36+1); idempotent replay with changed variant conflicts.
2. Upload-urls: presign for a `LOW/...` key on a `without_bottom` job is
   rejected; all variant rings accepted; `with_bottom` unchanged.
3. Finalize happy path for BOTH variants (manifest + S3 counts line up →
   QUEUED flip, idempotent replay OK).
4. Finalize 422 cases with stable rule ids: LOW files/manifest entries on a
   `without_bottom` job; a missing TOP ring; `flow_variant` mismatch with the
   job. Collect-all still returns every violated rule, not just the first.
5. Remote-config response contains the new block with exactly the default
   numbers; ETag/304 behavior still correct after the payload change.
6. Existing test suite fully green; `npm run build` (tsc) clean.
