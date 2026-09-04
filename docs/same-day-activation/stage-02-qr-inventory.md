✅✅✅✅✅✅✅✅

# Stage 2 — QR Inventory and Admin Batch Minting

**Side:** backend · **Size:** M (≈ 1 day) · **Depends on:** stage 1

---

## Goal

At the end of this stage a meaningless, permanent 8-character code can be minted in bulk, exported
as a CSV the print vendor can consume, and looked up. Codes are `UNASSIGNED` and resolve to nothing
— stage 3 gives them a public URL and stage 4 gives them a catalog. This is pure inventory.

The whole design rests on one sentence: **the code is meaningless and permanent; the mapping is
what moves.** Never derive a code from a catalog id, a restaurant name, a batch number, or a
counter. If a code can be guessed, the resolver becomes an enumeration oracle over every restaurant
on the platform.

---

## Prerequisites

- Stage 1 ticked (needs `QR_BATCH_MAX_SIZE` and `PUBLIC_RESOLVER_BASE_URL` in `env.ts`).

---

## Verified context

| Fact | Where |
|---|---|
| `admin.ts` mounts `requireAuth` then `requireRole('MODEL_ARTIST')` at router level | `src/routes/admin.ts:58-59` |
| Destructive admin routes add `requireRole('ADMIN')` inline as the second arg | `src/routes/admin.ts:241-243, 326-328` |
| Soft-delete via a `deletedAt` field is the house convention | `src/models/Catalog.ts:139-141`, every catalog model |
| `consumeRateWindow(key, max, windowSeconds, now?)`, keys pre-namespaced and PII-free | `src/utils/rateLimit.ts:14` |
| The standard envelope and Zod `validate` middleware | `src/middleware/validate.ts`, `src/middleware/errorHandler.ts` |
| Analytics events are exhaustive by `satisfies` — a missing schema is a compile error | `src/validation/analyticsSchemas.ts` |

---

## Steps

### 1. The code alphabet and generator

**New file:** `recapture-api/src/utils/qrCodes.ts`

Crockford base32 minus the ambiguous glyphs, so a code read off a printed standee by a human cannot
be mistyped into a *different valid* code:

```ts
/**
 * Crockford base32 with I, L, O and U removed.
 *
 * I/L collide with 1, O with 0, and U is dropped so a random 8-char draw cannot
 * spell an unfortunate word. 32 symbols is deliberate: 8 chars is 32^8 ≈ 1.1e12
 * codes, so a batch of 100k occupies under one ten-millionth of the space and a
 * guess is not a viable attack on the resolver.
 */
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
export const QR_CODE_LENGTH = 8;

/**
 * Rejection sampling over crypto.randomBytes — NOT `byte % 32`.
 *
 * 256 is divisible by 32, so modulo happens to be uniform for THIS alphabet;
 * the rejection loop is here so that shortening the alphabet later (dropping a
 * glyph that turns out to misprint) cannot silently introduce bias.
 */
export function generateQrCode(): string { /* … */ }

/**
 * Normalises user input to the stored form: uppercase, whitespace and hyphens
 * stripped. A standee may be printed as `ABCD-2345` for legibility while the
 * stored code is `ABCD2345`.
 *
 * Returns null for anything that is not exactly QR_CODE_LENGTH alphabet
 * characters after normalisation — so a malformed code never reaches the DB as
 * a query, which is what keeps the resolver's not-found path cheap.
 */
export function normalizeQrCode(raw: string): string | null { /* … */ }
```

Store and index the **normalised uppercase** form. Do not use a case-insensitive collation: a
collation makes the unique index's behaviour depend on server configuration, and this index is the
only thing preventing two standees from carrying the same code.

### 2. Three new collections

**New file:** `recapture-api/src/models/QrCode.ts` — the printed inventory item.

| Field | Type | Notes |
|---|---|---|
| `code` | `string` | Unique, uppercase, `QR_CODE_LENGTH` chars |
| `batchId` | `ObjectId` | The mint that produced it |
| `state` | `'UNASSIGNED' \| 'ACTIVE' \| 'RETIRED'` | Default `UNASSIGNED` |
| `catalogId` | `ObjectId?` | The **current** pointer. Many-to-one — see below |
| `activatedAt` | `Date?` | |
| `activatedByUserId` | `ObjectId?` | The rep, for audit |
| `deletedAt` | `Date \| null` | House soft-delete |

