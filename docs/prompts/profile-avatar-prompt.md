# Prompt — User Profile Picture (pick → S3 → account snapshot)

> Copy everything below the horizontal rule as the task prompt.
> Written against the repo as of `feature/manual-cap-3` @ `d6b87b5`, with the
> Profile screen from `docs/prompts/profile-screen-prompt.md` already shipped.

---

## Context you must read first

Read **AGENTS.md** before writing any code. It is the single source of truth for
both codebases (Flutter client at the repo root, Node/TS backend in
`recapture-api/`): the API response envelope, config/secrets rules, the
data-layer and rate-limiting patterns, the PII/logging rules, the analytics
seam, and the testing conventions. **Where this prompt disagrees with AGENTS.md,
AGENTS.md wins** — tell me about the conflict rather than silently picking one.

Then read the three places that already solve pieces of this problem. You are
extending these patterns, not inventing new ones:

| What | Where | Why it matters here |
|---|---|---|
| The account snapshot | `recapture-api/src/routes/auth.ts:32-43` (`accountSnapshot`) | ONE shape shared by GET and PATCH `/auth/me`. Every new avatar field goes here, and the client keeps exactly one parser. |
| Presigned-PUT upload slots | `POST /admin/projects/:id/model-images/upload-urls` — `routes/admin.ts:675-745`, service at `services/projectModelsService.ts:442-475` | The exact precedent for "client uploads an image straight to S3". Copy its shape: validate → rate-limit → presign → return `{key, url, expiresAt}`. |
| The bytes-proxy fallback | `GET /admin/projects/:id/photo-bytes` — `routes/admin.ts:747-806`, service at `projectModelsService.ts:495+` | Documents *why* a presigned GET is not always enough: **the raw bucket has no CORS**, so the web build cannot read it. Same constraint applies to avatars. |

The S3 primitives you need already exist in `src/services/s3ObjectStore.ts` —
`presignObjectPutUrl`, `presignObjectGetUrl`, `objectExists`, `getObjectBytes`,
`deleteObject`, `deleteObjectsUnderPrefix`. **Do not construct a second
`S3Client`**; `config/s3.ts` owns the one client.

## Goal

Let a signed-in user set and remove a profile picture. The picture is chosen
from the device gallery, uploaded **directly to S3** by the client (the bytes
never transit the API), and the account snapshot from `/auth/me` starts carrying
a URL the Profile screen renders inside the existing gold avatar ring.

---

## Four design decisions that are already made — implement them, don't relitigate

### 1. The DB stores the S3 **key**, not a URL

The obvious-sounding "store the image URL on the user document" is wrong here
and will rot in production. The raw bucket is private, so the only readable URL
is a **presigned** one, and a presigned URL is a bearer credential with an
expiry measured in minutes-to-hours. Persisting it means the DB holds a value
that is (a) dead within the hour and (b) a credential sitting in a document that
gets logged, exported, and backed up.

So: `User.avatarKey` holds the canonical S3 key. The **URL is derived per
response** by presigning that key. `avatarUrl` exists in the API payload and
nowhere else — never in Mongo, never in a log, never in analytics.

### 2. The bucket stays private

An avatar is a photograph of a person's face attached to an account — it is PII
under this repo's own stance (`routes/auth.ts:26-30`). It goes in
`BUCKET_RAW` (private, no public read, no CloudFront), not `BUCKET_ARTIFACTS`
(CloudFront-fronted, publicly readable by URL). Do not make the object public
and do not "simplify" this by putting avatars behind the CDN.

### 3. Upload is a **three-step** flow, not one

```
1. POST   /auth/me/avatar/upload-url   → { key, url, expiresAt }   (server presigns)
2. PUT    <url>                        → 200                        (client → S3, direct)
3. PUT    /auth/me/avatar  { key }     → { user }                   (server verifies + commits)
```

Step 3 is not ceremony. Without it the server never learns the upload happened,
and a client that dies mid-PUT would leave `avatarKey` pointing at an object
that does not exist — a permanently broken avatar with no way back. Step 3 is
also where the server **verifies** rather than trusts: the client supplies the
key, so the commit re-derives ownership from the token and HEADs the object
before flipping the pointer.

### 4. Every change writes a **new** key

`avatarId` is a fresh `randomUUID()` on every upload, so the key changes on
every change. This buys cache-busting for free — no `Image.network` cache, no
CDN, no client ever shows the previous picture — and it makes the commit step a
clean pointer flip. Cleanup is handled in §1.5.

