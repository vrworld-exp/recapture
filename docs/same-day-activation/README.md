# Same-Day Restaurant Activation — Implementation Pack

Staged, step-by-step build plan for collapsing restaurant onboarding into a single on-site visit:
the rep closes the deal, photographs the dishes, and activates a pre-printed QR standee before
leaving the building.

**Architecture source of truth:** [`../next-phase/07-same-day-activation.md`](../next-phase/07-same-day-activation.md).
That document says *what* and *why*. This folder says *in what order, in which file, and how you
know it worked*.

**Conventions source of truth:** [`../../AGENTS.md`](../../AGENTS.md). Everything here defers to it.
Where a stage adds a convention (there is exactly one — the public router's envelope carve-out), the
stage says so and gives the reason.

---

## Read this first

[`00-preflight-and-corrections.md`](00-preflight-and-corrections.md) — the plan was re-verified
against the working tree before this pack was written. **Seven of its statements are stale or
wrong**, including two correctness hazards: one would silently corrupt `publishedRevision`, the
other would make every scanned standee an infinite redirect loop. Read the corrections before
opening any stage file; the stages already incorporate them.

[`08-does-this-touch-mirage.md`](stage-08-does-this-touch-mirage.md) — **no**, zero code changes required
in `mirage-be` or `mirage-fe`, verified rather than assumed. Three mechanisms depend on Mirage
behaving a particular way; all three were checked against both the `production` and
`feature/recap-phase-2` branches.

[`09-mirage-prompts.md`](stage-09-mirage-prompts.md) — the runnable proof of that claim (**SM4**, a
two-minute probe), plus one contingency and two optional Mirage prompts. **None is required.**

---

## The seven stages

| # | Stage | Side | Depends on | Size | Ships behind |
|---|---|---|---|---|---|
| 1 | [Foundations — role ladder, config, client role fix](stage-01-foundations.md) | BE + FE | — | S | nothing (inert) |
| 2 | [QR inventory + admin batch minting](stage-02-qr-inventory.md) | BE | 1 | M | ADMIN gate |
| 3 | [Public resolver `/r/:code`](stage-03-public-resolver.md) | BE | 2 | M | unassigned codes only |
| 4 | [Delegation + rep activation](stage-04-delegation-and-activation.md) | BE | 1, 2, 3 | L | `SALES_REP` gate |
| 5 | [Pending models + asset promotion](stage-05-pending-models-and-promotion.md) | BE | — | L | `modelStatus` default `NONE` |
| 6 | [Flutter rep app](stage-06-flutter-rep-app.md) | FE | 1, 4, 5 | L | `isSalesRep` gate |
| 10 | [Web parity for the rep surface](stage-10-web-parity.md) | FE | 6 | M | capability flags |
| 7 | [Verification + rollout](stage-07-verification-and-rollout.md) | CROSS | 1–6, 10 | M | — |

Sizes: `S` ≈ ½ day · `M` ≈ 1 day · `L` ≈ 2 days. **~10 engineering days** before review and QA.

Stage 10 is numbered out of order because 8 and 9 are the Mirage reference pair, not build steps.
It runs **after 6 and before 7**.

### Dependency graph

```
                    ┌─────────────────────────────┐
  Stage 1 ─────────►│ Stage 2 ──► Stage 3 ──► Stage 4 ──┐
  (foundations)     └─────────────────────────────┘     │
        │                                                ├──► Stage 6 ──► Stage 7
        └────────────────────────────────────────────────┤    (Flutter)   (verify)
                                                         │
  Stage 5 ───────────────────────────────────────────────┘
  (independent — can run in parallel with 2/3/4)
```

**Stage 5 has no dependency on stages 2–4.** It is the "per-dish AR arrives later" half and is
worth landing early: it is the only stage that changes an existing hot path
(`meshyModelProcessor`), so it wants the most soak time.

**Stage 3 can ship to production before stage 4 exists.** With no activated codes, every `/r/:code`
hit renders the fallback page — which is exactly the demo surface the brief asks for. Shipping it
early proves the public surface under real traffic before a single restaurant depends on it.

---

## What is genuinely new vs. what already exists

The originating brief assumed greenfield. It is not. Do **not** rebuild:

| Already built | Where |
|---|---|
| 6-photo meshy capture ring, server-side best-4 selection | `lib/domain/capture/capture_mode.dart`, `src/services/autoPhotoSelectionService.ts` |
| Meshy submit → poll → re-host to CloudFront | `src/worker/engine/meshy/meshyClient.ts`, `src/worker/processors/meshyModelProcessor.ts` |
| Per-model `QUEUED\|PROCESSING\|SUCCEEDED\|FAILED` + progress | `src/models/ProjectModel.ts` |
| `Catalog → CatalogCategory → CatalogProduct` + publish worker | `src/models/Catalog*.ts`, `src/worker/processors/mirageCatalogPublishProcessor.ts` |
| Deterministic QR PNG/PDF from `publicUrl` | `src/services/catalogQrService.ts`, `GET /catalog/qr` |
| Targeted-publish *read* path (planner accepts `productIds`) | `src/services/catalog/publishPlanner.ts:354` |

New in this pack: **the QR code inventory**, **the public resolver**, **the `SALES_REP` role**, and
**delegated (act-on-behalf-of) tenancy**.

---

## The one invariant that must not break

> `Catalog.publicUrl` is minted once and frozen forever. `assertMappingImmutable`
> (`src/services/catalogPublishService.ts:359`) throws on any rewrite.

This pack does **not** relax it. A pre-printed standee encodes
`{PUBLIC_RESOLVER_BASE_URL}/r/{code}`; at activation that exact string is written to
`catalog.publicUrl` **once**. Remapping happens one level below, on the `QrCode` row.
`catalogQrService` needs **zero changes** — it still reads `publicUrl` verbatim, so `GET /catalog/qr`
renders a code byte-identical to the one on the standee.

If a stage ever tempts you to rewrite `publicUrl`, you have taken a wrong turn. Retire the code and
activate a second one onto the same catalog instead — that is what `QrCode.catalogId` being
many-to-one is for.

---

## Status board

Tick as each stage lands. Nothing here is a progress signal until it is ticked **and** the stage's
own "Done when" block is green.

- [ ] Stage 1 — Foundations
- [ ] Stage 2 — QR inventory + admin batch minting
- [ ] Stage 3 — Public resolver
- [ ] Stage 4 — Delegation + rep activation
- [ ] Stage 5 — Pending models + asset promotion
- [ ] Stage 6 — Flutter rep app
- [ ] Stage 10 — Web parity for the rep surface
- [ ] Stage 7 — Verification + rollout

---

## How to use a stage file

Each stage file is one focused session and is independently reviewable. Every one carries:

1. **Goal** — one paragraph, what is true at the end that was not true at the start.
2. **Prerequisites** — stages and env vars that must already be in place.
3. **Verified context** — what the tree actually contains right now, with line references.
4. **Steps** — numbered, one file each, with the code shape and the reasoning.
5. **Tests to write** — named suites with the specific assertion each must make.
6. **Done when** — the checklist that closes the stage.
7. **Rollback** — how to take it back out if it goes wrong in production.

Do not start a stage until its prerequisites are ticked on the status board above.
