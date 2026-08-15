# AWS Storage & CDN — S3 + CloudFront

How ReCapture stores bytes and how it serves them back. Covers **what** each
piece is, **why** it is shaped that way, and **how** to work with it (and set it
up from scratch).

This document describes the system as it exists in code. Where a fact lives only
in the AWS console and cannot be verified from this repo, it is marked
**[verify in console]**.

Related: [AGENTS.md](../AGENTS.md) §S3 key scheme, §Config & secrets — that file
is the normative source for conventions; this one explains the reasoning and the
operational side.

---

## 1. The one-paragraph version

Everything ReCapture stores lives in **two S3 buckets**. Capture photos and
profile pictures go into the **private** bucket and are only ever reachable
through short-lived **presigned URLs** minted by the API. Generated 3D models go
into the **artifacts** bucket, which sits behind a **CloudFront distribution** so
phones anywhere can stream a GLB fast and cheap. The app never talks to AWS
credentials — it receives URLs. The API never proxies capture bytes — it signs
URLs and gets out of the way.

```
                        ┌──────────────────────────────┐
  Flutter app ───────►  │  recapture-api (Render)      │
   (phone/web)          │  holds the IAM keys          │
        │               └──────────┬───────────────────┘
        │                          │ mints presigned URLs
        │                          │ (local SigV4, no network call)
        │                          ▼
        │              ┌────────────────────────────┐
        └── PUT/GET ──►│  S3: msxr-raw-captures     │  PRIVATE
           bytes go    │  photos, manifests,        │  presigned-only
           direct      │  avatars (PII)             │
                       └────────────────────────────┘

                       ┌────────────────────────────┐
   worker writes ─────►│  S3: msxr-model-artifacts  │
   model.glb etc.      │  GLB / USDZ / preview.jpg  │
                       └──────────┬─────────────────┘
                                  │ origin
                                  ▼
                       ┌────────────────────────────┐
   app <── GET ────────│  CloudFront distribution   │  PUBLIC URLs
   model.glb           │  d3ap77f0m6kfrr.cloudfront │  no signing
                       └────────────────────────────┘
```

---

## 2. The AWS account & IAM

| Thing | Value |
|---|---|
| Account id | `861276117526` |
| IAM user | `recapture-api-service` |
| User ARN | `arn:aws:iam::861276117526:user/recapture-api-service` |
| Region | `us-east-1` (`AWS_REGION`) |
| CloudFront distribution | `E258VPXCCDI4J2` |
| Distribution domain | `d3ap77f0m6kfrr.cloudfront.net` |

**What.** A single IAM *user* (long-lived access key + secret) that the API and
the worker both authenticate as.

**Why a user and not a role.** The API runs on Render, not on EC2/ECS, so there
is no instance profile to assume — a static key pair is the only credential
Render can hold. That is a deployment constraint, not a preference.

**How the credentials reach the code.** Only through env, validated at boot:

```ts
// src/config/env.ts — fails fast, the process will not start without these
AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
S3_BUCKET_RAW, S3_BUCKET_ARTIFACTS, CLOUDFRONT_BASE_URL
```

and are used to build **exactly one** shared client:

```ts
// src/config/s3.ts — never construct a second S3Client anywhere
export const s3Client = new S3Client({ region, credentials });
export const BUCKET_RAW       = env.S3_BUCKET_RAW;       // msxr-raw-captures
export const BUCKET_ARTIFACTS = env.S3_BUCKET_ARTIFACTS; // msxr-model-artifacts
export const CLOUDFRONT_BASE  = env.CLOUDFRONT_BASE_URL;
```

One client means one place to add retry config, one place to swap credentials,
and one object for tests to `vi.spyOn(s3Client, 'send')` against.

### Credential hygiene

- `AWS.txt` at the repo root holds the real access key, secret, and console
  password. It is **gitignored and untracked** — verified — so it has not leaked
  into history. Keep it that way; it is a local convenience file only.
- `.env` and `.env.*` are likewise gitignored. `.env.example` is committed and
  must never contain a real value.
- **Secrets never appear in logs, analytics, or error messages.** This extends to
  presigned URLs — see §6.