---

## Part 1 — Backend (`recapture-api/`)

### 1.1 Key scheme — new `src/utils/avatarKeys.ts`

**Do not extend `src/utils/s3Keys.ts`.** That file is the canonical
*capture-job* key space; its `parseImageKey` is a strict 7-segment parser and an
avatar key is not a capture image. New file, same discipline (its header comment
explains the rules — read it and follow them).

```
{env}/avatars/{userId}/{avatarId}.{jpg|png}
```

- `{env}` from the existing `s3EnvPrefix()` — **import it**, never re-derive the
  NODE_ENV → dev/staging/prod mapping.
- Reuse the same `SEGMENT_RE`-style validation on `userId` and `avatarId`: a
  segment may not contain `/`, `\`, whitespace, control characters, or a leading
  dot (which also kills `..`). Builders **throw**; the parser returns a
  discriminated failure, never a partial parse.

Export:

```ts
buildAvatarPrefix(userId): string            // {env}/avatars/{userId}/
buildAvatarKey(userId, avatarId, ext): string
parseAvatarKey(key): { ok: true; value: { env, userId, avatarId, ext } } | { ok: false; reason: string }
```

`parseAvatarKey` is the containment guard for step 3 — it is the security
boundary of this whole feature, so unit-test it directly (§1.7).

### 1.2 `User` model — `src/models/User.ts`

Two optional fields, added beside `displayName` (follow its comment style — say
*why*, and note that absent fields materialize as `undefined`, so there is no
migration, same reasoning as the `role` default):

```ts
avatarKey?: string;        // Schema: { type: String, trim: true }
avatarUpdatedAt?: Date;    // Schema: { type: Date }
```

`avatarKey` is the S3 key — **never a URL** (see decision 1).

### 1.3 Config — `src/config/env.ts`

Follow the file's existing style: every entry Zod-coerced with a default and a
doc comment saying why the number is what it is.

```ts
AVATAR_MAX_BYTES:                z.coerce.number().int().positive().default(2_097_152), // 2 MiB
AVATAR_UPLOAD_URL_TTL_SECONDS:   z.coerce.number().int().positive().default(900),       // 15 min
AVATAR_GET_URL_TTL_SECONDS:      z.coerce.number().int().positive().default(3600),      // 1 h
AVATAR_UPLOAD_MAX_PER_WINDOW:    z.coerce.number().int().positive().default(10),
AVATAR_UPLOAD_WINDOW_SECONDS:    z.coerce.number().int().positive().default(3600),
```

The client downscales to 512×512 before upload (§2.2), so 2 MiB is a generous
ceiling that still refuses a full-resolution phone photo.

### 1.4 `accountSnapshot` — `src/routes/auth.ts:32-43`

Extend the **one** snapshot function; both `/auth/me` verbs inherit it, and so
does the new commit route.

```ts
avatarUrl: user.avatarKey
  ? await presignObjectGetUrl(BUCKET_RAW, user.avatarKey, env.AVATAR_GET_URL_TTL_SECONDS)
  : null,
avatarUrlExpiresAt: user.avatarKey
  ? new Date(Date.now() + env.AVATAR_GET_URL_TTL_SECONDS * 1000).toISOString()
  : null,
