# 06 — Open Questions

Everything that could not be answered from the two codebases alone. Numbered so you can reply
"Q3: yes, Q7: option b".

---

## Section A — Blocking questions

These must be answered before MVP implementation starts.

**Q1. What should "Unpublish catalog" (feature 39) actually do to Mirage?**
Mirage has **no hide/offline/draft flag** on the restaurant document. The only removal primitive is
`DELETE /api/v1/delete-restaurant/:restaurantId` (`mirage-be/src/Controllers/adminController.js:1245`),
which hard-deletes the restaurant **and cascade-deletes all its categories and items** — destroying
the ObjectId that the public URL and the printed QR are built on. That directly violates feature 32.
Options:
- **(a) Recommended — delete the items (M10), keep the restaurant.** The public page renders an empty
  catalog, the URL and QR keep working, republish restores everything. Deleting the restaurant becomes
  a separate "delete catalog permanently, your QR will stop working" action.
- (b) Delete the restaurant. Simple, but every printed QR dies permanently.
- (c) Do not ship unpublish at all in this phase.

**Q2. Which Mirage admin credential should ReCapture use, and how is it obtained and rotated?**
Mirage's server-to-server auth is a static `apikey` header
(`mirage-be/src/Middlewares/apiKeyValidator.js`, key hardcoded in source and also shipped in the
public web bundle) plus a `token` header holding an **admin-role JWT**
(`src/Middlewares/middleware.js:5-110`). There is no client-credentials grant, no machine identity,
and no way to scope a token to one restaurant — the credential ReCapture holds will have read/write
over **every** business in Mirage. I need:
- Should ReCapture log in as an existing admin user via `POST /api/v1/login-user`, caching and
  refreshing the JWT, or should a long-lived token be minted once and injected as an env var?
- Which admin account? Is a dedicated `recapture-service` admin user acceptable?
- What is `JWT_SECRET_KEY` in the deployed Mirage environment? It currently falls back to the
  literal `"vr_secret"` (`middleware.js:40`) if unset.

**Q3. Which Mirage deployment and database does ReCapture point at for development and staging?**
`mirage-be/src/CONSTANT.js` defaults to a `restaurant-prod` Atlas database. ReCapture has a strict
`{env}` (`dev|staging|prod`) firewall in its own S3 key scheme specifically so non-prod can never
delete prod objects. If there is no non-prod Mirage, then MVP development would be writing test
catalogs and deleting test items **against production Mirage**. Is there a dev/staging Mirage host
and database, and what are its base URL and API key?

**Q4. What are the correct `BUCKET_NAME` and `CLOUD_FRONT_URL` values for ReCapture to send?**
Mirage reads both **from the request body** on every write
(`adminController.js:200-201, 530, 798-799, 1045-1046`) and bakes the CDN host into the stored URL.
There is no allow-list and no default — an omitted value produces a stored URL of literally
`undefined/<key>`, which fails only when a customer opens the page. Observed values elsewhere in the
codebase are bucket `maya-restaurants` and CDN `https://d1ubv1fp33ooxl.cloudfront.net`
(hardcoded in `adminController.js:115-116`). Please confirm these are the right ones for
ReCapture-published catalogs.

**Q5. On publish, should a locally-deleted product be deleted from Mirage or hidden?**
(Brief §8, edge case 3.) Mirage's item schema has an `isDeleted` field, but **no endpoint ever sets
it** — the only write is the hard delete M10, and `delete-category` (M7) is a stub that returns the
string `"Not created now."` (`adminController.js:1349-1351`). My recommendation is **delete on
publish**: leaving a product visible after the owner deleted it is the worse outcome, and ReCapture
keeps its own archived row so it can be re-created. Confirm, or say you want it left visible.

**Q6. Is it acceptable that every published 3D model and image exists twice — once on
`msxr-model-artifacts` behind ReCapture's CloudFront, once on `maya-restaurants` behind Mirage's?**
This is forced, not chosen: Mirage's write endpoints accept **file bytes only** via multer
(`src/libs/multer.js`, fields `image` and `object`), and `createItems` explicitly overwrites any
caller-supplied `image`/`model` URL with its own computed values (`adminController.js:948-955`).
There is no way to hand Mirage an existing CloudFront URL. This roughly doubles asset storage cost
and means a replaced model orphans the old Mirage object permanently. See Q-C1 for the fix that
would remove it.

