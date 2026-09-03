# Stage 3 — The Public Resolver `/r/:code`

**Side:** backend · **Size:** M (≈ 1 day) · **Depends on:** stages 1, 2

---

## Goal

At the end of this stage a diner can point a phone camera at a printed standee and land somewhere
sensible — always. An `ACTIVE` code redirects to the Mirage menu; every other outcome, including an
internal error, renders a human-readable HTML page. **A dead link is the one outcome the brief
forbids**, and this stage is where that promise is either kept or broken.

**This is the first customer-facing surface in `recapture-api`.** Today only `/health` and
`/remote-config` are unauthenticated (`src/app.ts:61-67`), and both are consumed by our own client.
Everything about this stage follows from that: the client is a phone camera opening a browser, not
a Dio instance that understands the JSON envelope.

**Ship this before stage 4.** With no activated codes, every hit renders the fallback — which is
exactly the demo surface the brief asks for. It proves the public path under real traffic before a
single restaurant depends on it.

---

## Prerequisites

- Stage 2 ticked. You need real minted codes to test against.
- `PUBLIC_RESOLVER_BASE_URL` set in the target environment.
- **Read risk R1 in [stage 7](stage-07-verification-and-rollout.md) first.** `render.yaml` sets
  `RUN_WORKER_IN_PROCESS=true`, and this stage puts customer traffic on the same event loop as the
  CPU-bound model optimizer. That decision belongs to stage 7 but it is *this* stage that makes it
  urgent.

---

## Verified context

| Fact | Where |
|---|---|
| `errorHandler` emits `{status, code, message}` JSON for everything | `src/middleware/errorHandler.ts` |
| `notFound` and `errorHandler` are mounted last and catch all | `src/app.ts:70-72` |
| Existing mounts, all with `requireAuth` inside the router except health/remote-config | `src/app.ts:61-67` |
| `helmet()` is applied globally before routing | `src/app.ts:56` |
| `catalog.publicUrl` is the frozen destination, read verbatim | `src/services/catalogQrService.ts:233-243` |

---

## Steps

### 1. Decide, and document, the envelope carve-out

**This stage adds the only new convention in the whole pack.** Add a short subsection to
[`../../AGENTS.md`](../../AGENTS.md) beside the existing envelope rule:

> **Envelope carve-out — the public router only.** Every route in this API returns the JSON
> envelope. `src/routes/public.ts` is the single exception: its client is a phone camera opening a
> browser, so it returns `302` redirects and `text/html`, never `{status, code, message}`. It
> therefore carries its **own terminal error handler**, mounted inside the router, so a thrown
> error renders the fallback page instead of falling through to `errorHandler.ts` and showing a
> diner a JSON blob. No other router may copy this.

Writing this down is a step, not a nicety. The next person to add a route will otherwise follow
`public.ts` as a pattern.

### 2. The fallback pages

**New file:** `recapture-api/src/services/qrFallbackPage.ts`

Three states, three pages, one function:

```ts
export type FallbackKind = 'NOT_YET_LIVE' | 'REPLACED' | 'UNKNOWN' | 'ERROR';
export function renderFallbackPage(kind: FallbackKind): string;
```

Rules that are not optional:

- **Zero external requests.** No CDN font, no remote image, no analytics beacon. Inline everything.
  A diner on a bad restaurant wifi connection must get the page.
- **Self-contained string, no template engine.** No new dependency, and nothing to fail at render
  time. The `ERROR` page in particular must be renderable when the database is down — so it takes
  no arguments and touches nothing.
- **Escape nothing, because nothing is interpolated.** Do not put the code, the restaurant name, or
  any request value into the HTML. It removes the entire XSS surface from a page that has no login
  and no CSRF token. If a future change needs interpolation, it needs an escaper first.
- **Responsive and readable at arm's length** — this is read on a phone held over a table.
- **`Cache-Control: no-store`** on every fallback. A code activated five minutes from now must not
  be shadowed by a cached "not live yet" page sitting in a CDN or a phone browser.

Copy per state:

| Kind | Copy |
|---|---|
| `NOT_YET_LIVE` | "This menu isn't live yet." Plus a line about what Mirage Menu is — an `UNASSIGNED` code is a demo surface, and the brief wants it to sell. **Also carries the rep activation link** — see below |
| `REPLACED` | "This code has been replaced." Ask the diner for a fresh standee |
| `UNKNOWN` | Same page as `NOT_YET_LIVE`. **Deliberate** — see step 4 |
| `ERROR` | "Something went wrong. Try again in a moment." No detail, no request id displayed |

**The rep activation link on `NOT_YET_LIVE`** — small, secondary, below the diner-facing copy:

> *Are you a Mirage rep? **Activate this code.***

pointing at `{WEB_APP_BASE_URL}/rep/activate?code={code}`. This is the **only** place the code is
interpolated into the page, so it needs the escaper the "escape nothing" rule otherwise makes
unnecessary — or, better, build the href from the already-normalised code, which is alphabet-
restricted by construction and cannot carry markup.