**Recommended hardening [verify in console]:**
1. Scope the IAM policy to exactly the two buckets and the actions actually used
   (`GetObject`, `PutObject`, `DeleteObject`, `ListBucket`, `HeadObject`,
   `CopyObject`, and the three multipart actions). A wildcard `s3:*` on `*` is
   the common default and is more than this app needs.
2. Rotate the access key on a schedule; the code reads it from env, so rotation
   is a Render env-var change plus a restart — no code change.
3. Enable a **console MFA** on the user, or better, stop using it for console
   sign-in entirely and keep it machine-only.

---

## 3. Two buckets — what goes where and why

| | `msxr-raw-captures` (`BUCKET_RAW`) | `msxr-model-artifacts` (`BUCKET_ARTIFACTS`) |
|---|---|---|
| Holds | capture photos, `capture_manifest.json`, **avatars** | `model.glb`, `model.usdz`, `preview.jpg` |
| Written by | the phone, directly (presigned multipart) | the worker, server-side |
| Read by | API + staff export, via presigned GET | **anyone**, via CloudFront |
| Public? | **No.** Private, presigned-only | Fronted by the CDN |
| CORS | **none** — deliberately | n/a (CDN serves it) |

### Why two buckets instead of one with prefixes

Because they have **opposite access policies**, and a bucket is the cleanest
boundary for that. Raw captures are user data — someone's living room, someone's
face. Model artifacts are the deliverable, meant to be streamed by the app from
anywhere with no auth round trip. Putting both in one bucket means one wrong
policy line exposes the photos.

### Why avatars live in the *private* bucket

A profile picture is a face attached to an account — that is PII. Serving it from
CloudFront would make it a permanent unauthenticated URL. So avatars go in
`BUCKET_RAW` and are served as **presigned GETs that expire within the hour**.

> Moving avatars behind the CDN is a **policy change**, not a refactor. It
> belongs in AGENTS.md before it belongs in code.

### The identical-prefix rule

Both buckets use the **same key prefix** for the same job. This is load-bearing:
deleting a project runs `deleteObjectsUnderPrefix` against *the same prefix in
both buckets* (`adminProjectsService.deleteProject`). If the two schemes ever
diverge, deletion silently half-works and orphans data.

**Accepted consequence:** the project name is visible inside public CloudFront
URLs (see §5). Conscious tradeoff, documented, not an oversight.

---

## 4. Key schemes — the address of every byte

There are **two** key spaces with **two** builders and **two** strict parsers,
deliberately not unified.

### 4.1 Capture jobs — `src/utils/s3Keys.ts`

```
{env}/{projectSlug}_{projectId}/{jobId}/images/{EYE|TOP|LOW}/{name}.jpg
{env}/{projectSlug}_{projectId}/{jobId}/capture_manifest.json
{env}/{projectSlug}_{projectId}/{jobId}/model-input/…       ← reserved
{env}/{projectSlug}_{projectId}/{jobId}/deleted/…           ← soft-delete park
{env}/{projectSlug}_{projectId}/{jobId}/models/{modelId}/…  ← 3D artifacts
```

Example:

```
prod/kitchen-table_665f1a2b3c4d5e6f77889900/665f9988.../images/EYE/frame_0001.jpg
```

**`{env}` — `dev` | `staging` | `prod`.** Config-driven from `NODE_ENV`, never
hardcoded. **Why it matters more than it looks:** the project-delete path wipes
objects *by prefix*. This segment is the firewall that stops a staging deploy
from deleting production objects. Non-negotiable.

**`{projectSlug}` — a label, never an identifier.** `projectNameSlug()`
lowercases, NFKD-strips diacritics (`Café` → `cafe`), collapses anything outside
`[a-z0-9_]` to a single `-`, trims edge separators, truncates to 40 chars. Pure
and deterministic. **Why it exists:** so a human debugging in the S3 console can
tell which project a folder is without cross-referencing Mongo. Nothing ever
reads it back — slugification is one-way. An all-emoji name slugifies to nothing
and the segment degrades to a bare `{projectId}`, never a leading `_`.

