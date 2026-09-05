✅✅✅✅✅
# Stage 7 — Verification and Rollout

**Side:** cross · **Size:** M (≈ 1 day) · **Depends on:** stages 1–6

---

## Goal

At the end of this stage the feature is proven end to end, the two operational decisions it forces
have been taken deliberately rather than by default, and the gaps that cannot be closed in code have
a named owner.

**Two of the items below are not engineering tasks.** R1 (splitting the worker) and R2 (turning on
unattended Meshy spend) are decisions with money and uptime attached. Do not let them ride in on a
deploy.

---

## Full verification suite

### Backend

```bash
cd recapture-api
npm run type-check && npm run lint && npm test
```

New suites, following the existing per-file `MongoMemoryServer` pattern, faking Meshy via
`setMeshyClient`, S3 via `vi.spyOn(s3Client, 'send')`, and Mirage via `tests/fixtures/mirageFake.ts`
— **CI never calls a live API**:

| Suite | Stage | The assertion that matters most |
|---|---|---|
| `qr-minting.test.ts` | 2 | Collision retry mints the full batch |
| `qr-resolver.test.ts` | 3 | A thrown error still renders HTML, never JSON |
| `qr-activation.test.ts` | 4 | Two concurrent activations produce exactly one winner |
| `qr-reassignment.test.ts` | 4 | A replacement code leaves `publicUrl` and prior scan rollups untouched |
| `rep-delegation.test.ts` | 4 | No delegation is indistinguishable from not-found |
| `catalog-model-promotion.test.ts` | 5 | Promotion under an active publish run loses nothing |

Extended suites:

| Suite | Added assertion |
|---|---|
| `catalog-provisioning.test.ts` | Provisioning must not overwrite a pre-set `publicUrl` |
| `catalog-publish-planner.test.ts` | A promoted product plans `UPDATE`, siblings plan `SKIP` |
| `catalog-product-edit.test.ts` | Replacing a READY model with a pending one behaves as decided |
| `admin-projects.test.ts` | `SALES_REP` does not pass a `MODEL_ARTIST` gate |

### Client

```bash
flutter analyze && flutter test
flutter build web
flutter build apk --debug
```

| Suite | Stage | Assertion |
|---|---|---|
| `test/auth/user_role_test.dart` | 1 | `salesRep.isStaff` is **false** |
| `test/auth/rep_role_gating_test.dart` | 6 | A rep sees no staff surfaces and reaches `/rep` |
| `test/catalog/catalog_products_polling_test.dart` | 6 | pending → ready, and the loop stops |
| `test/rep/rep_activation_test.dart` | 6 | Code normalisation and typed `409` copy |
| `test/rep/rep_web_parity_test.dart` | 10 | A hidden affordance is `findsNothing`, not disabled |
| `test/rep/rep_add_dish_source_test.dart` | 10 | 3 sources on mobile, 2 on web, both create a dish |
| `test/catalog/web_parity_test.dart` (extended) | 10 | No `dart:io` or layout `kIsWeb` in the rep tree |

**Run `make verify`, not just `flutter test`.** It gates analyze + test + **web build** + APK build
together, and the two toolchains fail differently — `flutter test` passing proves nothing about
whether the web build ships.

### End-to-end

Drive the web build with the `run-recapture` skill (headless Chrome, dev OTP `555555`):

1. Sign in as a `SALES_REP`.
2. Activate a minted code against a fresh restaurant phone.
3. `GET /r/{code}` — assert a `302` to the Mirage menu.
4. `GET /r/{unactivated}` — assert the fallback HTML, **not** a dead link.
5. `GET /r/{garbage}` — assert byte-identical output to step 4.
6. Sign in through the normal OTP flow **on the restaurant's phone** — assert you land on the
   catalog the rep created, with `phoneVerified` now true.

**Step 6 is the one that proves the whole tenancy design.** If it fails, the phone normaliser
diverged (stage 4, step 4) and every activation so far has stranded its owner.

> **The skill's documented limit:** native capture surfaces — camera, sensors, permission channels —
> do not exist on web. The dish-capture leg needs a device build and cannot be covered here.

### Device pass — not optional

| Check | Why web cannot cover it |
|---|---|
| Scan a printed standee with the **native iOS camera** | iOS and Android camera scanners differ in redirect handling |
| Same on **Android** | |
| Capture a dish through the rep flow | No camera on web |
| Watch a badge flip "3D generating…" → "AR ready" live | Needs a real generation |
| Launch AR on the published menu | AR Quick Look needs a physical iPhone |

