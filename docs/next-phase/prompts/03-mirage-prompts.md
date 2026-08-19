# Mirage Prompts — M1 … M5

Target repos:
- **Backend:** `phase2/mirage-be-phase-2-recap/` — the phase-2 working fork. Its `src/` is currently
  byte-identical to `phase2/mirage-be/` (only `.env`, `README.md` and `src/CONSTANT.js` differ), so
  every change here must be portable back to `mirage-be` without conflict. State in the PR which
  repo you changed.
- **Frontend:** `phase2/mirage-fe/` (M5 only).

## Read this before any Mirage prompt

The phase-2 Mirage work is **already substantially done**. Verified in the tree today:

| Capability | State |
|---|---|
| USDZ upload | `objectIos` multer field (`src/libs/multer.js:15-19`) → `model.iosSrc` (`adminController.js:1119,1175`) |
| `update-item` applies `description` + `category` | done (`adminController.js:1272-1281`) |
| `imgOnly` derived on create and update | done (`adminController.js:1195-1199, 1498-1502`) |
| `item.tags`, `item.availability`, `item.featured`, `item.sortPosition` | done (`src/Models/itemModel.js:176-203`) + `parseProductOptionalFields` multipart coercion |
| `category.sortPosition` + indexes | done (`src/Models/categoryModel.js:71-78`) |
| `restaurant.website`, `socialLinks`, `address`, `isPublished` | done (`src/Models/restaurantModel.js:81-118`) |
| Public reads sort by `sortPosition` then `createdAt` | done (`src/Controllers/itemController.js:523-651`) |
| Unpublished restaurant hidden from the public read | done (`itemController.js:490-491`) |
| Real `delete-category` with a non-empty guard and `?force=true` | done (`adminController.js:1708+`) |

**Do not re-implement any of the above.** The prompts below cover only what is still missing.

House style of this repo, which every prompt must respect:
- **CommonJS JavaScript**, no TypeScript, no build step, no test runner configured.
- Response envelope `{ status: <boolean>, message: <string>, data? }` — boolean, not a string.
- Auth: `apikey` header on all `/api/v1` routes (except analytics collect), plus `token` +
  `role === "admin"` on admin routes.
- Assets: multer to disk → read → `s3.upload` → `fs.unlinkSync`; the stored URL is
  `` `${CLOUD_FRONT_URL}/${key}` ``, and **`CLOUD_FRONT_URL` / `BUCKET_NAME` come from the request
  body**.
- 🔴 `src/CONSTANT.js` contains live credentials as `||` fallbacks and `apiKeyValidator.js`
  hardcodes the API key. **Do not add new hardcoded secrets, and do not "fix" the existing ones as a
  side effect of these tasks** — that is its own change, with its own rotation plan.

---

# M1 — URL passthrough on asset upload (highest value)