**Q7. Should publishing an empty catalog be blocked, allowed, or warned?**
My proposal is **blocked** with "Add at least one product before publishing" — Mirage renders an
empty page fine, but a QR is a physical artifact and a business that prints a sticker leading to an
empty catalog has the worse outcome. Confirm, or choose warn-and-allow.

---

## Section B — Non-blocking questions

Can be resolved during implementation.

**Q8. Is there an analytics destination for ReCapture's own events, or do they stay unshipped?**
`AGENTS.md` §Analytics is explicit that a typed event registry, per-event schemas, a PII guardrail
and a real destination are all **NOT YET BUILT** — the emit seams log in non-prod only. The §10b
authoring events in the architecture will therefore be *emitted but not collected*. Features 61–66
are unaffected (they read Mirage's own working analytics store). Should T-039 wait for a destination?

**Q9. Currency — INR only, or should the catalog carry a currency per product?**
Mirage's item schema stores a bare `price: Number` with **no currency field**, and the commented-out
aggregation in `itemController.js:552` defaults to `"INR"`. I have assumed INR-only with a
`currency` field stored ReCapture-side for future use.

**Q10. Should ReCapture adopt a pre-existing Mirage restaurant if the business is already onboarded?**
Some pilot businesses may already exist in Mirage from the manual admin-panel workflow. My design
looks for an exact case-insensitive name match via M1 before creating (feature 40). Is silent
adoption right, or should it require explicit founder confirmation to avoid attaching a catalog to
the wrong client?

**Q11. What is the retention/limit on the publish activity log (feature 55)?**
Mirage's analytics rows use a 365-day TTL. I propose keeping the last N publish runs per catalog
rather than a TTL. What is N?

**Q12. QR format details — size, error-correction level, and should a logo be embedded?**
Feature 33 says PNG and PDF. Print sizing (and whether the PDF should be a print-ready sticker sheet
vs a single code) is a product decision I cannot take from the code.

**Q13. Residual QR risk: should we defend against a restaurant whose name contains a 24-hex string?**
Mirage's public resolver tries the **name regex first** and only falls back to `findById`
(`itemController.js:472-478`), so a restaurant literally named like an ObjectId would shadow the
ObjectId route. This requires a business to name itself a hex string — vanishingly unlikely. I have
noted it rather than defended it. A one-line Mirage change (try `findById` first) would remove it
entirely, but Mirage changes are out of scope for this task.

**Q14. Should product names be validated against Mirage's uniqueness rule at authoring time?**
Mirage rejects a duplicate item name within a restaurant (`adminController.js:888-897`). I have the
publish gate check it, and also propose a soft warning at authoring time so the user finds out while
they are typing rather than at publish. Confirm the softer warning is wanted.

---

## Section C — Mirage-side gaps

Features that need Mirage behaviour that does not exist in `mirage-be/`. For each: the gap, a
ReCapture-side workaround, and the Mirage change that would remove it. **No Mirage change is
proposed or made — these are for your decision.**

**Q-C1. No URL passthrough on asset upload** (features 49a, 50, 51) — *highest value fix.*
`createItems`/`updateItem` accept multipart files only and overwrite any caller-supplied `image` or
`model.src` (`adminController.js:948-955`, `:1170-1175`). Multer accepts fields `image` and `object`
at 100 MB (`src/libs/multer.js`), and `uploadToS3` buffers the whole file in memory
(`src/libs/s3.js`).
- **Workaround:** ReCapture streams each asset from its own bucket and re-POSTs the bytes. Assets are
  duplicated across two CDNs (Q6); publish is slow; large models risk the 100 MB cap.
- **Mirage change that would fix it:** accept optional `imageUrl` / `modelSrcUrl` body fields on
  create-item and update-item and store them verbatim when present. This is small, backward
  compatible, and would eliminate the duplication, most of the publish latency, and the size cap.

**Q-C2. No USDZ path** (feature 49b).
`itemModel.model.iosSrc` exists in the schema but multer defines no third file field and **no
controller ever writes it**.
- **Workaround:** publish `model.src` (GLB) only. iOS users get the `<model-viewer>` web path rather
  than native AR Quick Look.
- **Mirage change:** add an `objectIos` multer field, or accept a `modelIosSrcUrl` body field (folds
  into Q-C1).

**Q-C3. `update-item` ignores `description`, `category` and `imgOnly`** (features 8a, 14, 25).
They are destructured and then commented out or never assigned (`adminController.js:1038-1047`,
`:1170-1175`).
- **Workaround:** description and category edits require **delete + recreate** (M10 + M8), which
  mints a new Mirage item id and resets that product's Mirage view counter.
- **Mirage change:** assign these three fields in `updateItem` as it already does for `name`/`price`.

**Q-C4. `imgOnly` cannot be unset** (feature 17, image-only → 3D upgrade).
`createItems` sets `imgOnly: true` when an image arrives without an object
(`adminController.js:963-969`); `updateItem` never touches it.
- **Workaround:** a type conversion becomes delete + recreate, and the product gets a new public link.
- **Mirage change:** recompute `imgOnly` in `updateItem` from the resulting `model.src`.

**Q-C5. No sort/position field anywhere** (features 10, 23c, 48).
Neither `itemModel` nor `categoryModel` has one; the public page sorts `createdAt: -1`
(`itemController.js:507`, `:543`).
- **Workaround:** order is honoured inside the ReCapture app only. The publish screen must say
  plainly that public order is by creation date.
- **Mirage change:** add `sortOrder: Number` to both schemas, accept it on create/update, and sort by
  it in `getDataForNewUi`.

**Q-C6. `delete-category` is a stub** (feature 23b).
`adminController.deleteCategory` (`adminController.js:1349-1351`) is a three-line body that returns
the string `"Not created now."`.
- **Workaround:** delete or move every item in the category — Mirage then cascade-deletes the empty
  category itself from `deleteItems` (`adminController.js:1312-1319`). Indirect and surprising.
- **Mirage change:** implement it.

**Q-C7. No featured, tags, or availability fields** (features 8b, 8c, 9).
None exist on `itemModel`.
- **Workaround:** all three are ReCapture-side only and invisible to customers. Out-of-stock cannot
  be shown on the public page — worth knowing before promising it to a pilot.
- **Mirage change:** add `isFeatured: Boolean`, `tags: [String]`, `available: Boolean`.

**Q-C8. No website, social links, or structured address on the restaurant** (features 42, 58, 59).
`restaurantModel` has `name`, `location` (free text), `phone`, `icon`, `description`, `clientType`.
- **Workaround:** ReCapture stores them; only name/location/phone/icon/description reach the public page.
- **Mirage change:** add `website: String`, `socials: Object`, `address: Object`.

**Q-C9. No idempotency and no batch endpoints on any write route.**
Confirmed across every controller — no idempotency key, no upsert, no bulk write. A retried create
returns `400 "Product already exist"` without the id.
- **Workaround:** the mapping table plus reconciliation via M11/M12 (architecture §7.4). It works,
  but it costs an extra round trip on every recovery and depends on **matching by name**.
- **Mirage change:** accept an `Idempotency-Key` header, or return the existing document (200 with
  `data`) instead of a bare 400 on a duplicate-name create. The latter is a two-line change and would
  remove the entire reconciliation path.

**Q-C10. Analytics reads are admin-scoped only** (feature 66).
`analyticsRoutes.js:20-24` and `analyticsController.js:99-105` both note that client-scoped read
routes do not exist and must not be created by loosening `isAdmin`.
- **Workaround:** ReCapture's backend proxies M27/M28/M29 with its admin credential and **forces**
  `?restaurant=` server-side. This respects the note and needs no Mirage change — but it does mean
  ReCapture holds an all-tenant credential (Q2).
- **Mirage change:** the client-scope work already sketched in that comment.

---

## Section D — Assumptions made

If any is wrong, tell me — the note says what changes.

**A1. Repo paths.** ReCapture = `phase2/ReCapture/` (Flutter root + `recapture-api/`);
Mirage backend = `phase2/mirage-be/`. Both are inside the working directory `phase2/`. Near-duplicate
copies exist at `VR World Code/ReCapture/` (older mtime) and `VR World Code/Mirage App New/` (contains
only `restaurant-fe`); I treated the `phase2/` copies as authoritative. **If wrong, the entire
findings document is against the wrong tree** — but it would be quick to re-run.

**A2. Deliverables location.** These six files are at `ReCapture/docs/next-phase/`, alongside the
existing `docs/` tree. No existing file in either repo was modified and no implementation code was written.

**A3. Stack.** The task brief describes a React/Vite/Tailwind frontend with `src/`, `vite.config.*`
and `tsconfig.json`. **ReCapture is a Flutter/Dart app** with a Node/TypeScript backend in
`recapture-api/`. I designed for what is actually there (Riverpod, go_router, Dio, Hive,
`flutter_secure_storage`) per AGENTS.md, which declares itself the tie-breaker over any task prompt.
If a React ReCapture exists somewhere else, all frontend tasks are wrong.

**A4. `mirage-be` is the whole Mirage backend.** `mirage-fe` was read only to determine the public
URL shape (`src/App.tsx:217-224`). There is also a `restaurant-fe` referenced from Mirage's analytics
docs; I did not treat it as a separate backend surface.

**A5. Publishing is explicit and batched**, not auto-sync on every edit (brief §13). The whole
draft/published design rests on this.

**A6. One catalog per business** (brief §3.G). Enforced by a unique index on `catalogs.userId`.
Multi-catalog would need that index dropped and the mapping moved.

**A7. The public Mirage host** is `mirage.mayasabhaxr.com` (or `.co.in`) — inferred from the
commented-out CORS allow-list in `mirage-be/index.js`. Configured as `MIRAGE_PUBLIC_BASE_URL`, not
hardcoded. Please confirm the canonical host, since it becomes part of every printed QR.

**A8. Every business user is a ReCapture `USER`-role account** with a working OTP login; catalog
features build on it and do not touch auth. Confirmed against `routes/auth.ts` — no change needed.

**A9. The capture pipeline is untouched.** New features consume `GET /projects/:id/models` and
`OwnerModelListItemDto`; the fresh-scan source (feature 12) deep-links into the existing flow and
reads its result.

**A10. 3D products publish the optimized GLB where one exists**, since `latestSucceededModel`
already returns the OPT record. This matters because Mirage buffers whole files in memory and caps
at 100 MB.

**A11. Product images are public catalog content, not PII**, so they go in `BUCKET_ARTIFACTS` behind
CloudFront — the opposite of the avatar decision (avatars are PII and stay in the private raw
bucket). If product photos should be treated as private, this changes.

**A12. Mirage's `restaurant.userBelong` field is not used** for the ReCapture↔Mirage mapping. Per the
brief's §7 constraint, the mapping is stored on the ReCapture side. Tell me if you also want it
written into `userBelong` for admin-panel visibility.

---

## Section E — Ambiguous features

**Q-E1. Feature 2 — "cover image".** Mirage's restaurant schema has `icon` (used as the logo) and no
cover-image field. Should the cover be ReCapture-only, or should it replace `icon`?

**Q-E2. Feature 5 — "preview the catalog".** Render an in-app approximation of the public page, or
open the real Mirage URL in a webview? An in-app preview can show *draft* state (which the real URL
cannot), so I chose that — but it will never match the live page pixel for pixel.

**Q-E3. Feature 9 — what does "featured" do?** There is no featured concept on Mirage, so it cannot
change the public page. Is it (a) an ordering hint inside ReCapture only, or (b) intended to drive a
hero slot on the public page — which would need Q-C7?

**Q-E4. Feature 30 — "bulk publish/unpublish".** Publishing is a whole-catalog action in this design
(features 36, 56). Does "bulk publish/unpublish" mean including/excluding selected products from the
next publish, or something else? I modelled it as an include/exclude flag.

**Q-E5. Feature 32 vs feature 39.** "QR is stable" and "unpublish takes the catalog offline" are in
direct tension given Mirage's only removal primitive destroys the id the QR is built on. Q1 resolves it.

**Q-E6. Feature 55 — audience for the sync log.** Founder/support debugging tool, or a
business-user-facing activity feed? The wording is different for each, and the log names Mirage
internals that a business user should probably not see.

**Q-E7. Feature 8 — "product thumbnail auto-generated for 3D products only".** I read this as: reuse
the existing generated `previewUrl` from `ProjectModel.artifacts.cdnUrls.preview`, no new generation
step. Confirm — if you want a *new* thumbnail render (e.g. a specific camera angle), that is a
separate pipeline task not in this breakdown.