Indexes: `{code:1}` unique · `{catalogId:1, state:1}` · `{batchId:1, state:1}`.

Put the state vocabulary in `src/models/types/qr.types.ts` beside the other model type files, for
the same reason `catalog.types.ts` exists: routes, services and (in stage 5) the worker all need
it, and services must not import from the worker.

> **`catalogId` is many-to-one and that is the whole point.** Replacing a lost standee means
> activating a *second* code onto the *same* catalog and retiring the first. `publicUrl` does not
> move, the old code's scan history stays intact, and `assertMappingImmutable` is never challenged.
> Do not add a unique index on `catalogId`.

**New file:** `recapture-api/src/models/QrCodeAssignment.ts` — the mapping ledger.

`qrCodeId` · `catalogId` · `assignedAt` · `unassignedAt?` · `assignedByUserId`.
Index `{qrCodeId:1, assignedAt:-1}` and `{catalogId:1, unassignedAt:1}`.

`QrCode.catalogId` is the current pointer; these rows are the history. Reassignment closes the open
row (`unassignedAt`) and opens a new one — it never edits or deletes a row. This is what makes
reassignment non-destructive and what lets stage 3's scan rollups stay attributed to the mapping
that was live when the scan happened.

**New file:** `recapture-api/src/models/QrScanDaily.ts` — one document per code per day.

`qrCodeId` · `assignmentId` · `day` (a `YYYY-MM-DD` string in UTC) · `count`.
Unique index `{qrCodeId:1, assignmentId:1, day:1}`; secondary `{assignmentId:1, day:1}`.

A rollup rather than per-scan rows because scan volume is unbounded and the resolver must stay fast
— consistent with the no-Redis, DB-backed house pattern. Stage 3 writes it with a single `$inc`
upsert.

`day` is a **string, not a Date**, so the bucket boundary is explicit and cannot drift with server
timezone. Write the timezone choice into the field comment.

### 3. The batch document

**New file:** `recapture-api/src/models/QrBatch.ts`

`label` (free text, e.g. `"Vendor A — Oct 2026, run 3"`) · `count` · `createdByUserId` ·
`createdAt`. That is all. The codes point at the batch, not the reverse.

### 4. The service

**New file:** `recapture-api/src/services/qrCodeService.ts`

```ts
export async function mintBatch(params: {
  count: number;
  label: string;
  createdByUserId: Types.ObjectId;
}): Promise<{ batchId: Types.ObjectId; minted: number }>;

export async function exportBatchCsv(batchId: Types.ObjectId): Promise<string | null>;

export async function findByCode(code: string): Promise<IQrCode | null>;
```

**Minting must survive a duplicate-key collision without losing the batch.** Generate `count` codes,
`insertMany` with `{ ordered: false }`, catch the bulk write error, count the successes, and
regenerate only the collided slots — retrying at most a small fixed number of rounds before giving
up with a clear error. At 8 characters over a 32-symbol alphabet a collision is vanishingly
unlikely, which is exactly why the path must be tested rather than trusted: it will otherwise never
run until the day the inventory is large.

```ts
/**
 * Mints `count` codes in ONE batch, retrying only the slots that collided.
 *
 * insertMany({ordered:false}) is what makes this work: an ordered insert stops
 * at the first duplicate and silently drops the rest of the batch, which would
 * hand the print vendor a short CSV nobody noticed was short.
 */
```

`exportBatchCsv` builds `code,url` rows where the URL is
`${env.PUBLIC_RESOLVER_BASE_URL}/r/${code}`. **Throw a typed error when
`PUBLIC_RESOLVER_BASE_URL` is unset** — a CSV of URLs against a guessed host is worse than no CSV,
because it gets printed onto ten thousand physical standees before anyone notices.

Emit the URL exactly as the resolver will accept it. The vendor's CSV and `catalogQrService`'s
render must produce byte-identical strings; stage 4 writes that same string into `publicUrl`.

### 5. The admin routes

**File:** `recapture-api/src/routes/admin.ts` — extend, do not create a new router

```ts
router.post(
  '/qr-batches',
  requireRole('ADMIN'),        // inline, on top of the router-level MODEL_ARTIST gate
  validate(mintQrBatchSchema),
  asyncHandler(async (req, res) => { /* … */ })
);

router.get(
  '/qr-batches/:batchId/export',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => { /* … */ })
);
```