---

## R1 — ⚠ Split the worker before this ships

`render.yaml` sets `RUN_WORKER_IN_PROCESS=true`, and the repo **already documents this as a broken
invariant**: `MODEL_OPTIMIZATION` is CPU-bound and stalls the event loop.

Until now the only victims were our own authenticated clients, who retry. Stage 3 puts **diner scan
traffic** on that same event loop. A cold start or an optimizer stall stops being an annoyance and
becomes a diner standing at a table looking at a spinner.

**Recommendation: split the worker into its own Render service before stage 3 reaches production.**
Set `RUN_WORKER_IN_PROCESS=false` on the web service and run a second service with the worker.

If that cannot happen in time, the fallback is to accept it **explicitly and in writing**, with:
- the resolver's two DB reads kept as the entire hot path (no third query — stage 3, step 5);
- a latency alert on `/r/:code`;
- a dated commitment to split.

Do not let this ride in unstated. It is the difference between a known tradeoff and an outage
nobody predicted.

## R2 — ⚠ Turning on unattended Meshy spend

Hands-off rep activation needs **both**:

1. `AUTO_MODEL_GENERATION_ENABLED=true` (defaults `false`, `src/config/env.ts:268`);
2. the live `autoModelGenerationEnabled` remote flag, which reads **fail-closed**.

This is a real-spend decision. Before flipping either:

- **Confirm the ceiling.** `AUTO_MODEL_MAX_PER_USER_PER_DAY` defaults to `10`
  (`src/config/env.ts:273`). Under D2 the "user" is the **restaurant**, so ten dishes a day is
  roughly one menu's worth. A rep onboarding a 30-dish restaurant will hit it mid-visit. Decide the
  number with whoever owns the Meshy budget, not in a config review.
- **Know what a rep can spend.** With `ACTIVATION_MAX_PER_WINDOW=30` (stage 1) and a per-restaurant
  ceiling of N, one rep's hourly worst case is `30 × N` generations. Multiply by the Meshy unit cost
  and check the number is one you are willing to see on an invoice.
- **Turn the remote flag on first, for one restaurant**, before the env var goes true globally. The
  flag is the faster lever to pull back.

## R3 — The orphan-user fix-up path

A mistyped phone at activation creates a `User` that permanently holds a catalog slot: the unique
index on `Catalog.userId` counts soft-deleted rows (`src/models/Catalog.ts:139-141`). Stage 6's
confirmation step reduces the frequency; it does not remove the case.

**Scope a staff fix-up path explicitly.** The smallest thing that works is a script beside
`scripts/set-user-role.ts`:

```
npx tsx scripts/repoint-catalog-owner.ts <catalogId> <correct-phone>
```

which resolve-or-creates the correct user, moves `Catalog.userId` and every `CatalogProduct.userId`
and `Project.userId` under it, and hard-deletes the orphan. **A script, not an endpoint** — the same
reasoning that keeps role grants script-only. It is rare, destructive, and wants a human who has
confirmed the right number.

Until it exists, the runbook answer is "escalate to engineering", and that should be written down
where support can find it.

## R4 — Cross-catalog repointing

Repointing a code to a *different* catalog leaves the first catalog's `publicUrl` pointing at a code
that no longer resolves to it. Stage 4 implements the rule: **allowed only while the source catalog
has never been published.** Confirm the rule holds in the shipped build, and that the client says
why when it refuses.

Replacing a standee for the **same** catalog is always safe and is the common case.

## R4b — Which Mirage branch is deployed

**AR works on every Mirage branch, including `production`** — `mirage-fe` gates the AR button on
`arAvailable: !!(item.model && item.model.src)` (`mirage-fe/src/api/menu.ts:116`), never on
`imgOnly`, and `production`'s `updateItem` does attach the model
(`adminController.js:1982`, `if (objectUrl) findProduct.model.src = objectUrl`). So stage 5's
promotion produces a working AR dish either way. **This is not a launch blocker.**

> **⚠ RESOLVED IN THE REPO, 2026-09-05 — the branch gap this item was written about is gone.**
> `origin/production` moved on **2026-09-03** (`02498d3 "Merge branch 'development' into
> production"`), which brought `3d89cd8` onto `production`. It now carries the re-derived `imgOnly`
> (`adminController.js:1995`) **and** `sortPosition`, `availability`, `socialLinks` and
> `isPublished`. Both paragraphs below described the state before that merge.
>
> Beware the check that looks obvious: `feature/recap-phase-2` is **not** a direct ancestor of
> `production` — the work landed via `development` — so branch-ancestry answers NO while the
> content is present. Verify content (`git grep <field> origin/production`), not ancestry.