Why it earns its place: the rep's **OS camera** already scans the standee and lands here, so this
link gives one-tap activation on any device with no in-app QR scanner at all. It is what lets
[stage 10](stage-10-web-parity.md) treat the missing web scanner as a non-issue rather than a gap.
`WEB_APP_BASE_URL` is a new optional env var — when unset, render the page without the link rather
than with a broken one.

### 3. The resolver service

**New file:** `recapture-api/src/services/qrResolverService.ts`

```ts
export type ResolveOutcome =
  | { kind: 'REDIRECT'; url: string }
  | { kind: 'FALLBACK'; fallback: FallbackKind };

export async function resolveCode(rawCode: string): Promise<ResolveOutcome>;
```

Order of operations, and each step's reason:

1. `normalizeQrCode(rawCode)` (stage 2). `null` returns `FALLBACK: UNKNOWN` **without touching the
   database** — this is what keeps a scan-flood of garbage from becoming a query-flood.
2. `QrCode.findOne({ code, deletedAt: null })`. Missing returns `FALLBACK: UNKNOWN`.
3. `state === 'RETIRED'` returns `FALLBACK: REPLACED`.
4. `state === 'UNASSIGNED'`, or `ACTIVE` with no `catalogId`, returns `FALLBACK: NOT_YET_LIVE`.
5. Load the catalog. **No `mirageRestaurantId` returns `FALLBACK: NOT_YET_LIVE`**, not an error —
   a catalog activated but not yet published is the normal state for the first minutes of a rep
   visit, and it is exactly what the "not live yet" page is for.
6. Record the scan (step 5 below), then `REDIRECT` to
   `${env.MIRAGE_PUBLIC_BASE_URL}/${catalog.mirageRestaurantId}` — **not** to `publicUrl`. See the
   box above.

### 4. The route

**New file:** `recapture-api/src/routes/public.ts` · **mounted** `app.use('/r', publicRouter)` in
`src/app.ts`, alongside the existing mounts and **before** `notFound`.

```
GET /r/:code
```

| Code state | Response |
|---|---|
| `ACTIVE`, catalog published | record scan, `302` → the **Mirage menu URL** (see the box below) |
| `ACTIVE`, not yet published | `200` HTML — "this menu isn't live yet" |
| `UNASSIGNED` | `200` HTML — "this menu isn't live yet" |
| `RETIRED` | `200` HTML — "this code has been replaced" |
| unknown | `200` HTML fallback, **not** a `404` JSON body |

> ### ⚠ Do NOT redirect to `catalog.publicUrl`
>
> The source plan's table says *"`302` → `catalog.publicUrl` (the Mirage menu)"*. Once Part 1
> lands, **those are no longer the same thing** — activation writes
> `{PUBLIC_RESOLVER_BASE_URL}/r/{code}` *into* `publicUrl`, so redirecting there is an infinite
> self-redirect. See **C6** in [`00-preflight-and-corrections.md`](00-preflight-and-corrections.md).
>
> The redirect target is derived from `catalog.mirageRestaurantId`:
> `${env.MIRAGE_PUBLIC_BASE_URL}/${catalog.mirageRestaurantId}` — the same expression
> `mintPublicUrl` uses (`src/services/catalogProvisioningService.ts:101-103`). Export that helper
> and call it; do not write a second copy of the format string.
>
> After Part 1, the two fields have distinct jobs and the naming is unfortunately close:
>
> | Field | Holds | Read by |
> |---|---|---|
> | `catalog.publicUrl` | the **standee** URL, `…/r/{code}` | `catalogQrService` — what the QR renders |
> | `catalog.mirageRestaurantId` | the Mirage id | this resolver — where a scan actually lands |

**Why unknown is `200` and not `404`.** Two reasons, both load-bearing:

1. A `404` from Express without a body handler falls through to `notFound` → JSON. The diner sees
   `{"status":"error","code":"NOT_FOUND"}`. That is the dead link the brief forbids.
2. `404` for unknown and `200` for unassigned is an **enumeration oracle**: it tells an attacker
   which codes are minted. Since unknown and unassigned render the identical page with the identical
   status, the two are indistinguishable from outside.

**Terminal error handling, inside the router:**

```ts
// LAST in this router. Mounted here rather than relying on errorHandler.ts
// because that one emits the JSON envelope, and a diner must never see it.
// A thrown error renders the ERROR page — which is why renderFallbackPage
// takes no arguments and touches no I/O.
publicRouter.use((err, _req, res, _next) => {
  logResolverError(err);
  res.status(200).type('html').set('Cache-Control', 'no-store')
     .send(renderFallbackPage('ERROR'));
});
```

Four-argument signature or Express will not treat it as an error handler. `asyncHandler`
(`src/utils/asyncHandler.ts`) forwards rejections into it, so use it on the route as usual.

**Redirect headers.** `302`, not `301` — a permanent redirect is cached by the browser forever and
would survive a code being retired or repointed. Set `Cache-Control: no-store` on the redirect too,
for exactly the same reason.

**Rate limiting.** Do **not** rate-limit by code. A popular restaurant's standee is *supposed* to be
scanned a hundred times an hour, and limiting it takes the menu down at dinner rush. If abuse
protection is needed later it belongs at the edge (Render/Cloudflare), not in this handler.