`POST /admin/qr-batches` takes `{count, label}` and returns `{batchId, minted}` in the standard
envelope. Validate `count` against `env.QR_BATCH_MAX_SIZE` in the Zod schema, not in the handler,
so the bound is visible to anyone reading `src/validation/qrSchemas.ts`.

`GET /admin/qr-batches/:batchId/export` returns `text/csv` with a
`Content-Disposition: attachment; filename="qr-batch-<label-slug>.csv"`. `Content-Disposition` is
already in the CORS `exposedHeaders` allowlist (`src/app.ts:46`) for the catalog QR download, so the
web client can read the filename with no CORS change.

> This partially answers **Q12** in `../next-phase/06-open-questions.md` (print-ready sticker sheet
> vs single code): the vendor gets a CSV and prints at scale, so no sheet renderer is needed.
> Note that in the answer to Q12.

### 6. Validation and analytics

**New file:** `recapture-api/src/validation/qrSchemas.ts` — `mintQrBatchSchema`, plus a reusable
`qrCodeParam` refinement built on `normalizeQrCode` that stages 3 and 4 both import.

**File:** `recapture-api/src/validation/analyticsSchemas.ts` — add
`QR_BATCH_MINTED: 'qr_batch_minted'` with props `{actor_id_hash, batch_size}`. The file is
exhaustive by `satisfies`, so a missing schema is a compile error — you will be told if you forget.
Hash the actor via `utils/otp.ts::hashIdentifier`, per the house rule. **No code value ever goes
into an analytics prop** — a code is a public identifier for a specific restaurant's menu.

---

## Tests to write

**New file:** `recapture-api/tests/qr-minting.test.ts` — per-file `MongoMemoryServer`, matching the
existing suites.

- **Alphabet.** Over a few thousand generated codes, every character is in the alphabet and no `I`,
  `L`, `O` or `U` ever appears. Assert length is exactly `QR_CODE_LENGTH`.
- **Normalisation.** `abcd-2345`, `ABCD 2345` and `abcd2345` all normalise to `ABCD2345`;
  `ABCD234` (short), `ABCD23456` (long) and `ABCDI234` (excluded glyph) all return `null`.
- **The unique index is real.** Two `QrCode` documents with the same `code` — the second insert
  must be rejected by the index, not by application code.
- **Collision retry.** Stub the generator to return one fixed code for the first two draws, then
  distinct ones. Mint a batch of 5 and assert exactly 5 distinct codes exist and the batch reports
  `minted: 5`. **This is the test that matters** — without it the retry path never runs.
- **`ordered: false` semantics.** Directly exercise the insert path with a pre-seeded duplicate and
  assert the non-colliding codes still landed.
- **Export refuses without config.** With `PUBLIC_RESOLVER_BASE_URL` unset, `exportBatchCsv`
  throws; it does not emit `undefined/r/ABCD2345`.
- **Export shape.** With it set, every row is `code,url`, the URL is
  `{base}/r/{code}`, and the row count equals the batch count.
- **Role gate.** `MODEL_ARTIST` gets `403` on both new routes (they are ADMIN-only despite the
  router-level MODEL_ARTIST mount); `USER` gets `403`; `ADMIN` succeeds.
- **`count` bound.** `count: env.QR_BATCH_MAX_SIZE + 1` is a `400` from validation, before any DB
  write — assert the collection is still empty afterwards.

---

## Done when

- [ ] `QrCode`, `QrCodeAssignment`, `QrScanDaily`, `QrBatch` exist with every listed index, and
      `tsc --noEmit` is clean.
- [ ] A code is 8 chars, drawn from the reduced alphabet, and never derived from anything.
- [ ] `POST /admin/qr-batches {count:50, label:"smoke"}` mints 50 `UNASSIGNED` codes as ADMIN and
      `403`s as `MODEL_ARTIST`.
- [ ] `GET /admin/qr-batches/:id/export` returns 50 CSV rows with a working
      `Content-Disposition` filename.
- [ ] Q12 in `../next-phase/06-open-questions.md` is annotated with the CSV answer.
- [ ] `npm run type-check && npm run lint && npm test` — green.

---

## Rollback

Additive only — four new collections, two new admin routes, one new util. Nothing existing reads
them. Revert the commit; optionally drop the four collections. No catalog, product or user document
is touched by this stage.
