# Analytics Tracking Plan

> **Single source of truth:** `src/validation/analyticsSchemas.ts`.
> This document mirrors it for analysts and client devs. If they disagree, the
> Zod schemas win — update this file to match. Every event is emitted through the
> typed `track()` in `src/utils/analytics.ts`; raw event-name strings are not
> permitted anywhere else (an unknown name is a compile error).

## Conventions

- **Property names:** `snake_case`, consistent across events.
- **No PII / secrets, ever:** identifiers are always **hashed** before they enter
  props (`identifier_hash` = hash of phone/email; `user_id_hash` = hash of user
  id), via `hashIdentifier()` (`src/utils/otp.ts`). The emit layer additionally
  drops + flags any property whose name looks sensitive (`phone`, `email`,
  `otp`, `code`, `token`, `password`, `secret`, …) as a backstop.
- **Resilience:** emission is fire-and-forget — it never blocks, delays, or
  throws into a request path. Invalid props are loud in dev/staging
  (`console.error`) and silently dropped in production. Auth succeeds even if
  analytics is down.

## Shared enums

| Vocabulary | Values |
|---|---|
| `channel` | `sms`, `email` |
| `stage` (auth_failed) | `send_otp`, `verify_otp`, `refresh` |
| `reason` (auth_failed) | `wrong_code`, `expired`, `locked`, `no_record`, `rate_limited`, `dispatch_failed`, `invalid_token` |
| `platform` (app_opened) | `ios`, `android`, `web` |
| `source` (permission granted) | `prompt`, `settings_return` |
| `permission` (permission_denied) | `camera`, `motion`, `photos` |
| `status` (permission_denied) | `denied`, `permanentlyDenied`, `restricted` |
| `criticality` (permission_denied) | `required`, `recommended`, `optional` |
| `presentation` (precapture_tip_opened) | `bottom_sheet`, `popover` |

## Events

### `app_opened`
- **When:** client cold start / session begin. **Client-emitted** — the backend
  has no ingest endpoint today, so the client validates against this schema and
  sends directly to the destination. The schema here is the shared contract.
- **Props:** `platform` (enum), `app_version` (string), `is_cold_start` (bool, optional)

### `auth_otp_sent`
- **When:** after an OTP **dispatch attempt** in `POST /auth/send-otp`. Not fired
  when the request is rejected before dispatch (rate limit) — that is `auth_failed`.
- **Props:** `channel` (enum), `identifier_hash` (string), `success` (bool)

### `auth_otp_verified`
- **When:** successful verification in `POST /auth/verify-otp`.
- **Props:** `channel` (enum), `identifier_hash` (string), `is_new_user` (bool)

### `auth_failed`  *(canonical failure event)*
- **When:** any auth attempt fails. **Supersedes** the former
  `auth_otp_verify_failed` — there is exactly one failure event name now.
- **Fired at:**
  - send-otp: `rate_limited` (cooldown / window cap), `dispatch_failed`
  - verify-otp: `rate_limited`, `no_record`, `expired`, `wrong_code`, `locked`
  - refresh: `rate_limited`, `invalid_token` (unknown / reused / expired / dead-user;
    the benign concurrent-rotation loser is **not** counted as a failure)
- **Props:** `stage` (enum), `reason` (enum), `channel` (enum, optional),
  `identifier_hash` (string, optional — omitted for refresh, which has no
  phone/email identifier)

### `auth_token_refreshed`
- **When:** successful refresh-token rotation in `POST /auth/refresh`.
- **Props:** `family_id` (string), `user_id_hash` (string)

### `auth_refresh_reuse_detected`  *(security signal)*
- **When:** a rotated/revoked refresh token is replayed (token theft signal);
  fires alongside an `auth_failed` (`stage: refresh`, `reason: invalid_token`).
- **Props:** `family_id` (string), `user_id_hash` (string)

### `projects_listed`
- **When:** `GET /projects`.
- **Props:** `user_id_hash` (string), `result_count` (int ≥ 0), `is_empty` (bool)

### `project_created`
- **When:** `POST /projects`.
- **Props:** `user_id_hash` (string), `project_id` (string), `object_size`
  (`small`|`medium`|`large`), `mode` (`guided`|`manual`), `category` (string|null)

### `project_renamed`
- **When:** `PATCH /projects/:id`. `was_changed` is `false` on a no-op rename.
- **Props:** `user_id_hash` (string), `project_id` (string), `was_changed` (bool)

### `project_deleted`
- **When:** `DELETE /projects/:id`. `was_already_deleted` is `true` on an
  idempotent repeat.
- **Props:** `user_id_hash` (string), `project_id` (string), `was_already_deleted` (bool)

