# 05 — MVP / V1.1 / V2 Bucketing

**MVP: 26 tasks (~34 days) | V1.1: 10 tasks (~10.5 days) | V2: 6 tasks (~6.5 days)**

Totals are engineering days only (S = ½, M = 1, L = 2), before review, QA and pilot support.
Every task from `04-task-breakdown.md` appears in exactly one bucket. 42 tasks, ~51 days.

**The MVP line:** a pilot business can sign in, create a catalog, add both a 3D and an image-only
product, organise them, preview, publish to Mirage, and get a working, permanent QR code — with
honest sync status when something fails. Anything not on that path is deferred.

---

## MVP — 26 tasks, ~34 days

| Task ID | Title | Size | Why it is MVP |
|---|---|---|---|
| T-001 | Catalog/Product/Category/PublishRun models + indexes | M | Nothing else exists without the data model |
| T-002 | Business profile fields + endpoints | S | Feature 42/59 — Mirage's restaurant record needs a name, logo, phone and location or the public page has no branding |
| T-003 | `MIRAGE_*` config | S | No Mirage call can be made without it; secrets must not be hardcoded |
| T-004 | Mirage HTTP adapter + error classification | M | The single seam every sync task depends on |
| T-005 | Flutter entities + repositories | M | The client cannot talk to any new endpoint without it |
| T-006 | Catalog tab shell + routes | S | The entry point to every catalog screen |
| T-007 | Catalog CRUD + logo/cover upload | M | Feature 1–4: the container itself |
| T-008 | Category CRUD + reorder | M | **Not optional.** Mirage's `create-item` rejects a missing or invalid category ObjectId (`adminController.js:847-854`), so no product can be published without a real category |
| T-009 | Product create (3D + image-only) | L | The core object of the whole phase |
| T-010 | Product image presign/commit | M | Image-only products (feature 13) cannot exist without an upload path |
| T-015 | Product list, filter, search | M | A catalog you cannot list is unusable past three products |
| T-017 | Flutter product grid | L | The screen the business user lives in |
| T-018 | Flutter add-product flow (3 sources) | L | Features 11–13 are the only ways to get a product in |
| T-023 | Flutter business profile screen | M | The user must be able to enter the branding T-002 stores and T-024 syncs |
| T-024 | Provisioning + mapping + URL minting | L | Features 40–42, and where the permanent public URL is minted and frozen |
| T-025 | QR generation, download, share | M | Feature 31–35 — the QR *is* the product from the business's point of view |
| T-027 | Publish job type + processor + planner | L | The sync layer's backbone |
| T-028 | Category sync | M | Required before any item sync can succeed (see T-008) |
| T-029 | Product sync + reconciliation | L | Features 43–46, and the brief's non-negotiable idempotency guarantee |
| T-030 | Asset sync (preflight + byte streaming) | L | Without it, published products have no model and no image — the catalog is empty shells |
| T-031 | Publish endpoint + state machine + gates | L | Features 36–38, 56, 57 — the draft/published split that makes the whole design safe |
| T-033 | Per-product sync status + manual retry | M | A pilot publish *will* partially fail; a business with no visibility and no retry is stuck and calls the founder |
| T-034 | Flutter publish screen | L | The user-facing half of publish, including the partial-failure and success states |
| T-040 | Toasts and inline confirmations | S | Feature 67 — without confirmation, users repeat destructive actions |
| T-041 | Error and success states | M | Features 68–69. A raw Mirage 400 with prose like "Product already exist" is unusable to a café owner |
| T-042 | Test hardening (Mirage fakes, idempotency, QR stability) | L | Mirage has no tests, no types and no versioning; the fakes are the only contract. The QR-stability and crash-replay tests protect the two guarantees that are expensive to discover broken in production |

**Deliberately excluded from MVP, with reasons:**

- **Editing products (T-011/T-019).** A pilot business can delete and re-add for the first weeks.
  Edit touches the riskiest Mirage gaps (M9 ignores `description`, `category` and `imgOnly`), and
  shipping it half-working is worse than not shipping it.
- **Analytics (T-037/T-038).** Collection is already happening — Mirage's public page has been
  emitting `client_page_view`, `product_page_view`, `model_loaded` and `ar_session_started` into
  `analyticsEventModel` all along, with a 365-day TTL. Deferring the **read** surface loses no data,
  so the dashboard can arrive later against a full backlog of history.