**`{userId}` is *not* in the path.** Ownership is enforced in the DB and by the
token, never by key prefix. A path is not an ACL.

**`{LEVEL}` is the ring name `EYE|TOP|LOW`,** not the mobile `A/B/C` codes. The
builders accept either as *input* (`normalizeCaptureLevel`) but always *emit* the
ring name, so keys never drift between clients.

**Safety:** every interpolated segment passes `requireSegment()` —
`/^[A-Za-z0-9][A-Za-z0-9._-]*$/`. That rejects `/`, `\`, whitespace, control
chars, and a leading dot (which is how `..` traversal starts). A hostile project
name cannot escape its prefix or inject key levels. Builders **throw**
`S3KeyError`; `parseImageKey` returns a discriminated `{ ok: false, reason }` —
never a partial parse.

**Keys are built ONCE**, at job creation, and persisted on the job
(`Job.upload.rawPrefix`, `Job.upload.manifestKey`). Every later
read/list/move/delete resolves from those persisted values.

> **Why this is the most important rule here:** it means changing the key scheme
> needs **no migration and no backfill**. Old objects stay where they are, old
> jobs keep uploading/finalizing/exporting/deleting. Rebuilding a prefix for an
> already-created job turns a scheme change into data loss. Don't.

### 4.2 Avatars — `src/utils/avatarKeys.ts`

```
{env}/avatars/{userId}/{avatarId}.{jpg|png}
```

Separate file, separate parser, on purpose — an avatar is not a capture image and
must not be reachable through `parseImageKey` (nor widen it). This space **keeps
`{userId}`**; the capture space dropped it.

`{avatarId}` is a fresh `randomUUID()` per upload, so **the key changes every
time the picture changes**. That buys cache-busting for free: no stale
`Image.network` cache, no client ever showing the previous picture, and the
commit step is a clean pointer flip.

`parseAvatarKey` is the **security boundary** of the avatar feature — see §7.3.

### 4.3 Model artifacts

```
{rawPrefix}models/{modelId}/model.glb
{rawPrefix}models/{modelId}/model.usdz     (optional)
{rawPrefix}models/{modelId}/preview.jpg    (optional)
```

Per-**model** prefix, not per-job. **Why:** a regenerate must never overwrite the
attempt an artist may still want to compare against, and it makes each record's
storage self-contained and independently deletable.

---

## 5. CloudFront

**What.** Distribution `E258VPXCCDI4J2`, domain `d3ap77f0m6kfrr.cloudfront.net`,
fronting `msxr-model-artifacts`. Configured in env as:

```
CLOUDFRONT_BASE_URL=https://d3ap77f0m6kfrr.cloudfront.net
```

validated as a real URL at boot (`z.string().url()`).

**Why a CDN at all.** Three reasons, in order of weight:

1. **Latency.** A GLB is megabytes. Pulling it from `us-east-1` to a phone in
   India is a slow first paint; pulling it from a nearby edge is not.
2. **Cost.** CloudFront egress is cheaper than S3 egress, and a cached model is
   served without touching S3 at all. Models are written once and read many
   times — the ideal cache profile.
3. **Stability of the URL.** The URL is persisted in Mongo and rendered by the
   app. A CDN domain is a stable indirection: the origin bucket can be moved or
   renamed behind it without invalidating a single stored URL.

**How URLs are built.** Plain string concatenation at the moment the artifact is
written, then persisted:

```ts
// src/worker/processors/meshyModelProcessor.ts
cdnUrls: {
  glb:     `${CLOUDFRONT_BASE}/${prefix}model.glb`,
  usdz:    `${CLOUDFRONT_BASE}/${prefix}model.usdz`,     // when present
  preview: `${CLOUDFRONT_BASE}/${prefix}preview.jpg`,    // when present
}
```

The CloudFront path is **identical to the S3 key** — no rewrite, no mapping
table. That is what makes "the same prefix in both buckets" a rule you can rely
on when debugging: paste the key after the CDN domain and you have the URL.

Same construction in `modelOptimizationProcessor.ts` and
`reconstructionEngine.ts`. There are only these three sites, and they all import
`CLOUDFRONT_BASE` from `config/s3.ts` — never a hardcoded domain.

### CloudFront URLs are public and unsigned

There is **no CloudFront signed-URL / signed-cookie setup** in this codebase — no
key-pair id, no private key, no `getSignedUrl` from `@aws-sdk/cloudfront-signer`.

**What that means concretely:** a model URL is a permanent, unauthenticated,
guess-resistant-but-not-secret link. Anyone who has it can fetch the model
forever. Security rests on the URL not being published — and the path contains
the project *name* slug, the project id, the job id and the model id, so it is
not guessable in practice, but it is not protected either.

This is a **reasonable default for a 3D-model CDN** and a **deliberate contrast**
with capture photos and avatars, which are never on this path. If model
confidentiality ever becomes a requirement (a private/enterprise tier, say), the
change is: CloudFront signed URLs + an origin access control, with the API
minting per-request signatures the way it already does for S3.

### Things to confirm in the console [verify in console]

The repo cannot tell you these; check them once and record the answers here:

1. **Origin access.** Is `msxr-model-artifacts` locked to the distribution via
   **Origin Access Control (OAC)**, with the bucket itself blocking public
   access? It should be — otherwise the bucket is directly readable and the CDN
   is decorative.
2. **Cache policy / TTL.** Artifacts are immutable (a new generation writes a new
   `{modelId}` prefix), so a **long max-age** is safe and desirable. If the TTL
   is short, you are paying S3 egress on every miss for no benefit.
3. **Compression.** GLB is already compressed; `preview.jpg` too. Little to gain,
   no harm.
4. **Invalidation.** Because keys are immutable per generation, **you should
   almost never need an invalidation.** If you find yourself invalidating
   regularly, something is overwriting a key that should have been a new one.

---

## 6. Presigned URLs — the core mechanism

**What.** A presigned URL is an S3 URL carrying a SigV4 signature that grants
*one* operation on *one* key until *one* deadline. The holder needs no AWS
credentials.

**Why the whole app is built on them.** The alternative is proxying bytes through
the API: every capture photo would flow phone → Render → S3, doubling transfer,
burning Render CPU and memory, and putting a 512 MB dyno in the path of a
multi-gigabyte upload. Presigning moves the bytes **phone ↔ S3 directly** while
the API keeps full control over *what* may be written *where* and *for how long*.

**How it's cheap.** Presigning is **local signing — no network call to AWS**.
Minting a hundred part-URLs in parallel costs nothing but CPU, which is why
`presignPartUrls` fans out with `Promise.all` instead of looping.

### The helpers (`src/services/s3ObjectStore.ts`)

| Function | Grants | Notes |
|---|---|---|
| `presignObjectGetUrl(bucket, key, ttl, opts?)` | one GET | `opts.downloadFilename` adds `Content-Disposition: attachment` |
| `presignObjectPutUrl(bucket, key, ttl, contentType)` | one PUT | **content type is inside the signature** |

**Why the content type is signed:** the uploader can only ever store an object of
the type the server declared. A client that presigns for `image/jpeg` cannot
upload an HTML file to that key.

**Why `downloadFilename` exists:** the raw bucket has no CORS policy, so a web
client cannot `fetch()` the bytes. But a plain browser *navigation* to a
`Content-Disposition: attachment` URL downloads fine. One URL therefore serves as
both an `<img>` source and a download link — the `<img>` path ignores the header.

### The iron rule

> **A presigned URL is a bearer credential. NEVER log it, never put it in an
> analytics event, never persist it.**

It may appear in exactly one place: the response body of the request that minted
it. This is why `accountSnapshot` presigns the avatar URL *per response* and
ships an `avatarUrlExpiresAt` alongside, rather than storing a URL in Mongo.

### TTLs

| Constant | Default | Applies to |
|---|---|---|
| `PRESIGN_EXPIRES_SECONDS` | 3600 (1 h) | multipart part URLs |
| `UPLOAD_PLAN_TTL_SECONDS` | 86400 (24 h) | the upload plan window |
| `AVATAR_UPLOAD_URL_TTL_SECONDS` | 900 (15 m) | avatar presigned PUT |
| `AVATAR_GET_URL_TTL_SECONDS` | 3600 (1 h) | avatar URL on the account snapshot |
| `ADMIN_EXPORT_URL_TTL_SECONDS` | 3600 (1 h) | staff export GETs |
| `MESHY_SOURCE_URL_TTL_SECONDS` | 3600 (1 h) | photos handed to Meshy |

**Why part URLs are 1 hour and the plan is 24 hours:** one hour is long enough to
push a single 5 MiB–5 GiB part over mobile data, short enough that a leaked URL
goes stale quickly. It does **not** bound the whole session — the client
re-fetches an expired part URL (`refreshPartUrl`), so a capture interrupted
overnight resumes inside the 24-hour plan window.

---

## 7. The flows

### 7.1 Capture upload — phone → S3, end to end

```
1.  POST /jobs
      → server mints jobId, builds rawPrefix + manifestKey ONCE, persists them
      → returns the upload plan: { bucket, keyPrefix, manifestKey,
                                   expectedFilesCount, expiresAt }
      → project status → UPLOADING

