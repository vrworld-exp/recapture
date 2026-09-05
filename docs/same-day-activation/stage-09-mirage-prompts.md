✅✅✅✅/2
# 09 — Mirage Prompts (SM1 … SM4)

Ready-to-paste prompts for the Mirage side of same-day activation.

> ## ⚠ None of these is required
>
> The feature works end to end with **zero Mirage changes** — see
> [`08-does-this-touch-mirage.md`](stage-08-does-this-touch-mirage.md) for the verification. This file
> exists because "no changes needed" deserves a runnable proof (**SM4**) and because the
> investigation surfaced two genuine, small, optional improvements (**SM1**, **SM2**) and one
> product decision that would need a real Mirage change if taken (**SM3**).
>
> **Run SM4 first.** It is a two-minute probe and it tells you whether SM1 is even relevant.

| | Prompt | Repo | When to run | Size |
|---|---|---|---|---|
| **SM4** | Probe: which Mirage am I talking to? | none (curl) | **Always, before rollout** | 10 min |
| **SM1** | Derive `imgOnly` on update-item | `mirage-be` | Only if SM4 says `production` | S |
| **SM2** | Self-host the default product image | `mirage-be` | Recommended, independent | S |
| **SM3** | "3D coming soon" on the public menu | `mirage-be` + `mirage-fe` | Only if the product decision is taken | M |

Target repos: `phase2/mirage-be/` (Node/Express/Mongoose) and `phase2/mirage-fe/` (React/TS).
**These do not run from `phase2/ReCapture/`.**

---

## Shared context — paste at the top of any prompt below

```
Repo: phase2/mirage-be (Node/Express/Mongoose) — and phase2/mirage-fe (React/TS) where stated.

Standing facts, verified in the tree — do not re-derive, and do not "fix" them:

- Mirage holds a DERIVED COPY of catalog truth. ReCapture owns the catalog and the
  publish worker is the only writer. Never add an authoring affordance here that
  ReCapture does not drive.
- `imgOnly` means "this product has a picture but no 3D model". It is DERIVED,
  never taken from the caller.
    - feature/recap-phase-2: derived on create (adminController.js:1580) AND on
      update (adminController.js:1995).
    - production: set on create only (`if (imageUrl && !objectUrl)`), never
      re-derived on update.
- `updateItem` attaches a model on both branches:
  `if (objectUrl) findProduct.model.src = objectUrl;` (production:1174).
- mirage-fe derives the AR button from the model URL, NOT from imgOnly:
  `arAvailable: !!(item.model && item.model.src)` (mirage-fe/src/api/menu.ts:116).
  `imgOnly` appears in mirage-fe once, as an unused optional type field
  (src/Types.ts:175).
- `imgOnly`'s only real consumer is the public menu sort:
  `.sort({ createdAt: -1, imgOnly: 1 })` (itemController.js:129 and :234).
- create-item does not require an uploaded image: it falls back to
  DEFAULT_PRODUCT_IMG_URL (CONSTANT.js:53, adminController.js:1501).

Why this matters right now: ReCapture's same-day activation feature publishes a
dish BEFORE its 3D model exists, then updates the same item with the GLB minutes
later. Same Mirage item id throughout — the item must never be deleted and
recreated, because that would reset its analytics history.

House style: match the surrounding code exactly, including the `// // //` comment
convention. No new dependencies. No schema field without a stated reason.
```

---

## SM4 — Probe: which Mirage am I talking to?

**Run this before anything else, against the environment ReCapture actually publishes to.**
No code change. It answers the one question stage 7's R4b asks.

```
Task: determine, against a running Mirage instance, whether update-item re-derives
`imgOnly` — which tells us whether the deployed build is `feature/recap-phase-2`
(or later) or `production`.

Steps, using the admin credentials the ReCapture worker already uses:

1. create-item with an `image` file and NO `object`. Record the returned item id.
   Assert the response has `imgOnly: true`.
2. update-item on that id, sending `name` (always required — Mirage builds the S3
   key from the request's name) and an `object` file.
3. Read the item back via the public menu endpoint.

Report three things:
  a) `imgOnly` after step 3 — `false` means feature/recap-phase-2 or later;
     `true` means production.
  b) `model.src` after step 3 — MUST be populated on either branch. If it is
     empty, stop and escalate: that breaks same-day activation outright and is
     not a known state of any branch.
  c) Whether the item id from step 1 is unchanged. It must be.

Then delete the probe item so the menu is left clean.

