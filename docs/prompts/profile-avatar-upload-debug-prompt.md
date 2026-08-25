# Prompt — Diagnose & fix the avatar upload failing on device

> Copy everything below the horizontal rule as the task prompt.
> Written against `feature/manual-cap-3` on 2026-08-01, after the avatar feature
> from `docs/prompts/profile-avatar-prompt.md` was implemented (uncommitted).

---

## Context you must read first

Read **AGENTS.md**, then `docs/prompts/profile-avatar-prompt.md` (the spec this
feature was built from). Where this prompt disagrees with AGENTS.md, AGENTS.md
wins — say so rather than silently choosing.

**This is a debugging task, not a build task.** The feature is fully
implemented on both sides. Something fails at runtime on an Android device and
the user sees *"Couldn't update your photo. Try again."* Your job is to find
the cause and fix that cause — not to rewrite the feature.

## Do not re-derive these — they are already established

Verified on 2026-08-01 against the **running local API** (`http://localhost:3000`)
and **real AWS** (`us-east-1`, bucket `msxr-raw-captures`), by driving the exact
three-step flow with curl using a dev-OTP token:

| Leg | Result |
|---|---|
| `POST /auth/me/avatar/upload-url` | **200** — key `dev/avatars/{userId}/{uuid}.jpg`, host `msxr-raw-captures.s3.us-east-1.amazonaws.com` |
| `PUT <presigned url>` (real bytes) | **200** |
| `PUT /auth/me/avatar { key }` | **200**, `user.avatarUrl` non-null |
| `DELETE /auth/me/avatar` | **200**, `avatarUrl` back to null |

So: **the routes, Zod schemas, AWS credentials, region, bucket, key builder,
containment guard, presign, and commit all work.** The failure is client-side or
network-side. Do not start by auditing `recapture-api/` — if you end up changing
backend code, you must first explain what evidence overturned the table above.

Also already true, do not re-investigate:

- The client/server contract matches: the client posts `{contentType, contentLength}`;
  `avatarUploadUrlSchema` is `.strict()` and expects exactly those.
- `API_BASE_URL=http://localhost:3000` in the **root `.env`**, which overrides
  `.env.dev` (dotenv is first-wins — see the env-loading convention).
- Auth works on device and `GET /auth/me` succeeds — the Profile screen renders
  the real name and masked contact. So our API *is* reachable from the device.
- Presigning is **local SigV4 with no network call**. A presign returning 200
  proves nothing about AWS reachability or IAM permissions.

## Already fixed in this area — do not "re-fix" or revert

1. **Android lost-pick recovery.** `image_picker` returns `null` when Android
   destroys the activity while the gallery is in front; the selection is parked
   and must be reclaimed with `retrieveLostData()`. Handled in
   `lib/data/datasources/avatar_image_picker.dart` (`retrieveLost`,
   `recoverLostAvatar`) and called on mount by the Profile screen.
   `getLostData` is **Android-only** — the platform interface's default throws
   `UnimplementedError`, so the `kIsWeb || defaultTargetPlatform` guard must stay.
2. **A silent drop on unmount.** `_pickAndUploadAvatar` used to read
   `if (picked == null || !mounted) return;`, discarding a real photo whenever the
   widget unmounted during the gallery trip. The notifier is now resolved before
   the round-trip; `mounted` guards only the snackbar.
3. **The mount probe must never report.** The lost-data probe runs unprompted on
   every open, so its own failure must not surface — it once produced
   `profile_avatar_failed {reason: unknown}` the instant the screen opened, which
   masked the real bug. `retrieveLost()` now never throws; the screen's reclaim
   and upload halves are separate `try` blocks. **There is a regression test for
   this — keep it passing.**
4. **The S3 PUT sends bytes, not `file.openRead()`.** A streamed body required a
   hand-set `Content-Length` and gave the adapter a chunked path to get wrong.

## The one thing that is NOT known

**Which of the three legs fails on the device, and why.** Every previous run was
polluted by defect 3 above, so no clean observation exists yet. Everything below
depends on getting one.

---

## Step 1 — Get the log line. Do not skip to a fix.

`lib/data/repositories/account_repository.dart` is instrumented through
`DevUploadLog` (the seam built for UNK-01; it `debugPrint`s with an
`[upload-dev]` prefix and is a no-op only in prod-flavor builds).

Run the app on the device with the local API up, open Profile, tap the avatar,
choose a photo, and capture the console.

A healthy run prints:

