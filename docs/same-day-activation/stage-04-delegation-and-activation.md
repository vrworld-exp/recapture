✅✅✅✅✅✅✅/2

# Stage 4 — Delegation and Rep Activation

**Side:** backend · **Size:** L (≈ 2 days) · **Depends on:** stages 1, 2, 3

---

## Goal

At the end of this stage a `SALES_REP` standing in a restaurant can scan an unassigned standee,
type the restaurant's name and phone, and have a live catalog with a working public URL before
leaving the table. The restaurant owns its own account from the first second; the rep acts through
an explicit, revocable, audited grant.

This is the largest and most security-sensitive stage in the pack. Two rules govern every decision
in it:

1. **The restaurant owns the catalog.** Not the rep. This is what preserves the unique index on
   `Catalog.userId`, every `userId`-scoped query, and `resolveOwnedModel`'s ownership proof — none
   of which needs weakening.
2. **Rep routes mirror owner routes; they never modify them.** `/catalog` and `/projects` stay
   exactly as they are. No second, weaker door into owner data.

---

## Prerequisites

- Stages 1, 2, 3 ticked.
- `PUBLIC_RESOLVER_BASE_URL` set — activation **must** fail loudly without it.
- A dev `SALES_REP` account from stage 1.

---

## Verified context

| Fact | Where |
|---|---|
| `Catalog` has a unique index on `userId` alone, counting soft-deleted rows | `src/models/Catalog.ts:139-141, 153` |
| `verifyOtpService` creates the user on first verify — first OTP verify *is* signup | `src/services/verifyOtpService.ts:213-215` |
| `authUid` is a `randomUUID()` and is the unique key | `src/services/verifyOtpService.ts:215` |
| `mintPublicUrl` writes under a `{mirageRestaurantId: null}` guard | `src/services/catalogProvisioningService.ts:286-297` |
| `PUBLIC_URL_SCHEMES` is a one-member enum, the documented grandfathering seam | `src/models/types/catalog.types.ts:42` |
| `resolveOwnedModel` proves ownership via `Project.userId` | `src/services/catalogProductsService.ts:383-390` |
| The atomic-claim pattern: conditional `findOneAndUpdate` | `src/services/catalogPublishService.ts:508-511` |

---

## Steps

### 1. Extend the URL scheme

**File:** `recapture-api/src/models/types/catalog.types.ts:42`

```ts
export const PUBLIC_URL_SCHEMES = ['MIRAGE_OBJECT_ID', 'RECAPTURE_SHORT_CODE'] as const;
```

Document the new member beside the existing one, in the same voice:

```
 *   RECAPTURE_SHORT_CODE — `{PUBLIC_RESOLVER_BASE_URL}/r/{code}`, written at
 *   REP ACTIVATION, before Mirage has ever heard of this restaurant. The
 *   indirection is the point: the printed code is meaningless and permanent,
 *   and remapping happens on the QrCode row rather than on this URL — so
 *   `publicUrl` stays as frozen under this scheme as under the other one.
```

The enum being multi-member is the whole reason it was written as an enum: existing catalogs keep
`MIRAGE_OBJECT_ID` and their printed codes keep working, visibly grandfathered rather than quietly
repointed.

### 2. Make provisioning yield to a pre-set URL

**File:** `recapture-api/src/services/catalogProvisioningService.ts` (~`:281-297`)

A rep-activated catalog already has `publicUrl` and `publicUrlScheme`, written at activation.
Provisioning must still write `mirageRestaurantId` and `mirageProvisionedAt` as it does today, but
must **not** overwrite the URL.

The existing update is a single `$set` under a `{mirageRestaurantId: null}` guard. Split the
payload: the mapping fields stay unconditional, the URL fields move into the `$set` only when the
loaded catalog has no `publicUrl`.

```ts
// A rep-activated catalog arrives here with publicUrl ALREADY SET — written at
// activation, pointing at the printed standee, before Mirage existed for this
// restaurant. Minting over it would break every code already in the field, and
// assertMappingImmutable would (correctly) throw on the next publish. Mirage
// provisioning owns `mirageRestaurantId`; it does NOT own the public URL.
const urlFields = catalog.publicUrl
  ? {}
  : { publicUrl: mintPublicUrl(mirageRestaurantId), publicUrlScheme: 'MIRAGE_OBJECT_ID' as const };
```