2.  POST /jobs/:jobId/uploads/initiate   { key, fileSize, ... }
      → guards: owned job (404) → CREATED/UPLOADING only (409)
              → plan window open (410) → key CONTAINED under keyPrefix (400)
              → part count achievable for fileSize (400)
      → CreateMultipartUpload → returns uploadId + part plan
      → first success flips CREATED → UPLOADING exactly once

3.  POST /jobs/:jobId/uploads/part-url   { key, uploadId, partNumber }
      → returns one presigned PUT URL. Stateless; re-callable on expiry.

    ── the phone PUTs each part straight to S3, collects ETags ──

4.  POST /jobs/:jobId/uploads/complete   { key, uploadId, parts[] }
      → CompleteMultipartUpload → S3 stitches the parts, returns the ETag

5.  POST /jobs/:jobId/finalize
      → resolves rawBucket/rawPrefix/manifestKey from the PERSISTED job
      → reads + validates capture_manifest.json
      → countObjectsUnderPrefix(rawBucket, rawPrefix) must equal
        expectedFilesCount EXACTLY (the count is manifest-INCLUSIVE)
      → mismatch → 422, nothing changes, retry is clean
      → match → job proceeds to processing
```

**Why multipart at all.** A capture is dozens of photos and can run to gigabytes.
Multipart gives resumability (a failed part retries alone), parallelism, and it
is S3's only path above 5 GB. The floors are S3's, not ours:
`PART_SIZE_MIN = 5 MiB`, `MAX_PARTS = 10_000`, `MAX_PART_SIZE = 5 GiB` — echoed
to the client so both sides plan identical chunking.

**Why finalize counts objects in S3 rather than trusting the client.** The client
reports what it *thinks* it uploaded; S3 knows what actually landed. An exact
match is required in both directions — an undershoot means a lost file, an
overshoot means something wrote where it shouldn't have. Either way, don't
enqueue processing on a bad input set.

**Why the count is manifest-inclusive and lists the *job root*,** not
`…/images/`: the manifest sits at the job root, so the boundary the plan
advertises and the boundary finalize verifies are the same prefix. One number,
one prefix, no off-by-one.

**Key containment.** `initiate` rejects any key not under the job's own
`keyPrefix`. This is the guard that stops an authenticated client from presigning
a write into someone else's job.

### 7.2 3D model generation — worker → S3 → CloudFront

```
1.  A generation is requested (staff pick, auto-after-capture, or the button)
2.  Worker sends the selected photos to Meshy as presigned GET URLs
       (TTL MESHY_SOURCE_URL_TTL_SECONDS — Meshy needs no credentials of ours)