```

This makes `accountSnapshot` **async** — update both existing call sites (`GET`
and `PATCH /auth/me`) as well as the new routes below. Presigning
is local SigV4 with no network call (`s3ObjectStore.ts:94-107` says so), so this
costs nothing measurable.

Update the function's doc comment. It currently documents the PII stance for
phone/email; it must now also say that `avatarUrl` is a short-lived presigned
credential that must never be logged.

### 1.5 Three new routes, same router

All are `requireAuth`. All return the standard envelope. The two that mutate
return the **same `user` snapshot** as `GET /auth/me`, so the client keeps one
parser across all four snapshot-returning endpoints.

**`POST /auth/me/avatar/upload-url`**

- Body (Zod, `.strict()`, in `validation/authSchemas.ts`):
  `{ contentType: 'image/jpeg' | 'image/png', contentLength: int 1..AVATAR_MAX_BYTES }`
- Rate-limit per user via `consumeRateWindow('avatar-upload:${userId}', …)` —
  copy the 429 body shape from `admin.ts:706-714`, `retryAfter` included.
- Mint `avatarId = randomUUID()`, build the key, presign a PUT with the
  **declared** content type (it is part of the signature, so the client can only
  ever store an object of that type — `s3ObjectStore.ts:139-144`).
- `200 { status:'success', key, url, expiresAt }`. No DB write. Stateless.
- The `url` is a WRITE bearer credential: the response body is the only place it
  may appear. Never log it, never track it.

**`PUT /auth/me/avatar`** — the commit. Body `{ key: string }`, `.strict()`.

Verify in this order, and fail before touching the DB:

1. `parseAvatarKey(key)` fails → **422** `INVALID_KEY`.
2. `parsed.value.userId !== req.user!.userId` → **403** `FORBIDDEN`. *This is
   the test that matters most in the whole feature: without it, any signed-in
   user can point their avatar at another user's object.*
3. `parsed.value.env !== s3EnvPrefix()` → **422** `INVALID_KEY` (a staging
   client must never commit a prod key).
4. Object missing in S3 (`objectExists`) → **409** `OBJECT_NOT_FOUND`,
   message *"Upload the image before saving it."*
5. `ContentLength > env.AVATAR_MAX_BYTES` → **413** `PAYLOAD_TOO_LARGE`, and
   delete the offending object. Presigning cannot enforce size, so this is the
   only place the ceiling is real — do not skip it.

Then: capture `previousKey`, `$set` the new `avatarKey` + `avatarUpdatedAt`,
and **only after the pointer has flipped**, best-effort clean up. Order matters:
a crash after the flip leaves an orphan (harmless), a crash before it leaves the
user with a deleted picture (broken).

Cleanup deletes **every other object under `buildAvatarPrefix(userId)`**, not
just `previousKey` — that self-heals the orphans left by presigned uploads the
user abandoned. Wrap it in try/catch and swallow: a failed cleanup must never
fail a successful save.

**`DELETE /auth/me/avatar`**

Clears `avatarKey`/`avatarUpdatedAt`, then best-effort
`deleteObjectsUnderPrefix(BUCKET_RAW, buildAvatarPrefix(userId))`. Idempotent —
a user with no avatar gets a plain 200 with the snapshot, never a 404.

### 1.6 Web fallback — `GET /auth/me/avatar/bytes`

`requireAuth`. Streams the signed-in user's own avatar bytes through the API,
reading `avatarKey` **from the token's user document** — no caller-supplied key,
so there is no containment question at all. 404 when `avatarKey` is null.

Mirror `getObjectBytes` usage and the response shape of the existing
`photo-bytes` proxy. It exists for the same documented reason: the raw bucket
serves no CORS, so the Flutter **web** build cannot fetch the presigned URL.
Native clients use `avatarUrl` directly and never hit this route — say so in the
doc comment, as `admin.ts:751-754` does.

Send `Cache-Control: private, max-age=300`.

### 1.7 Backend tests — `tests/` (this repo puts them in `recapture-api/tests/`, not `src/__tests__/`)

Vitest + Supertest + mongodb-memory-server. **Remember the env-before-import
gotcha** documented in the existing auth tests. Stub the S3 seam the way
`tests/admin-model-images.test.ts` already does — no live AWS.

`tests/avatar-keys.test.ts` (pure, no DB):
- round-trips `buildAvatarKey` → `parseAvatarKey`
- rejects `..`, `/`, backslash, whitespace, control chars, empty segments
- rejects a key whose env prefix is not the configured one

`tests/auth-me-avatar.test.ts`:
- `upload-url` returns a key under `{env}/avatars/{callerId}/` and a PUT url
- `upload-url` rejects `image/gif`, a zero `contentLength`, and one over the cap
- **committing another user's key → 403, and the DB is unchanged** ← the one
  that matters
- committing a well-formed key with no object in S3 → 409
- committing an oversized object → 413 **and the object is deleted**
- a successful commit sets `avatarKey`, and the response `user.avatarUrl` is
  non-null while `user.avatarKey` is **absent from the payload** (the key is an
  internal identifier; only the URL ships)
- a second successful commit deletes the previous object
- `DELETE` twice in a row → both 200, `avatarUrl` null
- every route without a token → 401
- **no response body contains a raw phone or email substring** — carry the
  guardrail assertion forward from `auth-me-profile.test.ts`

---

## Part 2 — Client (Flutter)

### 2.1 Dependency

Add `image_picker: ^1.1.2`.

**Flag the app-size cost in your summary before you add it.** This repo has
already deleted a feature over binary size — ML placement detection was removed
for exactly that reason (`lib/presentation/.../placement_guide`, resurrect from
`e6830bc`). `image_picker` is small, but the decision belongs to me, not you:
state the measured delta if you can get one.

iOS `Info.plist` already carries `NSPhotoLibraryUsageDescription` (line 34) —
**verify, don't re-add**. Android 13+ reaches the system photo picker with no
runtime permission, so **do not** route this through
`lib/data/datasources/platform/`'s native permission channel and do not add a
`READ_MEDIA_IMAGES` manifest entry. Gallery only in v1 (see Out of scope).

### 2.2 Pick + downscale — no image-processing dependency

```dart
final picked = await ImagePicker().pickImage(
  source: ImageSource.gallery,
  maxWidth: 512, maxHeight: 512, imageQuality: 85,
);
```

`maxWidth`/`maxHeight`/`imageQuality` resize and re-encode **natively** — that
is the whole reason not to add an `image` package. A cancelled pick returns
null: treat it as a silent no-op, not an error.

**Sniff the content type from the file's magic bytes, do not trust the
extension.** `image_picker` may hand back a `.png` path holding re-encoded JPEG
bytes, and the content type is baked into the presigned signature — a mismatch
is a confusing S3 403 at PUT time.

```dart
// FF D8 FF → image/jpeg;  89 50 4E 47 → image/png;  anything else → reject locally
```

### 2.3 Data layer — `lib/data/repositories/account_repository.dart`

Add to the existing interface (keep the doc-comment style — the file already
explains *why* `fetchRole` must keep throwing; match that register):

```dart
Future<UserProfile> uploadAvatar(File file);
Future<UserProfile> removeAvatar();
```

`uploadAvatar` runs all three steps and returns the committed snapshot.

**The S3 PUT must use a BARE `Dio`, not `dioProvider`.** The app Dio attaches
`Authorization: Bearer …` and the refresh interceptor; an `Authorization`
header on a presigned S3 request breaks the signature and S3 answers 403. The
warmup ping already establishes this bare-Dio precedent — follow it. Send the
bytes with exactly the `Content-Type` that was presigned and no other headers.

Map failures to a small typed enum (`AvatarUploadFailure`: `tooLarge`,
`unsupportedType`, `rateLimited`, `network`, `unknown`) rather than letting a
`DioException` reach the UI. The Screen-9F convention is that **raw transport
errors never reach user-facing copy** — same rule here.

### 2.4 Domain — `lib/domain/entities/user_profile.dart`

Add `String? avatarUrl` and `DateTime? avatarUrlExpiresAt`, parsed by the
existing **defensive** `fromJson` — both absent must stay a valid parse, because
an old backend must never crash a new client. Add `bool get hasAvatar`.

Leave `initials` exactly as it is: it is the fallback when there is no picture,
so it is more important now, not less.

### 2.5 State — `lib/application/auth/profile_provider.dart`

Add `updateAvatar(File)` and `removeAvatar()` to `ProfileNotifier`.

- Keep the **epoch guard** (`profile_provider.dart:64-75`). An avatar upload can
  outlive a sign-out on a slow connection; a late response must not repaint the
  next user's profile. This is the same reasoning that already governs
  `fetchProfile`.
- Expose an in-flight flag (a small `AvatarUploadState`, or a field on the
  notifier) so the UI can show progress **without** dropping the profile into
  `AsyncLoading` — the name, contact, and Sign out must all stay on screen and
  usable while a picture uploads.
- On failure, keep the previous snapshot and surface the typed failure. Unlike
  the rename, **do not** apply an optimistic update: there is no local URL to
  optimistically show, and a half-applied avatar is worse than a spinner.

### 2.6 UI — `lib/presentation/screens/profile/profile_screen.dart`

The `_Avatar` widget (line 350) currently renders initials or a person glyph
inside a 1.5px `royalGold` ring, and its comment calls that ring *"the screen's
ONE royalGold element (the 2–3% budget)"*. **That budget is unchanged.** The
picture goes *inside* the existing ring — do not add a second gold accent, a
gold camera badge, or a gold progress arc.

Render order, first non-null wins: `avatarUrl` → `initials` → `Icons.person_outline`.

- `Image.network(profile.avatarUrl!)` clipped with `ClipOval`, `fit: BoxFit.cover`.
- `loadingBuilder` → the initials, not a spinner (no layout jump, no flash of empty ring).
- `errorBuilder` → the initials. **An expired presigned URL must degrade to
  initials, never to a broken-image icon.** This will happen in real use: the
  URL lives ~1h and a backgrounded app outlives it.
- A small camera glyph badge at the bottom-right of the ring, in
  `AppColors.textSecondary` on `AppColors.surface2` — the affordance that the
  avatar is tappable.
- While uploading: dim the avatar and overlay a `CircularProgressIndicator`
  sized to the ring. The rest of the screen stays interactive.

**Tap → platform-adaptive sheet.** Reuse the pattern in
`lib/presentation/widgets/delete_confirmation_modal.dart`: Material on Android,
`CupertinoActionSheet` on iOS, branching on `Theme.of(context).platform`
(**not** `Platform.isIOS`, so tests can force either side).

- *Choose photo* → pick → upload.
- *Remove photo* → **only when `hasAvatar`**, styled destructive
  (`AppColors.error`), and it gets its own confirm via a new
  `ConfirmKind.removeAvatar` in `lib/domain/entities/confirm_kind.dart` — copy:
  *"Your initials will be shown instead."* Any dismissal resolves `false`.
- Failure → `SnackBar` with mapped copy per `AvatarUploadFailure`. Never the raw
  exception, never the key, never the URL.

Theme rules are unchanged and non-negotiable: no hex literal outside
`app_colors.dart`, spacing from `AppSpacing`, type from `Theme.of(context).textTheme`.

### 2.7 Analytics

Three events through the existing `Analytics.logEvent` seam:
`profile_avatar_updated`, `profile_avatar_removed`, `profile_avatar_failed`.

Properties are **`device_type`, plus a `reason` enum on the failure event, and
nothing else**. No key, no URL, no file path, no byte size tied to an identity,
no user id. The analytics layer's PII guardrail will reject more than that, and
it should. If you add a matching server-side event, hash the ids exactly as
`modelImageUploadsGeneratedProps` does (`validation/analyticsSchemas.ts:420-426`).

---

## Part 3 — Client tests (`test/auth/profile_avatar_test.dart`)

The existing `test/auth/profile_screen_test.dart` must keep passing untouched —
if you have to change an assertion there, stop and tell me why.

Use the same `_FakeAccountRepository` approach that file already establishes.

- A profile with `avatarUrl` renders an `Image`; initials are **not** shown
- `errorBuilder` path: a failing image URL falls back to initials
- No `avatarUrl` → initials, and no `Image` widget in the tree
- Tapping the avatar opens the sheet; *Remove photo* is **absent** with no avatar
  and **present** with one
- Remove → confirm dialog; dismissing calls `removeAvatar()` **zero** times,
  confirming calls it **exactly once**
- A failing upload keeps the previous profile on screen and shows mapped copy —
  assert the raw error string is **not** in the tree
- Sign out stays enabled while an avatar upload is in flight
- Double-tapping *Choose photo* fires one upload

**`\uXXXX`-escape and `pumpAndSettle` traps:** the existing profile tests hit
both. A `CircularProgressIndicator` never settles — use `pump(Duration)`, not
`pumpAndSettle`, anywhere the upload spinner is on screen, or the test hangs.

---

## Out of scope — do not build, do not leave TODOs promising them

Camera as a source (the repo's camera is a bespoke native pipeline — a separate
decision), in-app cropping/rotation UI, multiple or historical avatars, avatars
for *other* users anywhere in the app (Projects, admin lists, live projects),
CloudFront/public avatar delivery, Gravatar or any external fallback, and
server-side image processing or re-encoding.

## Definition of done

- `flutter analyze` clean; `flutter test` green
- `npm test` green in `recapture-api/`
- The **403 cross-user commit** test and the **no-raw-PII** assertion both pass
- `avatarKey` appears in Mongo and in **no** API response body
- No presigned URL appears in any log line or analytics property
- Report plainly what you verified and what you did not. **Device testing and a
  real S3 round-trip are almost certainly NOT done** unless you say otherwise —
  say so explicitly rather than implying green tests mean the upload works
  against live AWS.

## Tell me before you start if

- You think the avatar belongs in `BUCKET_ARTIFACTS`/CloudFront after all — that
  is a PII policy change and it goes in AGENTS.md, not in a commit message.
- `image_picker`'s size cost looks material.
- Making `accountSnapshot` async ripples further than the three call sites.
