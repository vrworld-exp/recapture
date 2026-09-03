# 08 — Does this touch `mirage-be` / `mirage-fe`?

**Short answer: no. Zero code changes in either repo.** Verified against `phase2/mirage-be` and
`phase2/mirage-fe`, not assumed.

The whole pack lives in `ReCapture/recapture-api/` and `ReCapture/lib/`. But "no changes" is not the
same as "Mirage is irrelevant" — three things depend on Mirage behaving a particular way, and all
three were checked. This page records what was checked and what it means, so nobody has to re-derive
it mid-stage.

---

## Why the answer is no, mechanism by mechanism

### 1. The scan destination — Mirage is the redirect target, unchanged

A scan lands on `recapture-api`, which `302`s to the Mirage menu page that already exists:
`{MIRAGE_PUBLIC_BASE_URL}/{mirageRestaurantId}`. Mirage never learns the QR code exists, never
serves `/r/:code`, and has nothing new to render.

The indirection is entirely on the ReCapture side. That is the design's main benefit: the printed
code is remappable without Mirage knowing anything changed.

> This is also where **C6** bites — the resolver must derive the target from `mirageRestaurantId`,
> not from `publicUrl`. See [`00-preflight-and-corrections.md`](00-preflight-and-corrections.md).

### 2. Publishing — the existing worker, unchanged

Rep-created catalogs and rep-created dishes are ordinary `Catalog` and `CatalogProduct` rows owned
by the restaurant's own user. They publish through the existing `MIRAGE_CATALOG_PUBLISH` job, the
existing planner, the existing `productSync`, against the existing M-endpoints.

Mirage cannot tell a rep-created restaurant from an owner-created one, and should not be able to.

### 3. Per-dish AR arriving later — Mirage already supports it

This is the one that could have needed a Mirage change. It does not. Two facts, both verified:

**A dish with no assets publishes fine.** `productSync.ts:240` asks for
`availableSlots(product)`, which for a pending 3D product (no `glbUrl`, no `thumbnailUrl`) returns
`[]` — so no files are sent. On the Mirage side, `adminController.js:1501` is
`let imageUrl = DEFAULT_PRODUCT_IMG_URL || "";` — a **default placeholder image**, so create-item
does not reject an item with no uploads. `imgOnly` derives to `true` and the dish appears on the
menu as an image card.

**Promotion upgrades it in place.** When the model lands, stage 5 copies the assets onto the
product; the planner sees `glbUrl`/`thumbnailUrl` in `PRODUCT_DIFF_FIELDS` and plans an `UPDATE`;
`update-item` writes `model.src` (`adminController.js:1174` on `production`, and the equivalent on
`feature/recap-phase-2`). **Same Mirage item id**, so the dish keeps its analytics history.

On `feature/recap-phase-2` the flag is also re-derived —
`findProduct.imgOnly = Boolean(findProduct.image) && !findProduct.model?.src`
(`adminController.js:1995`), with the intent stated in the comment above it:

> *"imgOnly stays DERIVED, exactly as on create. This is what lets an image-only product become a
> real 3d product: uploading an `object` now clears the flag."*

> ⚠ `recapture-api/src/models/types/catalog.types.ts:83` still claims `update-item` cannot unset
> `imgOnly` and that conversions need DELETE + CREATE. It is stale — see **C7**. Fix the comment in
> stage 5; do not build a DELETE + CREATE path around it.

### 4. `mirage-fe` — nothing to change, and it does not even read `imgOnly`

The public menu derives the AR affordance straight from the model URL:

```ts
arAvailable: !!(item.model && item.model.src)      // mirage-fe/src/api/menu.ts:116
```

`imgOnly` appears in `mirage-fe` exactly once, as an optional field on a type
(`src/Types.ts:175`), and drives no rendering.

This is what makes stage 5 robust across Mirage branches: a diner who scans during the generating
window sees a 2D card, and after promotion the same card gains its AR button — **whether or not
`imgOnly` was re-derived.** The flag's only real consumer is the menu sort in
`itemController.js:129, 234`.

---

## Two things to know before you rely on this

### The placeholder-image window is a product decision, not a bug

Between activation and model completion, a pending dish carries Mirage's
`DEFAULT_PRODUCT_IMG_URL` — a generic placeholder, not a photo of the food. For a menu that goes
live the moment the rep finishes, that is what a diner sees for the first several minutes.

**Recommended, and not currently in any stage's scope:** have the rep flow commit one of the six
capture photos as the product's `imageKey`, so the card shows the actual dish immediately and the
generated thumbnail replaces it on promotion. The photos already exist — the rep shot six of them
for Meshy — but they live in the raw project key space, not the product-image key space
(`src/utils/productImageKeys.ts`), so this is a real copy step, not a reference.

Decide this before the first real visit. It is roughly half a day in stage 5 or 6 and it is the
difference between a menu that looks finished and one that looks broken.

### Which Mirage branch is deployed changes what "fine" means

`phase2/mirage-be` is checked out on **`feature/recap-phase-2`** (`3d89cd8`), which carries the
derived `imgOnly` and the rest of the phase-2 work. **`production` does not.** Verified by reading
the branch directly, not by trusting a note:

| | `production` | `feature/recap-phase-2` |
|---|---|---|
| `updateItem` attaches `model.src` | ✅ `adminController.js:1174` | ✅ |
| `imgOnly` re-derived on update | ❌ set once on create, never again | ✅ `adminController.js:1995` |
| **AR on the public page after promotion** | **✅** (fe reads `model.src`) | **✅** |
| Menu sort correct after promotion | ❌ stale flag skews `.sort({imgOnly:1})` | ✅ |
| `sortPosition`, `availability`, `socialLinks`, `isPublished` | ❌ absent | ✅ |

**This feature works on either branch.** The difference is item ordering, not AR.

The last row is the real finding, and it is **pre-existing and much larger than this feature**:
`../next-phase/prompts/03-mirage-prompts.md` records that `mirage-be:production` carries none of the
phase-2 work, which degrades the whole ReCapture publish path. This pack neither creates that
problem nor depends on it being solved.

Run the **SM4** probe in [`09-mirage-prompts.md`](stage-09-mirage-prompts.md) against the target
environment to find out which branch you are actually talking to — about two minutes — then decide
whether **SM1** is worth running.

---

## Summary

| Repo | Code changes | Depends on it for |
|---|---|---|
| `ReCapture/recapture-api` | **All backend stages** | — |
| `ReCapture/lib` | **Stage 1 + stage 6** | — |
| `mirage-be` | **None required** | Redirect target · publish endpoints · `updateItem` writing `model.src` |
| `mirage-fe` | **None required** | Rendering an item that gains a model after first publish |

Optional and contingency Mirage work — none of it blocking — is written up as runnable prompts in
[`09-mirage-prompts.md`](stage-09-mirage-prompts.md).

Two decisions for [stage 7](stage-07-verification-and-rollout.md): identify the deployed Mirage
branch (SM4), and settle the placeholder-image question.