3.  Worker polls the Meshy task to completion
4.  rehostArtifacts(): downloads Meshy's GLB / USDZ / thumbnail and
       putObjectBytes() them into BUCKET_ARTIFACTS under
       {rawPrefix}models/{modelId}/
5.  Persists BOTH the S3 keys (for server-side re-reads) AND the CloudFront
       URLs (for the app) on the ProjectModel record
```

**Why re-hosting is a correctness requirement, not an optimization:** Meshy's
result URLs carry an `expires_at`. Persisting one would give us a model link that
dies. **Only our own CloudFront URLs are ever stored or served. Never store a
Meshy URL.**

**Why both `glbKey` and `cdnUrls.glb` are persisted:** the key is what the server
re-reads with (`headObject`, the optimizer's `getObjectBytes`); the URL is what
the app fetches. Deriving one from the other at read time would put the CDN
domain in a second place.

The **Optimize** action (`modelOptimizationProcessor`) runs a succeeded GLB
through glTF-Transform and writes the result as **its own record under its own
`{modelId}` prefix** — never over the original. Same reason as regenerate: the
source stays comparable.

### 7.3 Avatars — three steps, and where the security is

```
1.  POST /auth/me/avatar/upload-url   { contentType }
      → server mints avatarId = randomUUID(), builds the key,
        presigns a PUT (TTL 15 m) with the content type IN the signature

