
✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅
# Task: Home-Page Dev Tools — Health Check & AWS Upload Smoke-Test Buttons

> Touches BOTH codebases: the Flutter client (repo root) and `recapture-api/`.
> The two small backend items in §2 are hard prerequisites — without them the
> Upload button physically cannot complete (see §1). Do the backend part first.

Read **AGENTS.md** at the repo root first (response envelope, error shapes,
config/secrets rules, PII/logging rules, testing conventions). Its conventions
win over anything here.

---

## 1. Goal & grounding (read before coding)

Add a **developer-only "Dev Tools" section to the Home page** (the Projects
Hub, `lib/presentation/screens/projects/projects_screen.dart`) with two
visually distinct buttons:

1. **Health** — calls the running backend's `GET /health` and shows the raw
   response on-screen (status code, body, latency).
2. **Upload** — runs a full **real** upload smoke test against the running
   backend and AWS S3: generates a dummy capture bundle in memory, drives the
   real API chain (auth → project → job → presign → PUT to S3 → complete →
   finalize), and shows each step's result on-screen, ending with the job's
   `QUEUED` response.

Grounding facts (verified in the codebase — the prompt below depends on them):

- **These are the first real client→backend calls in the app.** Every
  repository (`auth_repository.dart`, `projects_repository.dart`) is currently
  a stub; `lib/data/remote/api_client.dart` already builds a Dio instance from
  `AppConfig.apiBaseUrl` (`API_BASE_URL` in the flavor `.env`) but nothing
  consumes it yet. The probe consumes it — the production repositories stay
  stubbed (out of scope).
- `GET /health` is public (no JWT) and returns a NON-envelope shape:
  `{ "status": "ok", "db": "connected", "timestamp": "...", "env": "development" }`
  (`recapture-api/src/routes/health.ts`). Display it verbatim; do not try to
  parse it as the standard envelope.
- **Client-side auth is fake** (`AuthRepository` accepts master OTP `555555`
  locally and mints `stub.access.token`). The real backend will 401 that
  token. The upload probe therefore performs its OWN real auth handshake
  against the backend (§2.1 + §3.4 step 1) and never touches the app's auth
  state.
- **The API has no multipart-complete endpoint** (open finding from the
  P0–P6 E2E verification). `initiate`/`part-url` presign part PUTs, but
  without `CompleteMultipartUpload` the uploaded parts never become S3
  objects, so finalize would always count 0. §2.2 adds it.
- **Upload contract (capture flow variants, already enforced):** a job's
  `expectedFilesCount` must be EXACTLY `expectedImageCount(variant) + 1` = 37;
  finalize lists the job prefix and requires exactly 37 objects, a manifest at
  `{prefix}capture_manifest.json`, and manifest content that passes
  `manifestValidationService` (12 photos per ring on EYE/TOP/LOW for
  `with_bottom`, stable rule ids on 422). The dummy bundle must satisfy all of
  it — this makes the button a genuine end-to-end contract test.
- Bundle key layout under the plan's `keyPrefix`:
  `images/{EYE|TOP|LOW}/{filename}.jpg` + `capture_manifest.json` (canonical
  scheme in `recapture-api/src/utils/s3Keys.ts`; upload-urls containment
  rejects anything else, including rings outside the job's variant).

---

## 2. Backend prerequisites (`recapture-api/`)

### 2.1 Dev-only OTP echo on send-otp

The probe needs real tokens, but the SMS provider is a stub that swallows the
code, so a machine can never read the OTP. Add:

- In the send-otp route/service response, include `devCode: "<the OTP>"`
  **only when `env.NODE_ENV !== 'production'`**. Hard-gate it at one place;
  never log the code (PII/logging rules unchanged).
- Tests: non-prod response carries `devCode` and it verifies successfully;
  a production-env test asserts the field is ABSENT. Existing OTP tests stay
  green (rate-limit windows unchanged — the probe must tolerate 429 by
  reusing its cached session, see §3.4).

### 2.2 `POST /jobs/:jobId/uploads/complete`

Completes one file's multipart upload server-side (the client cannot — no
presigned complete exists and the SDK call needs credentials):

- Body (Zod, `.strict()`): `key` (same bounds as initiate), `uploadId`
  (string 1–1024), `parts`: non-empty array of
  `{ partNumber: int 1–10000, etag: string 1–256 }`, capped at 10 000 entries.
