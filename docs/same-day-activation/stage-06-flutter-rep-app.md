# Stage 6 — The Flutter Rep App

**Side:** client (Android/iOS **and** web) · **Size:** L (≈ 2 days) · **Depends on:** stages 1, 4, 5

---

## Goal

At the end of this stage a `SALES_REP` can, on a phone, standing in a restaurant: sign in, scan or
type a standee code, fill in the restaurant's name and phone, activate, add dishes, capture each
dish through the **unmodified** existing capture flow, and watch each dish flip from
"3D generating…" to "AR ready" without leaving the screen.

Every prompt in this repo's client history ships Android/iOS **and** Flutter web in the same change.
This one does too — with one documented exception, called out below.

---

## Prerequisites

- Stage 1 ticked (`salesRep`, rank-based `isStaff`, `isSalesRep`).
- Stage 4 ticked — `/rep` is live and a real `SALES_REP` account exists.
- Stage 5 ticked — `modelStatus` is on the product DTO.

---

## Verified context

| Fact | Where |
|---|---|
| `AppRoutes.catalogQr` is **already registered** (plan says otherwise — see C3) | `lib/app/routes/app_router.dart:99, 170, 335-336` |
| Poll cadence proven in production: 3s → 10s backoff, `_maxPolls = 120`, `ref.onDispose` teardown, last-good-state on transient failure | `lib/application/projects/model_generation_notifier.dart:25-44, 61` |
| Product entity parses field-by-field, never a spread | `lib/domain/entities/catalog_product.dart:48-108` |
| Repositories ride the existing `dioProvider`; no HTTP in presentation | `lib/data/repositories/*` |
| Existing catalog notifiers to mirror | `lib/application/catalog/*` |

**Standing architectural constraints** (from the client prompt pack, still binding): Riverpod only ·
no HTTP in presentation · no parsing in the UI · no new packages without a stated reason · existing
theme tokens only · no raw upstream error text shown to a user.

---

## Steps

### 1. Entity changes

**File:** `lib/domain/entities/catalog_product.dart`

Add `modelStatus` as a `ProductModelStatus` enum mirroring the backend's five values, with a
fail-closed `fromApiValue` defaulting to `none` — same pattern and same reasoning as `UserRole`.

Parse it **field-by-field** in the existing `fromJson`, never by spread. A field the parser forgets
reads back as a default and the AR button silently never appears.

Add the two derived getters the UI actually wants, so no widget re-derives them:

```dart
/// AR is available. The ONLY gate — never check `type == threeD` for this,
/// because a THREE_D product whose model is still generating is a valid,
/// publishable menu item with no AR button.
bool get isArReady => modelStatus == ProductModelStatus.ready && glbUrl != null;

/// Something is coming. Drives both the badge and the poll loop's stop condition.
bool get isModelPending =>
    modelStatus == ProductModelStatus.queued ||
    modelStatus == ProductModelStatus.processing;
```

**New file:** `lib/domain/entities/rep_activation.dart` — the activation request and result shapes,
and `lib/domain/entities/qr_code_preflight.dart` for `GET /rep/codes/:code`.

### 2. The repository

**New file:** `lib/data/repositories/rep_repository.dart`

One method per `/rep` endpoint, riding `dioProvider`, returning the existing `CatalogFailure` type
on error. Mirror `catalog_products_repository.dart` exactly — including how it maps status codes to
failures, so activation's `409` becomes a typed "code already taken" rather than a generic error.

Map these to distinct failures, because the UI has a distinct thing to say for each:

| Backend outcome | User-facing meaning |
|---|---|
| `409` on activate | "That code is already in use." Offer to scan another |
| `CODE_UNAVAILABLE` on preflight | Same, before the rep has typed anything else |
| Cross-catalog repoint refused | "That code belongs to a published restaurant." |
| Rate limited | "Too many activations. Try again in N minutes." |

**Never surface a raw backend message.** Standing rule.

### 3. Poll while pending

**File:** `lib/application/catalog/catalog_products_notifier.dart`

Add a poll loop while any product `isModelPending`. **Reuse the exact cadence already proven** in
`model_generation_notifier.dart:25-44` — do not invent a second one:

- `_initialInterval = Duration(seconds: 3)`, `_maxInterval = Duration(seconds: 10)`, backoff between
- `_maxPolls = 120` — a hard cap, so a stuck model cannot poll forever
- `ref.onDispose(_stop)` — teardown when the screen goes
- **last-good-state on transient failure** — a dropped request must not blank the grid a rep is
  reading in a restaurant with bad wifi
- **stop the moment nothing is pending** — the loop's condition is `any(isModelPending)`, checked
  after every response

The cleanest implementation is to extract the loop from `model_generation_notifier.dart` into a
small shared helper rather than copying it. Two copies of a backoff will drift; if you copy, say why
in a comment.

### 4. The product badge

**File:** `lib/presentation/widgets/catalog/product_card.dart`

| `modelStatus` | Badge |
|---|---|
| `queued`, `processing` | "3D generating…" with the existing progress affordance |
| `ready` | "AR ready" |
| `failed` | "3D unavailable" — **not** an error state. The dish is on the menu; only AR is missing |
| `none` | No badge |

Existing theme tokens only. The `failed` copy matters: a rep seeing a red error next to a dish they
just photographed will re-shoot it and spend Meshy credits twice.

### 5. Routes and screens

**File:** `lib/app/routes/app_router.dart` — add `/rep`, `/rep/activate`, `/rep/catalogs`,
`/rep/catalogs/:id`. Per **C3**, `/catalog/qr` is already registered; add nothing for it.