2.  The client PUTs the image straight to S3

3.  PUT /auth/me/avatar   { key }
      → parseAvatarKey(key)                      ← strict, 4 segments
      → re-derive ownership from the TOKEN and compare to the parsed userId
           mismatch → 403                        ← THE security boundary
      → env prefix must match the configured one → 422
           (a staging client must never commit a prod key)
      → headObject → enforce AVATAR_MAX_BYTES (2 MiB)
      → flip User.avatarKey
      → best-effort sweep of the rest of the prefix
```

**Why size is enforced at commit and not at presign:** S3 presigning has **no
size condition**. The only moment you can know how big the object is, is after it
exists. Hence the HEAD.

**Why the pointer flips *before* the cleanup sweep:** a crash between them
orphans an object (cheap, self-healing on the next upload, since the sweep wipes
the whole prefix) instead of breaking a live avatar (visible, user-facing). Order
the two steps so the failure mode is the boring one.

**Why the client-supplied key is safe here:** it isn't, inherently — which is
exactly why `parseAvatarKey` exists and why `tests/avatar-keys.test.ts` covers it
directly. A key belonging to another user is a 403, not a 404, and not a write.

**`GET /auth/me/avatar/bytes`** is the web-only fallback: the raw bucket has no
CORS, so a browser cannot XHR the presigned URL. This route streams the bytes
through the API, reading the key **from the token's user document, never from the
caller**.

### 7.4 Staff export & the photo proxy

- `GET /admin/projects/:id/export` lists everything under the job prefix and
  presigns a GET per object (TTL 1 h), rate-limited per user
  (`ADMIN_EXPORT_MAX_PER_WINDOW` / `ADMIN_EXPORT_WINDOW_SECONDS`). Presigning is
  local, so presigning a whole manifest in parallel is cheap.
- The admin **photo-bytes proxy** exists for the same CORS reason as the avatar
  fallback: it buffers one photo (`getObjectBytes`) and serves it, so a browser
  client can display a capture without the raw bucket needing a CORS policy.
  Whole-object buffering is deliberate — single photos are a few MB, and
  buffering means a mid-stream S3 failure cannot corrupt an already-committed
  200.

### 7.5 Deletion

`deleteObjectsUnderPrefix(bucket, prefix)` lists (following continuation tokens)
then deletes one by one. `deleteProject` runs it against **the same prefix in
both buckets**.

- **Idempotent.** S3 `DeleteObject` on a missing key is a success, never a 404.
- **Partially-failed deletes are retryable** — a throw mid-sweep leaves the
  remainder in place, and re-running is safe.
- **Soft delete** (`moveObject`) is copy-then-delete, in that order, into the
  `…/deleted/` park. S3 has no native move. Copy-first means a crash between the
  steps leaves the object readable at **both** locations (recoverable) rather
  than at neither.

---

## 8. Working with it

### Common operations

```bash
# What's actually under a job prefix?
aws s3 ls s3://msxr-raw-captures/prod/kitchen_665f.../665f99.../ --recursive

# Total size of a project's captures
aws s3 ls s3://msxr-raw-captures/prod/kitchen_665f.../ --recursive --summarize

# Is the model where the DB says it is?
aws s3api head-object --bucket msxr-model-artifacts \
  --key "prod/kitchen_665f.../665f99.../models/6690aa.../model.glb"