~~What *does* differ~~ (before `02498d3`): `production` sets `imgOnly` once on create and never
re-derives it, so a promoted dish stays flagged `imgOnly: true` forever. The only consumer is the
menu sort (`itemController.js:129, 234` — `.sort({createdAt: -1, imgOnly: 1})`), so the effect was
**item ordering on the public menu**, cosmetic.

~~**The larger, pre-existing issue this uncovers:**~~ per
`../next-phase/prompts/03-mirage-prompts.md`, `mirage-be:production` carried **none** of the
phase-2 work. That note is now stale for the same reason; it was never caused by this work.

**Still establish which branch the target environment runs before rollout.** The findings above are
`git`, not HTTP — they say what `origin/production` *contains*, not what is *deployed*:

| Deployed content | Action |
|---|---|
| Carries `3d89cd8` (either branch, post-`02498d3`) | Nothing. Everything in this pack works as designed |
| An older `production` deploy | **SM1** (optional, cosmetic) or the full port-back, a pre-existing task |

The one-item probe in **SM4** answers "which is it" in about two minutes, and is now the *only*
thing left in this item — SM1 is expected to be unnecessary.

## R5 — Phase 2 free-tier QR is not blocked

`QrCode` carries no pricing or tier concept, and an unassigned code already has a graceful landing
page. Nothing here needs changing to support a free tier later. Noted so the question does not get
re-asked.

## R6 — Pre-existing issues, file separately

Not caused by this work; should be fixed anyway. Do **not** fold them into a stage:

1. `recapture-api/tok.txt` is git-tracked and holds a raw JWT.
2. `src/utils/nodeMailerTransport.ts:4-5` has a literal Gmail address and app password as
   `process.env` fallbacks.

---

## Rollout order

1. **Stage 1** — inert, deploy any time.
2. **Stage 5** — behind `modelStatus: 'NONE'` defaults. Deploy early, soak longest. It is the only
   stage that edits a live processor.
3. **R1** — split the worker. **Before** stage 3.
4. **Stage 2** — ADMIN-only. Mint a small pilot batch, print a handful.
5. **Stage 3** — public. Every code renders the fallback until stage 4 lands, which is itself the
   demo surface. Watch resolver latency for a few days.
6. **Stage 4** — gated on `SALES_REP`, which nobody holds until you grant it.
7. **R2** — turn on auto-generation for one restaurant, then widen.
8. **Stage 6** — client. Grant `SALES_REP` to one rep and do a real onboarding visit.
9. **Stage 10** — web parity. Ship in the same release as stage 6 wherever possible; the capability
   flags are what keep the web build from shipping a broken Scan button in the meantime.
10. **Stage 7** — full sweep, device pass, and the R3 script.

Codes are printed physical objects. **Do not mint a large batch until stage 4 has completed one real
end-to-end activation**, because `PUBLIC_RESOLVER_BASE_URL` is baked into every printed URL and a
wrong host is unrecoverable at scale.

---

## Sign-off checklist

- [ ] Every new and extended suite listed above is green.
- [ ] `flutter build web` and `flutter build apk --debug` both succeed.
- [ ] The end-to-end run passes, **including step 6** (owner OTP sign-in reaches the rep-created
      catalog).
- [ ] The device pass is done on both iOS and Android.
- [ ] R1 is either done or accepted in writing with an alert and a date.
- [ ] R2's ceiling is confirmed with the budget owner and the flag was rolled out to one restaurant
      first.
- [ ] R4b: the deployed Mirage branch is identified (SM4 probe), and SM1 run or consciously skipped.
- [ ] The placeholder-image decision (08) is made — rep photo as product image, or accept the
      generic placeholder during the generating window.
- [ ] Stage 10's matrix rows 15–24 are in `../next-phase/web-capability-matrix.md`.
- [ ] The web URL strategy is confirmed and the `/rep/activate?code=` link matches it.
- [ ] Deep-link option A or B is chosen and recorded (stage 10, note J).
- [ ] `make verify` passes — including the web build.
- [ ] The R3 fix-up script exists, or the escalation path is documented for support.
- [ ] The AGENTS.md envelope carve-out (stage 3, step 1) is written.
- [ ] Q12 in `../next-phase/06-open-questions.md` is annotated with the CSV answer.
- [ ] `../README.md`'s status board is fully ticked.
   