Gate the whole `/rep` subtree on `isSalesRep` in the router's redirect, alongside the existing staff
gate. A `USER` navigating to `/rep` goes to `/projects`, not to a screen that answers `403`.

**New:** `lib/presentation/screens/rep/`

- `rep_activation_screen.dart` — code entry → preflight → restaurant details → activate → success
  with the live link.
- `rep_catalogs_screen.dart` — the rep's live delegations.
- `rep_catalog_detail_screen.dart` — dish list for one delegated catalog, with the add-dish entry.

**The dish-capture leg deep-links into the existing capture flow, unmodified**, and returns with a
`modelId` — exactly as `T-018`'s fresh-scan path already does for owners. Do not fork the capture
flow for reps. If the flow needs a parameter it does not have, add the parameter; do not copy the
flow.

### 6. Code entry — scan and type, in that order

The rep is holding a phone in front of a standee. Camera scan is the primary path; manual entry is
the fallback for a damaged or badly-lit code.

- **Normalise on the client** the same way stage 2's `normalizeQrCode` does — uppercase, strip
  spaces and hyphens — so a code printed as `ABCD-2345` types cleanly. The server normalises again;
  the client copy is for the keyboard, not for trust.
- **Preflight before showing the details form.** `GET /rep/codes/:code` costs one request and saves
  the rep from typing a restaurant's whole profile against a code that turns out to be taken.
- **Accept a pasted full URL too.** A rep will paste `https://…/r/ABCD2345` at some point; extract
  the trailing segment rather than failing validation.

**⚠ Web exception.** Camera-based QR scanning does not exist on Flutter web the way it does on
device, and the `run-recapture` skill's documented limit is that native capture surfaces (camera,
sensors, permission channels) are absent on web. **On web, ship manual code entry only** and hide
the scan button. State this in the screen's file comment. The rep app's real target is a phone;
web is for demo and QA.

### 7. Phone entry is the highest-consequence field on the screen

A mistyped phone at activation creates an orphan `User` that permanently holds a catalog slot — the
unique index on `Catalog.userId` counts soft-deleted rows (`src/models/Catalog.ts:139-141`). The
owner then signs in on the correct number and gets an empty second account, with their catalog
stranded behind the typo.

Mitigate on the client, where it is cheap:

- Use the **same** phone input widget and validator as the OTP sign-in screen. Not a similar one.
- **Confirm-before-submit**: show the normalised number back to the rep in the exact form the
  restaurant would type it, and require an explicit tap.
- Put the number on the success screen too, so a wrong one is caught while the rep is still at the
  table.

This does not remove the need for the staff fix-up path in
[stage 7](stage-07-verification-and-rollout.md) — it reduces how often it is needed.

---

## Tests to write

**New file:** `test/auth/rep_role_gating_test.dart` — mirroring
`test/projects/projects_screen_role_gating_test.dart`

- A `SALES_REP` does **not** see the staff-only Live projects tab.
- A `SALES_REP` **does** reach `/rep`.
- A `USER` navigating to `/rep` is redirected, and never renders a screen that would `403`.
- A `MODEL_ARTIST` reaches both — pinning the accepted inheritance from D3 on the client too.

**New file:** `test/catalog/catalog_products_polling_test.dart`

- **pending → ready transition.** Seed a product as `processing`, advance a fake clock, return
  `ready` on the second poll, assert the badge changed and **the loop stopped**.
- **The loop never starts** when no product is pending.
- **Transient failure keeps last-good-state** — a failed poll leaves the grid populated.
- **`_maxPolls` is honoured** — the loop stops after the cap even if the product is still pending.
- **`ref.onDispose` stops it** — dispose mid-poll and assert no further requests.

**New file:** `test/rep/rep_activation_test.dart`

- Code normalisation: `abcd-2345`, `ABCD 2345`, and a pasted `https://…/r/abcd2345` all yield
  `ABCD2345`.
- A `409` from activate renders the "already in use" copy, not a raw backend message.
- The phone confirmation step blocks submission until tapped.

**Golden-JSON:** extend the existing product entity test with a fixture carrying `modelStatus`, and
one **without** it — asserting the absent field parses as `none` rather than throwing. That is the
test that lets the client roll out before or after the backend.

---

## Done when

- [ ] `modelStatus`, `isArReady` and `isModelPending` are on the product entity, parsed
      field-by-field.
- [ ] `rep_repository.dart` covers every `/rep` endpoint and maps `409` to a typed failure.
- [ ] The poll loop reuses the proven cadence (shared helper, or a comment saying why not).
- [ ] The badge renders all four states, with `failed` reading as "3D unavailable", not an error.
- [ ] `/rep/*` is gated on `isSalesRep` in the router redirect.
- [ ] The capture flow has **zero** diff in this stage.
- [ ] Web hides the scan button and offers manual entry, with the reason in a file comment.
- [ ] Phone entry reuses the OTP screen's widget and validator, with a confirmation step.
- [ ] `flutter analyze && flutter test` — green.
- [ ] `flutter build web` — succeeds.
- [ ] `flutter build apk --debug` — succeeds.
- [ ] Manual, on a real device: sign in as a rep → scan a standee → activate → add a dish → capture
      it → watch the badge flip to "AR ready".

---

## Rollback

Client-only. Revert the router registration to hide `/rep`; everything else is additive. The backend
stays live and any already-activated restaurant is unaffected — they own their catalog and reach it
through the normal owner app.