### `project_resumed`
- **When:** a user re-opens an existing, owned, **non-deleted** project via
  `GET /projects/:id`. Fires only on a successful authorized open — a 404 (not
  found / not owned / soft-deleted) emits nothing.
- **Dedupe:** the server emits **once per open**; it has no session state, so
  per-session/per-poll debounce is the **client's** responsibility.
- **Props:** `user_id_hash` (string), `project_id` (string), `source`
  (`projects_list`|`deep_link`|`direct`, optional — from `?source=`, lenient),
  `seconds_since_last_update` (int ≥ 0, optional)

### `job_created`
- **When:** `POST /jobs` persists a NEW upload job (201). An idempotent replay
  (same `Idempotency-Key`, 200) emits **nothing** — one job, one event. Nothing
  fires on validation/authorization failures.
- **Props:** `user_id_hash` (string), `project_id` (string), `job_id` (string),
  `object_size` (`small`|`medium`|`large`),
  `flow_variant` (`with_bottom`|`without_bottom`, optional),
  `expected_files_count` (int > 0)

### `job_upload_started`
- **When:** the FIRST successful `POST /jobs/:jobId/uploads/initiate` for a job
  (the CREATED → UPLOADING transition — a conditional update, so concurrent
  initiates emit it exactly once). Later per-file initiates emit nothing (a
  per-file event at ~90 files/job would be noise).
- **Props:** `user_id_hash` (string), `job_id` (string)

### `job_queued`
- **When:** `POST /jobs/:jobId/finalize` verifies the upload (manifest present,
  S3 object count matches) and performs the one-time transition to `QUEUED` —
  the enqueue itself. An idempotent re-finalize of an already-QUEUED job emits
  **nothing** (one queue entry, one event); verification failures emit nothing.
- **Props:** `user_id_hash` (string), `job_id` (string),
  `flow_variant` (`with_bottom`|`without_bottom`, optional),
  `files_verified` (int > 0)

### `remote_config_served`
- **When:** sampled (~1%) on `200` responses from `GET /remote-config` (never on
  `304`). `served_defaults` is `true` when baked defaults were used.
- **Props:** `config_version` (int ≥ 0), `served_defaults` (bool)

### Permission funnel (`permission_camera_granted`, `permission_motion_granted`, `permission_denied`)

**Client-emitted** (Screen 4A / permission gate). The defining rule: these fire
on an actual **grant/deny transition**, **never** on the passive `check()` calls
the resume re-check performs — emitting per-check would flood the funnel with
phantom grants on every resume. Each transition fires its event **exactly once**.
`user_id_hash` is **optional/omitted** because permissions may precede login
(join later when a session exists).

> **Naming asymmetry (intentional, pending analytics-owner sign-off):** Camera
> and Motion have *named* granted events; denials use a *single generic*
> `permission_denied` carrying the `permission`. Photos/storage has **no named
> granted event** (only camera/motion are named). If the funnel later wants
> symmetry, normalize to a generic `permission_granted` with a `permission` prop.
>
> **Motion reality:** Motion is permission-free (raw IMU — no OS permission), so
> in practice `permission_motion_granted` rarely/never fires (Motion starts
> granted and never transitions). The event is wired generically all the same.

### `permission_camera_granted`
- **When:** Camera transitions to **granted** — via the in-app prompt
  (`source: prompt`) or by enabling it in Settings, detected on the resume
  re-check (`source: settings_return`). Once per transition; not re-fired on
  later resumes while it stays granted.
- **Props:** `source` (`prompt`|`settings_return`, optional), `user_id_hash`
  (string, optional)

### `permission_motion_granted`
- **When:** Motion transitions to **granted** (same `source` semantics as above).
- **Props:** `source` (`prompt`|`settings_return`, optional), `user_id_hash`
  (string, optional)

### `permission_denied`
- **When:** a permission request resolves **non-granted**, or a granted→denied
  transition (revocation in Settings) is detected on resume. Once per transition;
  not fired on passive checks, not fired for the iOS `unavailable` state.
- **Props:** `permission` (`camera`|`motion`|`photos`), `status`
  (`denied`|`permanentlyDenied`|`restricted`), `criticality`
  (`required`|`recommended`|`optional`), `user_id_hash` (string, optional)

### Pre-capture checklist (`precapture_checklist_started`, `precapture_tip_opened`)

**Client-emitted** (Screen 4 — the pre-capture checklist — and its tip surface).
Like the permission funnel, the pre-capture screen may precede login, so
`user_id_hash` is **optional/omitted** (join later when a session exists).

### `precapture_checklist_started`
- **When:** the user **enters** the pre-capture checklist screen (Screen 4).
  **Resolved semantics: REACH** — this is the screen-entry metric, fired once in
  the screen's `initState`, **not** the Start-CTA conversion (the Start tap has
  its own navigation; no conversion event is wired here). The funnel can add a
  separate conversion event later if needed.
