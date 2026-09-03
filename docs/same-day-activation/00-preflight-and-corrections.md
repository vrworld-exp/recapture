✅✅✅✅✅

# 00 — Preflight and Corrections to the Plan

`../next-phase/07-same-day-activation.md` was re-verified line by line against the working tree
before this pack was written. It is substantially correct. **Seven statements are stale or wrong**,
and two of them are correctness hazards: one would silently mark unpublished products as live
(**C1**), the other would make every scanned standee an infinite redirect loop (**C6**).

Every stage file in this folder already incorporates these corrections. This page exists so the
divergence from the plan is visible rather than silent.

---

## C1 — ⚠ `FULL` + `productIds` would corrupt `publishedRevision`

**Plan says** (Part 2 §4): *"Targeted re-publish is already supported. `Job.payload` for
`MIRAGE_CATALOG_PUBLISH` already carries `{catalogId, publishRunId, mode, productIds?}` … Reuse the
`productIds`-scoped path."*

**Two things are wrong with this.**

**First, nothing supplies `productIds`.** The read path exists — `parsePayload`
(`recapture-api/src/worker/processors/mirageCatalogPublishProcessor.ts:117-136`) parses it and
`planPublish` (`src/services/catalog/publishPlanner.ts:354`) filters on it — but `openRun`
(`src/services/catalogPublishService.ts:496-502`) writes only `{catalogId, publishRunId, mode}`.
The field has never been populated by any caller. It is a designed-in seam, not a working path.

**Second, and this is the hazard:** `finalizeCatalogAfterRun`
(`src/services/catalog/publishRunState.ts:346-357`) advances `publishedRevision` to
`snapshotRevision` on **any** SUCCEEDED run whose mode is not `UNPUBLISH`. A `FULL` run narrowed to
three product ids that succeeds would set `publishedRevision = draftRevision` for the **whole**
catalog — falsely clearing the "you have unpublished changes" badge for every product the run never
touched. Those products stay stale on Mirage with the app reporting them live.

**Correction — and it is a simplification.** Promotion enqueues a **plain `FULL` publish with no
`productIds` at all.** The planner already self-narrows: `PRODUCT_DIFF_FIELDS`
(`publishPlanner.ts:77-98`) includes `glbUrl`, `usdzUrl` and `thumbnailUrl`, so a promoted product
diffs as changed and plans an `UPDATE`, while every untouched product plans a `SKIP`. The run
publishes exactly the promoted dishes, and `publishedRevision` advancing to the full
`draftRevision` is then **correct**, because the run genuinely did reconcile the whole catalog.

Cost: the planner walks every product per promotion. For a six-dish menu that is six in-memory
comparisons. Do not optimise this before it measures as a problem.

> Stage 5 builds it this way. `productIds` stays an unused seam.

---

## C2 — `scripts/set-user-role.ts` needs no change

**Plan says** (Files to touch): *"`scripts/set-user-role.ts` — accept `SALES_REP`"*.

**Reality:** the script derives its accepted set from the model —
`if (!(USER_ROLES as readonly string[]).includes(role))` (`scripts/set-user-role.ts:31`), and it
prints `USER_ROLES.join(...)` in its own usage text. Adding `SALES_REP` to `USER_ROLES` in
`src/models/User.ts` makes the script accept and advertise it with zero edits.

> Stage 1 drops this from the file list and adds a one-line assertion instead.

---

## C3 — `AppRoutes.catalogQr` is already registered

**Plan says** (Files to touch, client): *"`lib/app/routes/app_router.dart` — + `/rep/*` (register
the reserved `/catalog/qr` too)"*.

**Reality:** it is registered. `lib/app/routes/app_router.dart:99` declares the path,
`:170` the name, and `:335-336` wires both into a live `GoRoute`. The "reserved but unregistered"
note is a leftover from before batch 04 landed.

> Stage 6 adds `/rep/*` only.

---

## C4 — `ROLE_RANK` is module-private, which makes the ladder change cheap