- **Unpublish (T-032).** Blocked on Q1, and a pilot business that just got its QR printed is not
  about to take its catalog offline.

---

## V1.1 — 10 tasks, ~10.5 days

Fast-follow, driven by what the first pilots hit within days.

| Task ID | Title | Size | Why V1.1 |
|---|---|---|---|
| T-011 | Product edit — fields, replace model/image, convert type | M | The first thing every pilot asks for after a typo'd price. Held back from MVP only because the Mirage update gaps need the workarounds settled first |
| T-019 | Flutter product editor | L | The client half of T-011 |
| T-012 | Archive / restore / permanent delete | M | Features 19–21. Delete exists as a workaround in MVP via re-add; a real archive/restore flow is the first stabilisation ask |
| T-020 | Flutter archive/restore/delete UI | M | The client half of T-012 |
| T-014 | Featured flag + reorder endpoint | S | Features 9–10. Businesses want their best-seller first almost immediately |
| T-021 | Flutter category manager with drag reorder | L | MVP ships basic category CRUD via T-008/T-018; the managed reorder-and-move surface is polish |
| T-026 | Flutter catalog preview | M | Feature 5. Valuable, but a pilot can publish and look at the real page instead — and that is the more truthful preview anyway |
| T-032 | Unpublish | M | Feature 39. Needed once real customers are scanning, and it needs Q1 answered first |
| T-035 | Product order sync | S | Completes T-014 as far as Mirage allows; small, and honest about the gap |
| T-039 | ReCapture-side authoring analytics events | S | Instrumenting the funnel matters once there are pilots to measure, not before. Cheap to add later since the emit seam already exists |

---

## V2 — 6 tasks, ~6.5 days

Power features and anything that should wait for validation.

| Task ID | Title | Size | Why V2 |
|---|---|---|---|
| T-013 | Duplicate a product | S | A convenience for catalogs with many variants. Nobody is blocked without it, and Mirage's per-restaurant name uniqueness makes it fiddlier than it looks |
| T-016 | Bulk actions endpoint | M | Only pays off past ~30 products. Mirage has no batch endpoints, so a bulk action is N sequential syncs — build it once real catalog sizes are known |
| T-022 | Flutter bulk-selection mode | M | The client half of T-016, same reasoning |
| T-036 | Sync / activity log | M | The brief itself marks feature 55 optional for MVP. T-033's per-product status covers the "what failed and why" question; the full log is a debugging luxury |
| T-037 | Analytics proxy service | M | Features 61–66. Collection needs no work; only the read surface is deferred, and no data is lost while it waits |
| T-038 | Flutter analytics dashboard | L | Feature 66. The most-requested-after-launch feature, but zero pilots can be onboarded without it, and its shape should follow what pilots actually ask about |

---

## Bucketing rationale

The MVP is deliberately **wide but shallow**: every step of the end-to-end path is present, and none
of them is optional-quality. The two places that look like over-investment for an MVP are
intentional:

- **T-042 (test hardening) stays in MVP.** Mirage has no tests, no type checking, and returns HTTP
  400 for validation errors, not-found, bad credentials *and* its global 404. The only way to know
  the sync layer works is a fake pinned to real observed messages. Two specific guarantees —
  "publishing twice never duplicates" and "the QR never changes" — are cheap to test now and
  extremely expensive to discover broken after stickers are printed.
- **T-033 (sync status + retry) stays in MVP.** Publishing 10 products means 10 sequential
  unbatched, unidempotent multipart uploads against a server on a sleeping tier. Partial failure is
  the expected case, not the exceptional one. Without visibility and retry, every partial failure
  becomes a founder support call.

The largest deferral is **product editing**, which is unusual for an MVP. It is deferred because
Mirage's `update-item` silently ignores `description`, `category` and `imgOnly`
(`adminController.js:1038-1047`, `:1170-1175`), so a naive edit feature would appear to work in the
app and do nothing on the public page — the worst possible failure mode for a pilot's trust. The
workarounds (delete + recreate, which mints a new Mirage item id) deserve a deliberate design pass
rather than being rushed into MVP.