```
# FEATURE: Accept asset URLs on create/update, not just uploaded bytes
# Product: Mirage backend
# Phase: Next Phase — ReCapture integration
# Track: Backend
# Scope: Enhancement (closes Q-C1; unblocks ReCapture task T-030 / prompt B3)
# Priority: Highest value of any Mirage change in this phase

---

## Context

ReCapture already holds every product asset on its own S3 behind its own CloudFront: the optimized
GLB, the USDZ, the generated thumbnail, and product images. Mirage today accepts **bytes only** —
multer writes the upload to `uploads/`, the controller `fs.readFileSync`s the whole file, uploads it
to S3, then unlinks. In `createItems` the request body is spread into the document first and then
`image` and `model` are **overwritten** by the locally computed values, so a caller-supplied URL is
silently discarded.

The consequence for publishing: every 90 MB GLB is downloaded out of ReCapture's CloudFront and
re-POSTed as multipart into Mirage, which buffers it in memory, on a Render instance that self-pings
to stay awake. That is the single slowest and most failure-prone step of the whole publish path.

**With URL passthrough, Mirage fetches the asset server-side (S3-to-S3 or CDN-to-S3) and ReCapture
sends a small JSON body.** Publish time and failure rate both drop by an order of magnitude.

## Task

Let `create-item` and `update-item` (and, consistently, `create-restaurant` / `update-restaurant`
icons and `create-category` / `update-category` images) accept **either** an uploaded file **or** a
URL for each asset slot, and copy from that URL into Mirage's own bucket server-side.

## Files to inspect first

1. `src/Controllers/adminController.js` — `createItems` (asset section ~1119-1200),
   `updateItem` (~1400-1520), `createRestaurant` (~181-215), `updateRestaurant` (~468-525),
   `createCategory` (~742-775), `updateCategory` (~905-935)
2. `src/libs/s3.js` — `uploadToS3` and how the key + CDN URL are composed
3. `src/libs/multer.js` — the three file fields (`image`, `object`, `objectIos`)
4. `package.json` — `aws-sdk` v2 is present; check whether a fetch client is already available
   before adding one (Node 20 has global `fetch`)

## Implementation instructions

1. **New body fields**, all optional, each the URL twin of an existing file field:
   `imageUrl`, `objectUrl`, `objectIosUrl` on items; `iconUrl` on restaurants; `imageUrl` on
   categories. A file always wins over a URL for the same slot; sending both is not an error.

2. **One shared helper**, e.g. `src/helper/assetFromUrl.js`, exporting something like
   `copyUrlToS3({ url, key, bucket, contentTypeHint })`:
   - **Allow-list the source host.** Only hosts in a configured list (ReCapture's CloudFront
     distribution, and Mirage's own) may be fetched. This is an SSRF boundary, not a nicety: an
     unrestricted server-side fetcher lets any caller with the static API key make Mirage request
     internal addresses. Reject private/loopback/link-local addresses explicitly, and reject
     redirects that leave the allow-list.
   - **Stream** from the source into `s3.upload` — do not buffer a 90 MB GLB in memory (which is
     precisely the flaw being fixed).
   - Enforce the same **100 MB cap** as multer, from `Content-Length` when present and by aborting
     the stream when exceeded when not.
   - Derive the content type from the response, validated against an allow-list per slot
     (`image/*` for images, `model/gltf-binary` for GLB, `model/vnd.usdz+zip` for USDZ).
   - Timeout, and one retry on a transient network failure. On failure, throw with a message
     specific enough that ReCapture can classify it.

3. **Key layout stays exactly as today** — `{restaurant.name}/imgs/...`, `{restaurant.name}/models/...`,
   `{restaurant.name}/categories/...`, `res_icons/...`. Do not change key composition in this task;
   ReCapture's stored URLs and the public page both depend on it.

4. **`BUCKET_NAME` / `CLOUD_FRONT_URL` continue to come from the body**, unchanged. Keep the same
   `undefined/` failure mode visible rather than papering over it here.

5. **Response** is unchanged: the created/updated document with the stored CDN URLs. ReCapture
   verifies that the returned URL is on Mirage's CDN.

6. **Swagger.** The repo has `swagger-jsdoc` at `/docs`; add the new fields to the affected route
   docs so the contract is discoverable.

## What NOT to change

- The multipart path — it must keep working exactly as it does today; the URL path is additive.
- The response envelope, the auth middleware, or the key layout.
- The existing hardcoded credentials (separate change, separate rotation plan).
- Do not introduce TypeScript, a build step, or a second HTTP client style.

## Edge cases to handle

- URL 404s or times out → 400 with a distinguishable message (Mirage returns 400 for everything,
  so the **message** is what ReCapture classifies on — make it stable and specific).
- URL host not in the allow-list → explicit "source host not allowed", never a generic failure.
- `Content-Length` absent → stream with a hard byte ceiling and abort past it.
- Redirect chain → follow at most N hops, re-validating the host at every hop.
- Both file and URL supplied → file wins, no error, and say which was used in the message.
- Item created with `objectUrl` only (no image) → the existing "at least one of image/object" rule
  must now count URLs too, or a legitimate 3D-only create is rejected.
- `imgOnly` derivation must consider URL-sourced assets exactly as it considers uploaded ones.

## Constraints

- CommonJS, matching the surrounding style and comment idiom.
- No new hardcoded secrets. The host allow-list is config with a safe default, read the same way
  the rest of `src/CONSTANT.js` reads config.
- Streaming, bounded memory, one asset at a time.

## Acceptance criteria

- [ ] `create-item` accepts `objectUrl` + `imageUrl` with a JSON body and stores Mirage-CDN URLs.
- [ ] `update-item` accepts the same and replaces the asset.
- [ ] `objectIosUrl` writes `model.iosSrc`.
- [ ] A non-allow-listed host, a private IP, and an over-cap file are each rejected with distinct
      messages.
- [ ] The existing multipart path is byte-for-byte unaffected (verify with the current admin panel).
- [ ] No route buffers a whole file in memory on the URL path.

## Testing instructions

There is no test runner in this repo. Add a documented manual verification script under `scripts/`
or a `README` section covering: URL create, URL update, file create (regression), file+URL
precedence, blocked host, oversize, and a 3D-only create. If adding a minimal test runner is
acceptable to the repo owner, that is a strict improvement — say so, do not assume it.
```

---

# M2 — Idempotency on write endpoints

```
# FEATURE: Idempotency keys for admin write endpoints
# Product: Mirage backend
# Phase: Next Phase — ReCapture integration
# Track: Backend
# Scope: Enhancement (closes Q-C9a)
# Priority: High — removes the reconciliation dance from every publish retry

---

## Context

Mirage has no idempotency anywhere except analytics ingest (unique `eventId` index). A retried
`create-item` returns `400 "Product already exist"` **without the id of the existing item**, so the
caller cannot recover from a network failure that happened after the write landed. ReCapture works
around this by listing the category and matching on name — fragile, and it costs an extra round trip
per recovered row.

The one idempotent path in the repo — the unique `eventId` index on `analyticsEventModel` — is the
pattern to copy.

## Task

Accept an `Idempotency-Key` header on the admin write endpoints and make a replay return the
**original result** instead of a duplicate error.

## Files to inspect first

1. `src/Models/analyticsEventModel.js` — the unique-index idempotency pattern already in use
2. `src/Controllers/adminController.js` — `createRestaurant`, `createCategory`, `createItems`,
   `updateItem`, `deleteItems`
3. `src/Routes/adminRouter.js`, `src/Middlewares/middleware.js`
4. `src/helper/helper.js`

## Implementation instructions

1. **New collection** `idempotency_keys`: `{ key, route, requestHash, status, responseBody,
   createdAt }` with a **unique index on `(key, route)`** and a TTL on `createdAt` (24h is plenty —
   a publish run is minutes).
2. **Middleware** `src/Middlewares/idempotency.js`, applied to the create/update/delete admin routes:
   - No header → behave exactly as today (fully backward compatible).
   - Header present, no record → insert a `pending` record (the unique index is the race authority),
     run the handler, capture the response, store it, return it.
   - Header present, completed record, same `requestHash` → **replay the stored response**, with a
     header marking it a replay.
   - Header present, completed record, **different** `requestHash` → `400` with a distinct message;
     the same key must never be reused for a different payload.
   - Header present, `pending` record → `409`-equivalent "request in flight, retry shortly" so the
     caller backs off instead of racing.
3. `requestHash` covers the meaningful body fields, **not** file bytes (hashing a 90 MB upload
   defeats the purpose) — hash the metadata and the asset URLs/filenames.
4. The stored response body must be the exact envelope the handler produced, so a replay is
   indistinguishable from the original to the caller.
5. Document the header in Swagger for every route it applies to.

## What NOT to change

- The existing duplicate-name checks — they stay as the safety net for callers that send no key.
- The response envelope shape.
- Any read endpoint.

## Edge cases to handle

- Two concurrent requests with the same key → the unique index makes exactly one win; the other gets
  the in-flight response.
- Handler crashes after the write but before the response is stored → the record stays `pending`;
  the TTL eventually clears it, and a retry sees "in flight". Bound this with a stale-pending
  timeout so a crash cannot wedge a key for 24 hours.
- Key present on a route the middleware does not cover → ignore it silently, do not error.
- Very long or non-UUID keys → validate length and charset, reject clearly.

## Acceptance criteria

- [ ] A replayed create with the same key returns the original document, not a duplicate error.
- [ ] A create without a key behaves exactly as it does today.
- [ ] The same key with a different payload is rejected.
- [ ] Concurrent same-key requests produce exactly one document.
- [ ] Records expire.

## Testing instructions

Manual verification script covering: replay, no-key regression, key-reuse-with-different-body,
concurrency (two simultaneous requests), and stale-pending recovery.
```

---

# M3 — Batch write endpoint for catalog publish

```
# FEATURE: Batch catalog write endpoint
# Product: Mirage backend
# Phase: Next Phase — ReCapture integration
# Track: Backend
# Scope: New Feature (closes Q-C9b)
# Priority: Medium (V2) — depends on M1 and M2 to be worth building
# Depends on: M1 (URL passthrough), M2 (idempotency)

---

## Context

There are no batch endpoints. Publishing a 40-product catalog is 40+ sequential HTTP round trips
against an instance that self-pings every 30 seconds to avoid sleeping. With M1 in place each write
is a small JSON body, which is exactly what makes a batch endpoint cheap and safe to add.

## Task

`POST /api/v1/catalog-batch` — apply an ordered list of category and item operations in one request,
returning a **per-operation result array**.

## Files to inspect first

1. `src/Routes/adminRouter.js`, `src/Controllers/adminController.js`
2. `src/Middlewares/idempotency.js` (M2)
3. `src/helper/assetFromUrl.js` (M1)
4. `index.js` — the 30 MB body limit

## Implementation instructions

1. Request: `{ restaurantId, operations: [ { op, target, id?, clientRef, payload } ] }` where
   `op ∈ create|update|delete`, `target ∈ category|item`. `clientRef` is the caller's own id for the
   row, echoed back so results can be matched without relying on array order.
2. Execute **in the given order** — categories must be creatable before the items that reference
   them, and an operation may reference an id created earlier in the same batch (support
   `"$ref:<clientRef>"` for that, or document that it is unsupported; do not leave it ambiguous).
3. **Per-operation isolation:** one failure does not abort the batch. Return
   `{ status: true, results: [ { clientRef, ok, id?, message? } ] }` with a summary count. There are
   no Mongo transactions in play here, and partial application must be explicit rather than hidden.
4. Cap the operation count (e.g. 100) and reject over-cap with a clear message.
5. Assets referenced by URL only — no multipart in the batch path. This is what keeps the body small
   and the endpoint sane.
6. Honour `Idempotency-Key` for the batch as a whole (M2), so a retried batch replays rather than
   re-applying.
7. Swagger documentation, including the partial-success semantics — a caller that assumes
   all-or-nothing will corrupt its own state.

## What NOT to change

- The single-item endpoints — they stay, unchanged, as the fallback path.
- The auth model.

## Edge cases to handle

- An operation referencing a category created earlier in the same batch.
- A delete of an item that no longer exists → `ok: true` (already gone is success).
- Deleting a category's last item → the existing cascade still applies; report it in that
  operation's message so the caller can repair its mapping.
- Batch exceeding the body limit → reject before parsing everything.
- Duplicate `clientRef` values → reject the whole batch up front.

## Acceptance criteria

- [ ] 40 mixed operations apply in one request with per-operation results.
- [ ] One failing operation does not stop the rest, and is clearly reported.
- [ ] Order is honoured and intra-batch references resolve (or are explicitly rejected).
- [ ] A retried batch with the same idempotency key does not double-apply.
- [ ] Single-item endpoints are unaffected.

## Testing instructions

Manual script: mixed batch, failure isolation, intra-batch reference, retry replay, over-cap
rejection, cascade reporting.
```

---

# M4 — Client-scoped analytics reads

```
# FEATURE: Client-scoped analytics read endpoints
# Product: Mirage backend
# Phase: Next Phase — Analytics
# Track: Backend
# Scope: Enhancement (closes Q-C10)
# Priority: Low (V2) — ReCapture's proxy (prompt B7) covers the need without it

---

## Context

`summary`, `timeseries` and `top-products` require `token` + `role === "admin"`, and the repo's own
in-code note (`src/Routes/analyticsRoutes.js:20-24`, `analyticsController.js:99-105`) says plainly
that client-scoped read routes do not exist and **must not be created by loosening `isAdmin`** —
because these handlers take `restaurant` from the query string, so a non-admin caller reaching them
could read any restaurant's analytics.

ReCapture works around this by proxying with an admin credential and forcing the `restaurant`
parameter from its own mapping (prompt B7). That is correct and sufficient. Build this only if
Mirage needs to serve a restaurant owner directly — a Mirage-hosted owner dashboard, or removing
ReCapture's need to hold an admin credential at all.

## Task

Add **separate** client-scoped routes whose restaurant scope is derived from the token, never from
the query.

## Files to inspect first

1. `src/Routes/analyticsRoutes.js` (read the note at lines 16-24 before writing anything)
2. `src/Controllers/analyticsController.js:99-105, 163, 382, 459`
3. `src/Middlewares/middleware.js` — `isAuthorized`, `isAdmin`, and `req.tokenUserData`
4. `src/Models/{userModel,restaurantModel}.js` — how a user relates to a restaurant today

## Implementation instructions

1. **Do not touch the existing admin routes or `isAdmin`.** Add new paths, e.g.
   `/api/v1/analytics/me/{summary,timeseries,top-products}`.
2. New middleware `isRestaurantOwner`: resolves the caller's restaurant **from the token identity**
   and sets `req.scopedRestaurantId`. Note that `userModel` has no restaurant link today — adding
   one (or reusing `restaurant.userBelong`) is part of this task and must be stated explicitly in
   the PR, because it defines the ownership model.
3. The handlers **ignore any `restaurant` query parameter entirely** — not "validate it", ignore it.
   Extract the shared query logic so the admin and scoped routes cannot drift apart.
4. Rate-limit the scoped routes (the pattern exists in `src/Middlewares/analyticsRateLimit.js`).
5. Keep the response shape identical to the admin routes so one client can consume either.
6. Update the in-code note to reflect what now exists, so the next reader is not warned off a route
   that has since been built correctly.

## What NOT to change

- `isAdmin`, the existing admin analytics routes, or the ingest route's deliberate lack of `apikey`.
- The event vocabulary or the TTL.

## Edge cases to handle

- A user owning no restaurant → empty results, never an unscoped read.
- A user owning more than one → decide and document (this phase is one catalog per business).
- An admin calling the scoped route → scoped to their own mapping, not elevated.
- A `restaurant` query parameter supplied anyway → provably ignored.

## Acceptance criteria

- [ ] Scoped routes exist and derive the restaurant from the token only.
- [ ] A supplied `restaurant` parameter cannot change the result.
- [ ] Admin routes and `isAdmin` are untouched.
- [ ] Ownership model is documented in the PR.

## Testing instructions

Manual script: owner reads own data, owner cannot read another restaurant's data by any parameter,
no-restaurant user gets empty, admin routes unchanged.
```

---

# M5 — Public catalog page renders the phase-2 fields

```
# FEATURE: Render tags, availability, featured, order, USDZ AR and business links
# Product: Mirage frontend (public catalog page)
# Phase: Next Phase — Public catalog
# Track: Frontend
# Scope: Enhancement (makes the backend's phase-2 fields visible to customers)
# Priority: Medium — without it, several ReCapture authoring features have no public effect

---

## Context

The Mirage backend now stores `tags`, `availability`, `featured` and `sortPosition` on items,
`sortPosition` on categories, and `website`, `socialLinks`, `address`, `isPublished` on the
restaurant — and the public read endpoint already sorts by `sortPosition`. **The frontend consumes
none of these** (verified: no `tags` / `availability` / `featured` / `sortPosition` / `website` /
`socialLinks` / `address` reference anywhere under `src/features/menu/`, `src/api/menu.ts` or
`src/Types.ts`). Until it does, a business owner who marks a product out of stock or featured in
ReCapture sees no change on the page their customers scan into.

The one new-ish field that **is** already wired is `model.iosSrc` (`src/api/menu.ts:93` →
`src/features/ArModel/ArModel.tsx:53`) — that one needs verification, not implementation.

## Task

Consume the new fields in the public catalog page.

## Files to inspect first

1. `src/features/menu/useFetchApiForNewUi.ts:80` — the `get-data-for-new-ui` fetch
2. `src/features/menu/{MenuScreen,MenuList,MenuItemCard,types}.tsx|ts`
3. `src/Types.ts` — `NewProductInterface`, `NewCategoryInterface`, `NewRestaurantInterface`
4. `src/features/ArModel/ArModel.tsx` and `src/features/menu/NewModelViewer.tsx` — where `iosSrc`
   would be used for AR Quick Look
5. `src/analytics/` — the existing event emitters, so new UI keeps emitting correctly

## Implementation instructions

1. **Types first.** Extend the product/category/restaurant interfaces with the new fields, all
   optional, so an older backend response still type-checks and renders.
2. **Ordering:** render categories and items in the order the API returns them. The backend already
   sorts by `sortPosition` — the frontend must not re-sort by name or date and undo it.
3. **Featured:** a visual marker, and featured items first within their group. Ordering only — it
   hides nothing.
4. **Availability:** `OUT_OF_STOCK` items render visibly unavailable (badge + muted treatment). Do
   not hide them; a customer looking for a known item should see it is unavailable rather than think
   it is gone.
5. **Tags:** show as small chips on the product card/detail, and optionally as a filter. Keep it
   subtle — a menu is not a search engine.
6. **USDZ / iOS AR:** already wired — `src/api/menu.ts:93` maps `item.model?.iosSrc` to
   `modelIosSrc` and `src/features/ArModel/ArModel.tsx:53` consumes it. Do **not** rebuild it.
   The work here is verification only: publish a ReCapture 3D product with a USDZ through the
   backend's `objectIos` field and confirm AR Quick Look launches on a real iPhone. If it does not,
   fix the gap you find rather than adding a parallel path.
7. **Business links:** website, social links and structured address in the header/contact area,
   with the existing `contact_opened` / `contact_channel_clicked` / `brand_link_clicked` analytics
   events fired for each.
8. **Unpublished catalog:** the API now hides an unpublished restaurant. Render a clean
   "this catalog isn't available right now" page rather than a crash or an empty menu — a printed QR
   pointing at an unpublished catalog is an expected state, not an error.

## What NOT to change

- The analytics event vocabulary (the ingest schema enumerates it; a new event name is dropped).
- The URL shape `/{restaurantSlug}` — printed QR codes depend on it.
- The API key handling or the fetch layer's caching behaviour.

## Edge cases to handle

- Older backend response missing every new field → page renders exactly as today.
- All items out of stock → the page still reads as a catalog, not as an error.
- Many tags on one product → wrap or truncate; no horizontal overflow on a phone.
- `iosSrc` present but not a valid USDZ → the AR button must fail gracefully, not blank the page.
- Long website/address strings → truncate with the full value available on tap.

## Acceptance criteria

- [ ] Categories and items render in backend order.
- [ ] Featured, out-of-stock and tags are all visible on a phone viewport.
- [ ] iOS AR Quick Look launches from `model.iosSrc` on an iPhone (verified end-to-end from a
      ReCapture publish, through the existing path — no new AR code).
- [ ] Website / socials / address render and emit the existing analytics events.
- [ ] An unpublished catalog shows a friendly state.
- [ ] A response without any new field renders unchanged.

## Testing instructions

Manual QA on iOS Safari (AR), Android Chrome and desktop, on a restaurant with: featured items,
out-of-stock items, tags, a custom order, socials and an unpublished flag. Record the checks in the
PR description.
```
