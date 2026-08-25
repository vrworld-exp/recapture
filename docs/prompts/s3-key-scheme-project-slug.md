# Implementation prompt — project-slug S3 key scheme

**Branch:** `dev` · **Shipped in:** `2055dc2` (code + AGENTS.md), `b111325` (AWS docs)
**Codebase:** `recapture-api/` only. The Flutter client needs no change — it receives
`keyPrefix` / `keyTemplate` from the upload plan and never builds keys itself.
**Read `AGENTS.md` first.** Where this prompt disagrees with a foundational convention,
AGENTS.md wins — except for the key format itself, which this task deliberately changed.

> **Slug cap: 24.** `PROJECT_SLUG_MAX_LENGTH` shipped at 40 and was lowered to **24** in a
> follow-up. Nothing depends on the number — it is a readability knob, not a correctness
> one — but it is mirrored in four places (the constant, its docstring, `AGENTS.md`, and
> `docs/aws-storage-and-cdn.md`) plus the truncation test, so change them together.
>
> The cap is **not retroactive**: prefixes are persisted on `Job.upload.rawPrefix` at
> creation, so jobs created before the change keep their 40-char slugs. A mixed bucket is
> expected and harmless — nothing reads the slug back.

---

## 1. What changed, in one paragraph

Capture-job S3 keys used to root at `{env}/{userId}/{projectId}/{jobId}/` — three opaque
ids, so identifying a folder in the S3 console meant cross-referencing Mongo first. The
root is now `{env}/{projectSlug}_{projectId}/{jobId}/`: the user's own project name,
slugified, sits in the path as a human label, `{userId}` is dropped, and everything below
the job root is unchanged. `{projectId}` is retained so the path stays unique and
machine-parseable; the slug is decoration that nothing ever reads back.

```
before   {env}/{userId}/{projectId}/{jobId}/…      ← 7-segment image keys
after    {env}/{projectSlug}_{projectId}/{jobId}/… ← 6-segment image keys
```

---

## 2. Decisions locked — do not relitigate

Each of these was argued and settled. The reasons matter more than the conclusions,
because a future "let's shorten the path" will re-open all of them.

| Decision | Why |
| --- | --- |
| **`{env}` stays in the key** | The project-delete path wipes objects *by prefix*. This segment is the only thing stopping a staging deploy from deleting production objects. |
| **`{userId}` leaves the key** | Ownership is enforced in the DB and by the token. A path is not an ACL. The `Job.userId` **field** is untouched — only the path lost it. |
| **Both buckets keep an identical prefix** | `deleteProject` runs `deleteObjectsUnderPrefix` against the same prefix string in `BUCKET_RAW` and `BUCKET_ARTIFACTS`. If the schemes diverge, deletion silently half-works. |
| **`{jobId}` stays** | See §3 — this one is load-bearing for correctness, not tidiness. |
| **Ids stay full-length hex** | They are what make prefix-scoped list/count/delete safe to reason about. |
| **The slug may appear in public CloudFront URLs** | Accepted, conscious tradeoff. Artifact URLs are unsigned and public, so a project name is visible to anyone holding a model link. Documented in `docs/aws-storage-and-cdn.md` §5. |

---

## 3. Rejected alternatives

Recorded because each looks reasonable until you check what it breaks.

**Drop `{jobId}`.** Rejected — it is the isolation boundary finalize is built on.
`Job` is indexed `{ projectId: 1, createdAt: -1 }` (non-unique) and
`adminProjectsService` resolves the exportable job with `findOne(...).sort({ createdAt: -1 })`,
so multiple jobs per project is a designed-for case, not a hypothetical. Sharing a prefix
between two jobs breaks four things at once:

1. `capture_manifest.json` is one fixed filename at the job root — job #2 overwrites job #1's.
2. `countObjectsUnderPrefix` vs `expectedFilesCount` counts the *other* job's files, so a
   capture missing photos can finalize as complete. Silent corruption, not a loud error.
3. Image filenames are generic (`images/EYE/frame_0001.jpg`) — a direct byte-level overwrite.
4. Deleting one job's prefix destroys every job's data for that project.

**Drop `{projectId}`, keep only the slug.** Rejected — slugs collide. Two users each with
a project named "Kitchen" share a prefix root, and the delete path takes out both.

**Truncate ids to ~8 chars.** Rejected — reintroduces the same collision into a prefix that
gets deleted wholesale. (Also: take the *last* 8, never the first — an ObjectId's leading
4 bytes are a timestamp, so same-second creations share them.)

**Base64url the ObjectIds** (24 hex chars → 16). Rejected — it costs the exact property
this change was made to buy: you can no longer copy an id out of the path and paste it
straight into a Mongo query.

**Shorten `{env}`** (`staging` → `stg`). Rejected — saves 4 characters in one environment
and invalidates existing staging keys to do it.

> **The framing to keep:** the slug is decoration; the ids are load-bearing. Nothing reads
> the slug, so it can be stale, truncated, or empty without consequence. Every id in the
> path is what makes a prefix-scoped operation safe.