Do NOT change any Mirage code in this prompt.
```

**Reading the result:**

| Outcome | Meaning | Action |
|---|---|---|
| `imgOnly: false`, `model.src` set | `feature/recap-phase-2`+ | Nothing. Skip SM1 |
| `imgOnly: true`, `model.src` set | `production` | SM1 is available; cosmetic only |
| `model.src` empty | **Unknown state** | Stop. Escalate before rollout |

---

## SM1 — Derive `imgOnly` on update-item (contingency)

**Run only if SM4 reported `production`.** The consequence of skipping it is cosmetic: a promoted
dish keeps `imgOnly: true`, which skews the public menu's `.sort({imgOnly: 1})` ordering. **AR is
unaffected** — the front end reads `model.src`.

The change already exists on `feature/recap-phase-2`. Prefer porting that branch over hand-patching
production; this prompt is the minimal standalone version for when a full port-back is not on the
table.

```
Task: make `imgOnly` a derived field on update-item, matching how create-item
already derives it.

In `src/Controllers/adminController.js`, inside `exports.updateItem`, AFTER the
block that applies the caller's fields and AFTER `if (objectUrl)
findProduct.model.src = objectUrl;` — and BEFORE `await findProduct.save()` —
add:

    // // // imgOnly stays DERIVED, exactly as on create. This is what lets an
    // // // image-only product become a real 3d product: uploading an `object`
    // // // now clears the flag instead of leaving the public page's sort order
    // // // convinced there is no model to show.
    findProduct.imgOnly = Boolean(findProduct.image) && !findProduct.model?.src;

Constraints:
- Derived ONLY. Never read `imgOnly` from the request body here — create-item
  does not, and a caller-supplied value is exactly the bug this prevents.
- Use optional chaining on `model` — an image-only item has no `model` subdocument
  and `findProduct.model.src` would throw.
- Do NOT touch the create path; it is already correct.
- Do NOT touch `findRestaurant.clientType`. Its one-way flip to "BOTH" is
  existing behaviour and is out of scope.

Verification:
1. Re-run the SM4 probe. Step 3 must now report `imgOnly: false` with the same
   item id.
2. The reverse: update an item to REMOVE its model, and assert `imgOnly` returns
   to `true`. If the current handler has no removal path, say so rather than
   adding one.
3. An update that touches only `price` must leave `imgOnly` unchanged for both a
   3D item and an image-only item.
4. Confirm the public menu still returns 200 for a restaurant containing a mix of
   image-only and 3D items.
```

---

## SM2 — Self-host the default product image (recommended, independent)

Not caused by this feature, but this feature makes it visible: **every** rep-created dish shows
`DEFAULT_PRODUCT_IMG_URL` for the minutes between activation and model completion. Before
same-day activation, few items ever lacked an image; now every dish does, briefly, on a menu a
diner is actively reading.

Today that constant is (`src/CONSTANT.js:53`):

```js
exports.DEFAULT_PRODUCT_IMG_URL =
   "https://res.cloudinary.com/dlvq8n2ca/image/upload/v1762238745/dciw1uvzthx78db4zczq.jpg" || …
```

Three problems: it is a **third-party host** we do not control, on an account nobody on the team
may own; it is an opaque asset id nobody can visually verify; and the `||` fallback is dead code —
a non-empty string literal is always truthy, so the second URL can never be reached.

```
Task: replace the default product image with a self-hosted, brand-appropriate
placeholder, and remove the dead fallback.

1. Add a placeholder asset to the same S3/CloudFront space the app already serves
   product images from. It must read as "photo coming soon", not as a broken
   image and not as a stock-photo watermark.
2. In `src/CONSTANT.js`, replace DEFAULT_PRODUCT_IMG_URL with the CloudFront URL,
   built from the existing CLOUD_FRONT_URL constant rather than hardcoded.
3. Delete the `|| "https://images.squarespace-cdn.com/..."` fallback. Explain in a
   `// // //` comment that the value is a constant, so a fallback here is
   unreachable — do not replace it with a different fallback.
4. Do the same review for DEFAULT_CATEGORY_IMG_URL (CONSTANT.js:50), which points
   at a shutterstock.com watermarked stock image. Flag it; change it only if a
   replacement asset is available.

Constraints:
- No new dependency, no image processing at runtime. One static URL.
- Do not change create-item's logic — only the constant it falls back to.

Verification:
- create-item with no image; assert the returned `image` is the new URL and that
  it resolves 200 from the CDN.
