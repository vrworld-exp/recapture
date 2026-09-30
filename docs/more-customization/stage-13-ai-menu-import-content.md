# ✅ Stage 13 — Menu from a photo + AI content help

> **Status (2026-09-30): built, uncommitted.** Q7 answered 2026-09-30: **Claude** (official
> `@anthropic-ai/sdk`, model `claude-opus-5-5` via `AI_MODEL`), **₹2,000/month** hard cap across all
> restaurants, **reps + owners on every plan**. Typecheck / lint / analyze clean (Flutter: all of
> `lib`). Tests: `recapture-api/tests/menu-import-ai.test.ts` (12 — messy output cleaned, per-page
> draft with a declined page skipped, no-dish failure, apply = one draftRevision bump + price
> updates instead of duplicates + existing section reused, undo removes only unedited rows and
> restores untouched prices, 5/day cap, AI off, budget charged + enforced, descriptions scoped +
> capped, prompt guardrails) — provider faked and S3 mocked, no network;
> `test/catalog/stage13_import_test.dart` (2). Regression: product-sync / publish / offers /
> customers suites pass (131).
>
> **AI module** (`src/modules/ai/`): `provider.ts` — one interface, the Claude implementation, and a
> `setAiProvider` test seam; structured outputs via `client.beta.messages.parse` +
> `betaZodOutputFormat` (zod/v4 schemas), re-validated and sanitised after; server-side refusal
> fallback on (`fallbacks: 'default'`, beta `server-side-fallback-2026-07-01`); effort `medium` for
> reading menus, `low` for descriptions. `budget.ts` + `models/AiUsage.ts` — per-month INR spend
> from each response's token usage (Opus 5.5 $4/$20 per M, `AI_USD_TO_INR`), checked before every
> call. Env: `AI_API_KEY` (absent = every AI button hidden, routes 503), `AI_MODEL`,
> `AI_MONTHLY_BUDGET_INR` (2000), `AI_USD_TO_INR` (84).
>
> **13.1 import** — `models/MenuImport.ts`, `services/menuImport/{sanitize,menuImportService}.ts`,
> job `MENU_IMPORT` (reserved lane), processor, hourly 30-day photo purge. Routes (owner
> `/catalog/…`, rep `/rep/catalogs/:id/…`, one router `routes/aiCatalogRoutes.ts`):
> `POST /imports`, `POST /imports/:id/pages/:n` (raw body), `POST /imports/:id/start`,
> `GET /imports/:id`, `POST /imports/:id/apply`, `POST /imports/:id/undo`, `GET /imports`.
> Products/categories carry `importId`. Flutter `screens/catalog/menu_import_screen.dart` at
> `/catalog/import` and `/rep/catalogs/:id/import` (camera / gallery / PDF → upload → progress →
> review → apply → undo); entry in the catalog ⋮ menu and on the rep's restaurant screen.
> **13.2** — `services/aiContentService.ts`, `POST …/ai/descriptions`, `PUT …/ai/tone`,
> `Catalog.aiTone`; ✨ "Write description" in the product editor (3 options, fills the field only);
> `/catalog/ai-descriptions` bulk screen. **13.3** — `POST …/images/enhance {productId}` (sharp:
> upright, 4:3 attention crop, normalise, warmth, sharpen) → new staged key; "Enhance photo" in the
> editor shows original vs enhanced; "Use enhanced" commits through the normal image commit.
>
> **Differs from the text below:**
> - **Pages go through our API** (`POST …/pages/:n`, raw body), not presigned S3 PUTs — the web
>   build cannot PUT cross-origin to the bucket (the product-photo precedent).
> - **One AI call per page**; sections with the same name on different pages are merged; a dish
>   name seen twice is kept once (Mirage refuses duplicate names) and listed.
> - **Variants**: dishes have one price, so the first variant is the price and all of them are
>   written into the description ("Half ₹120 · Full ₹220").
> - **Photo-less dishes publish**: new opt-in `allowNoImage` on Mirage `create-item` (mirage-be
>   `adminController.js`), sent by `productSync.ts` only for an image-only dish with no photo;
>   Mirage shows its default dish image. Every other caller still needs a photo or a model.
> - **Undo** judges "edited since" by a fingerprint of the editable fields (name, price,
>   description, section, veg), not `updatedAt` — a publish also touches `updatedAt`.
> - Review screen: edit / untick / tick-all per section, "update price?" for existing dishes.
>   "Move to category" and "merge duplicates" are not built (the draft is already de-duplicated).
> - No blur check on the photos (the capture camera's blur module is not reused).
> - An import stuck in PROCESSING for 30 minutes (job retries exhausted) reads as FAILED
>   `TIMED_OUT`.
> - The ✨ button is in the owner's product editor; the rep's dish editor does not have it yet
>   (reps get import). Enhance is owner-only.

**Side:** recapture-api (new AI module + worker) + Flutter.
**Depends on:** nothing. Stage 6 translations can reuse the same AI provider module.
**Size:** L
**Priority:** big win for **reps** — onboarding a restaurant goes from hours of typing to minutes of checking.

## Why

Typing a 120-dish menu into the app is the slowest part of onboarding (see
`docs/same-day-activation/`). Most restaurants already have a printed menu. Photograph it → get a
draft catalog → the owner/rep only fixes mistakes.

---

## 13.1 Menu import from photos / PDF

### Flow

1. Catalog screen → **Import menu** → take up to 10 photos (reuse the capture camera; blur check
   from `docs/camera/blur-detection.md`) or pick images / a PDF.
2. Upload to S3 via the existing presign pattern (`s3MultipartService.ts`) under
   `imports/<catalogId>/<importId>/`.
3. API creates a `MenuImport` job → worker extracts → status `PROCESSING → READY | FAILED`
   (poll like model generation, progress per page).
4. **Review screen**: extracted categories and dishes in an editable list: name, price, variants
   ("Half ₹120 / Full ₹220"), description, veg/non-veg guess, confidence highlight (yellow =
   check this). Bulk actions: select all / remove / move to category / merge duplicates.
5. **Apply** → creates `CatalogCategory` + `CatalogProduct` rows (type image-only, no photo yet)
   in **one** transaction-like batch with an `importId` tag, `$inc draftRevision` once.
   Never publishes automatically. **Undo import** removes everything tagged with that `importId`
   that hasn't been edited since.
6. Existing catalog: dishes whose name matches an existing product (case/space-insensitive) are
   shown as "Update price ₹180 → ₹200?" instead of duplicates.

### Extraction (recapture-api)

- New `modules/ai/` with a provider interface `AiProvider.extractMenu(images) → ExtractedMenu`
  and `generateText(prompt)`; the implementation calls a vision-capable LLM (default: Claude, the
  current model id from Anthropic's docs at build time) with a **strict JSON schema** response:

  ```ts
  interface ExtractedMenu {
    currency: 'INR' | string;
    categories: { name: string; items: {
      name: string; description?: string; price?: number;
      variants?: { label: string; price: number }[];
      foodType?: 'VEG' | 'NON_VEG' | 'NONE'; confidence: number; sourcePage: number;
    }[] }[];
  }
  ```

- Validate with Zod; drop items without a name; clamp prices (0 < p < 100000); never trust the
  model's output as-is.
- Env: `AI_PROVIDER`, `AI_API_KEY` — absent = the Import button is hidden (served via remote config),
  same "absent = off" style as `RAZORPAY_*`.
- Cost guard: max 10 pages/import, 5 imports/catalog/day, log token usage per import on the job.
- Privacy: images deleted from S3 after 30 days; no customer data involved.

## 13.2 AI dish descriptions

- Product editor: **✨ Write description** next to the description field → `POST /catalog/products/:id/ai-description`
  with name, category, foodType, tags, language → 1–2 sentence appetising description (≤ 160
  chars), 3 options to pick from. Owner edits before saving; nothing auto-saved.
- Bulk: "Write descriptions for 34 dishes without one" → review list → apply selected.
- Tone option on the catalog: `casual | premium | fun` stored in `Catalog.aiTone`.
- Guardrails in the prompt: no health claims, no invented ingredients beyond the name ("may
  include" never used), no prices, Indian English.

## 13.3 Photo enhancement

- Product image upload → optional **Enhance**: auto-exposure/white balance/crop to 4:3 and
  optional background blur or clean plate background.
- Start with deterministic image processing (sharp: normalize, modulate, smart crop) — cheap and
  predictable. AI background replacement only behind a flag later; always keep the original and
  show before/after, owner picks.

## Flutter

- `screens/catalog/menu_import/` — capture/pick, progress, review list, apply, undo.
- ✨ buttons in `product_editor_screen.dart`; bulk description screen.
- Rep flow: Import menu available on delegated catalogs (it's the rep's main time saver).

## Tests

- Zod validation of messy model output (missing prices, strings as numbers, empty categories).
- Apply creates the right rows, one draftRevision bump, undo removes only untouched rows.
- Duplicate matching → update suggestions, not duplicates.
- Provider mocked in all tests; no network in CI.

## Done when

- [ ] A real 2-page printed menu photo produces a draft with ≥ 90% of dishes and prices correct.
- [ ] Rep imports, fixes 5 items, applies, publishes — in under 10 minutes for a 60-dish menu.
- [ ] Without `AI_API_KEY` the app shows no AI buttons and nothing breaks.