# Does the CDN serve it? (headers only — don't download the GLB)
curl -I https://d3ap77f0m6kfrr.cloudfront.net/prod/kitchen_665f.../…/model.glb

# Rarely needed — keys are immutable per generation. If you need this often,
# something is overwriting keys that should have been new ones.
aws cloudfront create-invalidation --distribution-id E258VPXCCDI4J2 --paths "/prod/*"
```

### Reading `x-cache` on a CloudFront response

`Hit from cloudfront` — served from the edge, S3 untouched.
`Miss from cloudfront` — fetched from the origin bucket this time.
`RefreshHit` — revalidated. Persistent misses on the same URL point at a short
TTL or a cache policy that varies on something it shouldn't (query strings,
headers).

### Setting this up in a fresh AWS account

1. **Buckets.** Create `<prefix>-raw-captures` and `<prefix>-model-artifacts` in
   your region. **Block all public access on both.**
2. **CORS.** Add a CORS policy on the *raw* bucket **only if** you need browser
   clients to PUT directly. Native mobile does not need it. (The current setup
   deliberately has none — hence the two proxy routes in §7.3/§7.4.)
3. **IAM user.** Create a programmatic user, attach a policy scoped to those two
   bucket ARNs and the actions listed in §2. Save the key pair once.
4. **CloudFront.** Create a distribution with the **artifacts** bucket as origin.
   Use **OAC**, and let the console update the bucket policy for you. Set a long
   default TTL — artifacts are immutable.
5. **Env.** Fill `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
   `S3_BUCKET_RAW`, `S3_BUCKET_ARTIFACTS`, `CLOUDFRONT_BASE_URL` (no trailing
   slash). The API fails fast at boot if any is missing or malformed.
6. **Verify.** Boot the API, create a job, confirm the plan's `keyPrefix` carries
   the right `{env}` segment. Then generate a model and `curl -I` its CDN URL.

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| App boots then dies immediately | An AWS env var missing/malformed — `config/env.ts` fails fast by design. Read the message; it names the variable. |
| `SignatureDoesNotMatch` on a part PUT | Clock skew on the device, or the part URL expired (1 h) — the client should call `part-url` again. |
| `AccessDenied` on every S3 call | Wrong key pair, wrong region, or the IAM policy doesn't cover the bucket. |
| Presigned PUT rejected | The `Content-Type` sent doesn't match the one that was signed — it is part of the signature. |
| Finalize returns 422 | Object count under the prefix ≠ `expectedFilesCount`. List the prefix; remember the count includes the manifest. |
| Model URL 403s from CloudFront | Object isn't at that key, or OAC/bucket policy is wrong. HEAD the S3 key first to tell the two apart. |
| Model URL 404s but the object exists | Prefix mismatch between what was persisted and what the CDN path is — the two must be byte-identical. |
| Browser can't load a capture photo | Expected: the raw bucket has no CORS. Use the bytes proxy, not a direct fetch. |
| Avatar commit → 403 | The key's `{userId}` doesn't match the token. Working as designed. |
| Staging deleted prod objects | Should be impossible — `{env}` is the firewall. If it happened, someone hardcoded a prefix. |

---

## 9. The rules, condensed

1. **One S3 client** (`config/s3.ts`). Never construct a second.
2. **One key builder per key space.** Inline key templates are a bug.
3. **`{env}` is config-driven.** It is what keeps a non-prod deploy from deleting
   prod data.
4. **Keys are built once and persisted.** Never rebuild a prefix for an existing
   job.
5. **Both buckets share the identical prefix.** Deletion depends on it.
6. **Presigned URLs are bearer credentials.** Response body only — never logs,
   never analytics, never Mongo.
7. **Raw captures and avatars are private.** CloudFront is for artifacts only;
   moving anything else there is a policy decision.
8. **Never persist a third-party URL** (Meshy's expire). Re-host, then store ours.
9. **The client never builds keys.** It receives `keyPrefix` / `keyTemplate` and
   composes underneath.
10. **Ownership lives in the DB and the token, never in the path.**