**Plan says** (D3) the ladder becomes
`USER_ROLES = ['USER','SALES_REP','MODEL_ARTIST','ADMIN']` with
`ROLE_RANK = {USER:0, SALES_REP:1, MODEL_ARTIST:2, ADMIN:3}`.

**Worth knowing before you touch it:** `ROLE_RANK` is **not exported** from
`src/models/User.ts:16`. The only thing that reads it is `hasRoleAtLeast` in the same file, and the
only thing that calls `hasRoleAtLeast` is `src/middleware/requireRole.ts:47`. Renumbering
`MODEL_ARTIST` from 1 to 2 and `ADMIN` from 2 to 3 therefore cannot break a call site anywhere —
there are none. The numbers are ordinals, never persisted, never compared across a wire.

`USER_ROLES` **is** exported and is read by `scripts/set-user-role.ts:14` and
`src/validation/analyticsSchemas.ts:17` (which does `z.enum(USER_ROLES)` for the actor-role
property on admin events). Both pick the new member up for free. Nothing persists a rank.

> Stage 1 states this so the reviewer does not go hunting for call sites that do not exist.

---

## C5 — The client `isStaff` landmine is real, and worse than described

**Plan says:** *"`lib/domain/entities/user_role.dart` defines `isStaff => this != user`. Adding
`salesRep` silently makes every rep 'staff'."*

**Confirmed** — `lib/domain/entities/user_role.dart:19` is exactly
`bool get isStaff => this != UserRole.user;`.

**One thing the plan does not say:** the Dart enum's declaration order is
`user, modelArtist, admin`, and Dart's `index` follows declaration order. If `salesRep` is inserted
in ladder position (between `user` and `modelArtist`) then **any code comparing `.index`** shifts
underneath it. Grep before you insert. If nothing compares `.index` — and at the time of writing
nothing does — insert in ladder order so the enum reads as the ladder it mirrors. If something
does, append `salesRep` last and add an explicit `rank` getter instead of relying on `index`.

> Stage 1 makes the grep an explicit step, not an assumption.

---

## C6 — ⚠ Redirecting to `publicUrl` is an infinite self-redirect

**Plan says** (Part 1, resolver table): *"`ACTIVE` | record scan, `302` → `catalog.publicUrl` (the
Mirage menu)"*.

**Those two things stop being the same the moment Part 1 lands.** The plan's own key insight is
that activation writes `{PUBLIC_RESOLVER_BASE_URL}/r/{code}` **into** `catalog.publicUrl` — that is
precisely what makes `catalogQrService` render the standee's code with zero changes. So for every
rep-activated catalog:

```
GET /r/ABCD2345  →  302 → catalog.publicUrl
                        = {PUBLIC_RESOLVER_BASE_URL}/r/ABCD2345
                        = the request that just arrived
```

The browser follows it until it hits its redirect limit and shows an error page. **Every standee in
the field is a dead link** — the one outcome the brief forbids.

The parenthetical "(the Mirage menu)" is the giveaway: the plan means the Mirage menu, and before
Part 1 `publicUrl` *was* the Mirage menu. It stops being that under the new scheme.

**Correction.** The resolver derives its target from `catalog.mirageRestaurantId`:

```ts
`${env.MIRAGE_PUBLIC_BASE_URL}/${catalog.mirageRestaurantId}`
```

which is exactly `mintPublicUrl` (`src/services/catalogProvisioningService.ts:101-103`). Export
that helper and call it rather than writing the format string twice.

After Part 1 the two fields have distinct jobs, and the naming is unhelpfully close:

| Field | Holds | Read by |
|---|---|---|
| `catalog.publicUrl` | the **standee** URL, `…/r/{code}` | `catalogQrService` — what the QR renders |
| `catalog.mirageRestaurantId` | the Mirage restaurant id | the resolver — where a scan lands |

A catalog with no `mirageRestaurantId` (activated, not yet published) renders the "not live yet"
page. That is the normal state for the first minutes of a rep visit, not an error.