```
[upload-dev] avatar 1/3 presign — type=image/jpeg bytes=…
[upload-dev] avatar 2/3 PUT → S3
[upload-dev] avatar 3/3 commit
[upload-dev] avatar done
```

A failure prints one line naming the step, Dio error type, status, host, and the
error code lifted from either our envelope or S3's XML:

```
[upload-dev] avatar <step> FAILED → <failure> — <dioType> status=<code> host=<host> code=<errorCode>
```

**Report that line verbatim in your summary.** It is the finding; the fix is
downstream of it.

## Step 2 — Fix the cause the log names

| What you see | Cause | What to do |
|---|---|---|
| No `1/3` line at all | The repository was never entered — the picker returned null or threw first | Look for `[upload-dev] avatar: pick returned null` / `lost-data probe`. The pick path is the bug, not the upload. |
| `1/3 … status=429` | Per-user rate window exhausted — `AVATAR_UPLOAD_MAX_PER_WINDOW` defaults to **10 per hour**, and **every attempt counts, including ones that later failed** | Very likely after repeated debugging. Wait out the window, use a different account, or raise the env var locally. **Not a code bug — do not "fix" it in code.** |
| `1/3 … status=404` | The device is hitting an API without these routes (they are uncommitted) | Confirm which host the device resolves; make sure it is the local server running this working tree. |
| `1/3 … status=401` | Token/refresh problem on this route only | Check the interceptor is attaching Bearer to POST as it does to GET. |
| `1/3 … status=400 code=INVALID_REQUEST` | Body rejected — most likely `contentLength` (0, or over `AVATAR_MAX_BYTES` = 2 MiB) | Log the length; check what `image_picker` actually wrote. |
| `2/3 … type=connectionError status=-` | **The leading hypothesis.** The device cannot reach `amazonaws.com`. Our API is `localhost` (reached via `adb reverse` or similar), but S3 is the public internet — a path the working profile fetch never exercises | Verify the device has real internet, and that no proxy/VPN/firewall blocks it. If the device genuinely cannot reach S3, say so plainly: the direct-to-S3 design cannot work on that device and the choice (proxy the bytes through the API vs fix the network) is the user's, not yours. |
| `2/3 … status=403 code=SignatureDoesNotMatch` | The PUT's `Content-Type` differs from the presigned one | The type is part of the signature. Confirm the sniffed type sent to `upload-url` is byte-identical to the header on the PUT, and that nothing appends a charset. |
| `2/3 … status=403 code=AccessDenied` | IAM lacks `s3:PutObject` on `dev/avatars/*` | Credentials work for capture prefixes; this prefix is new. Report it — an IAM policy change is the user's call. |
| `2/3 … status=400 code=EntityTooLarge` / `RequestTimeout` | Body/length mismatch | Confirm the byte body is sent whole and no `Content-Length` is hand-set. |
| `3/3 … status=409 code=OBJECT_NOT_FOUND` | The PUT reported success but the server HEADs nothing — bucket or region disagreement between presign and commit | Both must come from `config/s3.ts`. Do not paper over this by dropping the existence check. |
| `3/3 … status=403` | Ownership/containment refused the key | The security guard is working; find out why the key's `userId` differs from the token's. |

## Guardrails — these are not negotiable

- **Never log or render a presigned URL or an S3 key.** A presigned URL is a
  bearer credential; the key is an internal identifier. The current log prints
  the **host only** — never the path or query. Keep it that way.
- **Keep the mapped-copy convention.** A raw `DioException`, an S3 XML body, or a
  status code must never reach user-facing text. If a cause deserves its own
  sentence, add a value to `AvatarUploadFailure` and map it — do not leak the raw
  error as a shortcut.
- **Do not widen the failure enum just to make debugging easier.** The dev log is
  where detail belongs.
- Analytics carries `device_type` plus a mapped `reason` and nothing else.

## Definition of done

- The failing log line is quoted in your summary, with the cause named.
- The fix addresses **that** cause. If the cause is environmental (rate window,
  network, IAM), the correct deliverable is a clear explanation and **no code
  change** — say so instead of inventing one.
- `flutter analyze` clean; `flutter test test/auth/` green (129 tests at the time
  of writing, including the mount-probe regression test).
- If you touched `recapture-api/`, `npm test` green — and justify why, given the
  verified table above.
- State plainly what you verified on a real device versus what you only reasoned
  about. A green test suite is **not** evidence the upload works on hardware.