- Guards: identical family to initiate via the existing `loadUploadableJob`
  (owned job 404 / state 409 / plan-window 410 / key containment incl. the
  variant LEVEL check → 400). No per-file state is persisted (matches the
  deliberately stateless per-file design).
- Action: S3 `CompleteMultipartUpload` with the parts list (helper in
  `s3MultipartService.ts` next to `initiateMultipartUpload`). Response:
  `{ status: 'success', key, etag }` (the composite object ETag). An S3
  failure surfaces as 500 via the error handler; a stale/foreign `uploadId`
  becomes S3's error (surface it, don't pre-validate — same policy as
  part-url).
- Tests (Vitest + Supertest + mongodb-memory-server, mocked S3 client like
  `jobs-upload-urls.test.ts`): happy path sends `CompleteMultipartUploadCommand`
  with the exact Bucket/Key/UploadId/Parts; guard failures (foreign key,
  wrong state, expired plan, LOW key on a `without_bottom` job) never call S3;
  malformed body → 400.
- Out of scope here: an abort endpoint (the S3 lifecycle
  `AbortIncompleteMultipartUpload` rule remains the reaper).

---

## 3. Client (Flutter, repo root)

### 3.1 Placement & gating

- New self-contained module `lib/dev/dev_probe/` — service, models, widgets.
  It uses the existing `api_client.dart` Dio seam (its own instance is fine)
  and **must not** touch repositories, notifiers, auth state, Hive, or
  analytics. It is throwaway-quality-adjacent dev tooling, but still passes
  `flutter analyze`.
- The Dev Tools section renders on the Projects screen **only when
  `!kAppEnvironment.isProduction`** (compile-time flavor from
  `lib/utils/app_env.dart`). In prod builds the section does not exist in the
  tree at all. Place it between the app bar and the list/empty state, and keep
  it visually clearly "dev": e.g. a slim header row `DEV TOOLS` in
  `AppColors.textMuted` above the two buttons.

### 3.2 The two buttons — deliberately different UIs

Both follow the design tokens (`AppColors.*`, `AppSpacing.*` — never raw hex):

- **Health**: a compact **outlined pill/chip** — stethoscope-ish icon
  (`Icons.monitor_heart_outlined`), label "API Health", thin
  `AppColors.success`-tinted border, transparent fill. Small and quiet.
  While in flight: inline spinner replacing the icon.
- **Upload**: an **elevated filled card** — full-width, `AppColors.surface1`
  with the `primaryGradient` accent edge or icon chip, `Icons.cloud_upload`,
  title "S3 Upload Smoke Test", subtitle "37-file dummy bundle → backend →
  AWS". While running it shows a determinate progress bar (files completed /
  37) directly on the card.

Two different shapes, sizes, and color treatments — they must not look like
siblings from one list.

### 3.3 Health button behavior

- Tap → `GET {API_BASE_URL}/health` with a short timeout (~5s), measuring
  wall latency.
- Result bottom sheet: HTTP status code, latency in ms, and the pretty-printed
  raw JSON body in a monospace scrollable block. Connection refused / timeout
  → the same sheet in an error state ("Backend unreachable at <base URL>" +
  the Dio error type) — never an unhandled exception, never a crash.
- Repeat taps allowed; one in-flight guard (ignore taps while running).

### 3.4 Upload button behavior — the smoke pipeline

One tap runs the ordered steps below. The card expands (or opens a full-height
sheet) into a **step list**: each row = step name + live state
(pending / spinner / ✓ / ✗) + tap-to-expand raw response JSON. A failure stops
the pipeline, marks the step ✗ with the envelope error (`code`, `message`,
and `validationErrors` rule ids verbatim when present), and leaves prior
steps' results visible.

1. **Auth** — `POST /auth/send-otp` (a fixed dev phone, e.g. `+911111111111`)
   → read `devCode` (§2.1) → `POST /auth/verify-otp` → keep
   `{accessToken, refreshToken}` **in memory only** for the app session and
   reuse on subsequent runs (avoids the send-otp rate window; on 401 later,
   redo the handshake once). If `devCode` is absent (prod backend), fail the
   step with a clear message.
2. **Create project** — `POST /projects`
   `{ name: 'Dev Upload Smoke <HH:mm:ss>', objectSize: 'medium', mode: 'guided' }`.