- Confirm the placeholder renders correctly on the public menu at a 430px viewport,
  in a grid alongside real product photos.
```

---

## SM3 — "3D coming soon" on the public menu (optional, only if the decision is taken)

**Do not build this by default.** It is here because it is the *only* thing in same-day activation
that would genuinely require a Mirage change, so the decision should be explicit rather than
discovered later.

**The question:** during the generating window a dish is indistinguishable from a permanently
image-only dish. Should the public menu say "3D coming soon"?

**Arguments against (the default):** it exposes our processing state to diners; a failed generation
turns the promise into a lie; and it needs a new field on `itemModel` that only one publisher ever
writes. The dish already looks fine as a 2D card.

**Argument for:** a restaurant that just bought an AR menu wants the AR visible on day one, and a
"coming soon" badge is a sales asset during the visit itself.

**Prefer the cheaper alternative first:** [`08`](stage-08-does-this-touch-mirage.md) recommends committing
one of the rep's six capture photos as the product image. That fixes the *look* of the generating
window entirely on the ReCapture side, with no Mirage change and no diner-facing promise. Take
SM3 only if a real badge is wanted on top of that.

```
Task: surface a per-item "3D model is being generated" state on the public menu.

Backend (phase2/mirage-be):
1. `src/Models/itemModel.js` — add:
       modelPending: { type: Boolean, default: false }
   with a `// // //` comment stating that it is set ONLY by the ReCapture publish
   worker, is advisory, and must never gate rendering on its own.
2. `adminController.js` — accept `modelPending` on create-item and update-item as
   an ordinary optional boolean field. Unlike `imgOnly` this one IS caller-supplied:
   only ReCapture knows a generation is in flight.
3. `itemController.js` — include it in the public menu payload. Do NOT add it to
   the sort.

Frontend (phase2/mirage-fe):
4. `src/api/menu.ts` — map it onto the MenuItem type. Leave
   `arAvailable: !!(item.model && item.model.src)` EXACTLY as it is: the badge is
   advisory, the model URL is truth. An item with modelPending true and a model
   present shows AR, not a badge.
5. Render a subtle badge on the card when `modelPending && !arAvailable`. Existing
   design tokens only. Copy: "3D coming soon". Never a progress bar or an ETA —
   Mirage has no idea how long it will take.

Constraints:
- The badge must NEVER appear on an item that has a model.
- A stale `modelPending: true` on a failed generation must degrade to "an ordinary
  2D dish", so the badge must not add any affordance that fails when tapped.

Then, in ReCapture (phase2/ReCapture/recapture-api), a follow-up change is required
for this to do anything: `productSync.ts` must send modelPending derived from the
product's `modelStatus` (QUEUED/PROCESSING → true, everything else → false), and
`modelStatus` must be added to PRODUCT_DIFF_FIELDS so a status change plans an
UPDATE. Note that this makes every promotion publish twice — once to set the flag,
once to clear it and attach the model. Budget for that before agreeing to SM3.

Verification:
- An image-only product never shows the badge.
- A pending 3D product shows it; after promotion + republish, the badge is gone and
  the AR button is present.
- A failed generation leaves a plain 2D card with no badge and no dead control.
```

> ⚠ The last paragraph is the real cost of SM3: **it doubles the publish traffic per dish** and
> puts a ReCapture processing state into Mirage's data model. That is why it is not the default.

---

## What is deliberately NOT here

| Considered | Why no prompt |
|---|---|
| A Mirage-side `/r/:code` resolver | The resolver lives in `recapture-api` by decision **D1**. Mirage never learns codes exist |
| Mirage storing the QR code or batch | Same. `QrCode` is ReCapture inventory; Mirage holds no pricing or tier concept either (risk R5) |
| Scan counting in Mirage analytics | Scans are counted in `QrScanDaily` before the redirect. Mirage's own page-view analytics continue to work unchanged and independently |
| A `SALES_REP` concept in Mirage | Reps never authenticate to Mirage. The publish worker is the only writer and uses the existing admin credentials |
| Changing `clientType`'s one-way flip to "BOTH" | Pre-existing behaviour, triggered by any image-only item. Out of scope; file separately if it matters |
| Porting `feature/recap-phase-2` → `production` | **Real, pre-existing, and larger than this feature.** It belongs to `../next-phase/prompts/03-mirage-prompts.md`, which already documents the cherry-pick and the one manual `CONSTANT.js` step. Do not fold it into this pack |