Careful with the guard: it currently matches on `mirageRestaurantId: null`, which is still correct
— an activated catalog has no Mirage id yet. Do **not** widen it to include `publicUrl: null`, or
activation's own URL would make provisioning skip the Mirage mapping entirely.

`mappingOf` (`:106-113`) returns `null` unless **both** `mirageRestaurantId` and `publicUrl` are
present, so an activated-but-unprovisioned catalog correctly reads as having no mapping. That is
already right; leave it.

### 3. The delegation grant

**New file:** `recapture-api/src/models/CatalogDelegation.ts`

`repUserId` · `catalogId` · `grantedAt` · `revokedAt?` · `grantedByUserId?`.

Indexes:
- `{repUserId:1, catalogId:1}` unique **among live rows only** —
  `partialFilterExpression: { revokedAt: null }`. A revoked grant must not block a re-grant, and a
  partial index is the only thing that expresses "unique while live" in Mongo.
- `{catalogId:1, revokedAt:1}` — "who can act on this catalog".
- `{repUserId:1, revokedAt:1}` — the `GET /rep/catalogs` list.

**New file:** `recapture-api/src/services/catalogDelegationService.ts`

```ts
export async function grantDelegation(repUserId, catalogId, grantedByUserId?): Promise<void>;
export async function revokeDelegation(repUserId, catalogId): Promise<void>;
export async function listDelegatedCatalogs(repUserId): Promise<CatalogSummaryDto[]>;

/**
 * THE gate. Every /rep route that touches a catalog goes through this and
 * nothing else.
 *
 * Returns null for "no live delegation" AND for "no such catalog" — the two are
 * deliberately indistinguishable, so a rep cannot probe for the existence of
 * catalogs they do not hold. Same reasoning as resolveOwnedModel returning
 * MODEL_NOT_FOUND for a model owned by someone else.
 */
export async function resolveDelegatedCatalog(
  repUserId: Types.ObjectId,
  catalogId: string
): Promise<ICatalog | null>;
```

One helper, one gate, every route. If a route ever resolves a catalog any other way, that is the
bug.

### 4. Resolve-or-create the restaurant user

**New file:** `recapture-api/src/services/activationService.ts`

The rep enters the restaurant's phone. Resolve-or-create a `User` on it — the same operation
`verifyOtpService` performs today, minus the OTP, since the rep is present and vouching.

```ts
/**
 * The restaurant's own account, created on the rep's word rather than on an OTP.
 *
 * phoneVerified stays FALSE — nobody proved possession of this number. When the
 * owner later signs in with it through the normal OTP flow, verifyOtpService
 * finds this exact user and flips the flag: they simply ARE the owner. No
 * migration, no claim step, no merge.
 */
async function resolveOrCreateRestaurantUser(phone: string): Promise<IUser>;
```

Non-negotiable properties:

- `phoneVerified: false`. Do not shortcut it. The whole point is that this account becomes real
  when the owner verifies, and until then it is a rep's assertion.
- **Normalise the phone identically to `verifyOtpService`.** If activation stores `9876543210` and
  OTP looks up `+919876543210`, the owner signs in to a *second* empty account and their catalog is
  stranded behind an orphan user. Extract the existing normaliser and call it from both, rather than
  writing a second one. This is the single highest-consequence detail in the stage.
- Reuse the existing user when the phone already has one — an existing customer being re-signed by
  a rep must land on their existing catalog, not collide with it.

### 5. Activation, atomically

**In `activationService.ts`:**

```ts
export async function activate(params: {
  repUserId: Types.ObjectId;
  code: string;
  restaurantName: string;
  restaurantPhone: string;
  businessName?: string;
  contact?: CatalogContact;
}): Promise<ActivationResult>;
```

Order, and why:

1. **Refuse if `PUBLIC_RESOLVER_BASE_URL` is unset.** Fail before any write.
2. Rate-limit: `consumeRateWindow('activation:' + repUserId, env.ACTIVATION_MAX_PER_WINDOW,
   env.ACTIVATION_WINDOW_SECONDS)`. Per the plan's D3 mitigation, `/rep` activation gets its own
   window — the role inheritance means an ADMIN also passes this gate, and the window is part of
   what makes that auditable rather than unbounded.
3. Normalise and load the code. Not `UNASSIGNED` → `CODE_UNAVAILABLE`.
4. Resolve-or-create the restaurant user.
5. Resolve-or-create their catalog. `Catalog.userId` is uniquely indexed, so use
   `findOneAndUpdate(..., {upsert:true})` and let the index be the rule — do not read-then-write.