- **Rule:** once per screen **entry**; never on rebuilds/rotations (a fresh
  `State` per entry). Leaving and returning is a new entry → fires again (no
  per-session dedupe).
- **Props:** `source` (string, optional — how the user arrived), `user_id_hash`
  (string, optional)

### `precapture_tip_opened`
- **When:** a checklist item's tip surface (Material bottom sheet on Android /
  Cupertino popover on iOS) is **opened** from the item's info affordance.
- **Rule:** once per **open action**; not on rebuilds while the tip stays up. The
  tip surface's no-stacking guard collapses a rapid double-tap into one open
  (→ one event). Dismiss + reopen the same item = two opens = two events (open
  count is meaningful). A missing/invalid `item_id` is rejected by the schema
  (signals a content bug to fix, not to mask).
- **Props:** `item_id` (string, the checklist item's stable id — not PII),
  `presentation` (`bottom_sheet`|`popover`, optional), `user_id_hash` (string,
  optional)

### Admin / staff live-projects access (P7-A)

Server-emitted from the staff-only `/admin` route group (min role
`MODEL_ARTIST`) and its gate. **Never** carries owner phone/email or a
presigned URL — actor/project/job identifiers are hashed.

### `admin_projects_listed`
- **When:** `GET /admin/projects` (staff cross-user list) succeeds.
- **Props:** `actor_role` (`USER`|`MODEL_ARTIST`|`ADMIN`), `status_filter`
  (a ProjectStatus, or `default` = the PROCESSING/COMPLETED live set),
  `page_size` (int > 0)

### `project_export_generated`
- **When:** `GET /admin/projects/:id/export` returns a presigned-URL manifest.
  Nothing fires on 404/409/429.
- **Props:** `actor_id_hash` (string), `project_id_hash` (string),
  `job_id_hash` (string), `file_count` (int ≥ 0), `ttl_seconds` (int > 0)

### `project_photos_deleted`
- **When:** `DELETE /admin/projects/:id/photos` (ADMIN-only) soft-deletes one or
  more captured objects (moves them to the job's `deleted/` namespace). Nothing
  fires on 400/403/404/409.
- **Props:** `actor_id_hash` (string), `project_id_hash` (string),
  `job_id_hash` (string), `deleted_count` (int ≥ 0), `missing_count` (int ≥ 0).
  **Never** carries a key or presigned URL.

### `admin_access_denied`
- **When:** `requireRole` rejects an **authenticated** caller whose role is
  below the route's minimum (403). Unauthenticated 401s emit nothing.
- **Props:** `actor_id_hash` (string), `route` (string, e.g. `GET /admin/projects`)

## Catalog publish runs

Emitted by the publish **worker** (`worker/processors/mirageCatalogPublishProcessor.ts`),
not by the endpoint that enqueues the run — the endpoint returns `202` long
before the outcome exists.

⚠ None of these carry catalog CONTENT. No product name, no category name, no
business name, no phone/email. `targetName` is recorded on the run's
`entries[]` (which the owner reads back through the activity log) and stops
there.

### `catalog_publish_started`
- **When:** a run flips QUEUED → RUNNING and its plan has been built.
- **Props:** `user_id_hash` (string), `catalog_id` (string), `run_id` (string),
  `mode` (`FULL`|`RETRY_FAILED`|`UNPUBLISH`), `planned_total` (int ≥ 0)

### `catalog_publish_finished`
- **When:** the run reaches a terminal state — including the terminal-failure
  path where the processor threw.
- **Props:** `user_id_hash`, `catalog_id`, `run_id`, `mode`,
  `state` (`SUCCEEDED`|`PARTIAL`|`FAILED`), `total`, `synced`, `failed`,
  `skipped` (ints ≥ 0)

### `catalog_publish_target_failed`
- **When:** one target inside a still-continuing run failed. Fires once per
  failed target, so a PARTIAL run emits several.
- **Props:** `user_id_hash`, `catalog_id`, `run_id`,
  `target` (`RESTAURANT`|`CATEGORY`|`PRODUCT`),
  `action` (`CREATE`|`UPDATE`|`DELETE`|`SKIP`), `failure_reason` (string)
- **Note:** the ReCapture `UPPER_SNAKE` code travels as `failure_reason`, NOT
  `code`. The emitter strips any property whose NAME contains `code` as a
  suspected OTP/secret leak, so a prop called `code` would be dropped silently.

## QA

Run `npx tsx scripts/analytics-qa.ts` (see the script header for the dev/prod
invocations). It verifies: valid emit reaches the sink, invalid props are
rejected, forbidden PII keys are stripped, and a throwing sink never propagates.