> Stage 3 builds it this way and carries a test asserting the `Location` header contains no `/r/`.

---

## C7 — `catalog.types.ts:83` is stale about `imgOnly`

**`recapture-api/src/models/types/catalog.types.ts:83` says:** *"M9 (`update-item`) cannot unset
`imgOnly`, so a conversion has to be published as DELETE + CREATE and mints a new Mirage item id."*

**That is no longer true, and stage 5 depends on it not being true.** Verified in `mirage-be`
(the main repo, not the phase-2 fork) at `src/Controllers/adminController.js:1990-1995`:

```js
// // // imgOnly stays DERIVED, exactly as on create. This is what lets an
// // // image-only product become a real 3d product: uploading an `object`
// // // now clears the flag instead of leaving the public page convinced
// // // there is no model to show.
findProduct.imgOnly = Boolean(findProduct.image) && !findProduct.model?.src;
```

`src/services/mirage/mirageClient.ts:87` and `:786-790` already record the corrected behaviour and
cite the same handler lines. Only `catalog.types.ts:83` was left behind.

This matters because it is the mechanism stage 5 rides on: a dish published while its model is
generating becomes a real 3D product **on the same Mirage item id**, keeping its analytics history,
rather than being deleted and recreated.

> **Fix the stale comment as part of stage 5.** A future reader who believes it will build the
> DELETE + CREATE dance that C7 makes unnecessary.

---

## Things the plan got right that are worth re-confirming

Verified in the tree, so you do not have to:

| Claim | Verified at |
|---|---|
| `PUBLIC_URL_SCHEMES` is a deliberate one-member enum | `src/models/types/catalog.types.ts:42` |
| `mintPublicUrl` writes under a `mirageRestaurantId: null` guard | `src/services/catalogProvisioningService.ts:286-297` |
| `Catalog` has a unique index on `userId` alone, counting soft-deleted rows | `src/models/Catalog.ts:153` + the comment at `:139-141` |
| `resolveOwnedModel` rejects anything not `SUCCEEDED` with artifacts | `src/services/catalogProductsService.ts:393-395` |
| Ownership is proven through `Project.userId`, not the model row | `src/services/catalogProductsService.ts:383-390` |
| The publish lock is a conditional `findOneAndUpdate` on `activePublishRunId: null` | `src/services/catalogPublishService.ts:508-511` |
| `catalogQrService` uses `publicUrl` verbatim, no derivation | `src/services/catalogQrService.ts:233-243` |
| `consumeRateWindow(key, max, windowSeconds, now?)` is DB-backed, no Redis | `src/utils/rateLimit.ts:14` |
| Only `/health` and `/remote-config` are unauthenticated today | `src/app.ts:61-67` |
| `AUTO_MODEL_GENERATION_ENABLED` defaults `false` | `src/config/env.ts:268` |
| `AUTO_MODEL_MAX_PER_USER_PER_DAY` defaults `10` | `src/config/env.ts:273` |
| `admin.ts` mounts `requireAuth` then `requireRole('MODEL_ARTIST')` at router level, with `requireRole('ADMIN')` inline on destructive routes | `src/routes/admin.ts:58-59, 241-243, 326-328` |

---

## Preflight checklist

Run before opening stage 1. All must be green on a clean tree.

```bash
cd recapture-api
npm ci
npm run type-check && npm run lint && npm test
```

```bash
cd ..           # repo root
flutter pub get
flutter analyze && flutter test
```

If any of these is red before you start, fix that first. A stage's "Done when" block asks for the
same commands, and you cannot tell your breakage from pre-existing breakage otherwise.

**Two pre-existing issues, unrelated to this work, that should be fixed anyway** (carried over from
the plan's risk list — file them separately, do not fold them into a stage):

1. `recapture-api/tok.txt` is git-tracked and holds a raw JWT.
2. `src/utils/nodeMailerTransport.ts:4-5` has a literal Gmail address and app password as
   `process.env` fallbacks.