6. Write `publicUrl` = `${env.PUBLIC_RESOLVER_BASE_URL}/r/${code}` and
   `publicUrlScheme: 'RECAPTURE_SHORT_CODE'` **only if absent**, guarded in the query:
   `{_id: catalogId, publicUrl: null}`. An already-activated catalog keeps its first URL.
7. **Bind the code with a conditional update** — this is the concurrency guard:

```ts
const claimed = await QrCode.findOneAndUpdate(
  { _id: qrCode._id, state: 'UNASSIGNED', deletedAt: null },   // ← the guard IS the lock
  { $set: { state: 'ACTIVE', catalogId, activatedAt: new Date(), activatedByUserId: repUserId } },
  { new: true }
).exec();
if (!claimed) return { outcome: 'CODE_UNAVAILABLE' };   // someone else won — clean 409
```

Two reps scanning the same standee produce one winner and one clean `409` — the same atomicity
pattern as `activePublishRunId` (`catalogPublishService.ts:508`) and refresh-token rotation. There
is no transaction and none is needed: the single-document conditional update *is* the mutual
exclusion.

8. Open the `QrCodeAssignment` row and set `QrCode.currentAssignmentId`.
9. `grantDelegation(repUserId, catalogId)`.
10. Emit analytics. **Never the code, never the phone** — `hashIdentifier` the rep, and carry
    nothing else identifying.

**Step 7 must come after steps 4–6 and before 8–10.** If the process dies between 7 and 9 the code
is bound with no delegation: the restaurant owns a live catalog and the rep cannot edit it. That is
recoverable (re-run activation on the same code returns the existing catalog and re-grants) and is
the right direction to fail. Make step 7 onwards **idempotent on re-run**: a code already `ACTIVE`
and pointing at *this* catalog re-grants and returns `ALREADY_ACTIVE` rather than `CODE_UNAVAILABLE`.

### 6. The rep router

**New file:** `recapture-api/src/routes/rep.ts` · **mounted** `app.use('/rep', repRouter)`

```ts
router.use(requireAuth);
router.use(requireRole('SALES_REP'));
```

Router-level gates, mirroring `admin.ts:58-59`.

| Endpoint | Purpose |
|---|---|
| `GET /rep/codes/:code` | Preflight — is this code valid and unassigned? |
| `POST /rep/activations` | `{code, restaurantName, restaurantPhone, businessName?, contact?}` |
| `GET /rep/catalogs` | The rep's live delegations |
| `POST /rep/catalogs/:id/products` | Dish authoring on behalf of the restaurant |
| `POST /rep/catalogs/:id/qr-codes` | Attach a replacement standee `{code}` |
| `POST /rep/qr-codes/:code/retire` | Retire a code |

**Every catalog-scoped route calls `resolveDelegatedCatalog` and nothing else.** `null` → the same
`404` a nonexistent catalog gives.

`POST /rep/catalogs/:id/products` **delegates to the existing
`catalogProductsService.createProduct`**, passing the restaurant's `userId` as the owner. Do not
reimplement product creation. The rep route is an authorization wrapper over the owner service, and
the moment it grows its own product logic the two will drift.

**Replacement standees.** `POST /rep/catalogs/:id/qr-codes` activates a *second* code onto the same
catalog: bind the new code (same conditional update), close the old assignment, open a new one, and
**leave `publicUrl` alone**. That is feature 32 satisfied rather than worked around. The old code
should then be retired via the separate endpoint — deliberately two calls, so "print a spare" and
"kill the lost one" are distinct decisions.

**Cross-catalog repointing** — activating a code that is `ACTIVE` on catalog A onto catalog B —
leaves A's `publicUrl` pointing at a code that no longer resolves to it. Per the plan's risk 4:
**refuse it unless the source catalog has never been published**
(`publishedRevision < 0` / `status === 'DRAFT'`). Return a distinct error code so the client can say
why. Write the rule into the service, not the route.

### 7. Validation

**New file:** `recapture-api/src/validation/repSchemas.ts`

Reuse the `qrCodeParam` refinement from stage 2. Reuse the existing catalog name and contact
schemas from `catalogSchemas.ts` rather than declaring parallel ones — a rep-created catalog must
satisfy exactly the same rules as an owner-created one, and two schemas will drift.

Phone validation must be the **same** schema `authSchemas.ts` uses for OTP requests. Same reasoning
as the normaliser in step 4.