**Worth revisiting only if environments get split for other reasons:** move `{env}` out of
the key and into per-environment buckets. A bucket boundary is a strictly stronger firewall
than a prefix — a misconfigured deploy physically cannot reach prod objects. Costs six
buckets and a CloudFront distribution per environment; not worth it for five characters
alone.

---

## 4. The slug — `projectNameSlug()`

Pure and deterministic (no clock, no randomness), so one name always yields one key.

- lowercase; NFKD-normalize and strip combining marks (`Café` → `cafe`)
- any run outside `[a-z0-9_]` collapses to a single `-`
- leading/trailing `-`/`_` stripped — `requireSegment` demands an alphanumeric first char
- truncate to `PROJECT_SLUG_MAX_LENGTH`, then re-strip so truncation cannot leave a
  trailing separator
- **empty result is legal** — an all-emoji name is a real input and must not throw

`_` deliberately survives slugification, because the project segment is split on its
**last** underscore and project ids are ObjectId hex (`[a-f0-9]{24}`, never an underscore).
`.` deliberately does **not** survive — a leading dot is how `..` traversal starts.

| `Project.name` | Slug | Rule |
| --- | --- | --- |
| `Wooden Dining Table` | `wooden-dining-table` | spaces → `-` |
| `Rahul's Café Chair!` | `rahul-s-cafe-chair` | diacritics folded, punctuation → `-` |
| `2nd Floor Lamp` | `2nd-floor-lamp` | leading digit is fine |
| `table_v2` | `table_v2` | `_` survives; split on the last one |
| `Big Red Kitchen Cabinet Door` | `big-red-kitchen-cabinet` | cut landed on `-`, re-stripped |
| `🪑` | *(empty)* | degrades to a bare `{projectId}`, never a leading `_` |

The composed `{slug}_{projectId}` always passes back through `requireSegment()` — a future
slugifier bug must not be able to emit a traversal.

### Worked example

```
prod/wooden-dining-table_665f1a2b3c4d5e6f70819293/6660c4d5e6f708192a3b4c5d/
├── capture_manifest.json
├── images/{EYE,TOP,LOW}/frame_0001.jpg …
├── model-input/{sessionId}/photo_1.jpg …
└── deleted/images/EYE/frame_0007.jpg
```

Identical prefix in `BUCKET_ARTIFACTS`, plus `models/{modelId}/model.glb|model.usdz|preview.jpg`.
A re-capture of the same project reuses the project segment and gets a **new** `{jobId}`
folder — which is precisely what the `{jobId}` segment exists to provide.

---

## 5. Backward compatibility — no migration

Existing objects stayed where they were. **No backfill, no renames.**

This works because `rawPrefix` and `manifestKey` are built **once** at job creation and
persisted on `Job.upload`; every later read/list/move/delete resolves from those stored
values rather than rebuilding the prefix. Old jobs keep uploading, finalizing, generating,
exporting, and deleting against their old-format keys.

> Rebuilding a prefix for an already-created job would turn a scheme change into data loss.
> If you ever add such a call site, this guarantee is gone.

`parseImageKey` was rewritten for the 6-segment scheme and had no production call sites at
the time — only itself and `tests/`. Old 7-segment keys now parse as a clean
`{ ok: false, reason }`, never a partial parse or a throw.

---

## 6. Out of scope

- **`utils/avatarKeys.ts`** — `{env}/avatars/{userId}/{avatarId}.{ext}` is a separate key
  space with its own parser and its own `SEGMENT_RE`. It **keeps** `{userId}`.
- **The artifact sub-prefix builders** in `meshyModelProcessor.ts` /
  `modelOptimizationProcessor.ts` — they compose from `rawPrefix`, so they needed no change.
- Bucket names, CloudFront config, IAM, `config/s3.ts`.

---

## 7. Verification

```bash
cd recapture-api
npm run type-check   # tsc --noEmit, strict
npm run lint         # no-explicit-any / no-unused-vars are errors
npm test             # tests/s3-keys.test.ts carries the bulk of the new coverage
```

Coverage added for: spaces, diacritics, emoji-only (→ empty, no throw), leading digits,
`/` and `\` (must not survive), a name at `Project.name`'s 100-char maxlength, a name
containing `_`, determinism, `{env}` still config-driven, `parseImageKey(buildImageKey(x)) === x`,
last-underscore split recovering the right `projectId`, old 7-segment keys failing cleanly,
and both buckets receiving the identical prefix.

---

## 8. Related

- **`AGENTS.md` §S3 key scheme** — normative conventions.
- **`docs/aws-storage-and-cdn.md`** — the storage/CDN system in full: buckets, presigning,
  CloudFront, the flows, troubleshooting. §4.1 covers this key space.
- **Known stale:** `docs/prompts/profile-avatar-prompt.md:93` still describes
  `parseImageKey` as "a strict 7-segment parser." It is 6 now. That file is a historical
  prompt, so the reference is wrong-but-harmless; fix it if you touch that doc.