3. **Create job** — `POST /jobs`
   `{ projectId, objectSize: 'medium', captureVariant: 'with_bottom', expectedFilesCount: 37 }`
   with an `Idempotency-Key` = a fresh UUID per run. Keep the returned
   `uploadPlan` (`keyPrefix`, `manifestKey`, `levels`).
4. **Generate the dummy bundle in memory** (pure function, unit-testable):
   36 images — 12 per ring for each of EYE/TOP/LOW — named
   `{ring.toLowerCase()}_0001.jpg` … `_0012.jpg`, each a small byte blob
   (~2–8 KB) beginning with the JPEG SOI marker `FF D8 FF E0` and ending
   `FF D9`, plus a **valid** `capture_manifest.json`:
   `{ "flowVariant": "with_bottom", "summary": { "totalPhotos": 36, "warningsCount": 0 }, "photos": [ { "photoId": "...", "ringName": "EYE|TOP|LOW" } × 36 ] }`.
   Keys = `keyPrefix + 'images/{RING}/{name}.jpg'` and the plan's
   `manifestKey`. The generator must derive counts/rings from one local
   constant table mirroring the variant contract — and a unit test pins
   36 + 1 = 37.
5. **Upload each of the 37 files** sequentially (keep it simple):
   `POST /jobs/:id/uploads/initiate` `{ key, fileSize, partCount: 1 }` →
   HTTP `PUT` the bytes to `parts[0].url` (plain Dio, no auth header — it's a
   presigned S3 URL) → collect the `ETag` response header →
   `POST /jobs/:id/uploads/complete` `{ key, uploadId, parts: [{ partNumber: 1, etag }] }`.
   Update the card's progress bar per completed file. Surface the per-file
   step in the log as one aggregated row ("Upload files 37/37") with the last
   error expanded on failure.
6. **Finalize** — `POST /jobs/:id/finalize` `{ reportedFilesCount: 37 }` →
   expect `{ status: 'success', state: 'QUEUED', filesVerified: 37 }`. Show it
   as the final ✓ row plus a summary line (total bytes, total duration).
   A 422 here must display the `validationErrors` rule ids — that's the
   button's whole diagnostic value.

### 3.5 Config & how to run it (document in the module header)

- Backend up: `docker compose up -d` (Mongo), then `cd recapture-api && npm run dev`
  with real AWS credentials in its `.env` (buckets are in `us-east-1`).
- Client `API_BASE_URL` in `.env.dev`: Android emulator → `http://10.0.2.2:3000`,
  physical device → `http://<LAN-IP>:3000`, Windows desktop / web →
  `http://127.0.0.1:3000`.
- **Flutter web caveat:** the S3 `PUT` + reading the `ETag` header require S3
  bucket CORS (`PUT` origin + `ExposeHeaders: ETag`). Primary target is a real
  device/emulator (no CORS there); on web, expect step 5 to fail until bucket
  CORS is configured — note this in the failure copy, don't chase it.

---

## 4. Out of scope

- Wiring the production repositories (auth/projects) to the real API.
- Any change to the capture/upload engine (`ChunkedUploadManager` etc.).
- An abort endpoint, retries/resume in the probe, parallel part uploads.
- Analytics events for the probe. Localization. Prod builds ever seeing it.

## 5. Acceptance criteria & tests

1. Backend: `devCode` present in non-prod send-otp response, absent in prod
   (tested both ways); `uploads/complete` endpoint with the guard/S3 tests of
   §2.2; existing suite fully green; `npm run build` + lint clean.
2. Client: Dev Tools section visible in dev flavor, absent from the widget
   tree when `kAppEnvironment.isProduction` (widget test both ways).
3. Health button: widget test with a mocked Dio — success renders code +
   latency + body; connection error renders the unreachable state, no throw.
4. Dummy bundle generator unit tests: exactly 37 entries, 12 per ring across
   EYE/TOP/LOW, manifest JSON round-trips and matches the counts, every image
   blob starts `FF D8` and ends `FF D9`, keys sit under a given prefix.
5. Upload pipeline: service unit test with a mocked Dio walking all steps in
   order (assert each request's method/path/body shape, Idempotency-Key
   present, ETag threaded from PUT → complete), and a failure-injection test
   (finalize 422) proving the step list stops and surfaces rule ids.
6. Manual E2E (documented, not automated): against the locally running
   backend + real AWS, the Upload button ends with `state: QUEUED`,
   `filesVerified: 37`, and the S3 console shows 37 objects under the job
   prefix. `flutter analyze` + `flutter test` fully green.