---

## Tests to write

**New file:** `recapture-api/tests/qr-activation.test.ts`

- **Two concurrent activations of one code produce exactly one winner.** Fire both with
  `Promise.all`; assert one `201` and one `409`, one `QrCode` in `ACTIVE`, exactly one
  `QrCodeAssignment`, exactly one `CatalogDelegation`. **The stage's headline test.**
- **`publicUrl` is the standee's URL**, byte-identical to the CSV row stage 2 exported for that
  code.
- **Re-activating the same code by the same rep is idempotent** — `ALREADY_ACTIVE`, no second
  assignment, no second delegation, `publicUrl` unchanged.
- **An existing user's phone reuses the account** and does not create a second `User`.
- **Phone normalisation round-trips through OTP.** Activate on a phone, then run the real OTP
  request+verify flow for that phone, and assert it resolves to the **same** `_id` with
  `phoneVerified` now `true` and the catalog still attached. This is the test that catches the
  stranded-owner bug.
- **Activation refuses with `PUBLIC_RESOLVER_BASE_URL` unset**, before any write — assert no
  `User`, `Catalog`, `QrCode` or delegation changed.
- **Rate limit trips** at `ACTIVATION_MAX_PER_WINDOW + 1`.

**New file:** `recapture-api/tests/rep-delegation.test.ts`

- **A rep with no live delegation gets an identical `404` to a nonexistent catalog** — compare
  status, code and body across both cases. No existence leak.
- **A revoked delegation is immediately dead** on the next request (no token expiry involved).
- **Revoke then re-grant works** — proves the partial unique index is on live rows only.
- **A `USER` gets `403` on every `/rep` route**; a `SALES_REP` passes; a `MODEL_ARTIST` and an
  `ADMIN` also pass, **asserted explicitly** so the accepted inheritance from D3 is pinned by a test
  rather than assumed.
- **`/catalog` and `/projects` are unchanged for the rep** — a rep hitting `/catalog` gets their
  *own* (empty) catalog, never the restaurant's. Proves no weaker second door was opened.
- **A rep-created product is owned by the restaurant** — assert `CatalogProduct.userId ===
  restaurantUserId`, not the rep's.

**New file:** `recapture-api/tests/qr-reassignment.test.ts`

- **Attaching a replacement code leaves `publicUrl` untouched** and leaves the prior assignment's
  scan rollups untouched.
- **Two assignment rows exist**, the first with `unassignedAt` set, the second open.
- **Retiring the old code** makes it render the `REPLACED` page (stage 3) while the new one
  redirects.
- **Cross-catalog repoint is refused** once the source catalog has published, and allowed while it
  is `DRAFT`.

**Extend:** `recapture-api/tests/catalog-provisioning.test.ts`

- **Provisioning does not overwrite a pre-set `publicUrl`.** Seed a catalog with a
  `RECAPTURE_SHORT_CODE` URL, run provisioning, assert `mirageRestaurantId` and
  `mirageProvisionedAt` were written and `publicUrl`/`publicUrlScheme` were not.
- **The unchanged path still mints.** A catalog with no `publicUrl` still gets the
  `MIRAGE_OBJECT_ID` URL exactly as before — proves the split payload did not break the existing
  flow.

---

## Done when

- [ ] `PUBLIC_URL_SCHEMES` has both members and the new one is documented in the file.
- [ ] Provisioning writes the Mirage mapping without touching a pre-set `publicUrl`, proven by test.
- [ ] `CatalogDelegation` exists with the partial unique index on live rows.
- [ ] `resolveDelegatedCatalog` is the only catalog resolution path in `rep.ts` (grep to confirm).
- [ ] Activation is atomic under concurrency, proven by test.
- [ ] Phone normalisation is shared with `verifyOtpService`, proven by the round-trip test.
- [ ] `/catalog` and `/projects` have **zero** diff in this stage.
- [ ] `npm run type-check && npm run lint && npm test` — green.
- [ ] Manual: as a real `SALES_REP`, `POST /rep/activations` against a real minted code, then scan
      the standee on a phone and land on the Mirage menu.

---

## Rollback

Unmount `/rep` and redeploy — reps lose access, no data is harmed, and every activated catalog keeps
working because the restaurant owns it outright. The `publicUrl` values already written are frozen
and stay valid as long as `/r` stays mounted.

**Do not roll back stage 3 while activated codes exist in the field.** That is the one combination
that produces dead links on printed material.