### 5. Scan recording — never on the critical path

**In `qrResolverService.ts`**, a single `$inc` upsert:

```ts
await QrScanDaily.updateOne(
  { qrCodeId, assignmentId, day: utcDay(new Date()) },
  { $inc: { count: 1 }, $setOnInsert: { qrCodeId, assignmentId, day } },
  { upsert: true }
);
```

Three rules:

- **`assignmentId`, not just `qrCodeId`.** Scans stay attributed to the mapping that was live when
  they happened, so repointing a code does not retroactively move history to the new restaurant.
- **Never block the redirect on it.** Wrap in `try/catch` and swallow. A metrics write must not be
  able to break a menu. Log at warn level and move on.
- **`day` is UTC**, matching the field comment from stage 2. State it in the code, not just the
  model.

The `assignmentId` is the currently-open `QrCodeAssignment` for the code. Cache it on the `QrCode`
row (`currentAssignmentId`) rather than querying the ledger on every scan — the resolver's hot path
should be exactly two reads: the code and the catalog.

> Add `currentAssignmentId` to the `QrCode` model in stage 2 if you are building the stages back to
> back; otherwise add it here and note it as a stage-2 amendment.

### 6. Analytics

Add `QR_CODE_SCANNED: 'qr_code_scanned'` to `src/validation/analyticsSchemas.ts` with props
`{outcome}` where `outcome` is an enum of the four resolve results. **No code value, no catalog id,
no restaurant name, no IP, no user agent.** A code identifies one restaurant's menu; a scan
identifies one diner's presence there. Neither belongs in an analytics prop.

---

## Tests to write

**New file:** `recapture-api/tests/qr-resolver.test.ts`

- **All four states.** `ACTIVE` + published → `302`; `UNASSIGNED`, `RETIRED` and unknown → `200`.
- **⚠ No self-redirect.** Assert the `Location` header is **not** the request URL, and that it does
  **not** contain `/r/`. Then assert it equals
  `${MIRAGE_PUBLIC_BASE_URL}/${mirageRestaurantId}` exactly. Without this test the C6 loop is
  invisible in unit tests and only shows up as a browser redirect-limit error on a phone in a
  restaurant.
- **An activated but unpublished catalog** (no `mirageRestaurantId`) renders `NOT_YET_LIVE`,
  never a `302` to a broken URL.
- **Never JSON.** For all three HTML outcomes assert `Content-Type` starts with `text/html` **and**
  that the body does not parse as JSON. Do this as an explicit assertion, not as a snapshot — this
  is the brief's non-negotiable and it should fail loudly.
- **A thrown error still renders the fallback.** `vi.spyOn(QrCode, 'findOne')` to throw; assert
  `200`, `text/html`, and that the body contains the error copy. **This is the single most important
  test in the stage** — it is the only one that proves the carve-out actually catches.
- **Unknown and unassigned are indistinguishable.** Assert identical status, identical
  `Content-Type` and identical body bytes for an unminted code and a minted-but-unassigned one.
- **A scan failure does not break the redirect.** Make `QrScanDaily.updateOne` reject; assert the
  `302` still happens with the correct `Location`.
- **Scan attribution.** Activate code → scan → reassign to a second catalog → scan. Assert two
  `QrScanDaily` rows exist with different `assignmentId`s and the first row's count is unchanged.
- **Malformed input never queries.** `vi.spyOn(QrCode, 'findOne')`; request `/r/!!!` and `/r/ABC`;
  assert the spy was never called and both returned the fallback.
- **Case and hyphen insensitivity.** `/r/abcd-2345` resolves the code stored as `ABCD2345`.
- **No-store.** Assert `Cache-Control: no-store` on both the redirect and every fallback.
- **`302`, not `301`.** Assert the exact status code.

---

## Done when

- [ ] `app.use('/r', publicRouter)` is mounted before `notFound`.
- [ ] The AGENTS.md carve-out subsection is written.
- [ ] All four code states return the documented response.
- [ ] The redirect target is derived from `mirageRestaurantId`, **never** from `publicUrl`, and a
      test asserts the `Location` contains no `/r/` (C6).
- [ ] A forced internal error renders HTML, not JSON — proven by a test.
- [ ] Unknown and unassigned are byte-identical responses.
- [ ] No fallback page makes an external request (grep the rendered HTML for `http`).
- [ ] Scan recording cannot fail the redirect.
- [ ] Manual check on a real phone: mint a code, print or display
      `{PUBLIC_RESOLVER_BASE_URL}/r/{code}` as a QR, scan it with the native camera app, land on the
      "not live yet" page. Do this on **both** iOS and Android — the native camera scanners differ
      in how they follow redirects.
- [ ] `npm run type-check && npm run lint && npm test` — green.

---

## Rollback

Comment out the `app.use('/r', publicRouter)` line and redeploy. Every printed standee then
`404`s to the JSON envelope — ugly, but no data is affected. If codes are already in the field,
prefer leaving the router mounted and retiring codes individually over unmounting it.
